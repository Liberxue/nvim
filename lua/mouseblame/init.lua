-- mouseblame: 光标停在某一行上, 浮窗显示这行的 git 提交信息
--
-- 触发源是 CursorHold, 不是鼠标. 鼠标悬停要求终端上报无按键的鼠标移动
-- (xterm 1003 any-event), Warp 不上报, :MouseBlameDebug 三秒内收不到任何
-- <MouseMove>. 所以默认走光标停留; 终端支持的话把 source 设成 "mouse" 或
-- "both" 就能同时用鼠标.
--
-- 停留时长取 'updatetime', LazyVim 已把它设为 200ms. 这里不动它, 那是全局设置,
-- trouble.nvim 等插件也挂在同一个事件上.

local M = {}

local config = {
  -- "cursor" 光标停留触发, "mouse" 鼠标悬停触发, "both" 两个都要
  source = "cursor",
  delay = 120, -- CursorHold 之后再等多久才发 git(ms), 吸收连续移动
  max_width = 96,
  body_lines = 8, -- commit message 正文最多显示几行
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
local last ---@type table|nil  上次查询的 {win, line}
local job ---@type vim.SystemObj|nil
local enabled = false
local move_count = 0 -- 只给 :MouseBlameDebug 用

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
    return "刚刚"
  elseif d < 60 then
    return d .. " 秒前"
  elseif d < 3600 then
    return math.floor(d / 60) .. " 分钟前"
  elseif d < 86400 then
    return math.floor(d / 3600) .. " 小时前"
  elseif d < 86400 * 30 then
    return math.floor(d / 86400) .. " 天前"
  elseif d < 86400 * 365 then
    return math.floor(d / (86400 * 30)) .. " 个月前"
  else
    return string.format("%.1f 年前", d / (86400 * 365))
  end
end

--- 解析 git blame --porcelain 的单行输出
local function parse_porcelain(out)
  local info = {}
  for line in out:gmatch("[^\n]+") do
    -- 首行形如 "<40 位 sha> <orig-line> <final-line> <num-lines>".
    -- 注意 Lua 模式没有 {n} 重复计数, 只能靠 %x+ 加上后面两个数字来定位.
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
-- 浮窗
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

  -- screenrow/screencol 是 1 基; relative=editor 的 row/col 是 0 基
  local row = anchor.screenrow -- 放在鼠标下一行
  if row + h + 2 > vim.o.lines then
    row = math.max(0, anchor.screenrow - h - 3) -- 放不下就翻到上方
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
-- 查询
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
          rows[#rows + 1] = { ("… 还有 %d 行"):format(#body - config.body_lines), "MouseBlameBody" }
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
      -- 鼠标已经移开了
      if not last or last.line ~= line then
        return
      end
      if res.code ~= 0 then
        return -- 不在 git 仓库里、文件未跟踪等, 静默放过
      end
      local info = parse_porcelain(res.stdout or "")
      if not info.sha then
        return
      end
      local rows = {}
      if info.sha:match("^0+$") then
        rows[#rows + 1] = { "未提交的改动", "MouseBlameWarn" }
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
          { "缓冲区有未保存改动, blame 按磁盘文件定位, 行号可能不一致", "MouseBlameWarn" }
      end
      show(rows, anchor)
      if not info.sha:match("^0+$") then
        enrich_body(dir, info.sha, rows, anchor)
      end
    end)
  )
end

---------------------------------------------------------------------------
-- 事件
---------------------------------------------------------------------------

function M.on_move()
  move_count = move_count + 1
  local pos = vim.fn.getmousepos()
  -- 鼠标落在自己的浮窗上就别动, 否则一进浮窗就闪没了
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
    return -- 还在同一行上, 不重复查
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

--- CursorHold 触发: 查光标所在行. 比 M.line 多了防抖和去重, 光标还停在同一行
--- 时不会重复发 git.
function M.on_hold()
  if not enabled then
    return
  end
  local w = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_get_config(w).relative ~= "" then
    return -- 光标在浮窗里
  end
  local b = vim.api.nvim_win_get_buf(w)
  if not eligible(b) then
    return
  end
  local lnum = vim.api.nvim_win_get_cursor(w)[1]
  if last and last.winid == w and last.line == lnum then
    return -- 这一行查过了
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

--- 立即查光标所在行, 不等停留. 供 :MouseBlameLine 用.
function M.line()
  local b = vim.api.nvim_get_current_buf()
  if not eligible(b) then
    vim.notify("mouseblame: 当前 buffer 不是可 blame 的文件", vim.log.levels.WARN)
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

  -- CursorMoved 在 CursorHold 之前到. 只有真的换了行才清 last, 否则同一行上
  -- 反复停留会反复发 git.
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
    vim.notify("mouseblame: 已关闭", vim.log.levels.INFO)
  else
    M.enable()
    vim.notify("mouseblame: 已开启", vim.log.levels.INFO)
  end
end

--- 判断终端到底有没有把鼠标移动事件报上来
function M.debug()
  if config.source == "cursor" then
    vim.notify(
      "mouseblame: 当前触发源是光标停留(CursorHold), 不用鼠标.\n"
        .. ' 要测鼠标先 setup({ source = "both" }).',
      vim.log.levels.INFO
    )
    return
  end
  if not enabled then
    M.enable()
  end
  local base = move_count
  vim.notify("mouseblame: 3 秒内移动鼠标", vim.log.levels.INFO)
  vim.defer_fn(function()
    local got = move_count - base
    if got > 0 then
      vim.notify(("mouseblame: 收到 %d 个 <MouseMove> 事件, 终端支持"):format(got), vim.log.levels.INFO)
    else
      vim.notify(
        "mouseblame: 3 秒内没有收到 <MouseMove> 事件.\n"
          .. "终端不上报无按键的鼠标移动.\n"
          .. "改用 :MouseBlameLine 或 gitsigns 的 <leader>ghb 查光标行.",
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
  vim.api.nvim_create_user_command("MouseBlameToggle", M.toggle, { desc = "开关鼠标悬停 git blame" })
  vim.api.nvim_create_user_command("MouseBlameDebug", M.debug, { desc = "检测终端是否上报鼠标移动" })
  vim.api.nvim_create_user_command("MouseBlameLine", M.line, { desc = "查光标所在行的 git 提交信息" })
  M.enable()
end

return M
