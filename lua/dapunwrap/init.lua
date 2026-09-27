-- Hovering a wrapper during a debug session answers with its bookkeeping: an
-- Arc reports strong/weak counts, a MutexGuard reports a lock address, a
-- RefCell reports a borrow flag. The number the program is actually working on
-- sits several levels below, reachable only by expanding the tree.
--
-- This walks down for you and reports the leaves. The walk uses the variables
-- request rather than expressions on purpose: the Rust formatters expose
-- synthetic children that an expression cannot address, so `counter.data.data`
-- answers "Attribute 'data' is not defined" while the tree holds the value.

local M = {}

local config = {
  depth = 6,
  max_leaves = 12,
  -- Bookkeeping fields of the std wrappers. Descending into them yields
  -- borrow counters and allocator markers, never the payload.
  skip = {
    ["[raw]"] = true,
    poison = true,
    phantom = true,
    alloc = true,
    _marker = true,
    inner = true,
  },
}

--- A value worth reporting rather than descending into.
local function is_leaf_value(v)
  if not v or v == "" then
    return false
  end
  if v:match("^{.*}$") or v == "{...}" then
    return false
  end
  return true
end

--- Depth-first walk collecting `path = value` for anything that looks like data.
local function collect(session, ref, prefix, depth, acc, done)
  if depth > config.depth or #acc >= config.max_leaves or not ref or ref == 0 then
    return done()
  end
  session:request("variables", { variablesReference = ref }, function(err, res)
    if err or not res or not res.variables then
      return done()
    end
    local pending = 0
    local finished = false
    local function step()
      pending = pending - 1
      if pending == 0 and not finished then
        finished = true
        done()
      end
    end
    for _, v in ipairs(res.variables) do
      if not config.skip[v.name] and #acc < config.max_leaves then
        local path = prefix == "" and v.name or (prefix .. "." .. v.name)
        if is_leaf_value(v.value) then
          acc[#acc + 1] = { path = path, value = v.value }
        elseif v.variablesReference and v.variablesReference ~= 0 then
          pending = pending + 1
          collect(session, v.variablesReference, path, depth + 1, acc, step)
        end
      end
    end
    if pending == 0 and not finished then
      finished = true
      done()
    end
  end)
end

local function show(lines)
  local width = 0
  for _, l in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(l))
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  local win = vim.api.nvim_open_win(buf, false, {
    relative = "cursor",
    row = 1,
    col = 0,
    width = math.min(width + 2, vim.o.columns - 4),
    height = math.min(#lines, 16),
    style = "minimal",
    border = "rounded",
    focusable = false,
    noautocmd = true,
    zindex = 60,
  })
  vim.wo[win].wrap = false
  vim.api.nvim_create_autocmd({ "CursorMoved", "InsertEnter", "BufLeave" }, {
    once = true,
    callback = function()
      pcall(vim.api.nvim_win_close, win, true)
    end,
  })
end

--- Hover the expression under the cursor, descending through wrappers.
function M.hover()
  local dap = require("dap")
  local session = dap.session()
  if not session then
    return vim.lsp.buf.hover()
  end
  local frame = session.current_frame
  local word = vim.fn.expand("<cword>")
  if word == "" then
    return
  end

  session:request("evaluate", { expression = word, frameId = frame and frame.id, context = "hover" }, function(err, res)
    vim.schedule(function()
      if err or not res then
        vim.notify(("dap: %s"):format(err and (err.message or err) or "no result"), vim.log.levels.WARN)
        return
      end
      local head = ("%s = %s"):format(word, res.result or "")
      if not res.variablesReference or res.variablesReference == 0 then
        return show({ head })
      end
      -- A wrapper: report what it holds rather than what it is.
      local acc = {}
      collect(session, res.variablesReference, "", 1, acc, function()
        vim.schedule(function()
          local lines = { head }
          for _, leaf in ipairs(acc) do
            lines[#lines + 1] = ("  %s = %s"):format(leaf.path, leaf.value)
          end
          if #acc == 0 then
            lines[#lines + 1] = "  (no scalar fields)"
          end
          show(lines)
        end)
      end)
    end)
  end)
end

---------------------------------------------------------------------------
-- Inline values
--
-- The end-of-line text comes straight from the adapter, so a wrapper shows its
-- bookkeeping there too. Walking the scopes tree once per stop and caching what
-- the wrappers hold lets the inline text report the value instead, with no key
-- to press.
---------------------------------------------------------------------------

local cache = {} ---@type table<string, string> variable name -> unwrapped value

--- True when a value is a wrapper's own bookkeeping rather than its contents.
local function looks_wrapped(value)
  if not value or value == "" then
    return false
  end
  return value:match("^strong=") ~= nil -- Arc, Rc
    or value:match("^{lock:") ~= nil -- MutexGuard, RwLockGuard
    or value:match("^{%.%.%.}$") ~= nil
    or value:match("^{value:") ~= nil -- RefCell and friends
end

--- Shortest leaf wins: `data.data.value` beats `data.inner.pal.ptr.v`, and the
--- payload is always nearer the surface than the bookkeeping around it.
local function best_leaf(leaves)
  local best
  for _, leaf in ipairs(leaves) do
    if not best or #leaf.path < #best.path then
      best = leaf
    end
  end
  return best
end

local function refresh_inline()
  local ok, vt = pcall(require, "nvim-dap-virtual-text")
  if ok and vt.refresh then
    pcall(vt.refresh)
  end
end

--- Walk every scope of the current frame, caching what each wrapper holds.
local function build_cache()
  local dap = require("dap")
  local session = dap.session()
  local frame = session and session.current_frame
  if not (session and frame) then
    return
  end
  cache = {}
  session:request("scopes", { frameId = frame.id }, function(err, res)
    if err or not res then
      return
    end
    local pending = 0
    local function maybe_refresh()
      pending = pending - 1
      if pending <= 0 then
        vim.schedule(refresh_inline)
      end
    end
    for _, scope in ipairs(res.scopes or {}) do
      -- Registers and globals hold nothing worth unwrapping and are large.
      if not scope.expensive and scope.name ~= "Registers" then
        pending = pending + 1
        session:request("variables", { variablesReference = scope.variablesReference }, function(e2, r2)
          if e2 or not r2 then
            return maybe_refresh()
          end
          local inner = 0
          local function step()
            inner = inner - 1
            if inner <= 0 then
              maybe_refresh()
            end
          end
          for _, v in ipairs(r2.variables or {}) do
            if looks_wrapped(v.value) and v.variablesReference and v.variablesReference ~= 0 then
              inner = inner + 1
              local acc = {}
              local name = v.name
              collect(session, v.variablesReference, "", 1, acc, function()
                local leaf = best_leaf(acc)
                if leaf then
                  cache[name] = leaf.value
                end
                step()
              end)
            end
          end
          if inner == 0 then
            maybe_refresh()
          end
        end)
      end
    end
    if pending == 0 then
      vim.schedule(refresh_inline)
    end
  end)
end

--- For nvim-dap-virtual-text. Reports the unwrapped value when one is known.
function M.display_callback(variable, _, _, _, options)
  local value = variable.value or ""
  local unwrapped = cache[variable.name]
  if unwrapped and looks_wrapped(value) then
    value = unwrapped
  end
  value = value:gsub("%s+", " ")
  if options and options.virt_text_pos == "inline" then
    return " = " .. value
  end
  return variable.name .. " = " .. value
end

function M.setup(opts)
  config = vim.tbl_deep_extend("force", config, opts or {})
  local dap = require("dap")
  -- After stackTrace rather than after event_stopped: nvim-dap fills in
  -- session.current_frame from the stack trace response, so on the stopped
  -- event there is no frame yet and the walk finds nothing.
  --
  -- Not after `scopes` either, since the walk issues scopes requests of its own
  -- and would trigger itself.
  dap.listeners.after.stackTrace["dapunwrap"] = function()
    vim.schedule(build_cache)
  end
  dap.listeners.after.event_terminated["dapunwrap"] = function()
    cache = {}
  end
end

return M
