-- codemap: call hierarchy for the symbol under the cursor.
--
-- Everything comes from the LSP: hover, references, callHierarchy. No network,
-- no model. Laid out as text in a floating window, with rows fading in one at a
-- time -- extmarks interpolate the foreground from the background colour, which
-- needs termguicolors; without it the rows simply appear.

local M = {}

local uv = vim.uv or vim.loop

local config = {
  width = 0.82, -- of the screen
  max_width = 120,
  max_height = 0.72, -- of the screen
  doc_lines = 8, -- documentation lines before truncating; d shows the rest
  max_depth = 6, -- how deep <Tab> may expand a call chain
  timeout = 15000, -- ms to wait on the LSP before drawing with what arrived
  animate = true,
  anim = {
    interval = 18, -- ms per frame
    stagger = 1, -- frames between one row and the next
    ramp = 6, -- frames for one row to reach full colour
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
local st = nil ---@type table|nil state of the open panel; only one at a time

---------------------------------------------------------------------------
-- Width helpers. extmarks take byte columns while alignment needs display
-- width, and the two differ for wide characters.
---------------------------------------------------------------------------

local function dw(s)
  return vim.fn.strdisplaywidth(s)
end

--- Longest prefix that fits in width display cells
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
-- Line: a row of highlighted segments, with concat, pad and truncate
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
  local budget = width - 1 -- leave a cell for the ellipsis
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
-- Interpolated highlight groups used by the fade
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

--- Blend a group towards the background. level runs 0..ramp.
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
  -- Fall back to any client that can answer hover
  cs = vim.lsp.get_clients({ bufnr = bufnr, method = "textDocument/hover" })
  return cs[1]
end

--- Unpack hover contents directly, sidestepping deprecations across versions
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

--- Split hover into the signature block and the prose below it
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
  -- rust-analyzer adds an "Implements notable traits" line that says nothing here
  doc = vim.tbl_filter(function(l)
    return not l:match("^%s*Implements notable traits")
  end, doc)
  while #doc > 0 and doc[#doc] == "" do
    doc[#doc] = nil
  end
  -- rust-analyzer hover is usually [module path, signature], so take the last block
  local sig = #blocks > 0 and table.concat(blocks[#blocks], " "):gsub("%s+", " ") or nil
  local modpath = #blocks > 1 and vim.trim(blocks[1][1] or "") or nil
  return sig, modpath, doc
end

--- Truncate from the left. A path is worth reading at its tail, file.rs:123,
--- not its head, ~/.rustup/...
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
    -- Outside cwd (dependency sources, rustup toolchains) keep only the last
    -- two segments, or the path eats the row
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
    -- Draw as each response lands. hover answers in milliseconds, so the
    -- signature and documentation appear at once; references and callHierarchy
    -- search the whole workspace and fill in later.
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
-- Layout
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

--- Rows for one column. Returns {lines = {Line...}, nav = {node...}}
local function column_lines(s, col, width)
  local lines, nav = {}, {}
  local open = col.open ~= false
  local head = Line.new()
  head:add(open and "▾ " or "▸ ", "CodeMapSection")
  head:add(col.title, "CodeMapSection")
  if col.pending then
    head:add(" (querying)", "CodeMapLoc")
  else
    head:add(" (" .. #col.nodes .. ")", "CodeMapCount")
  end
  lines[#lines + 1] = head:truncate(width)

  if not open then
    return { lines = lines, nav = nav }
  end
  if #col.nodes == 0 then
    lines[#lines + 1] = Line.new():add(col.pending and "  querying" or "  (none)", "CodeMapLoc")
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

--- Turn reference locations into nodes carrying their source line. Reads files
--- synchronously, so call it only when the list is about to be shown.
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

--- Build s.rows, each {text, spans, cells}
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
    push(Line.new():add(" querying " .. (s.client and s.client.name or "LSP"), "CodeMapLoc"))
    s.rows, s.nav = rows, { c1 = {}, c2 = {} }
    return
  end

  -- Signature and location
  if s.sig then
    push(Line.new():add(" "):concat(Line.new():add(s.sig, "CodeMapSig")):truncate(W))
  end
  local head = Line.new():add(" ")
  if s.modpath then
    head:add(s.modpath, "CodeMapPath"):add("  ", "CodeMapLoc")
  end
  head:add(loc_label(s.root_uri, s.root_range), "CodeMapLoc")
  if s.refs then
    head:add("  ·  ", "CodeMapLoc"):add(tostring(s.refs), "CodeMapCount"):add(" references", "CodeMapLoc")
  end
  push(head:truncate(W))

  -- Documentation
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
    dh:add(s.doc_open and "▾ " or "▸ ", "CodeMapSection"):add("Docs", "CodeMapSection")
    if clipped then
      dh:add(("  (%d lines, d for all)"):format(total), "CodeMapLoc")
    end
    push(dh)
    for i, dl in ipairs(shown) do
      if clipped and i > config.doc_lines then
        break
      end
      push(Line.new():add("   "):add(dl, "CodeMapDoc"):truncate(W))
    end
  end

  -- callHierarchy is empty for anything that is not a function, so fall back to
  -- a single column of references. Wait until the hierarchy is known to be
  -- empty, or the two-column layout flashes up first.
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
    s.cols.c1 = { title = "References", kind = "reference", nodes = build_ref_nodes(s), open = true }
    s.focus.key, s.focus.idx = "c1", 1
  end

  -- Two columns, stacked when narrow or in single-column mode
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
  key("j/k", "move")
  key("h/l", "column")
  key("<Tab>", "expand")
  key("<CR>", "jump")
  key("d", "docs")
  key("r", "refresh")
  key("q", "close")
  push(help:truncate(W))

  s.rows, s.nav = rows, nav
end

---------------------------------------------------------------------------
-- Painting
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
  -- Focused cell
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

  -- Move focus to the other column when this one empties. With both empty,
  -- leave it alone, or a still-loading panel throws focus to c2.
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
-- Interaction
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
    vim.notify("codemap: depth limit " .. config.max_depth .. " reached", vim.log.levels.WARN)
    return
  end
  if s.cols[s.focus.key].kind == "reference" then
    vim.notify("codemap: a reference has nothing to expand; <CR> jumps to it", vim.log.levels.INFO)
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
      s.errors[#s.errors + 1] = ("%s: %s"):format(method, err.message or "failed")
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
      "codemap: j/k move  h/l column  <Tab> expand  <CR> jump  d docs  r refresh  q close",
      vim.log.levels.INFO
    )
  end)
end

---------------------------------------------------------------------------
-- Entry point
---------------------------------------------------------------------------

function M.open()
  M.close()

  local src_buf = vim.api.nvim_get_current_buf()
  local src_win = vim.api.nvim_get_current_win()
  local client = pick_client(src_buf)
  if not client then
    vim.notify("codemap: no LSP client with call hierarchy on this buffer", vim.log.levels.WARN)
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
      c1 = { title = "Callers", kind = "incoming", nodes = {}, open = true, pending = true },
      c2 = { title = "Calls", kind = "outgoing", nodes = {}, open = true, pending = true },
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
      s.errors[#s.errors + 1] = "LSP timed out; showing what arrived"
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
  end, { desc = "Call hierarchy for the symbol under the cursor" })
end

return M
