# nvim

基于 [LazyVim](https://github.com/LazyVim/LazyVim) 的个人配置, 主要用于 Rust.
除 LazyVim 之外还带四个自写模块, 都在 `lua/` 下, 不是第三方插件.

在 Neovim 0.12.4 / macOS 上验证.

## 换机器安装

```sh
git clone <本仓库地址> ~/.config/nvim
~/.config/nvim/scripts/bootstrap.sh
```

脚本会按 `lazy-lock.json` 把插件还原到锁定的 commit(用 `restore` 不用 `sync`,
后者会拉最新, 两台机器就不一致了), 装 mason 工具和 treesitter parser, 并为
**每一个**已安装的 rustup toolchain 装 rust-analyzer 组件.

最后一件事单独说明. rust-analyzer 是 rustup 的 per-toolchain 组件, 装在 stable
上不会让钉了具体版本的项目用上它. 项目里有 `rust-toolchain.toml` 时, LSP 起不来,
按 `<C-]>` 只会看到 `E426: Tag not found` -- 这个报错指向 ctags, 与 LSP 无关,
很容易误判. 脚本对所有 toolchain 都装一遍来规避.

装完还需要手动确认:

- 终端字体用 Nerd Font
- `:checkhealth`
- `:MouseBlameDebug` 判断终端上不上报鼠标移动

## 快捷键

常用键位见 [KEYMAPS.md](KEYMAPS.md), 由运行中的 nvim 导出后整理. 四个自写模块
的入口:

| 键 | 作用 |
| --- | --- |
| `gt` | 当前行每个子表达式的类型 |
| `<leader>cg` | 光标处符号的调用关系 |
| 光标停留 | 该行的 git 提交信息, 无需按键 |
| winbar | 光标所在函数的签名, 自动 |

## 自写模块

### codemap -- `<leader>cg`

光标处符号的调用关系, 浮窗展示, 数据全部来自 LSP.

光标在**函数**上时是左右两栏: 左边 `被调用`(callHierarchy/incomingCalls),
右边 `调用`(outgoingCalls), `<Tab>` 可以顺着调用链递归展开, 深度上限 6.
光标在**类型, 字段, 常量**上时 callHierarchy 返回空, 这时换成单栏引用列表
(textDocument/references), 每条带上那一行的源码.

面板内按键: `j/k` 移动, `h/l` 换栏, `<Tab>` 展开, `<CR>` 跳转(跳前 `m'` 入
jumplist, `<C-o>` 可回), `d` 展开完整文档, `r` 重查, `q` 关闭, `g?` 看键位.

增量渲染: 四个请求里 hover 是毫秒级的, references 和 incomingCalls 要全 workspace
搜索. 所以哪个先回来就先画哪块, 未到的栏显示 `(查询中)`. 实测在 11 个调用者的
函数上, 签名和文档 11ms 上屏, 调用关系 495ms 补齐; 改成增量之前要等满 495ms.

节点逐行淡入是用 extmark 把前景色从背景色插值到目标色实现的, 需要
`termguicolors`; 没开则直接显示. `setup({ animate = false })` 可关.

不绑定 Rust, 任何支持 callHierarchy 的 LSP 都能用.

### typechain -- `gt`

光标所在行每个子表达式的类型.

```
 f                                    -> Vec<&str, Global>
 line                                 -> &str
 |- .split(',')                       -> Split<'_, char>
    |- .map(str::trim)                -> Map<Split<'_, char>, fn trim(&str) -> &str>
       |- .collect()                  -> Vec<&str, Global>
```

依赖 rust-analyzer 的一个非标准扩展: `textDocument/hover` 的 `position` 传
Range 时返回那一段表达式的类型. LSP 标准的 hover 只接受单个位置, 在
`line.split(',').map(f).collect()` 上无论点哪里都只会返回 `line` 的类型.

子表达式由 treesitter 切分, 并过滤掉冗余节点 -- `line.split` 这种「调用的函数
部分」与 `line.split(',')` 类型完全相同, 不重复列出. 链式调用自动缩进并只显示
增量, 不必在重复前缀里找差异.

别的语言服务器不认 Range 时会退化成按起点返回, 输出价值降低但不会出错.

### mouseblame

鼠标停在某行上 350ms, 浮窗显示该行的 git 提交信息.

`git blame -L n,n --porcelain` 异步取 sha, 作者, 时间和 subject, 先画一次;
随后 `git log -1 --format=%b` 把 commit body 追加进去, 浮窗自动长高.
缓冲区有未保存改动时会提示行号可能与 blame 不一致, 因为 blame 读的是磁盘文件.

依赖终端上报无按键的鼠标移动(xterm 1003 any-event). 终端不支持时不会报错,
只是什么都不发生. 用 `:MouseBlameDebug` 判断; 不支持就用 `:MouseBlameLine`
查光标行, 或 gitsigns 的 `<leader>ghb`.

其他命令: `:MouseBlameToggle`.

### funcsig

winbar 常驻显示光标所在函数的签名, 在 impl 块内会带上类型上下文:

```
ApiResponse<T>  ·  pub fn ok(data: T) -> Self
```

走 treesitter 不走 LSP, 光标移动时重算不给语言服务器加负担, 也不受索引状态影响.
`:FuncSigToggle` 可关.

## 覆盖的默认键位

| 键 | 本配置 | 被覆盖的 LazyVim 默认 |
| --- | --- | --- |
| `<C-j>` | 开关浮动终端 | 切到下方窗口(改用内置 `<C-w>j`) |
| `gt` | 类型链 | vim 的切 tab 页, 这里用不到 |

`<C-j>` 在终端模式下也绑了, 所以 Ctrl-J 不再透传给 shell. 要留给 shell 就在
`lua/config/keymaps.lua` 里删掉 `"t"`, 改用 LazyVim 自带的 `<C-/>` 退出终端.

## 启用的 LazyVim extras

见 `lazyvim.json`. 当前为 `lang.rust`, `lang.toml`, `dap.core`.

`dap.core` 带来 nvim-dap, nvim-dap-ui 和 nvim-dap-virtual-text; 配合
`lang.rust` 装的 codelldb, 断点停住后变量的实际值会以虚拟文本显示在行尾.
Rust 场景下 `<leader>dr` 是 rustaceanvim 的 buffer-local 映射(列出可调试目标),
会盖掉 dap.core 的 Toggle REPL.

## 目录

```
init.lua                 入口
KEYMAPS.md               快捷键
lazyvim.json             启用的 extras, 必须提交
lazy-lock.json           插件版本锁, 必须提交
lua/config/lazy.lua      lazy.nvim 引导
lua/config/modules.lua   四个自写模块的装载
lua/config/keymaps.lua   键位
lua/config/options.lua   选项
lua/config/autocmds.lua  autocmd
lua/plugins/             插件覆盖
lua/codemap/             自写模块
lua/typechain/
lua/mouseblame/
lua/funcsig/
scripts/bootstrap.sh     新机器安装
```

## 已知环境限制

- Warp 不支持 kitty graphics 协议, 也不支持 sixel, nvim 里无法内联显示图片.
  `snacks.image` 的 `force = true` 只是跳过能力检测, 不会让它真的画出来.
  需要内联图片就换 Ghostty, kitty 或 WezTerm.
- 同一个 rustc 版本在 rustup 里可能存在两个独立 toolchain(`stable` 与 `1.96.0`),
  组件要分别安装. 见上面安装一节.
