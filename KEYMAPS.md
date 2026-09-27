# 快捷键

`<leader>` 是空格. 标 `*` 的是本配置自有或覆盖了 LazyVim 默认的, 其余为
LazyVim 默认, 完整列表在 nvim 里按 `<leader>` 等 which-key 弹出, 或 `:map` 查.

本文档由运行中的 nvim 导出后整理, 与实际键位一致.

## 本配置自有

| 键 | 作用 |
| --- | --- |
| `gt` | 当前行每个子表达式的类型 |
| `<leader>cg` | 光标处符号的调用关系 |
| `<C-j>` | 开关浮动终端, 普通模式与终端模式都可 |

光标停在某行上 200ms 自动显示该行的 git 提交信息, 无需按键.

相关命令: `:TypeChain` `:CodeMap` `:MouseBlameLine` `:MouseBlameToggle`
`:MouseBlameDebug` `:FuncSigToggle`

## 覆盖的默认键

| 键 | 本配置 | LazyVim 默认 | 替代 |
| --- | --- | --- | --- |
| `<C-j>` | 开关浮动终端 | 切到下方窗口 | `<C-w>j` |
| `gt` | 类型链 | vim 的切 tab 页 | 缓冲区用 `<S-h>` / `<S-l>` |

`<C-j>` 在终端模式下也绑了, 所以 Ctrl-J 不再透传给 shell. 要留给 shell 就在
`lua/config/keymaps.lua` 里删掉 `"t"`, 用 `<C-/>` 退出终端.

## 代码导航

| 键 | 作用 |
| --- | --- |
| `gd` | 跳到定义 |
| `gD` | 跳到声明 |
| `gr` | 引用列表 |
| `gI` | 实现 |
| `gy` | 类型定义 |
| `gK` | 函数签名 |
| `gO` | 文档符号 |
| `gt` * | 当前行类型链 |
| `<leader>cg` * | 调用关系 |
| `<C-]>` / `<C-t>` | 跳转 / 返回, 走 LSP 的 tagfunc |
| `<C-o>` / `<C-i>` | jumplist 后退 / 前进 |

Rust 里 `gd` 第一次按可能没反应, 那是 rust-analyzer 还在建索引, 十几个 crate
的 workspace 首次要等几分钟. 用 `:checkhealth vim.lsp` 看 client 是否已挂载.

## 代码操作 `<leader>c`

| 键 | 作用 |
| --- | --- |
| `<leader>ca` | Code Action |
| `<leader>cA` | Source Action |
| `<leader>cr` | 重命名符号 |
| `<leader>cR` | 重命名文件 |
| `<leader>cf` | 格式化 |
| `<leader>cd` | 当前行诊断 |
| `<leader>cs` | 符号列表 (Trouble) |
| `<leader>cS` | 引用/定义 (Trouble) |
| `<leader>cl` | LSP 信息 |
| `<leader>cm` | Mason |
| `<leader>cc` | 运行 Codelens |

Rust 下 `<leader>cR` 被 rustaceanvim 改成 Code Action (buffer-local).

## 查找 `<leader>f` `<leader>s`

| 键 | 作用 |
| --- | --- |
| `<leader><space>` | 查找文件 |
| `<leader>ff` | 查找文件 (项目根) |
| `<leader>fF` | 查找文件 (cwd) |
| `<leader>fg` | 查找 git 跟踪的文件 |
| `<leader>fr` | 最近打开 |
| `<leader>fb` | 缓冲区列表 |
| `<leader>fp` | 项目列表 |
| `<leader>fe` | 文件树 |
| `<leader>fc` | 打开本配置 |
| `<leader>sg` | 全局 grep |
| `<leader>sw` | 搜索光标下的词 |
| `<leader>sb` | 当前缓冲区内搜索 |
| `<leader>ss` | 文档符号 |
| `<leader>sS` | 工作区符号 |
| `<leader>sd` | 诊断列表 |
| `<leader>sk` | 查快捷键 |
| `<leader>sR` | 恢复上次搜索 |

## Git `<leader>g`

| 键 | 作用 |
| --- | --- |
| `<leader>gg` | Lazygit |
| `<leader>gb` | 当前行 blame |
| `<leader>ghb` | 当前行 blame (gitsigns) |
| `<leader>ghB` | 整个文件 blame |
| `<leader>gd` | 查看 hunk 差异 |
| `<leader>gf` | 当前文件历史 |
| `<leader>gL` | 提交日志 |
| `<leader>gB` | 在浏览器打开 |
| `]h` / `[h` | 下一个 / 上一个 hunk |

## 调试 `<leader>d`

需要 codelldb, 已随 `lang.rust` 装好.

| 键 | 作用 |
| --- | --- |
| `<leader>db` | 断点开关 |
| `<leader>dB` | 条件断点 |
| `<leader>dc` | 运行 / 继续 |
| `<leader>da` | 带参数运行 |
| `<leader>di` | 步入 |
| `<leader>dO` | 步过 |
| `<leader>do` | 步出 |
| `<leader>dC` | 运行到光标处 |
| `<leader>de` | 求值 |
| `<leader>du` | 开关 dap-ui |
| `<leader>dr` | Rust: 列出可调试目标 |

断点停住后变量的实际值以虚拟文本显示在行尾. `<leader>dr` 在 Rust 里是
rustaceanvim 的 buffer-local 映射, 会盖掉默认的 Toggle REPL.

## 缓冲区与窗口

| 键 | 作用 |
| --- | --- |
| `<S-h>` / `<S-l>` | 上一个 / 下一个缓冲区 |
| `<leader>bd` | 关闭当前缓冲区 |
| `<leader>bo` | 关闭其他缓冲区 |
| `<leader>bp` | 固定缓冲区 |
| `<C-h/j/k/l>` | 切换窗口. **`<C-j>` 被占用, 用 `<C-w>j` 向下** |
| `<leader>wd` | 关闭窗口 |
| `<leader>wm` | 窗口最大化开关 |
| `<C-方向键>` | 调整窗口大小 |

## 诊断与列表 `<leader>x`

| 键 | 作用 |
| --- | --- |
| `<leader>xx` | 诊断列表 (Trouble) |
| `<leader>xX` | 当前缓冲区诊断 |
| `<leader>xq` | quickfix |
| `<leader>xt` | TODO 列表 |
| `]d` / `[d` | 下一个 / 上一个诊断 |
| `]e` / `[e` | 下一个 / 上一个错误 |

## 开关 `<leader>u`

| 键 | 作用 |
| --- | --- |
| `<leader>ud` | 诊断开关 |
| `<leader>uf` | 保存时自动格式化开关 |
| `<leader>uh` | inlay hints 开关 |
| `<leader>ul` | 行号开关 |
| `<leader>uw` | 自动换行开关 |
| `<leader>ub` | 明暗主题切换 |
| `<leader>uC` | 选配色 |

截图里 `: i32` `: Arc<Mutex<u32>>` 那类类型提示就是 inlay hints, `<leader>uh` 关.

## 其他

| 键 | 作用 |
| --- | --- |
| `<leader>l` | Lazy 插件管理 |
| `<leader>qq` | 退出全部 |
| `<leader>qs` | 恢复会话 |
| `<leader>n` | 通知历史 |
| `s` | flash 跳转 |
| `gc` | 注释开关 (配合 motion) |
| `gcc` | 注释当前行 |
| `<C-/>` | 开关终端 (与 `<C-j>` 同) |
