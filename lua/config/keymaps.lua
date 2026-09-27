-- Keymaps are automatically loaded on the VeryLazy event
-- Default keymaps that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/keymaps.lua
-- Add any additional keymaps here

require("config.modules").setup()

-- <C-j> 开关浮动终端, cwd 取项目根.
-- 覆盖了 LazyVim 默认的「切到下方窗口」, 原功能仍可用内置的 <C-w>j.
-- 终端模式下也绑了, 所以 Ctrl-J 不再透传给 shell; 要把它留给 shell 就删掉 "t",
-- 改用 LazyVim 自带的 <C-/> 退出终端.
vim.keymap.set({ "n", "t" }, "<C-j>", function()
  Snacks.terminal.toggle(nil, { cwd = LazyVim.root() })
end, { desc = "Terminal (Root Dir)" })
