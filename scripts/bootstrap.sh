#!/usr/bin/env bash
# Bring a fresh machine to the same state as this checkout.
# Safe to run repeatedly: every step checks before it acts.
set -uo pipefail

CONFIG_DIR="${NVIM_CONFIG_DIR:-$HOME/.config/nvim}"
FAILED=0

say()  { printf '\n==> %s\n' "$*"; }
ok()   { printf '    ok    %s\n' "$*"; }
warn() { printf '    warn  %s\n' "$*"; }
die()  { printf '    fail  %s\n' "$*"; FAILED=1; }

# Parsers this config expects, matching lua/plugins and the enabled extras.
PARSERS="bash c diff html javascript json lua luadoc markdown markdown_inline
         printf python query regex ron rust toml tsx typescript vim vimdoc xml yaml"

# Tools mason installs. rust-analyzer is not one of them; see the step below.
MASON_TOOLS="stylua shfmt taplo codelldb lua-language-server"

say "1/6 prerequisites"
command -v git >/dev/null || die "git missing"
command -v nvim >/dev/null || die "nvim missing"
if command -v nvim >/dev/null; then
  NVIM_VER=$(nvim --version | head -1 | sed 's/^NVIM v//')
  MAJOR=${NVIM_VER%%.*}; REST=${NVIM_VER#*.}; MINOR=${REST%%.*}
  if [ "$MAJOR" -eq 0 ] && [ "$MINOR" -lt 11 ]; then
    die "nvim $NVIM_VER is too old, 0.11 or newer required (verified on 0.12.4)"
  else
    ok "nvim $NVIM_VER"
  fi
fi
[ -d "$CONFIG_DIR" ] || die "$CONFIG_DIR does not exist, clone this repo there first"
[ "$FAILED" -eq 1 ] && { printf '\nPrerequisites failed, stopping.\n'; exit 1; }

say "2/6 rust-analyzer"
# The easiest thing to get wrong here. rust-analyzer is a per-toolchain rustup
# component: installing it for stable leaves a project pinned by a
# rust-toolchain.toml without a language server. In that state <C-]> answers
# "E426: Tag not found", which points at ctags and hides the real cause.
# Installing it for every toolchain avoids that.
if command -v rustup >/dev/null; then
  while read -r tc; do
    [ -z "$tc" ] && continue
    if [ -x "$HOME/.rustup/toolchains/$tc/bin/rust-analyzer" ]; then
      ok "$tc already has it"
    elif rustup component add rust-analyzer --toolchain "$tc" >/dev/null 2>&1; then
      ok "$tc installed"
    else
      warn "$tc does not offer the component (toolchains older than 2021), skipped"
    fi
  done < <(rustup toolchain list | sed 's/ (.*)//')
else
  warn "no rustup, skipped. Fine if you do not write Rust"
fi

say "3/6 plugins, restored to the commits in lazy-lock.json"
# restore rather than sync: sync would pull the latest and the two machines
# would no longer match.
LOG=$(mktemp)
nvim --headless "+Lazy! restore" +qa >"$LOG" 2>&1
LOCKED=$(grep -c '": {' "$CONFIG_DIR/lazy-lock.json")
PRESENT=$(find "${XDG_DATA_HOME:-$HOME/.local/share}/nvim/lazy" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
if [ "$PRESENT" -ge "$LOCKED" ]; then
  ok "$PRESENT plugin directories, lock file lists $LOCKED"
else
  die "only $PRESENT plugin directories, lock file lists $LOCKED"
  tail -5 "$LOG"
fi
rm -f "$LOG"

say "4/6 mason tools"
# mason.nvim is lazy-loaded, so :MasonInstall does not exist in a headless
# session until it is loaded explicitly.
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
  if [ -x "$MASON_BIN/$t" ]; then ok "$t"; else die "$t missing, install it from :Mason"; fi
done

say "5/6 treesitter parsers"
# shellcheck disable=SC2086
nvim --headless "+TSInstall! $PARSERS" +qa >/dev/null 2>&1
PARSER_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/nvim/site/parser"
MISSING=""
for lang in $PARSERS; do
  [ -f "$PARSER_DIR/$lang.so" ] || MISSING="$MISSING $lang"
done
if [ -z "$MISSING" ]; then
  ok "$(find "$PARSER_DIR" -name '*.so' | wc -l | tr -d ' ') parsers"
else
  warn "missing:$MISSING  install them with :TSInstall"
fi

say "6/6 result"
nvim --headless -c 'lua
local n = 0
for _ in pairs(require("lazy.core.config").plugins) do n = n + 1 end
print(string.format("    %d plugins", n))
print(string.format("    extras %s", vim.inspect(require("lazyvim.config").json.data.extras)))
' -c qa 2>&1 | grep -E "^\s+([0-9]+ plugins|extras)" || warn "could not read the summary"

cat <<'TIP'

    Still to check by hand:
      - a Nerd Font in the terminal, or icons render as boxes
      - :checkhealth
      - :MouseBlameDebug, if you want blame on mouse hover rather than on hold

TIP
[ "$FAILED" -eq 1 ] && exit 1
exit 0
