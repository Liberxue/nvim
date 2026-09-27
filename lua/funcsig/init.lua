-- funcsig: keeps the enclosing function's signature in the winbar.
--
-- Reads treesitter rather than the LSP. A local syntax query sends no request
-- and does not care whether the index is ready, so recomputing it on every
-- cursor move costs rust-analyzer nothing.

local M = {}

local config = {
  sep = "  ·  ", -- between the impl context and the signature
  max_ratio = 1.0, -- fraction of the window width the bar may use
}

local HLS = {
  FuncSigText = { link = "Function" },
  FuncSigCtx = { link = "Comment" },
}

-- Node types that count as a function, across languages
local FN = {
  function_item = true, -- rust
  function_declaration = true, -- go / js / zig
  function_definition = true, -- c / cpp / python / lua
  method_declaration = true, -- go / java
  method_definition = true, -- js / ts
  local_function = true, -- lua
  function_expression = true,
  arrow_function = true,
}
-- Closures are a fallback, used only when no named function encloses the cursor
local CLOSURE = { closure_expression = true, lambda = true }
-- One level further up: the impl, class or trait the function belongs to
local CTX = {
  impl_item = true,
  trait_item = true,
  class_declaration = true,
  class_definition = true,
  struct_item = true,
}

local enabled = true
local cache = {} -- winid -> {buf, lnum, tick, text}

local function node_text(buf, node)
  local sr, sc, er, ec = node:range()
  local ok, lines = pcall(vim.api.nvim_buf_get_text, buf, sr, sc, er, ec, {})
  if not ok then
    return ""
  end
  return (table.concat(lines, " "):gsub("%s+", " "))
end

--- Function node to just its signature, stopping where the body starts
local function signature(buf, node)
  local body = node:field("body")[1]
  local sr, sc = node:range()
  local er, ec
  if body then
    er, ec = body:range()
  else
    local a, b = node:end_()
    er, ec = a, b
  end
  local ok, lines = pcall(vim.api.nvim_buf_get_text, buf, sr, sc, er, ec, {})
  if not ok then
    return nil
  end
  local s = table.concat(lines, " "):gsub("%s+", " ")
  s = s:gsub("%s*[{:]%s*$", "") -- trailing { , or : in python
  s = vim.trim(s)
  return s ~= "" and s or nil
end

local function compute(buf, win)
  local cursor = vim.api.nvim_win_get_cursor(win)
  local ok, node = pcall(vim.treesitter.get_node, {
    bufnr = buf,
    pos = { cursor[1] - 1, math.max(0, cursor[2]) },
  })
  if not ok or not node then
    return nil
  end
  local fn, closure
  local n = node
  while n do
    local t = n:type()
    if FN[t] then
      fn = n
      break
    end
    if CLOSURE[t] and not closure then
      closure = n
    end
    n = n:parent()
  end
  fn = fn or closure
  if not fn then
    return nil
  end
  local sig = signature(buf, fn)
  if not sig then
    return nil
  end
  -- Walk up for an impl or class to prefix the signature with
  local ctx
  local p = fn:parent()
  while p do
    if CTX[p:type()] then
      local ty = p:field("type")[1] or p:field("name")[1]
      if ty then
        ctx = node_text(buf, ty)
      end
      break
    end
    p = p:parent()
  end
  return ctx, sig
end

--- winbar uses statusline syntax, so % has to be escaped
local function esc(s)
  return (s:gsub("%%", "%%%%"))
end

local function eligible(buf)
  return vim.bo[buf].buftype == "" and vim.api.nvim_buf_get_name(buf) ~= ""
end

function M.refresh()
  if not enabled then
    return
  end
  local win = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_get_config(win).relative ~= "" then
    return -- floating windows have no winbar
  end
  local buf = vim.api.nvim_win_get_buf(win)
  if not eligible(buf) then
    return
  end
  local lnum = vim.api.nvim_win_get_cursor(win)[1]
  local tick = vim.b[buf].changedtick
  local c = cache[win]
  if c and c.buf == buf and c.lnum == lnum and c.tick == tick then
    return
  end

  local ctx, sig = compute(buf, win)
  local text
  if sig then
    local width = math.floor(vim.api.nvim_win_get_width(win) * config.max_ratio) - 2
    local full = (ctx and (ctx .. config.sep) or "") .. sig
    if vim.fn.strdisplaywidth(full) > width then
      full = vim.fn.strcharpart(full, 0, math.max(0, width - 1)) .. "…"
    end
    if ctx then
      text = "%#FuncSigCtx#" .. esc(ctx .. config.sep) .. "%#FuncSigText#" .. esc(sig) .. "%*"
    else
      text = "%#FuncSigText#" .. esc(full) .. "%*"
    end
  end
  cache[win] = { buf = buf, lnum = lnum, tick = tick, text = text }
  vim.wo[win].winbar = text
end

function M.clear()
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(w) and vim.api.nvim_win_get_config(w).relative == "" then
      pcall(function()
        vim.wo[w].winbar = nil
      end)
    end
  end
  cache = {}
end

function M.toggle()
  enabled = not enabled
  if enabled then
    M.refresh()
    vim.notify("funcsig: on", vim.log.levels.INFO)
  else
    M.clear()
    vim.notify("funcsig: off", vim.log.levels.INFO)
  end
end

function M.setup(opts)
  config = vim.tbl_deep_extend("force", config, opts or {})
  local function defhl()
    for name, val in pairs(HLS) do
      vim.api.nvim_set_hl(0, name, vim.tbl_extend("force", val, { default = true }))
    end
  end
  defhl()
  vim.api.nvim_create_autocmd("ColorScheme", { callback = defhl })
  local g = vim.api.nvim_create_augroup("funcsig", { clear = true })
  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI", "BufEnter", "WinEnter", "BufWritePost" }, {
    group = g,
    callback = function()
      pcall(M.refresh)
    end,
  })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = g,
    callback = function(a)
      cache[tonumber(a.match)] = nil
    end,
  })
  vim.api.nvim_create_user_command("FuncSigToggle", M.toggle, { desc = "Toggle the function signature winbar" })
end

return M
