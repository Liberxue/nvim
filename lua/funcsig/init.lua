-- funcsig: 在窗口顶部常驻显示「光标当前在哪个函数里、它返回什么」
--
-- 用 treesitter 而不是 LSP: 纯本地语法查询, 不发请求、不受索引状态影响,
-- 光标移动时重算也不会给 rust-analyzer 添负担.

local M = {}

local config = {
  sep = "  ·  ", -- impl 与 fn 之间的分隔
  max_ratio = 1.0, -- 最多占窗口宽度的多少
}

local HLS = {
  FuncSigText = { link = "Function" },
  FuncSigCtx = { link = "Comment" },
}

-- 各语言里「函数」节点的类型名
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
-- 闭包只在找不到真正的函数时兜底
local CLOSURE = { closure_expression = true, lambda = true }
-- 往上再找一层的上下文(impl / class / trait)
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

--- 函数节点 → 只要签名那段(到 body 之前)
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
  s = s:gsub("%s*[{:]%s*$", "") -- 去掉结尾的 { 或 python 的 :
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
  -- 再往上找 impl / class 之类的上下文
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

--- winbar 走的是 statusline 语法, % 必须转义
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
    return -- 浮窗不管
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
    vim.notify("funcsig: 已开启", vim.log.levels.INFO)
  else
    M.clear()
    vim.notify("funcsig: 已关闭", vim.log.levels.INFO)
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
  vim.api.nvim_create_user_command("FuncSigToggle", M.toggle, { desc = "开关顶部函数签名栏" })
end

return M
