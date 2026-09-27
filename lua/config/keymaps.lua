-- Keymaps are automatically loaded on the VeryLazy event
-- Default keymaps that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/keymaps.lua
-- Add any additional keymaps here

require("config.modules").setup()

-- Floating terminal rooted at the project. This takes <C-j> away from
-- LazyVim's window-down mapping; <C-w>j still does that.
-- Bound in terminal mode too, so Ctrl-J no longer reaches the shell. Drop the
-- "t" below to give it back and use LazyVim's <C-/> to leave the terminal.
vim.keymap.set({ "n", "t" }, "<C-j>", function()
  Snacks.terminal.toggle(nil, { cwd = LazyVim.root() })
end, { desc = "Terminal (Root Dir)" })
