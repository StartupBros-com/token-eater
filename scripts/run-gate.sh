#!/usr/bin/env bash
# run-gate.sh - run a deterministic project gate and classify pass/fail.
#
# Usage:
#   scripts/run-gate.sh [target-dir] [explicit gate command...]
#
# If an explicit command is provided, it wins. Otherwise this script detects a
# sensible deterministic gate from common project markers. It prints the gate it
# ran and exits 0 on PASS, non-zero on FAIL or when no gate can be found.
set -euo pipefail

# --list <dir>: print the ordered gate candidates (strongest first) and exit. Used by the ladder.
LIST=0
if [ "${1:-}" = "--list" ]; then LIST=1; shift; fi

TARGET="${1:-.}"
if [ "$#" -gt 0 ]; then
  shift
fi

if [ ! -d "$TARGET" ]; then
  echo "token-eater gate: target directory not found: $TARGET" >&2
  exit 2
fi

TARGET="$(cd "$TARGET" && pwd)"
GATE=""

has_cmd() {
  command -v "$1" >/dev/null 2>&1
}

has_package_script() {
  [ -f package.json ] || return 1
  grep -Eq '"'"$1"'"[[:space:]]*:' package.json
}

has_make_target() {
  [ -f Makefile ] || return 1
  grep -Eq '^[[:alnum:]_.%/-]+([[:space:]]+[[:alnum:]_.%/-]+)*:[^=]*$' Makefile || return 1
  grep -Eq '^'"$1"':[[:space:]]' Makefile || grep -Eq '^'"$1"':' Makefile
}

first_existing() {
  while [ "$#" -gt 0 ]; do
    [ -e "$1" ] && { echo "$1"; return 0; }
    shift
  done
  return 1
}

# Each detector emits candidate gates as "<ecosystem>\t<command>" lines, STRONGEST FIRST, with NO early
# return (so the ladder sees the full per-ecosystem list). Strongest = a behavior-proving gate
# (`typecheck && test`, `test`); `lint`/`format` are style gates DEMOTED below correctness — a broken or
# unconfigured lint script must never mask a working test gate. The ecosystem tag lets the ladder group
# candidates correctly even when commands within one ecosystem start with different binaries
# (pytest / uv / ruff), instead of guessing the ecosystem from the command's first word.
emit() { printf '%s\t%s\n' "$1" "$2"; }

detect_node_gate() {
  [ -f package.json ] || return 0
  if has_package_script typecheck && has_package_script test; then emit node "pnpm typecheck && pnpm test"; fi
  if has_package_script typecheck; then emit node "pnpm typecheck"; fi
  if has_package_script test; then emit node "pnpm test"; fi
  if has_package_script build; then emit node "pnpm build"; fi
  if has_package_script format:check; then emit node "pnpm format:check"; fi
  if has_package_script check:format; then emit node "pnpm check:format"; fi
  if has_package_script lint; then emit node "pnpm lint"; fi
  if [ -f tsconfig.json ] && has_cmd pnpm; then emit node "pnpm exec tsc --noEmit"; fi
  if [ -f biome.json ] && has_cmd pnpm; then emit node "pnpm exec biome check ."; fi
  if first_existing eslint.config.js eslint.config.mjs eslint.config.cjs .eslintrc .eslintrc.js .eslintrc.cjs .eslintrc.json >/dev/null && has_cmd pnpm; then emit node "pnpm exec eslint ."; fi
  if first_existing .prettierrc .prettierrc.json .prettierrc.yml .prettierrc.yaml .prettierrc.js prettier.config.js prettier.config.cjs >/dev/null && has_cmd pnpm; then emit node "pnpm exec prettier --check ."; fi
}

detect_make_gate() {
  [ -f Makefile ] || return 0
  has_make_target test      && emit make "make test"
  has_make_target check     && emit make "make check"
  has_make_target typecheck && emit make "make typecheck"
  has_make_target build     && emit make "make build"
  has_make_target lint      && emit make "make lint"
  return 0
}

detect_python_gate() {
  { [ -f pyproject.toml ] || [ -f pytest.ini ] || [ -d tests ]; } || return 0
  # correctness (tests) FIRST; lint/format demoted below
  if has_cmd pytest; then emit python "pytest"; fi
  if has_cmd uv && { [ -f pyproject.toml ] || [ -f pytest.ini ]; }; then emit python "uv run pytest"; fi
  if has_cmd ruff && { [ -f pyproject.toml ] || [ -f ruff.toml ] || [ -f .ruff.toml ]; }; then emit python "ruff check ."; emit python "ruff format --check ."; fi
}

detect_rust_gate() {
  [ -f Cargo.toml ] || return 0
  if has_cmd cargo; then emit rust "cargo test"; emit rust "cargo fmt --check"; fi
}

detect_go_gate() {
  [ -f go.mod ] || return 0
  if has_cmd go; then emit go "go test ./..."; fi
  if has_cmd gofmt && find . -name '*.go' -type f -not -path './.git/*' | grep -q .; then emit go "test -z \"\$(gofmt -l .)\""; fi
}

# Emit ALL candidate gates as "<eco>\t<cmd>", strongest first, across ecosystems (for the ladder / --list).
gate_candidates() {
  detect_node_gate 2>/dev/null || true
  detect_make_gate 2>/dev/null || true
  detect_python_gate 2>/dev/null || true
  detect_rust_gate 2>/dev/null || true
  detect_go_gate 2>/dev/null || true
}

detect_gate() {
  local first; first="$(gate_candidates | grep -v '^[[:space:]]*$' | head -1)"
  [ -n "$first" ] && { printf '%s\n' "${first#*$'\t'}"; return 0; }   # strip the eco tag -> bare command
  return 1
}

run_gate() {
  echo "token-eater gate: $GATE"
  # Bound every gate with a timeout: a watch-mode `test` script, a hanging install, or a gate run
  # against missing deps must not wedge the run forever. A gate that doesn't finish is not green.
  local ok=0
  if has_cmd timeout; then
    timeout "${TOKEN_EATER_GATE_TIMEOUT:-900}" bash -lc "$GATE" || ok=$?
  else
    bash -lc "$GATE" || ok=$?
  fi
  if [ "$ok" -eq 0 ]; then
    echo "token-eater gate: PASS"
    return 0
  fi
  [ "$ok" -eq 124 ] && echo "token-eater gate: TIMEOUT (>${TOKEN_EATER_GATE_TIMEOUT:-900}s)" >&2
  echo "token-eater gate: FAIL" >&2
  return 1
}

cd "$TARGET"

if [ "$LIST" = 1 ]; then
  gate_candidates | grep -v '^[[:space:]]*$'
  exit 0
fi

if [ "$#" -gt 0 ]; then
  GATE="$*"
else
  if ! GATE="$(detect_gate)"; then
    echo "token-eater gate: no deterministic gate found in $TARGET" >&2
    echo "token-eater gate: FAIL" >&2
    exit 4
  fi
fi

run_gate
