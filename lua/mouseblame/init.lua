-- mouseblame: the commit behind a line, on demand.
--
-- Nothing fires on its own. The end-of-line annotation from gitsigns covers the
-- glanceable case, and CursorHold belongs to hoverdoc, which answers the
-- question asked far more often while reading code: what is this and what does
-- it return. This popup carries more than the annotation does -- absolute time
-- and the commit body -- so it stays available through :MouseBlameLine.
--
-- Set source to "cursor" to bring back the CursorHold popup, or "mouse" on a
-- terminal that reports motion with no button held (xterm 1003 any-event);
-- Warp does not, and :MouseBlameDebug sees no <MouseMove> there at all.

local M = {}

local config = {
  -- "off" for :MouseBlameLine only, "cursor" on CursorHold, "mouse" on hover,
  -- "both" for either
  source = "off",
  delay = 120, -- ms after CursorHold before running git, to absorb fast movement
  max_width = 96,
  body_lines = 8, -- lines of commit body to show before truncating
  ignore_ft = { codemap = true, ["snacks_terminal"] = true, ["neo-tree"] = true, help = true },
}

local HLS = {
  MouseBlameNormal = { link = "NormalFloat" },
  MouseBlameBorder = { link = "FloatBorder" },
  MouseBlameSha = { link = "Identifier" },
  MouseBlameAuthor = { link = "Function" },
  MouseBlameDate = { link = "Comment" },
  MouseBlameSubject = { link = "Normal" },
  MouseBlameBody = { link = "Comment" },
  MouseBlameWarn = { link = "WarningMsg" },
}

local ns = vim.api.nvim_create_namespace("mouseblame")
local uv = vim.uv or vim.loop

local timer ---@type uv.uv_timer_t|nil
local win, buf
local last ---@type table|nil  {win, line} of the last query
local job ---@type vim.SystemObj|nil
local enabled = false
local move_count = 0 -- only read by :MouseBlameDebug

---------------------------------------------------------------------------

local function stop_timer()
  if timer then
    timer:stop()
    if not timer:is_closing() then
      timer:close()
    end
    timer = nil
  end
end

local function hide()
  stop_timer()
  if job then
    pcall(function()
      job:kill(9)
    end)
    job = nil
  end
  if win and vim.api.nvim_win_is_valid(win) then
    pcall(vim.api.nvim_win_close, win, true)
  end
  win, buf = nil, nil
end

M.hide = hide

local function rel_time(ts)
  local d = os.time() - ts
  if d < 0 then
    return "just now"
  elseif d < 60 then
    return d .. "s ago"
  elseif d < 3600 then
    return math.floor(d / 60) .. "m ago"
  elseif d < 86400 then
    return math.floor(d / 3600) .. "h ago"
  elseif d < 86400 * 30 then
    return math.floor(d / 86400) .. " days ago"
  elseif d < 86400 * 365 then
    return math.floor(d / (86400 * 30)) .. " months ago"
  else
    return string.format("%.1f years ago", d / (86400 * 365))
  end
end

--- Parse one line of git blame --porcelain output
local function parse_porcelain(out)
  local info = {}
  for line in out:gmatch("[^\n]+") do
    -- Header line is "<40-char sha> <orig-line> <final-line> <num-lines>".
    -- Lua patterns have no {n} repetition, so the sha is anchored by the two
    -- numbers that follow it rather than by its length.
    local sha = line:match("^(%x%x%x%x%x%x%x%x+)%s+%d+%s+%d+")
    if sha and not info.sha then
      info.sha = sha
    elseif line:match("^author ") then
      info.author = line:sub(8)
    elseif line:match("^author%-time ") then
      info.time = tonumber(line:sub(13))
    elseif line:match("^summary ") then
      info.summary = line:sub(9)
    end
  end
  return info
end

local function eligible(b)
  if not b or not vim.api.nvim_buf_is_valid(b) then
    return false
  end
  if vim.bo[b].buftype ~= "" then
    return false
  end
  if config.ignore_ft[vim.bo[b].filetype] then
    return false
  end
  local name = vim.api.nvim_buf_get_name(b)
  return name ~= "" and vim.fn.filereadable(name) == 1
end

---------------------------------------------------------------------------
-- Popup
---------------------------------------------------------------------------

--- rows: { {text, hl}, ... }
local function show(rows, anchor)
  hide()
  local w = 0
  for _, r in ipairs(rows) do
    w = math.max(w, vim.fn.strdisplaywidth(r[1]))
  end
  w = math.min(w + 2, config.max_width, vim.o.columns - 4)
  local h = math.min(#rows, math.max(3, math.floor(vim.o.lines * 0.4)))

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
      hl_group = r[2] or "MouseBlameNormal",
      priority = 200,
    })
  end

  -- screenrow/screencol are 1-based, relative=editor row/col are 0-based
  local row = anchor.screenrow -- one line below the anchor
  if row + h + 2 > vim.o.lines then
    row = math.max(0, anchor.screenrow - h - 3) -- flip above when there is no room
  end
  local col = math.max(0, math.min(anchor.screencol - 1, vim.o.columns - w - 3))

  win = vim.api.nvim_open_win(buf, false, {
    relative = "editor",
    row = row,
    col = col,
    width = w,
    height = h,
    style = "minimal",
    border = "rounded",
    focusable = false,
    noautocmd = true,
    zindex = 200,
  })
  vim.wo[win].wrap = false
  vim.wo[win].winhighlight = "Normal:MouseBlameNormal,FloatBorder:MouseBlameBorder"
end

---------------------------------------------------------------------------
-- Query
---------------------------------------------------------------------------

local function enrich_body(dir, sha, rows, anchor)
  vim.system(
    { "git", "-C", dir, "log", "-1", "--format=%b", sha },
    { text = true },
    vim.schedule_wrap(function(res)
      if res.code ~= 0 or not last or not (win and vim.api.nvim_win_is_valid(win)) then
        return
      end
      local body = vim.split(vim.trim(res.stdout or ""), "\n", { plain = true })
      if #body == 0 or body[1] == "" then
        return
      end
      rows[#rows + 1] = { "", "MouseBlameBody" }
      for i, l in ipairs(body) do
        if i > config.body_lines then
          rows[#rows + 1] = { ("... %d more lines"):format(#body - config.body_lines), "MouseBlameBody" }
          break
        end
        rows[#rows + 1] = { l, "MouseBlameBody" }
      end
      show(rows, anchor)
    end)
  )
end

local function blame(b, anchor)
  local path = vim.api.nvim_buf_get_name(b)
  local dir = vim.fs.dirname(path)
  local line = anchor.line
  local modified = vim.bo[b].modified
  job = vim.system(
    { "git", "-C", dir, "blame", "-L", line .. "," .. line, "--porcelain", "--", path },
    { text = true },
    vim.schedule_wrap(function(res)
      job = nil
      -- The cursor has moved on
      if not last or last.line ~= line then
        return
      end
      if res.code ~= 0 then
        return -- not a repo, file untracked, and so on; stay quiet
      end
      local info = parse_porcelain(res.stdout or "")
      if not info.sha then
        return
      end
      local rows = {}
      if info.sha:match("^0+$") then
        rows[#rows + 1] = { "Uncommitted change", "MouseBlameWarn" }
      else
        rows[#rows + 1] = {
          ("%s  %s  %s (%s)"):format(
            info.sha:sub(1, 7),
            info.author or "?",
            info.time and rel_time(info.time) or "?",
            info.time and os.date("%Y-%m-%d %H:%M", info.time) or "?"
          ),
          "MouseBlameSha",
        }
        rows[#rows + 1] = { info.summary or "", "MouseBlameSubject" }
      end
      if modified then
        rows[#rows + 1] =
          { "Buffer modified; blame reads the file on disk, so lines may not line up", "MouseBlameWarn" }
      end
      show(rows, anchor)
      if not info.sha:match("^0+$") then
        enrich_body(dir, info.sha, rows, anchor)
      end
    end)
  )
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------

function M.on_move()
  move_count = move_count + 1
  local pos = vim.fn.getmousepos()
  -- Ignore the popup itself, or entering it would dismiss it
  if win and pos.winid == win then
    return
  end
  if pos.winid == 0 or pos.line == 0 then
    hide()
    last = nil
    return
  end
  local b = vim.api.nvim_win_get_buf(pos.winid)
  if not eligible(b) then
    hide()
    last = nil
    return
  end
  if last and last.winid == pos.winid and last.line == pos.line then
    return -- same line, already queried
  end
  hide()
  last = { winid = pos.winid, line = pos.line, screenrow = pos.screenrow, screencol = pos.screencol }
  local anchor = last
  timer = uv.new_timer()
  timer:start(
    config.delay,
    0,
    vim.schedule_wrap(function()
      stop_timer()
      if last == anchor and vim.api.nvim_win_is_valid(anchor.winid) then
        blame(b, anchor)
      end
    end)
  )
end

--- CursorHold entry point. Unlike M.line it debounces and deduplicates, so
--- resting on one line does not run git more than once.
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
  local lnum = vim.api.nvim_win_get_cursor(w)[1]
  if last and last.winid == w and last.line == lnum then
    return -- this line is already shown
  end
  hide()
  last = { winid = w, line = lnum, screenrow = vim.fn.screenrow(), screencol = vim.fn.screencol() }
  local anchor = last
  stop_timer()
  timer = uv.new_timer()
  timer:start(
    config.delay,
    0,
    vim.schedule_wrap(function()
      stop_timer()
      if last == anchor and vim.api.nvim_win_is_valid(anchor.winid) then
        blame(b, anchor)
      end
    end)
  )
end

--- Query the cursor line at once, without waiting for a hold. Used by :MouseBlameLine.
function M.line()
  local b = vim.api.nvim_get_current_buf()
  if not eligible(b) then
    vim.notify("mouseblame: this buffer is not a file git can blame", vim.log.levels.WARN)
    return
  end
  local anchor = {
    winid = vim.api.nvim_get_current_win(),
    line = vim.api.nvim_win_get_cursor(0)[1],
    screenrow = vim.fn.screenrow(),
    screencol = vim.fn.screencol(),
  }
  last = anchor
  blame(b, anchor)
end

function M.enable()
  if enabled then
    return
  end
  enabled = true
  local g = vim.api.nvim_create_augroup("mouseblame", { clear = true })

  if config.source == "mouse" or config.source == "both" then
    vim.o.mousemoveevent = true
    vim.keymap.set({ "n", "i", "v" }, "<MouseMove>", M.on_move, { silent = true, desc = "Mouse blame hover" })
  end

  if config.source == "cursor" or config.source == "both" then
    vim.api.nvim_create_autocmd("CursorHold", { group = g, callback = M.on_hold })
  end

  -- CursorMoved arrives before CursorHold. Clearing last only on a real line
  -- change keeps repeated holds on one line from running git each time.
  vim.api.nvim_create_autocmd("CursorMoved", {
    group = g,
    callback = function()
      local w = vim.api.nvim_get_current_win()
      local lnum = vim.api.nvim_win_get_cursor(w)[1]
      if last and (last.winid ~= w or last.line ~= lnum) then
        last = nil
      end
      hide()
    end,
  })
  for _, ev in ipairs({ "CursorMovedI", "InsertEnter", "WinScrolled", "BufLeave" }) do
    vim.api.nvim_create_autocmd(ev, {
      group = g,
      callback = function()
        hide()
        last = nil
      end,
    })
  end
end

function M.disable()
  enabled = false
  hide()
  last = nil
  if config.source == "mouse" or config.source == "both" then
    pcall(vim.keymap.del, { "n", "i", "v" }, "<MouseMove>")
  end
  pcall(vim.api.nvim_del_augroup_by_name, "mouseblame")
end

function M.toggle()
  if enabled then
    M.disable()
    vim.notify("mouseblame: off", vim.log.levels.INFO)
  else
    M.enable()
    vim.notify("mouseblame: on", vim.log.levels.INFO)
  end
end

--- Report whether the terminal sends mouse motion events at all
function M.debug()
  if config.source == "cursor" then
    vim.notify(
      "mouseblame: triggering on CursorHold, not the mouse.\n" .. 'Set source = "both" first to test mouse hover.',
      vim.log.levels.INFO
    )
    return
  end
  if not enabled then
    M.enable()
  end
  local base = move_count
  vim.notify("mouseblame: move the mouse within 3 seconds", vim.log.levels.INFO)
  vim.defer_fn(function()
    local got = move_count - base
    if got > 0 then
      vim.notify(("mouseblame: %d <MouseMove> events, this terminal reports motion"):format(got), vim.log.levels.INFO)
    else
      vim.notify(
        "mouseblame: no <MouseMove> in 3 seconds.\n"
          .. "This terminal does not report motion without a button held.\n"
          .. "Use :MouseBlameLine, or gitsigns <leader>ghb, for the cursor line.",
        vim.log.levels.WARN
      )
    end
  end, 3000)
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
  vim.api.nvim_create_user_command("MouseBlameToggle", M.toggle, { desc = "Toggle inline git blame" })
  vim.api.nvim_create_user_command(
    "MouseBlameDebug",
    M.debug,
    { desc = "Check whether the terminal reports mouse motion" }
  )
  vim.api.nvim_create_user_command("MouseBlameLine", M.line, { desc = "Commit behind the cursor line" })
  M.enable()
end

return M
