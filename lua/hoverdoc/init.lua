-- hoverdoc: signature and documentation for the symbol under the cursor,
-- shown when the cursor rests.
--
-- K already opens the full hover window. This one is deliberately smaller: the
-- signature, which carries the return type, and the first few lines of prose.
-- It never takes focus, so it stays out of the way while reading.
--
-- The hold interval is 'updatetime', which LazyVim sets to 200ms.

local M = {}

local uv = vim.uv or vim.loop

local config = {
  delay = 150, -- ms after CursorHold before asking, to absorb fast movement
  max_width = 100,
  max_height = 16,
  doc_lines = 6, -- prose lines before truncating
  ignore_ft = { codemap = true, help = true, ["neo-tree"] = true, snacks_picker_list = true },
}

local HLS = {
  HoverDocNormal = { link = "NormalFloat" },
  HoverDocBorder = { link = "FloatBorder" },
  HoverDocSig = { link = "Function" },
  HoverDocPath = { link = "Comment" },
  HoverDocText = { link = "NormalFloat" },
  HoverDocDim = { link = "Comment" },
}

local ns = vim.api.nvim_create_namespace("hoverdoc")

local win, buf
local timer
local last ---@type table|nil {win, line, col, word}
local enabled = true

---------------------------------------------------------------------------

local function dw(s)
  return vim.fn.strdisplaywidth(s)
end

local function stop_timer()
  if timer then
    timer:stop()
    if not timer:is_closing() then
      timer:close()
    end
    timer = nil
  end
end

function M.close()
  stop_timer()
  if win and vim.api.nvim_win_is_valid(win) then
    pcall(vim.api.nvim_win_close, win, true)
  end
  win, buf = nil, nil
end

--- Unpack hover contents without going through util, whose shape has shifted
--- between versions.
local function contents_lines(contents)
  local out = {}
  local function push(s)
    vim.list_extend(out, vim.split(s or "", "\n", { plain = true }))
  end
  if type(contents) == "string" then
    push(contents)
  elseif contents.kind or contents.value then
    push(contents.value)
  else
    for _, c in ipairs(contents) do
      if type(c) == "string" then
        push(c)
      elseif c.language then
        push("```" .. c.language)
        push(c.value)
        push("```")
      else
        push(c.value)
      end
    end
  end
  return out
end

--- Split hover into fenced code blocks and the prose around them.
local function split_hover(contents)
  local blocks, doc, cur = {}, {}, nil
  for _, l in ipairs(contents_lines(contents)) do
    if l:match("^%s*```") then
      if cur then
        blocks[#blocks + 1] = cur
        cur = nil
      else
        cur = {}
      end
    elseif cur then
      cur[#cur + 1] = l
    elseif not l:match("^%s*%-%-%-+%s*$") then
      -- rust-analyzer adds a notable-traits line that says nothing useful here
      if not l:match("^%s*Implements notable traits") then
        if l ~= "" or (#doc > 0 and doc[#doc] ~= "") then
          doc[#doc + 1] = l
        end
      end
    end
  end
  if cur then
    blocks[#blocks + 1] = cur
  end
  while #doc > 0 and doc[#doc] == "" do
    doc[#doc] = nil
  end
  return blocks, doc
end

local function strip_md(s)
  return (s:gsub("%*%*", ""):gsub("`", ""))
end

local function wrap(text, width)
  local out, cur = {}, ""
  for _, w in ipairs(vim.split(text, " ", { plain = true })) do
    local cand = cur == "" and w or (cur .. " " .. w)
    if dw(cand) <= width then
      cur = cand
    else
      if cur ~= "" then
        out[#out + 1] = cur
      end
      cur = w
    end
  end
  if cur ~= "" then
    out[#out + 1] = cur
  end
  return out
end

---------------------------------------------------------------------------

--- rows: { {text, hl}, ... }
local function show(rows)
  M.close()
  if #rows == 0 then
    return
  end
  local w = 0
  for _, r in ipairs(rows) do
    w = math.max(w, dw(r[1]))
  end
  w = math.min(w + 2, config.max_width, vim.o.columns - 4)
  local h = math.min(#rows, config.max_height)

  buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.api.nvim_buf_set_lines(
    buf,
    0,
    -1,
    false,
    vim.tbl_map(function(r)
      return " " .. r[1]
    end, rows)
  )
  vim.bo[buf].modifiable = false
  for i, r in ipairs(rows) do
    pcall(vim.api.nvim_buf_set_extmark, buf, ns, i - 1, 0, {
      end_line = i - 1,
      end_col = #(" " .. r[1]),
      hl_group = r[2] or "HoverDocNormal",
      priority = 200,
    })
  end

  -- Below the cursor when there is room, above otherwise, so the line being
  -- read stays visible either way.
  local below = vim.fn.winheight(0) - vim.fn.winline()
  local anchor, row = "NW", 1
  if below < h + 2 and vim.fn.winline() > h + 2 then
    anchor, row = "SW", 0
  end
  win = vim.api.nvim_open_win(buf, false, {
    relative = "cursor",
    anchor = anchor,
    row = row,
    col = 0,
    width = w,
    height = h,
    style = "minimal",
    border = "rounded",
    focusable = false,
    noautocmd = true,
    zindex = 40,
  })
  vim.wo[win].wrap = false
  vim.wo[win].winhighlight = "Normal:HoverDocNormal,FloatBorder:HoverDocBorder"
end

local function render(contents)
  local blocks, doc = split_hover(contents)
  local rows = {}
  -- rust-analyzer answers with [module path, signature]; the signature is last
  if #blocks > 1 then
    rows[#rows + 1] = { vim.trim(table.concat(blocks[1], " ")), "HoverDocPath" }
  end
  if #blocks > 0 then
    for _, l in ipairs(blocks[#blocks]) do
      if l:match("%S") then
        rows[#rows + 1] = { vim.trim(l), "HoverDocSig" }
      end
    end
  end
  if #doc > 0 then
    if #rows > 0 then
      rows[#rows + 1] = { "", "HoverDocDim" }
    end
    local shown = 0
    for _, l in ipairs(doc) do
      for _, wl in ipairs(wrap(strip_md(l), config.max_width - 4)) do
        if shown >= config.doc_lines then
          rows[#rows + 1] = { "...", "HoverDocDim" }
          return rows
        end
        rows[#rows + 1] = { wl, "HoverDocText" }
        shown = shown + 1
      end
    end
  end
  return rows
end

---------------------------------------------------------------------------

local function eligible(b)
  return vim.bo[b].buftype == "" and not config.ignore_ft[vim.bo[b].filetype]
end

local function query(anchor)
  local b = anchor.buf
  local client = vim.lsp.get_clients({ bufnr = b, method = "textDocument/hover" })[1]
  if not client then
    return
  end
  local params = vim.lsp.util.make_position_params(anchor.winid, client.offset_encoding or "utf-16")
  client:request("textDocument/hover", params, function(err, result)
    if err or not result or not result.contents then
      return
    end
    -- The cursor has moved on since the request went out
    if not last or last.line ~= anchor.line or last.col ~= anchor.col then
      return
    end
    local rows = render(result.contents)
    if #rows > 0 then
      show(rows)
    end
  end, b)
end

function M.on_hold()
  if not enabled then
    return
  end
  local w = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_get_config(w).relative ~= "" then
    return -- cursor is inside a floating window
  end
  local b = vim.api.nvim_win_get_buf(w)
  if not eligible(b) then
    return
  end
  -- Nothing to look up on whitespace or punctuation
  if vim.fn.expand("<cword>"):match("^[%w_]") == nil then
    return
  end
  local pos = vim.api.nvim_win_get_cursor(w)
  if last and last.line == pos[1] and last.col == pos[2] and win and vim.api.nvim_win_is_valid(win) then
    return -- already showing this position
  end
  M.close()
  last = { winid = w, buf = b, line = pos[1], col = pos[2] }
  local anchor = last
  stop_timer()
  timer = uv.new_timer()
  timer:start(
    config.delay,
    0,
    vim.schedule_wrap(function()
      stop_timer()
      if last == anchor and vim.api.nvim_win_is_valid(anchor.winid) then
        query(anchor)
      end
    end)
  )
end

function M.toggle()
  enabled = not enabled
  if not enabled then
    M.close()
  end
  vim.notify("hoverdoc: " .. (enabled and "on" or "off"), vim.log.levels.INFO)
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

  local g = vim.api.nvim_create_augroup("hoverdoc", { clear = true })
  vim.api.nvim_create_autocmd("CursorHold", { group = g, callback = M.on_hold })
  vim.api.nvim_create_autocmd("CursorMoved", {
    group = g,
    callback = function()
      local pos = vim.api.nvim_win_get_cursor(0)
      if last and (last.line ~= pos[1] or last.col ~= pos[2]) then
        last = nil
        M.close()
      end
    end,
  })
  for _, ev in ipairs({ "InsertEnter", "BufLeave", "WinScrolled", "CursorMovedI" }) do
    vim.api.nvim_create_autocmd(ev, {
      group = g,
      callback = function()
        last = nil
        M.close()
      end,
    })
  end
  vim.api.nvim_create_user_command("HoverDocToggle", M.toggle, { desc = "Toggle the hover documentation popup" })
end

return M
