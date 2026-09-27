-- LazyVim's breakpoint signs are Nerd Font glyphs from the private use area
-- (U+F192 and friends). A terminal font without them renders nothing, so a
-- breakpoint gets set and stays invisible: the session stops there but the
-- gutter never shows why.
--
-- These characters are in ordinary Unicode fonts. Overriding LazyVim's icon
-- table rather than calling sign_define here, because its dap extra defines the
-- signs from that table in its own config, which runs later and would win.
return {
  {
    "LazyVim/LazyVim",
    opts = {
      icons = {
        dap = {
          Stopped = { "▶ ", "DiagnosticWarn", "DapStoppedLine" },
          Breakpoint = { "● ", "DiagnosticError" },
          BreakpointCondition = { "◆ ", "DiagnosticWarn" },
          BreakpointRejected = { "○ ", "DiagnosticError" },
          LogPoint = { "◇ ", "DiagnosticInfo" },
        },
      },
    },
  },
}
