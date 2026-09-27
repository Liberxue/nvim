# Keymaps

`<leader>` is space. Entries marked `*` are specific to this config or override
a LazyVim default; the rest are LazyVim's. For the full list, press `<leader>`
and wait for which-key, or run `:map`.

Generated from a running nvim, so it matches what is actually bound.

## This config

| Key | Does |
| --- | --- |
| `gt` | type of every sub-expression on the current line |
| `<leader>cg` | call hierarchy for the symbol under the cursor |
| `<C-j>` | floating terminal, in normal and terminal mode |

Resting the cursor on a symbol for 200ms shows its signature and documentation.
No key needed. Git history stays out of the way: the end of the line carries
author and summary, and `:MouseBlameLine` opens the full commit.

Commands: `:TypeChain` `:CodeMap` `:HoverDocToggle` `:MouseBlameLine`
`:MouseBlameToggle` `:MouseBlameDebug` `:FuncSigToggle`

## Overridden defaults

| Key | Here | LazyVim default | Instead |
| --- | --- | --- | --- |
| `<C-j>` | floating terminal | window down | `<C-w>j` |
| `gt` | type chain | vim's tab paging | buffers are `<S-h>` / `<S-l>` |

`<C-j>` is bound in terminal mode too, so Ctrl-J no longer reaches the shell.
Drop the `"t"` in `lua/config/keymaps.lua` to give it back and leave terminals
with `<C-/>`.

## Navigation

| Key | Does |
| --- | --- |
| `gd` | definition |
| `gD` | declaration |
| `gr` | references |
| `gI` | implementations |
| `gy` | type definition |
| `gK` | signature help |
| `gO` | document symbols |
| `gt` * | type chain for the current line |
| `<leader>cg` * | call hierarchy |
| `<C-]>` / `<C-t>` | jump / return, through the LSP tagfunc |
| `<C-o>` / `<C-i>` | back / forward in the jumplist |

In Rust the first `gd` may do nothing while rust-analyzer builds its index; a
workspace of a dozen crates takes minutes the first time. `:checkhealth vim.lsp`
shows whether a client has attached.

## Code actions `<leader>c`

| Key | Does |
| --- | --- |
| `<leader>ca` | code action |
| `<leader>cA` | source action |
| `<leader>cr` | rename symbol |
| `<leader>cR` | rename file |
| `<leader>cf` | format |
| `<leader>cd` | line diagnostics |
| `<leader>cs` | symbols (Trouble) |
| `<leader>cS` | references and definitions (Trouble) |
| `<leader>cl` | LSP info |
| `<leader>cm` | Mason |
| `<leader>cc` | run codelens |
| `<leader>ce` * | compile on godbolt |
| `<leader>cE` * | compile on godbolt, live |
| `<leader>cw` * | open godbolt in the browser |

Rust adds these, all from rust-analyzer through rustaceanvim:

| Key | Does |
| --- | --- |
| `<leader>cx` | expand the macro under the cursor |
| `<leader>cp` | jump to the parent module |
| `<leader>cD` | open docs.rs for the symbol |
| `<leader>cT` | open Cargo.toml |
| `<leader>cy` | syntax tree |
| `<leader>cI` / `<leader>cH` | view MIR / HIR |
| `<leader>cj` | join lines |
| `<leader>cP` | rebuild proc macros |

`gd` on a macro lands on its definition, which for a derive or proc macro is not
where the generated code is; `<leader>cx` runs the expansion instead.

In Rust, rustaceanvim rebinds `<leader>cR` to code action as a buffer-local
mapping.

## Finding `<leader>f` `<leader>s`

| Key | Does |
| --- | --- |
| `<leader><space>` | find files |
| `<leader>ff` | find files (project root) |
| `<leader>fF` | find files (cwd) |
| `<leader>fg` | find git-tracked files |
| `<leader>fr` | recent files |
| `<leader>fb` | buffers |
| `<leader>fp` | projects |
| `<leader>fe` | file explorer |
| `<leader>fc` | open this config |
| `<leader>sg` | grep |
| `<leader>sw` | search the word under the cursor |
| `<leader>sb` | search the current buffer |
| `<leader>ss` | document symbols |
| `<leader>sS` | workspace symbols |
| `<leader>sd` | diagnostics |
| `<leader>sk` | search keymaps |
| `<leader>sR` | resume the last search |

## Git `<leader>g`

| Key | Does |
| --- | --- |
| `<leader>gg` | lazygit |
| `<leader>gb` | blame the current line |
| `<leader>ghb` | blame the current line (gitsigns) |
| `<leader>ghB` | blame the whole file |
| `<leader>gd` | hunk diff |
| `<leader>gf` | history of the current file |
| `<leader>gH` * | history of the current line, git log -L |
| `<leader>gL` | log |
| `<leader>gB` | open in the browser |
| `]h` / `[h` | next / previous hunk |

The author and summary at the end of the cursor line come from gitsigns.
`:Gitsigns toggle_current_line_blame` turns them off.

## Debugging `<leader>d`

Uses codelldb, installed with `lang.rust`.

| Key | Does |
| --- | --- |
| `<leader>db` | toggle breakpoint |
| `<leader>dB` | conditional breakpoint |
| `<leader>dc` | run or continue |
| `<leader>da` | run with arguments |
| `<leader>di` | step into |
| `<leader>dO` | step over |
| `<leader>do` | step out |
| `<leader>dC` | run to cursor |
| `<leader>de` | evaluate |
| `<leader>du` | toggle dap-ui |
| `<leader>dr` | Rust: list debuggable targets |

At a breakpoint each variable's value appears as virtual text at the end of its
line. In Rust, `<leader>dr` is a buffer-local rustaceanvim mapping that shadows
the default Toggle REPL.

## Buffers and windows

| Key | Does |
| --- | --- |
| `<S-h>` / `<S-l>` | previous / next buffer |
| `<leader>bd` | close this buffer |
| `<leader>bo` | close other buffers |
| `<leader>bp` | pin buffer |
| `<C-h/j/k/l>` | move between windows. **`<C-j>` is taken; use `<C-w>j`** |
| `<leader>wd` | close window |
| `<leader>wm` | toggle zoom |
| `<C-arrow>` | resize window |

## Diagnostics and lists `<leader>x`

| Key | Does |
| --- | --- |
| `<leader>xx` | diagnostics (Trouble) |
| `<leader>xX` | buffer diagnostics |
| `<leader>xq` | quickfix |
| `<leader>xt` | todo list |
| `]d` / `[d` | next / previous diagnostic |
| `]e` / `[e` | next / previous error |

## Toggles `<leader>u`

| Key | Does |
| --- | --- |
| `<leader>ud` | diagnostics |
| `<leader>uf` | format on save |
| `<leader>uh` | inlay hints |
| `<leader>ul` | line numbers |
| `<leader>uw` | line wrap |
| `<leader>ub` | dark background |
| `<leader>uC` | pick a colorscheme |

The `: i32` and `: Arc<Mutex<u32>>` annotations in the buffer are inlay hints;
`<leader>uh` turns them off.

## Other

| Key | Does |
| --- | --- |
| `<leader>l` | Lazy |
| `<leader>qq` | quit all |
| `<leader>qs` | restore session |
| `<leader>n` | notification history |
| `s` | flash jump |
| `gc` | toggle comment, with a motion |
| `gcc` | toggle comment on this line |
| `<C-/>` | terminal, same as `<C-j>` |
