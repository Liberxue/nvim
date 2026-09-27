# nvim

A LazyVim config, used mostly for Rust. Beyond LazyVim it carries four local
modules under `lua/`, none of which are third-party plugins.

Verified on Neovim 0.12.4, macOS.

## Installing on another machine

```sh
git clone git@github.com:Liberxue/nvim.git ~/.config/nvim
~/.config/nvim/scripts/bootstrap.sh
```

The script restores plugins to the commits in `lazy-lock.json` rather than
syncing them, installs the mason tools and treesitter parsers, and adds the
rust-analyzer component to **every** installed rustup toolchain.

That last step is worth explaining. rust-analyzer is a per-toolchain rustup
component, so installing it for stable does nothing for a project pinned by a
`rust-toolchain.toml`. Such a project gets no language server, and `<C-]>`
answers `E426: Tag not found` -- a ctags error that says nothing about the LSP
and is easy to chase in the wrong direction.

Left to do by hand afterwards:

- a Nerd Font in the terminal
- `:checkhealth`
- `:MouseBlameDebug`, if you want blame on mouse hover rather than on hold

## Keymaps

[KEYMAPS.md](KEYMAPS.md) lists the bindings worth remembering; it was generated
from a running nvim. The local modules are reached through:

| Key | Does |
| --- | --- |
| `gt` | type of every sub-expression on the current line |
| `<leader>cg` | call hierarchy for the symbol under the cursor |
| cursor hold | commit behind the current line |
| winbar | signature of the enclosing function |

## Local modules

### codemap -- `<leader>cg`

Call relationships for the symbol under the cursor, drawn in a floating window
from LSP data alone.

On a **function** it shows two columns: callers on the left
(`callHierarchy/incomingCalls`), calls on the right (`outgoingCalls`), with
`<Tab>` walking either chain up to six levels deep. On a **type, field or
constant** callHierarchy comes back empty, so it falls back to a single column
of references (`textDocument/references`), each carrying its source line.

Inside the panel: `j/k` move, `h/l` switch column, `<Tab>` expands, `<CR>` jumps
(after `m'`, so `<C-o>` comes back), `d` shows the full documentation, `r`
requeries, `q` closes, `g?` prints the keys.

It renders incrementally. Of the four requests it makes, hover answers in
milliseconds while references and incomingCalls search the whole workspace, so
each part is drawn as it lands and pending columns read `(querying)`. On a
function with eleven callers the signature and documentation reach the screen in
11ms and the call hierarchy fills in at 495ms; waiting for all four meant 495ms
before anything appeared.

Rows fade in through extmarks that interpolate the foreground from the
background colour, which needs `termguicolors`; without it they simply appear.
`setup({ animate = false })` turns it off.

Nothing here is Rust-specific -- any server with callHierarchy works.

### typechain -- `gt`

The type of every sub-expression on the current line.

```
 f                                    -> Vec<&str, Global>
 line                                 -> &str
 |- .split(',')                       -> Split<'_, char>
    |- .map(str::trim)                -> Map<Split<'_, char>, fn trim(&str) -> &str>
       |- .collect()                  -> Vec<&str, Global>
```

This rests on an extension rust-analyzer offers: `textDocument/hover` accepts a
Range where the spec says position, and answers with the type of that span.
Standard hover takes a single position, so on
`line.split(',').map(f).collect()` every position in the chain answers with the
type of `line`.

treesitter splits the line into sub-expressions, minus the redundant ones -- the
callee half of a call, `line.split`, has the same type as `line.split(',')` and
is not listed twice. Chained calls are indented and show only what each step
adds, so the differences are not buried in a shared prefix.

A server without the Range extension degrades to answering by start position:
less useful, not an error.

### mouseblame

The commit behind the line the cursor rests on, after 200ms.

`git blame -L n,n --porcelain` fetches sha, author, time and subject
asynchronously and draws once; `git log -1 --format=%b` then appends the commit
body and the popup grows. A modified buffer gets a warning that the line numbers
may not line up, since blame reads the file on disk.

The trigger is CursorHold. Mouse hover needs the terminal to report motion with
no button held (xterm 1003 any-event), which Warp does not do -- there
`:MouseBlameDebug` sees no `<MouseMove>` at all. On a terminal that does report
it, `setup({ source = "both" })` enables both.

Also: `:MouseBlameLine` queries the cursor line without waiting,
`:MouseBlameToggle` turns it off.

gitsigns annotates the end of the cursor line with author and summary, which is
the other half of what GitLens shows. Both fire on the same CursorHold; the
annotation is glanceable and the popup adds the commit body. Drop either with
`:Gitsigns toggle_current_line_blame` or `:MouseBlameToggle`. `<leader>gH` lists
the commits that touched the current line, `<leader>gf` the whole file.

### funcsig

The enclosing function's signature in the winbar, prefixed with the impl context
where there is one:

```
ApiResponse<T>  ·  pub fn ok(data: T) -> Self
```

It reads treesitter rather than the LSP, so recomputing it on every cursor move
costs the language server nothing and works before the index is ready.
`:FuncSigToggle` turns it off.

## Overridden defaults

| Key | Here | LazyVim default |
| --- | --- | --- |
| `<C-j>` | floating terminal | window down (use `<C-w>j`) |
| `gt` | type chain | vim's tab paging, unused here |

`<C-j>` is bound in terminal mode too, so Ctrl-J no longer reaches the shell.
Drop the `"t"` in `lua/config/keymaps.lua` to give it back and use LazyVim's
`<C-/>` to leave the terminal.

## LazyVim extras

Listed in `lazyvim.json`: `lang.rust`, `lang.toml`, `dap.core`.

`dap.core` brings nvim-dap, nvim-dap-ui and nvim-dap-virtual-text. With codelldb
from `lang.rust`, stopping at a breakpoint shows each variable's actual value as
virtual text at the end of its line. In Rust, `<leader>dr` is a buffer-local
rustaceanvim mapping that lists debuggable targets, shadowing dap.core's
Toggle REPL.

## Layout

```
init.lua                 entry point
KEYMAPS.md               keymaps
lazyvim.json             enabled extras, must be committed
lazy-lock.json           plugin versions, must be committed
lua/config/lazy.lua      lazy.nvim bootstrap
lua/config/modules.lua   loads the four local modules
lua/config/keymaps.lua   keymaps
lua/config/options.lua   options
lua/config/autocmds.lua  autocmds
lua/plugins/             plugin overrides
lua/codemap/             local modules
lua/typechain/
lua/mouseblame/
lua/funcsig/
scripts/bootstrap.sh     install on a new machine
```

## Environment notes

- Warp supports neither the kitty graphics protocol nor sixel, so images cannot
  render inline in nvim there. `snacks.image` with `force = true` only skips the
  capability check; it does not make the image appear. Ghostty, kitty or WezTerm
  do work.
- One rustc version can exist as two separate rustup toolchains (`stable` and
  `1.96.0`), each needing its own components. See the install section.
