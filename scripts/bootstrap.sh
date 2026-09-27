#!/usr/bin/env bash
# 在新机器上把这份 nvim 配置还原到同一状态.
# 可以重复执行, 每一步先检查再动手.
set -uo pipefail

CONFIG_DIR="${NVIM_CONFIG_DIR:-$HOME/.config/nvim}"
FAILED=0

say()  { printf '\n==> %s\n' "$*"; }
ok()   { printf '    ok    %s\n' "$*"; }
warn() { printf '    warn  %s\n' "$*"; }
die()  { printf '    fail  %s\n' "$*"; FAILED=1; }

# 这份配置用到的 treesitter parser. 与 lua/plugins 和已启用的 LazyVim extras 对应.
PARSERS="bash c diff html javascript json lua luadoc markdown markdown_inline
         printf python query regex ron rust toml tsx typescript vim vimdoc xml yaml"

# mason 管理的外部工具. rust-analyzer 不在这里, 见下面单独一步.
MASON_TOOLS="stylua shfmt taplo codelldb lua-language-server"

say "1/6 前置检查"
command -v git >/dev/null || die "缺 git"
command -v nvim >/dev/null || die "缺 nvim"
if command -v nvim >/dev/null; then
  NVIM_VER=$(nvim --version | head -1 | sed 's/^NVIM v//')
  MAJOR=${NVIM_VER%%.*}; REST=${NVIM_VER#*.}; MINOR=${REST%%.*}
  if [ "$MAJOR" -eq 0 ] && [ "$MINOR" -lt 11 ]; then
    die "nvim $NVIM_VER 过旧, 需要 0.11 以上(本配置在 0.12.4 上验证)"
  else
    ok "nvim $NVIM_VER"
  fi
fi
[ -d "$CONFIG_DIR" ] || die "$CONFIG_DIR 不存在, 先 clone 本仓库到该路径"
[ "$FAILED" -eq 1 ] && { printf '\n前置检查未通过, 中止.\n'; exit 1; }

say "2/6 rust-analyzer"
# 这一步是本配置最容易踩的坑: rust-analyzer 是 rustup 的 per-toolchain 组件,
# 装在 stable 上并不会让钉了具体版本的项目(rust-toolchain.toml)用上它.
# 那种情况下 nvim 里按 <C-]> 只会得到 "E426: Tag not found", 因为 LSP 根本没起来.
# 所以这里对每个已安装的 toolchain 都装一遍.
if command -v rustup >/dev/null; then
  while read -r tc; do
    [ -z "$tc" ] && continue
    if [ -x "$HOME/.rustup/toolchains/$tc/bin/rust-analyzer" ]; then
      ok "$tc 已有"
    elif rustup component add rust-analyzer --toolchain "$tc" >/dev/null 2>&1; then
      ok "$tc 已安装"
    else
      warn "$tc 不提供该组件(2021 年之前的 toolchain 没有), 跳过"
    fi
  done < <(rustup toolchain list | sed 's/ (.*)//')
else
  warn "没有 rustup, 跳过. 不写 Rust 可以忽略"
fi

say "3/6 插件: 按 lazy-lock.json 还原到锁定的 commit"
# 用 restore 不用 sync. sync 会拉最新, 那样两台机器就不一样了.
LOG=$(mktemp)
nvim --headless "+Lazy! restore" +qa >"$LOG" 2>&1
LOCKED=$(grep -c '": {' "$CONFIG_DIR/lazy-lock.json")
PRESENT=$(find "${XDG_DATA_HOME:-$HOME/.local/share}/nvim/lazy" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
if [ "$PRESENT" -ge "$LOCKED" ]; then
  ok "$PRESENT 个插件目录, lock 文件记录 $LOCKED 个"
else
  die "只有 $PRESENT 个插件目录, lock 文件记录 $LOCKED 个"
  tail -5 "$LOG"
fi
rm -f "$LOG"

say "4/6 mason 工具"
# mason.nvim 是懒加载的, headless 启动时 :MasonInstall 还不存在, 必须先 load.
MASON_BIN="${XDG_DATA_HOME:-$HOME/.local/share}/nvim/mason/bin"
MISSING=""
for t in $MASON_TOOLS; do
  [ -x "$MASON_BIN/$t" ] || MISSING="$MISSING $t"
done
if [ -n "$MISSING" ]; then
  # shellcheck disable=SC2086
  nvim --headless "+Lazy! load mason.nvim" "+MasonInstall$MISSING" +qa >/dev/null 2>&1
fi
for t in $MASON_TOOLS; do
  if [ -x "$MASON_BIN/$t" ]; then ok "$t"; else die "$t 未装上, 进 nvim 用 :Mason 手动补"; fi
done

say "5/6 treesitter parser"
# shellcheck disable=SC2086
nvim --headless "+TSInstall! $PARSERS" +qa >/dev/null 2>&1
PARSER_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/nvim/site/parser"
MISSING=""
for lang in $PARSERS; do
  [ -f "$PARSER_DIR/$lang.so" ] || MISSING="$MISSING $lang"
done
if [ -z "$MISSING" ]; then
  ok "$(find "$PARSER_DIR" -name '*.so' | wc -l | tr -d ' ') 个 parser"
else
  warn "缺:$MISSING  进 nvim 用 :TSInstall 手动补"
fi

say "6/6 结果"
nvim --headless -c 'lua
local n = 0
for _ in pairs(require("lazy.core.config").plugins) do n = n + 1 end
print(string.format("    插件 %d 个", n))
print(string.format("    extras %s", vim.inspect(require("lazyvim.config").json.data.extras)))
' -c qa 2>&1 | grep -E "^\s+(插件|extras)" || warn "统计失败"

cat <<'TIP'

    还需要手动确认的:
      - 终端字体装 Nerd Font, 否则图标显示成方块
      - :checkhealth 看有没有红项
      - :MouseBlameDebug 判断终端上不上报鼠标移动, 不支持就用 :MouseBlameLine

TIP
[ "$FAILED" -eq 1 ] && exit 1
exit 0
