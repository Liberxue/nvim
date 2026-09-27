-- codemap: 光标处符号的调用关系脑图
--
-- 数据全部来自 LSP(hover / references / callHierarchy), 不联网、不调模型.
-- 渲染在浮窗里做纯文本布局, 节点按行逐帧淡入(靠 extmark 把前景色从背景色
-- 插值到目标色实现, 所以需要 termguicolors；没开则自动退化为直接显示).

local M = {}

local uv = vim.uv or vim.loop

local config = {
  width = 0.82, -- 浮窗宽度占屏比
  max_width = 120,
  max_height = 0.72, -- 浮窗高度上限占屏比
  doc_lines = 8, -- 文档默认最多显示行数(按 d 展开全部)
  max_depth = 6, -- 调用链展开深度上限
  timeout = 15000, -- 等 LSP 响应的上限, 超时就用已有数据渲染
  animate = true,
  anim = {
    interval = 18, -- 每帧毫秒
    stagger = 1, -- 相邻行错开几帧
    ramp = 6, -- 单行淡入占几帧
  },
}

local HLS = {
  CodeMapNormal = { link = "NormalFloat" },
  CodeMapBorder = { link = "FloatBorder" },
  CodeMapSig = { link = "Function" },
  CodeMapPath = { link = "Comment" },
  CodeMapRule = { link = "WinSeparator" },
  CodeMapSection = { link = "Special" },
  CodeMapCount = { link = "Number" },
  CodeMapTree = { link = "NonText" },
  CodeMapName = { link = "Identifier" },
  CodeMapLoc = { link = "Comment" },
  CodeMapDoc = { link = "NormalFloat" },
  CodeMapFocus = { link = "Visual" },
  CodeMapKey = { link = "Special" },
  CodeMapHelp = { link = "Comment" },
  CodeMapWarn = { link = "WarningMsg" },
}

local ns = vim.api.nvim_create_namespace("codemap")
local st = nil ---@type table|nil 当前打开的面板状态(同时只允许一个)

---------------------------------------------------------------------------
-- 文本宽度工具(extmark 用字节列, 对齐用显示宽度, 中文下两者不等)
---------------------------------------------------------------------------

local function dw(s)
  return vim.fn.strdisplaywidth(s)
end

--- 截断到不超过 width 显示宽度的前缀
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
  return vim.fn.strcharpart(text, 0, lo)
end

---------------------------------------------------------------------------
-- Line: 带高亮分段的一行, 支持拼接 / 补齐 / 截断
---------------------------------------------------------------------------

local Line = {}
Line.__index = Line

function Line.new()
  return setmetatable({ parts = {}, w = 0, b = 0 }, Line)
end

function Line:add(text, hl)
  if text == nil or text == "" then
    return self
  end
  text = tostring(text)
  self.parts[#self.parts + 1] = { text = text, hl = hl or "CodeMapNormal" }
  self.w = self.w + dw(text)
  self.b = self.b + #text
  return self
end

function Line:concat(other)
  for _, p in ipairs(other.parts) do
    self.parts[#self.parts + 1] = p
  end
  self.w = self.w + other.w
  self.b = self.b + other.b
  return self
end

function Line:pad(width, hl)
  if self.w < width then
    self:add(string.rep(" ", width - self.w), hl)
  end
  return self
end

function Line:truncate(width)
  if self.w <= width then
    return self
  end
  local keep, w, b = {}, 0, 0
  local budget = width - 1 -- 给省略号留一格
  for _, p in ipairs(self.parts) do
    local pw = dw(p.text)
    if w + pw <= budget then
      keep[#keep + 1] = p
      w, b = w + pw, b + #p.text
    else
      local t = cut(p.text, budget - w)
      if t ~= "" then
        keep[#keep + 1] = { text = t, hl = p.hl }
        w, b = w + dw(t), b + #t
      end
      break
    end
  end
  keep[#keep + 1] = { text = "…", hl = "CodeMapLoc" }
  self.parts, self.w, self.b = keep, w + 1, b + #"…"
  return self
end

--- @return string text, table spans  spans = { {start_byte, end_byte, hl}, ... }
function Line:build()
  local chunks, spans, col = {}, {}, 0
  for _, p in ipairs(self.parts) do
    spans[#spans + 1] = { col, col + #p.text, p.hl }
    chunks[#chunks + 1] = p.text
    col = col + #p.text
  end
  return table.concat(chunks), spans
end

---------------------------------------------------------------------------
-- 淡入用的插值高亮组
---------------------------------------------------------------------------

local fade_cache = {}

local function hl_attrs(name)
  local ok, h = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
  return ok and h or {}
end

local function default_bg()
  local h = hl_attrs("NormalFloat")
  if h.bg then
    return h.bg
  end
  h = hl_attrs("Normal")
  if h.bg then
    return h.bg
  end
  return vim.o.background == "light" and 0xffffff or 0x000000
end

local function rgb(c)
  return math.floor(c / 65536) % 256, math.floor(c / 256) % 256, c % 256
end

local function blend(fg, bg, a)
  local fr, fg2, fb = rgb(fg)
  local br, bg2, bb = rgb(bg)
  local r = math.floor(br + (fr - br) * a + 0.5)
  local g = math.floor(bg2 + (fg2 - bg2) * a + 0.5)
  local b = math.floor(bb + (fb - bb) * a + 0.5)
  return r * 65536 + g * 256 + b
end

--- 把 group 的前景色往背景色方向插值, level 为 0..ramp
local function fade_group(group, level)
  local ramp = config.anim.ramp
  if level >= ramp then
    return group
  end
  local key = group .. "\0" .. level
  local cached = fade_cache[key]
  if cached then
    return cached
  end
  local bg = default_bg()
  local fg = hl_attrs(group).fg or hl_attrs("Normal").fg or (vim.o.background == "light" and 0x000000 or 0xffffff)
  local name = ("CodeMapFade%s_%d"):format((group:gsub("%W", "")), level)
  vim.api.nvim_set_hl(0, name, { fg = blend(fg, bg, level / ramp) })
  fade_cache[key] = name
  return name
end

---------------------------------------------------------------------------
-- LSP
---------------------------------------------------------------------------

local function pick_client(bufnr)
  local cs = vim.lsp.get_clients({ bufnr = bufnr, method = "textDocument/prepareCallHierarchy" })
  if #cs > 0 then
    return cs[1]
  end
  -- 退一步: 至少能拿 hover 的 client
  cs = vim.lsp.get_clients({ bufnr = bufnr, method = "textDocument/hover" })
  return cs[1]
end

--- 自己拆 hover 的 contents, 绕开各版本 util 的弃用差异
local function hover_lines(contents)
  local out = {}
  local function push(s)
    vim.list_extend(out, vim.split(s or "", "\n", { plain = true }))
  end
  if type(contents) == "string" then
    push(contents)
  elseif vim.islist and vim.islist(contents) or (not contents.kind and not contents.value and contents[1]) then
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
  elseif contents.kind or contents.value then
    push(contents.value)
  end
  return out
end

--- 从 hover 里分出「签名代码块」和「文档正文」
local function parse_hover(result)
  if not result or not result.contents then
    return nil, nil, {}
  end
  local lines = hover_lines(result.contents)
  local blocks, doc, cur = {}, {}, nil
  for _, l in ipairs(lines) do
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
      if l ~= "" or (#doc > 0 and doc[#doc] ~= "") then
        doc[#doc + 1] = l
      end
    end
  end
  if cur then
    blocks[#blocks + 1] = cur
  end
  -- rust-analyzer 会在 hover 里塞一行 "Implements notable traits: ...", 对脑图没用
  doc = vim.tbl_filter(function(l)
    return not l:match("^%s*Implements notable traits")
  end, doc)
  while #doc > 0 and doc[#doc] == "" do
    doc[#doc] = nil
  end
  -- rust-analyzer 的 hover 通常是 [模块路径块, 签名块], 签名取最后一块
  local sig = #blocks > 0 and table.concat(blocks[#blocks], " "):gsub("%s+", " ") or nil
  local modpath = #blocks > 1 and vim.trim(blocks[1][1] or "") or nil
  return sig, modpath, doc
end

--- 保留尾部的截断(路径要看到 file.rs:123, 而不是开头的 ~/.rustup/...)
local function tail(text, width)
  if width <= 0 then
    return ""
  end
  if dw(text) <= width then
    return text
  end
  local n = vim.fn.strchars(text)
  local keep = 0
  for k = 1, n do
    if dw(vim.fn.strcharpart(text, n - k, k)) > width - 1 then
      break
    end
    keep = k
  end
  return "…" .. vim.fn.strcharpart(text, n - keep, keep)
end

local function loc_label(uri, range)
  if not uri then
    return ""
  end
  local path = vim.uri_to_fname(uri)
  local rel = vim.fn.fnamemodify(path, ":.")
  if rel:sub(1, 1) == "/" then
    -- 不在 cwd 下(依赖源码、rustup toolchain): 只留最后两段, 否则一行全是路径
    local parts = vim.split(path, "/", { plain = true })
    local n = #parts
    rel = n >= 2 and ("…/" .. parts[n - 1] .. "/" .. parts[n]) or parts[n]
  end
  local lnum = range and range.start and (range.start.line + 1) or nil
  return lnum and (rel .. ":" .. lnum) or rel
end

local function to_node(item, kind, depth)
  return {
    name = item.name,
    detail = item.detail,
    uri = item.uri,
    range = item.selectionRange or item.range,
    item = item,
    kind = kind,
    depth = depth,
    open = false,
    children = nil,
  }
end

local function request(s, method, params, cb)
  local client = s.client
  if not client then
    return
  end
  s.pending = s.pending + 1
  local ok = client:request(method, params, function(err, result)
    if err then
      s.errors[#s.errors + 1] = ("%s: %s"):format(method, err.message or vim.inspect(err))
    else
      cb(result)
    end
    s.pending = s.pending - 1
    if st ~= s then
      return
    end
    -- 增量渲染: 哪个响应先到就先画哪块. hover 是毫秒级的, 所以签名和文档立刻出来,
    -- references / callHierarchy 这两个要全 workspace 搜索的慢请求在后面自己填进去.
    local first = not s.rendered
    s.rendered = true
    s.loading = false
    M._render(s, first)
  end, s.src_buf)
  if not ok then
    s.pending = s.pending - 1
  end
end

---------------------------------------------------------------------------
-- 布局
---------------------------------------------------------------------------

local function flatten(nodes, depth, prefix, out)
  for i, n in ipairs(nodes) do
    local last = i == #nodes
    n._prefix, n._last, n._depth = prefix, last, depth
    out[#out + 1] = n
    if n.open and n.children then
      flatten(n.children, depth + 1, prefix .. (last and "   " or "│  "), out)
    end
  end
end

--- 一列的所有行；返回 {lines = {Line...}, nav = {node...}}
local function column_lines(s, col, width)
  local lines, nav = {}, {}
  local open = col.open ~= false
  local head = Line.new()
  head:add(open and "▾ " or "▸ ", "CodeMapSection")
  head:add(col.title, "CodeMapSection")
  if col.pending then
    head:add(" (查询中)", "CodeMapLoc")
  else
    head:add(" (" .. #col.nodes .. ")", "CodeMapCount")
  end
  lines[#lines + 1] = head:truncate(width)

  if not open then
    return { lines = lines, nav = nav }
  end
  if #col.nodes == 0 then
    lines[#lines + 1] = Line.new():add(col.pending and "  查询中" or "  (无)", "CodeMapLoc")
    return { lines = lines, nav = nav }
  end

  local flat = {}
  flatten(col.nodes, 0, " ", flat)
  for _, n in ipairs(flat) do
    local l = Line.new()
    l:add(n._prefix, "CodeMapTree")
    if n.children and #n.children > 0 then
      l:add(n.open and "▾ " or "▸ ", "CodeMapTree")
    elseif n.children then
      l:add(n._last and "╰─ " or "├─ ", "CodeMapTree")
    elseif n.loading then
      l:add("◌ ", "CodeMapTree")
    else
      l:add(n._last and "╰─ " or "├─ ", "CodeMapTree")
    end
    l:add(n.name, "CodeMapName")
    local room = width - l.w - 2
    if room >= 10 then
      local loc = tail(loc_label(n.uri, n.range), room)
      if loc ~= "" then
        l:pad(width - dw(loc))
        l:add(loc, "CodeMapLoc")
      end
    end
    lines[#lines + 1] = l:truncate(width)
    nav[#nav + 1] = { node = n, row = #lines }
  end
  return { lines = lines, nav = nav }
end

local function wrap_text(text, width)
  local out, cur = {}, ""
  for _, word in ipairs(vim.split(text, " ", { plain = true })) do
    local cand = cur == "" and word or (cur .. " " .. word)
    if dw(cand) <= width then
      cur = cand
    else
      if cur ~= "" then
        out[#out + 1] = cur
      end
      while dw(word) > width do
        local piece = cut(word, width)
        out[#out + 1] = piece
        word = word:sub(#piece + 1)
      end
      cur = word
    end
  end
  if cur ~= "" then
    out[#out + 1] = cur
  end
  return out
end

local function strip_md(s)
  s = s:gsub("%*%*", ""):gsub("`", "")
  return s
end

--- 把 references 的位置转成带源码文本的可跳转节点. 同步读文件, 所以只在真要显示时调.
local function build_ref_nodes(s)
  if s.ref_nodes then
    return s.ref_nodes
  end
  s.ref_nodes = {}
  local cache = {}
  for i, loc in ipairs(s.ref_locs or {}) do
    if i > 200 then
      break
    end
    local uri = loc.uri or loc.targetUri
    local range = loc.range or loc.targetSelectionRange
    if uri and range then
      local path = vim.uri_to_fname(uri)
      local lines = cache[path]
      if lines == nil then
        lines = vim.fn.filereadable(path) == 1 and vim.fn.readfile(path) or false
        cache[path] = lines
      end
      local lnum = range.start.line + 1
      local text = lines and lines[lnum] and vim.trim(lines[lnum]) or ""
      s.ref_nodes[#s.ref_nodes + 1] = {
        name = text ~= "" and text or vim.fs.basename(path),
        uri = uri,
        range = range,
        kind = "reference",
        depth = 0,
        open = false,
      }
    end
  end
  return s.ref_nodes
end

--- 生成 s.rows: 每行 {text, spans, cells}
local function build_rows(s, W)
  local rows = {}
  local function push(line, cells)
    local text, spans = line:build()
    rows[#rows + 1] = { text = text, spans = spans, cells = cells }
  end
  local function rule(divider_at, glyph)
    local l = Line.new()
    if divider_at then
      l:add(string.rep("─", divider_at), "CodeMapRule")
      l:add(glyph or "┬", "CodeMapRule")
      l:add(string.rep("─", math.max(0, W - divider_at - 1)), "CodeMapRule")
    else
      l:add(string.rep("─", W), "CodeMapRule")
    end
    push(l)
  end

  local inner = W - 2

  if s.loading then
    push(Line.new():add(" 正在向 " .. (s.client and s.client.name or "LSP") .. " 查询", "CodeMapLoc"))
    s.rows, s.nav = rows, { c1 = {}, c2 = {} }
    return
  end

  -- 签名 + 位置
  if s.sig then
    push(Line.new():add(" "):concat(Line.new():add(s.sig, "CodeMapSig")):truncate(W))
  end
  local head = Line.new():add(" ")
  if s.modpath then
    head:add(s.modpath, "CodeMapPath"):add("  ", "CodeMapLoc")
  end
  head:add(loc_label(s.root_uri, s.root_range), "CodeMapLoc")
  if s.refs then
    head:add("  ·  ", "CodeMapLoc"):add(tostring(s.refs), "CodeMapCount"):add(" 处引用", "CodeMapLoc")
  end
  push(head:truncate(W))

  -- 文档
  if #s.doc > 0 then
    rule()
    local shown = {}
    for _, dl in ipairs(s.doc) do
      for _, wl in ipairs(wrap_text(strip_md(dl), inner - 2)) do
        shown[#shown + 1] = wl
      end
    end
    local total = #shown
    local clipped = not s.doc_open and total > config.doc_lines
    local dh = Line.new():add(" ")
    dh:add(s.doc_open and "▾ " or "▸ ", "CodeMapSection"):add("文档", "CodeMapSection")
    if clipped then
      dh:add(("  (共 %d 行, 按 d 看全部)"):format(total), "CodeMapLoc")
    end
    push(dh)
    for i, dl in ipairs(shown) do
      if clipped and i > config.doc_lines then
        break
      end
      push(Line.new():add("   "):add(dl, "CodeMapDoc"):truncate(W))
    end
  end

  -- 光标在非函数符号上时 callHierarchy 是空的, 这时把「使用」摊开成单栏引用列表.
  -- 必须等调用层级确定为空再切, 否则会先闪一下双栏再跳回来.
  local ch_done = s.ch_possible == false or (s.got_in and s.got_out)
  if
    not s.single
    and ch_done
    and s.got_refs
    and #s.cols.c1.nodes == 0
    and #s.cols.c2.nodes == 0
    and #(s.ref_locs or {}) > 0
  then
    s.single = true
    s.cols.c1 = { title = "引用", kind = "reference", nodes = build_ref_nodes(s), open = true }
    s.focus.key, s.focus.idx = "c1", 1
  end

  -- 两列(窄窗、或单栏模式退化成上下堆叠)
  local colw = math.floor((W - 5) / 2)
  local stacked = colw < 24 or s.single
  local nav = { c1 = {}, c2 = {} }

  if stacked then
    for _, key in ipairs(s.single and { "c1" } or { "c1", "c2" }) do
      local col = s.cols[key]
      rule()
      local built = column_lines(s, col, inner)
      local base = #rows
      for _, l in ipairs(built.lines) do
        push(Line.new():add(" "):concat(l):truncate(W), nil)
      end
      for _, item in ipairs(built.nav) do
        local row = base + item.row
        rows[row].cells = { { key = key, s = 1, e = #rows[row].text } }
        nav[key][#nav[key] + 1] = { node = item.node, row = row }
      end
    end
  else
    rule(colw + 1)
    local left = column_lines(s, s.cols.c1, colw)
    local right = column_lines(s, s.cols.c2, colw)
    local n = math.max(#left.lines, #right.lines)
    local base = #rows
    for i = 1, n do
      local l = Line.new():add(" ")
      local ls = l.b
      local lc = left.lines[i] or Line.new()
      l:concat(lc):pad(1 + colw)
      local le = l.b
      l:add(" │ ", "CodeMapRule")
      local rs = l.b
      local rc = right.lines[i] or Line.new()
      l:concat(rc):pad(1 + colw + 3 + colw)
      local re = l.b
      push(l, { { key = "c1", s = ls, e = le }, { key = "c2", s = rs, e = re } })
    end
    for _, item in ipairs(left.nav) do
      nav.c1[#nav.c1 + 1] = { node = item.node, row = base + item.row }
    end
    for _, item in ipairs(right.nav) do
      nav.c2[#nav.c2 + 1] = { node = item.node, row = base + item.row }
    end
    rule(colw + 1, "┴")
  end

  if stacked then
    rule()
  end
  for _, e in ipairs(s.errors) do
    push(Line.new():add(" ! "):add(e, "CodeMapWarn"):truncate(W))
  end

  local help = Line.new():add(" ")
  local function key(k, d)
    help:add(k, "CodeMapKey"):add(" " .. d .. "  ", "CodeMapHelp")
  end
  key("j/k", "移动")
  key("h/l", "换列")
  key("<Tab>", "展开")
  key("<CR>", "跳转")
  key("d", "文档")
  key("r", "刷新")
  key("q", "关闭")
  push(help:truncate(W))

  s.rows, s.nav = rows, nav
end

---------------------------------------------------------------------------
-- 绘制
---------------------------------------------------------------------------

local function focused(s)
  local list = s.nav and s.nav[s.focus.key]
  if not list or #list == 0 then
    return nil
  end
  local idx = math.min(math.max(s.focus.idx, 1), #list)
  s.focus.idx = idx
  return list[idx]
end

local function paint(s, frame)
  if not (s.buf and vim.api.nvim_buf_is_valid(s.buf)) then
    return
  end
  vim.api.nvim_buf_clear_namespace(s.buf, ns, 0, -1)
  local ramp, stagger = config.anim.ramp, config.anim.stagger
  for i, row in ipairs(s.rows) do
    local level = ramp
    if frame then
      level = math.max(0, math.min(ramp, frame - (i - 1) * stagger))
    end
    for _, sp in ipairs(row.spans) do
      local hl = level >= ramp and sp[3] or fade_group(sp[3], level)
      pcall(vim.api.nvim_buf_set_extmark, s.buf, ns, i - 1, sp[1], {
        end_col = sp[2],
        hl_group = hl,
        priority = 200,
      })
    end
  end
  -- 焦点格
  local f = focused(s)
  if f then
    local row = s.rows[f.row]
    for _, cell in ipairs(row and row.cells or {}) do
      if cell.key == s.focus.key then
        pcall(vim.api.nvim_buf_set_extmark, s.buf, ns, f.row - 1, cell.s, {
          end_col = cell.e,
          hl_group = "CodeMapFocus",
          priority = 120,
        })
      end
    end
  end
end

local function stop_anim(s)
  if s.timer then
    s.timer:stop()
    if not s.timer:is_closing() then
      s.timer:close()
    end
    s.timer = nil
  end
end

local function animate(s)
  stop_anim(s)
  local frames = #s.rows * config.anim.stagger + config.anim.ramp
  local frame = 0
  s.timer = uv.new_timer()
  s.timer:start(
    0,
    config.anim.interval,
    vim.schedule_wrap(function()
      if not (s.win and vim.api.nvim_win_is_valid(s.win)) then
        stop_anim(s)
        return
      end
      frame = frame + 1
      paint(s, frame)
      if frame >= frames then
        stop_anim(s)
        paint(s, nil)
      end
    end)
  )
end

function M._render(s, animated)
  if not (s.win and vim.api.nvim_win_is_valid(s.win)) then
    return
  end
  local W = vim.api.nvim_win_get_width(s.win)
  build_rows(s, W)

  local lines = {}
  for i, row in ipairs(s.rows) do
    lines[i] = row.text
  end
  vim.bo[s.buf].modifiable = true
  vim.api.nvim_buf_set_lines(s.buf, 0, -1, false, lines)
  vim.bo[s.buf].modifiable = false

  local maxh = math.max(6, math.floor(vim.o.lines * config.max_height))
  local h = math.min(#lines, maxh)
  pcall(vim.api.nvim_win_set_config, s.win, {
    relative = "editor",
    width = W,
    height = h,
    row = math.max(0, math.floor((vim.o.lines - h) / 2) - 1),
    col = math.floor((vim.o.columns - W) / 2),
  })

  -- 焦点列空了就换到另一列；两列都空则保持原样(否则加载中的空面板会把焦点甩到 c2)
  if #(s.nav[s.focus.key] or {}) == 0 then
    local other = s.focus.key == "c1" and "c2" or "c1"
    if #(s.nav[other] or {}) > 0 then
      s.focus.key = other
      s.focus.idx = 1
    end
  end
  local f = focused(s)
  if f then
    local cell
    for _, c in ipairs(s.rows[f.row].cells or {}) do
      if c.key == s.focus.key then
        cell = c
      end
    end
    pcall(vim.api.nvim_win_set_cursor, s.win, { f.row, cell and cell.s or 0 })
  end

  if animated and config.animate and vim.o.termguicolors then
    animate(s)
  else
    stop_anim(s)
    paint(s, nil)
  end
end

---------------------------------------------------------------------------
-- 交互
---------------------------------------------------------------------------

function M.close()
  local s = st
  st = nil
  if not s then
    return
  end
  stop_anim(s)
  if s.win and vim.api.nvim_win_is_valid(s.win) then
    pcall(vim.api.nvim_win_close, s.win, true)
  end
end

local function move(delta)
  local s = st
  if not s then
    return
  end
  local list = s.nav[s.focus.key] or {}
  if #list == 0 then
    return
  end
  s.focus.idx = math.min(math.max(s.focus.idx + delta, 1), #list)
  M._render(s, false)
end

local function switch_col(key)
  local s = st
  if not s then
    return
  end
  if #(s.nav[key] or {}) == 0 then
    return
  end
  s.focus.key = key
  M._render(s, false)
end

local function toggle_expand()
  local s = st
  if not s then
    return
  end
  local f = focused(s)
  if not f then
    return
  end
  local n = f.node
  if n.children then
    n.open = not n.open
    M._render(s, false)
    return
  end
  if n._depth and n._depth >= config.max_depth then
    vim.notify("codemap: 已到展开深度上限 " .. config.max_depth, vim.log.levels.WARN)
    return
  end
  if s.cols[s.focus.key].kind == "reference" then
    vim.notify("codemap: 引用条目没有下级, 用 <CR> 跳转", vim.log.levels.INFO)
    return
  end
  local method = s.cols[s.focus.key].kind == "incoming" and "callHierarchy/incomingCalls"
    or "callHierarchy/outgoingCalls"
  local field = s.cols[s.focus.key].kind == "incoming" and "from" or "to"
  n.loading = true
  M._render(s, false)
  s.pending = s.pending + 1
  local ok = s.client:request(method, { item = n.item }, function(err, result)
    s.pending = s.pending - 1
    n.loading = false
    if err then
      s.errors[#s.errors + 1] = ("%s: %s"):format(method, err.message or "失败")
    else
      local kids = {}
      for _, call in ipairs(result or {}) do
        kids[#kids + 1] = to_node(call[field], s.cols[s.focus.key].kind, (n._depth or 0) + 1)
      end
      n.children = kids
      n.open = #kids > 0
    end
    if st == s then
      M._render(s, false)
    end
  end, s.src_buf)
  if not ok then
    s.pending = s.pending - 1
    n.loading = false
  end
end

local function jump()
  local s = st
  if not s then
    return
  end
  local f = focused(s)
  if not (f and f.node.uri) then
    return
  end
  local node, win, enc = f.node, s.src_win, s.offset_encoding
  M.close()
  if win and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_set_current_win(win)
  end
  vim.cmd("normal! m'")
  vim.lsp.util.show_document({ uri = node.uri, range = node.range }, enc, { focus = true })
end

local function toggle_doc()
  local s = st
  if not s then
    return
  end
  s.doc_open = not s.doc_open
  M._render(s, false)
end

local function setup_keys(s)
  local function map(lhs, fn)
    vim.keymap.set("n", lhs, fn, { buffer = s.buf, nowait = true, silent = true })
  end
  map("q", M.close)
  map("<Esc>", M.close)
  map("j", function()
    move(1)
  end)
  map("<Down>", function()
    move(1)
  end)
  map("k", function()
    move(-1)
  end)
  map("<Up>", function()
    move(-1)
  end)
  map("h", function()
    switch_col("c1")
  end)
  map("<Left>", function()
    switch_col("c1")
  end)
  map("l", function()
    switch_col("c2")
  end)
  map("<Right>", function()
    switch_col("c2")
  end)
  map("<Tab>", toggle_expand)
  map("<CR>", jump)
  map("d", toggle_doc)
  map("r", function()
    local win = s.src_win
    M.close()
    if win and vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_set_current_win(win)
    end
    M.open()
  end)
  map("g?", function()
    vim.notify(
      "codemap: j/k 移动  h/l 换列  <Tab> 展开/收起  <CR> 跳转  d 文档  r 刷新  q 关闭",
      vim.log.levels.INFO
    )
  end)
end

---------------------------------------------------------------------------
-- 入口
---------------------------------------------------------------------------

function M.open()
  M.close()

  local src_buf = vim.api.nvim_get_current_buf()
  local src_win = vim.api.nvim_get_current_win()
  local client = pick_client(src_buf)
  if not client then
    vim.notify("codemap: 当前缓冲区没有支持调用层级的 LSP(先等 LSP 挂载)", vim.log.levels.WARN)
    return
  end

  local s = {
    src_buf = src_buf,
    src_win = src_win,
    client = client,
    offset_encoding = client.offset_encoding or "utf-16",
    pending = 0,
    rendered = false,
    loading = true,
    errors = {},
    doc = {},
    doc_open = false,
    ref_nodes = nil,
    ref_locs = nil,
    got_refs = false,
    got_in = false,
    got_out = false,
    ch_possible = nil,
    single = false,
    rows = {},
    nav = { c1 = {}, c2 = {} },
    focus = { key = "c1", idx = 1 },
    cols = {
      c1 = { title = "被调用", kind = "incoming", nodes = {}, open = true, pending = true },
      c2 = { title = "调用", kind = "outgoing", nodes = {}, open = true, pending = true },
    },
  }
  st = s

  local word = vim.fn.expand("<cword>")
  s.buf = vim.api.nvim_create_buf(false, true)
  vim.bo[s.buf].bufhidden = "wipe"
  vim.bo[s.buf].filetype = "codemap"
  vim.bo[s.buf].modifiable = false

  local W = math.min(config.max_width, math.floor(vim.o.columns * config.width))
  s.win = vim.api.nvim_open_win(s.buf, true, {
    relative = "editor",
    width = W,
    height = 3,
    row = math.floor(vim.o.lines / 2) - 1,
    col = math.floor((vim.o.columns - W) / 2),
    style = "minimal",
    border = "rounded",
    title = " " .. (word ~= "" and word or "codemap") .. " ",
    title_pos = "center",
    zindex = 60,
  })
  vim.wo[s.win].wrap = false
  vim.wo[s.win].cursorline = false
  vim.wo[s.win].winhighlight = "Normal:CodeMapNormal,FloatBorder:CodeMapBorder"
  setup_keys(s)
  vim.api.nvim_create_autocmd({ "WinClosed" }, {
    buffer = s.buf,
    once = true,
    callback = function()
      if st == s then
        st = nil
      end
      stop_anim(s)
    end,
  })
  M._render(s, false)

  local params = vim.lsp.util.make_position_params(src_win, s.offset_encoding)

  request(s, "textDocument/hover", params, function(result)
    local sig, modpath, doc = parse_hover(result)
    s.sig, s.modpath, s.doc = sig, modpath, doc or {}
  end)

  request(
    s,
    "textDocument/references",
    vim.tbl_extend("force", params, {
      context = { includeDeclaration = false },
    }),
    function(result)
      s.refs = result and #result or 0
      s.ref_locs = result or {}
      s.got_refs = true
    end
  )

  request(s, "textDocument/prepareCallHierarchy", params, function(result)
    local item = result and result[1]
    if not item then
      s.ch_possible = false
      s.cols.c1.pending, s.cols.c2.pending = false, false
      return
    end
    s.ch_possible = true
    s.root_uri, s.root_range = item.uri, item.selectionRange or item.range
    if not s.sig then
      s.sig = item.name
    end
    request(s, "callHierarchy/incomingCalls", { item = item }, function(res)
      for _, call in ipairs(res or {}) do
        s.cols.c1.nodes[#s.cols.c1.nodes + 1] = to_node(call.from, "incoming", 0)
      end
      s.got_in = true
      s.cols.c1.pending = false
    end)
    request(s, "callHierarchy/outgoingCalls", { item = item }, function(res)
      for _, call in ipairs(res or {}) do
        s.cols.c2.nodes[#s.cols.c2.nodes + 1] = to_node(call.to, "outgoing", 0)
      end
      s.got_out = true
      s.cols.c2.pending = false
    end)
  end)

  vim.defer_fn(function()
    if st == s and not s.rendered then
      s.rendered = true
      s.loading = false
      s.errors[#s.errors + 1] = "LSP 响应超时, 下列为已拿到的部分数据"
      M._render(s, true)
    end
  end, config.timeout)
end

function M.setup(opts)
  config = vim.tbl_deep_extend("force", config, opts or {})
  local function defhl()
    fade_cache = {}
    for name, val in pairs(HLS) do
      vim.api.nvim_set_hl(0, name, vim.tbl_extend("force", val, { default = true }))
    end
  end
  defhl()
  vim.api.nvim_create_autocmd("ColorScheme", { callback = defhl })
  vim.api.nvim_create_user_command("CodeMap", function()
    M.open()
  end, { desc = "光标处符号的调用关系脑图" })
end

return M
