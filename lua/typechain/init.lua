-- typechain: 显示光标所在行每个子表达式的类型
--
-- 关键点: LSP 标准的 textDocument/hover 只接受一个「位置」, 在
-- `line.split(',').map(f).collect()` 上无论点哪里都只会得到 `line` 的类型.
-- rust-analyzer 支持一个非标准扩展 —— position 传一个 Range 时, 返回的是
-- 那一段表达式的类型. 本模块就是靠这个把整条链拆出来的.
--
-- 子表达式由 treesitter 提供, 所以换语言只要改 IGNORE/ACCEPT 规则.

local M = {}

local config = {
  max_items = 16, -- 一行最多查多少个子表达式
  max_width = 110,
  max_expr = 44, -- 表达式文本显示宽度上限
  timeout = 3000,
}

local HLS = {
  TypeChainNormal = { link = "NormalFloat" },
  TypeChainBorder = { link = "FloatBorder" },
  TypeChainExpr = { link = "Identifier" },
  TypeChainArrow = { link = "Comment" },
  TypeChainType = { link = "Type" },
  TypeChainTree = { link = "NonText" },
  TypeChainDim = { link = "Comment" },
}

local ns = vim.api.nvim_create_namespace("typechain")

---------------------------------------------------------------------------

local function dw(s)
  return vim.fn.strdisplaywidth(s)
end

local function cut(text, width)
  if width <= 0 then
    return ""
  end
  if dw(text) <= width then
    return text
  end
  local lo, hi = 0, vim.fn.strchars(text)
  while lo < hi do
    local mid = math.floor((lo + hi + 1) / 2)
    if dw(vim.fn.strcharpart(text, 0, mid)) <= width then
      lo = mid
    else
      hi = mid - 1
    end
  end
  return vim.fn.strcharpart(text, 0, lo) .. "…"
end

--- treesitter 给的是字节列, LSP 可能要 utf-16
local function to_enc(buf, line, byte_col, enc)
  if enc == "utf-8" then
    return byte_col
  end
  local text = vim.api.nvim_buf_get_lines(buf, line, line + 1, false)[1] or ""
  local ok, idx = pcall(vim.str_utfindex, text, enc, byte_col)
  if ok then
    return idx
  end
  ok, idx = pcall(vim.str_utfindex, text, byte_col)
  return ok and idx or byte_col
end

--- 从 hover 结果里抠出类型
local function extract_type(contents)
  local v = type(contents) == "string" and contents or (contents and contents.value or "")
  if v == "" then
    return nil
  end
  local block = v:match("```%a*\n(.-)```")
  if not block then
    return vim.trim((v:gsub("%s+", " ")))
  end
  block = vim.trim(block)
  -- ```text\nType: &str\nCoerced to: &str\n```
  local t = block:match("^Type:%s*([^\n]+)")
  if t then
    local co = block:match("\nCoerced to:%s*([^\n]+)")
    t = vim.trim(t)
    if co and vim.trim(co) ~= t then
      t = t .. "  (coerced → " .. vim.trim(co) .. ")"
    end
    return t
  end
  return (vim.trim(block):gsub("%s*\n%s*", " "))
end

---------------------------------------------------------------------------
-- 选出这一行上值得查的子表达式
---------------------------------------------------------------------------

local ACCEPT = {
  call_expression = true,
  method_call_expression = true,
  field_expression = true,
  binary_expression = true,
  unary_expression = true,
  reference_expression = true,
  index_expression = true,
  try_expression = true,
  await_expression = true,
  parenthesized_expression = true,
  struct_expression = true,
  macro_invocation = true,
  identifier = true,
  scoped_identifier = true,
  self = true,
  integer_literal = true,
  string_literal = true,
  float_literal = true,
  boolean_literal = true,
}

local function collect(buf, lnum)
  local ok, parser = pcall(vim.treesitter.get_parser, buf)
  if not ok or not parser then
    return {}
  end
  local root = parser:parse()[1]:root()
  local out, seen = {}, {}

  local function walk(n)
    local sr, sc, er, ec = n:range()
    if sr > lnum or er < lnum then
      return
    end
    -- 只要完整落在这一行里的节点, 跨行的表达式没法在一行里展示
    if sr == lnum and er == lnum and ACCEPT[n:type()] then
      local parent = n:parent()
      local pt = parent and parent:type() or ""
      local skip = false
      -- `line.split` 这种「调用的函数部分」, 类型和它的接收者链完全一样, 是冗余
      if n:type() == "field_expression" and pt == "call_expression" then
        skip = true
      end
      -- `str::trim` 里的 `str` / `trim`
      if pt == "scoped_identifier" then
        skip = true
      end
      -- 字段名本身(.split 的 split)
      if parent and parent:field("field")[1] == n then
        skip = true
      end
      local key = sc .. ":" .. ec
      if not skip and not seen[key] then
        seen[key] = true
        out[#out + 1] = { sc = sc, ec = ec, type_ = n:type() }
      end
    end
    for ch in n:iter_children() do
      walk(ch)
    end
  end
  walk(root)

  table.sort(out, function(a, b)
    if a.sc ~= b.sc then
      return a.sc < b.sc
    end
    return a.ec < b.ec
  end)
  return out
end

---------------------------------------------------------------------------

local win, buf

function M.close()
  if win and vim.api.nvim_win_is_valid(win) then
    pcall(vim.api.nvim_win_close, win, true)
  end
  win, buf = nil, nil
end

--- rows: { {parts = {{text, hl}, ...}}, ... }
local function show(rows)
  M.close()
  local texts, spans = {}, {}
  for i, r in ipairs(rows) do
    local t, sp, col = "", {}, 0
    for _, p in ipairs(r) do
      sp[#sp + 1] = { col, col + #p[1], p[2] }
      t = t .. p[1]
      col = col + #p[1]
    end
    texts[i], spans[i] = " " .. t, sp
  end
  local w = 0
  for _, t in ipairs(texts) do
    w = math.max(w, dw(t))
  end
  w = math.min(w + 1, config.max_width, vim.o.columns - 4)
  local h = math.min(#texts, math.max(3, math.floor(vim.o.lines * 0.5)))

  buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, texts)
  vim.bo[buf].modifiable = false
  for i, sp in ipairs(spans) do
    for _, s in ipairs(sp) do
      pcall(vim.api.nvim_buf_set_extmark, buf, ns, i - 1, s[1] + 1, {
        end_col = s[2] + 1,
        hl_group = s[3],
        priority = 200,
      })
    end
  end

  -- 光标下方放不下就翻到上方
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
    zindex = 150,
    title = " 表达式类型链 ",
    title_pos = "left",
  })
  vim.wo[win].wrap = false
  vim.wo[win].winhighlight = "Normal:TypeChainNormal,FloatBorder:TypeChainBorder"

  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI", "InsertEnter", "BufLeave", "WinScrolled" }, {
    once = true,
    callback = M.close,
  })
end

---------------------------------------------------------------------------

function M.open()
  local b = vim.api.nvim_get_current_buf()
  local client = vim.lsp.get_clients({ bufnr = b, method = "textDocument/hover" })[1]
  if not client then
    vim.notify("typechain: 当前缓冲区没有挂载支持 hover 的 LSP", vim.log.levels.WARN)
    return
  end
  local lnum = vim.api.nvim_win_get_cursor(0)[1] - 1
  local src = vim.api.nvim_buf_get_lines(b, lnum, lnum + 1, false)[1] or ""
  local items = collect(b, lnum)
  if #items == 0 then
    vim.notify("typechain: 这一行没有可查询的表达式", vim.log.levels.INFO)
    return
  end
  if #items > config.max_items then
    items = vim.list_slice(items, 1, config.max_items)
  end

  local enc = client.offset_encoding or "utf-16"
  local td = vim.lsp.util.make_text_document_params(b)
  local pending = #items
  local done = false

  local function render()
    local rows, stack = {}, {}
    for _, it in ipairs(items) do
      local text = src:sub(it.sc + 1, it.ec)
      -- 链式调用: 和上一条同起点且是它的扩展时, 缩进并只显示增量
      local depth, disp = 0, text
      for j = #stack, 1, -1 do
        local prev = stack[j]
        if prev.sc == it.sc and #prev.text < #text and text:sub(1, #prev.text) == prev.text then
          depth = prev.depth + 1
          disp = text:sub(#prev.text + 1)
          break
        end
      end
      stack[#stack + 1] = { sc = it.sc, text = text, depth = depth }

      local parts = {}
      if depth > 0 then
        parts[#parts + 1] = { string.rep("  ", depth - 1) .. "└ ", "TypeChainTree" }
      end
      parts[#parts + 1] = { cut(disp, config.max_expr), "TypeChainExpr" }
      local pad = config.max_expr + 4 - dw(parts[#parts][1]) - (depth > 0 and (depth - 1) * 2 + 2 or 0)
      parts[#parts + 1] = { string.rep(" ", math.max(1, pad)), "TypeChainNormal" }
      parts[#parts + 1] = { "→ ", "TypeChainArrow" }
      parts[#parts + 1] = it.ty and { it.ty, "TypeChainType" } or { "…", "TypeChainDim" }
      rows[#rows + 1] = parts
    end
    show(rows)
  end

  for _, it in ipairs(items) do
    local params = {
      textDocument = td,
      position = {
        start = { line = lnum, character = to_enc(b, lnum, it.sc, enc) },
        ["end"] = { line = lnum, character = to_enc(b, lnum, it.ec, enc) },
      },
    }
    client:request("textDocument/hover", params, function(err, result)
      pending = pending - 1
      if not err and result then
        it.ty = extract_type(result.contents)
      end
      if not done and (pending == 0) then
        done = true
        render()
      end
    end, b)
  end

  -- 慢的话先把已有的画出来, 别干等
  vim.defer_fn(function()
    if not done then
      done = true
      render()
    end
  end, config.timeout)
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
  vim.api.nvim_create_user_command("TypeChain", M.open, { desc = "显示当前行每个子表达式的类型" })
end

return M
