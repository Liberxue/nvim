-- LazyVim passes dap-ui an empty opts table, so the defaults apply: a 40 column
-- sidebar split four ways and full type names. Rust does not fit in that. A
-- line reads `name type = value`, and a type like
-- `std::sync::poison::mutex::Mutex<unsigned int>` runs past the edge on its own,
-- taking the value with it -- the panel ends up showing nothing but namespaces.
-- Values and variable names both resolve to Normal by default, so a scopes line
-- reads as one undifferentiated colour. The virtual text at the end of a line
-- links to Comment, which is dim on purpose and works against the one thing it
-- exists to show.
--
-- Linking to semantic groups rather than fixed colours keeps this working when
-- the colorscheme changes.
local function set_highlights()
  local links = {
    DapUIVariable = "Identifier",
    DapUIValue = "String",
    DapUIWatchesValue = "String",
    DapUIType = "Type",
    DapUIScope = "Function",
    DapUIThread = "Function",
    DapUIStoppedThread = "DiagnosticWarn",
    DapUISource = "Directory",
    -- A value that changed since the last stop is the signal worth catching.
    DapUIModifiedValue = "DiagnosticWarn",
    NvimDapVirtualText = "DiagnosticVirtualTextInfo",
    NvimDapVirtualTextChanged = "DiagnosticVirtualTextWarn",
  }
  for group, link in pairs(links) do
    vim.api.nvim_set_hl(0, group, { link = link })
  end
  vim.api.nvim_set_hl(0, "DapUIModifiedValue", { link = "DiagnosticWarn", bold = true })
end

return {
  {
    "rcarriga/nvim-dap-ui",
    init = function()
      set_highlights()
      vim.api.nvim_create_autocmd("ColorScheme", { callback = set_highlights })
    end,
    opts = {
      render = {
        -- Drop the type. The value already carries the shape for Rust:
        -- Some(60), "hello", size=3, (60, 5). Set this to a positive number to
        -- truncate instead, or -1 to print types in full.
        max_type_length = 0,
        max_value_lines = 100,
        indent = 2,
      },
      -- Press this on a line too long for the panel to read it in a float.
      expand_lines = true,
      layouts = {
        {
          position = "left",
          -- A fraction of the window rather than a column count, so it holds up
          -- on a laptop screen as well as a wide one.
          size = 0.3,
          elements = {
            -- Scopes is what gets read; the rest are reference.
            { id = "scopes", size = 0.55 },
            { id = "watches", size = 0.2 },
            { id = "stacks", size = 0.15 },
            { id = "breakpoints", size = 0.1 },
          },
        },
        {
          position = "bottom",
          size = 12,
          elements = {
            { id = "repl", size = 0.5 },
            { id = "console", size = 0.5 },
          },
        },
      },
    },
  },
}
