-- 本仓库自带的四个本地模块, 都不是第三方插件.
--
--   codemap     <leader>cg   光标处符号的调用关系脑图
--   typechain   <leader>ct   当前行每个子表达式的类型
--   mouseblame  鼠标悬停       该行的 git 提交信息
--   funcsig     winbar        光标所在函数的签名
--
-- 写成普通 lua 模块而不是 lazy.nvim 的本地插件规格, 是因为四个模块共用
-- stdpath("config") 这一个目录, 而 lazy 以 dir 为键, 四条规格会互相冲突.

local M = {}

function M.setup()
  -- 按键触发的两个
  require("codemap").setup()
  vim.keymap.set("n", "<leader>cg", function()
    require("codemap").open()
  end, { desc = "Code Map (调用关系)" })

  -- gt 而不是 <leader>ct: g 前缀在 LazyVim 里是查看符号信息那一族(gd 定义,
  -- gy 类型定义, gK 签名), 类型链排进去更顺手. 原生 vim 的 gt 是切 tab 页,
  -- 但这里用 bufferline 管缓冲区(<S-h>/<S-l>), tab 页用不到.
  require("typechain").setup()
  vim.keymap.set("n", "gt", function()
    require("typechain").open()
  end, { desc = "Type Chain (当前行类型链)" })

  -- 事件驱动的两个, 必须在启动时就把 autocmd 挂上
  --
  -- mouseblame 依赖终端上报无按键的鼠标移动(xterm 1003 any-event). 终端不支持
  -- 时它不会报错, 只是什么都不发生; 用 :MouseBlameDebug 判断, 用
  -- :MouseBlameLine 或 gitsigns 的 <leader>ghb 查光标行代替.
  require("mouseblame").setup()

  -- funcsig 走 treesitter 不走 LSP, 光标移动时重算不会给语言服务器加负担
  require("funcsig").setup()
end

return M
