-- Four modules that live in this repo rather than coming from a plugin manager.
--
--   codemap     <leader>cg   call hierarchy for the symbol under the cursor
--   typechain   gt           type of every sub-expression on the current line
--   mouseblame  cursor hold  commit behind the current line
--   funcsig     winbar       signature of the enclosing function
--
-- Plain lua modules rather than lazy.nvim local plugin specs: all four would
-- share stdpath("config") as their dir, and lazy keys plugins by dir, so the
-- four specs would collide.

local M = {}

function M.setup()
  -- Key-triggered
  require("codemap").setup()
  vim.keymap.set("n", "<leader>cg", function()
    require("codemap").open()
  end, { desc = "Code Map (call hierarchy)" })

  -- gt rather than <leader>ct: the g prefix is where LazyVim keeps symbol
  -- lookups (gd definition, gy type definition, gK signature), and a type chain
  -- belongs with them. gt paged through tabs in vim, but buffers are handled by
  -- bufferline here (<S-h>/<S-l>), so nothing used it.
  require("typechain").setup()
  vim.keymap.set("n", "gt", function()
    require("typechain").open()
  end, { desc = "Type Chain (current line)" })

  -- Event-driven, so their autocmds have to be installed at startup.
  --
  -- mouseblame triggers on CursorHold. Mouse hover needs the terminal to report
  -- motion without a button held (xterm 1003 any-event), which Warp does not do;
  -- set source = "mouse" or "both" on a terminal that does.
  require("mouseblame").setup()

  -- funcsig reads treesitter rather than the LSP, so recomputing it on every
  -- cursor move costs the language server nothing.
  require("funcsig").setup()
end

return M
