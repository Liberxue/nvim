-- A disassembly panel for the debugger, docked in the dap-ui layout.
--
-- codelldb answers the DAP `disassemble` request and annotates each
-- instruction with the symbol it calls and the source line it came from, which
-- is what makes the output readable rather than a wall of addresses. nvim-dap
-- does not expose that request and dap-ui ships no element for it, so this
-- registers one.
--
-- Unlike godbolt this is the real thing: instructions from the running process,
-- with the program counter marked, not a compiler's idea of what it would emit.

local M = {}

local config = {
  before = 8, -- instructions to show above the program counter
  count = 40, -- instructions per refresh
}

local HLS = {
  DapDisasmAddr = { link = "Comment" },
  DapDisasmMnemonic = { link = "Keyword" },
  DapDisasmArgs = { link = "Normal" },
  DapDisasmComment = { link = "Comment" },
  DapDisasmSource = { link = "Type" },
  DapDisasmCurrent = { link = "DiagnosticWarn" },
  DapDisasmCurrentLine = { link = "Visual" },
}

local ns = vim.api.nvim_create_namespace("dapdisasm")
local buf

local function get_buf()
  if buf and vim.api.nvim_buf_is_valid(buf) then
    return buf
  end
  buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false
  vim.api.nvim_buf_set_name(buf, "DAP Disassembly")
  return buf
end

local function set_lines(lines, marks)
  local b = get_buf()
  vim.bo[b].modifiable = true
  vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
  vim.bo[b].modifiable = false
  vim.api.nvim_buf_clear_namespace(b, ns, 0, -1)
  for _, m in ipairs(marks or {}) do
    pcall(vim.api.nvim_buf_set_extmark, b, ns, m.line, m.col, {
      end_col = m.end_col,
      hl_group = m.hl,
      line_hl_group = m.line_hl,
      priority = 150,
    })
  end
end

--- Split "callq 0x100000e00  ; <symbol> at file.rs:728" into its parts.
local function split_instruction(text)
  local mnemonic, rest = text:match("^(%S+)%s*(.*)$")
  mnemonic = mnemonic or text
  rest = rest or ""
  local args, comment = rest:match("^(.-)%s*;%s*(.+)$")
  return mnemonic, args or rest, comment
end

local function render_now()
  local ok, dap = pcall(require, "dap")
  if not ok then
    return
  end
  local session = dap.session()
  local frame = session and session.current_frame
  if not (session and frame) then
    set_lines({ "  no debug session" })
    return
  end
  local pointer = frame.instructionPointerReference
  if not pointer then
    -- A frame without one is usually synthetic; nothing to disassemble.
    set_lines({ "  frame exposes no instruction pointer" })
    return
  end

  session:request("disassemble", {
    memoryReference = pointer,
    instructionOffset = -config.before,
    instructionCount = config.count,
    resolveSymbols = true,
  }, function(err, res)
    vim.schedule(function()
      if err then
        set_lines({ "  disassemble failed: " .. tostring(err.message or err) })
        return
      end
      local lines, marks = {}, {}
      for i, ins in ipairs((res or {}).instructions or {}) do
        local current = ins.address == pointer
        local addr = ins.address or ""
        local mnemonic, args, comment = split_instruction(ins.instruction or "")
        local src = ""
        if ins.location and ins.line then
          src = ("%s:%d"):format(vim.fs.basename(ins.location.name or ins.location.path or "?"), ins.line)
        end

        local marker = current and "▶ " or "  "
        local text = ("%s%-12s %-8s %s"):format(marker, addr, mnemonic, args)
        if comment then
          text = text .. "  ; " .. comment
        end
        if src ~= "" then
          text = text .. "  " .. src
        end
        lines[i] = text

        local row = i - 1
        local col = #marker
        marks[#marks + 1] = { line = row, col = col, end_col = col + #addr, hl = "DapDisasmAddr" }
        local mcol = col + 13
        marks[#marks + 1] =
          { line = row, col = mcol, end_col = math.min(mcol + #mnemonic, #text), hl = "DapDisasmMnemonic" }
        if current then
          marks[#marks + 1] =
            { line = row, col = 0, end_col = 1, hl = "DapDisasmCurrent", line_hl = "DapDisasmCurrentLine" }
        end
      end
      if #lines == 0 then
        lines = { "  nothing disassembled at " .. pointer }
      end
      set_lines(lines, marks)
    end)
  end)
end

M.element = {
  render = render_now,
  buffer = get_buf,
  allow_without_session = true,
  float_defaults = function()
    return { width = 110, height = 30, enter = true }
  end,
}

function M.setup()
  local function defhl()
    for name, val in pairs(HLS) do
      vim.api.nvim_set_hl(0, name, vim.tbl_extend("force", val, { default = true }))
    end
  end
  defhl()
  vim.api.nvim_create_autocmd("ColorScheme", { callback = defhl })

  local ok, dapui = pcall(require, "dapui")
  if ok then
    pcall(dapui.register_element, "disassembly", M.element)
  end

  local dap = require("dap")
  -- Re-read on every stop: stepping moves the program counter, and the panel is
  -- only useful if it follows it.
  dap.listeners.after.event_stopped["dapdisasm"] = function()
    vim.schedule(render_now)
  end
  dap.listeners.after.scopes["dapdisasm"] = function()
    vim.schedule(render_now)
  end
  dap.listeners.after.event_terminated["dapdisasm"] = function()
    vim.schedule(function()
      set_lines({ "  no debug session" })
    end)
  end

  vim.api.nvim_create_user_command("DapDisasm", function()
    render_now()
    pcall(function()
      require("dapui").float_element("disassembly", { enter = true })
    end)
  end, { desc = "Disassembly around the program counter" })
end

return M
