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

detect_node_gate() {
  [ -f package.json ] || return 1

  # Emit candidate gates in STRENGTH order (strongest first). The ladder (run-session.sh) tries them
  # in order and uses the strongest one that is green; `detect_gate` (single) returns the first.
  #
  # Strongest = a behavior-proving gate: `typecheck && test` together (Tier A). Then individual
  # correctness checks (Tier B). `lint`/`format` are style gates, demoted BELOW correctness — a broken
  # or unconfigured lint script must never mask a working test/typecheck/build gate.
  if has_package_script typecheck && has_package_script test; then echo "pnpm typecheck && pnpm test"; fi
  if has_package_script typecheck; then echo "pnpm typecheck"; fi
  if has_package_script test; then echo "pnpm test"; fi
  if has_package_script build; then echo "pnpm build"; fi
  if has_package_script format:check; then echo "pnpm format:check"; fi
  if has_package_script check:format; then echo "pnpm check:format"; fi
  if has_package_script lint; then echo "pnpm lint"; fi

  if [ -f tsconfig.json ] && has_cmd pnpm; then echo "pnpm exec tsc --noEmit"; fi
  if [ -f biome.json ] && has_cmd pnpm; then echo "pnpm exec biome check ."; fi
  if first_existing eslint.config.js eslint.config.mjs eslint.config.cjs .eslintrc .eslintrc.js .eslintrc.cjs .eslintrc.json >/dev/null && has_cmd pnpm; then
    echo "pnpm exec eslint ."
  fi
  if first_existing .prettierrc .prettierrc.json .prettierrc.yml .prettierrc.yaml .prettierrc.js prettier.config.js prettier.config.cjs >/dev/null && has_cmd pnpm; then
    echo "pnpm exec prettier --check ."
  fi
  return 0
}

detect_make_gate() {
  [ -f Makefile ] || return 1
  if has_make_target test; then echo "make test"; return 0; fi
  if has_make_target check; then echo "make check"; return 0; fi
  if has_make_target lint; then echo "make lint"; return 0; fi
  if has_make_target typecheck; then echo "make typecheck"; return 0; fi
  if has_make_target build; then echo "make build"; return 0; fi
  return 1
}

detect_python_gate() {
  if [ -f pyproject.toml ] || [ -f pytest.ini ] || [ -d tests ]; then
    if has_cmd ruff && { [ -f pyproject.toml ] || [ -f ruff.toml ] || [ -f .ruff.toml ]; }; then
      echo "ruff check ."; return 0
    fi
    if has_cmd pytest; then echo "pytest"; return 0; fi
    if has_cmd uv && { [ -f pyproject.toml ] || [ -f pytest.ini ]; }; then
      echo "uv run pytest"; return 0
    fi
  fi
  return 1
}

detect_rust_gate() {
  [ -f Cargo.toml ] || return 1
  if has_cmd cargo; then echo "cargo test"; return 0; fi
  return 1
}

detect_go_gate() {
  [ -f go.mod ] || return 1
  if has_cmd go; then echo "go test ./..."; return 0; fi
  return 1
}

detect_formatter_gate() {
  if has_cmd gofmt && find . -name '*.go' -type f -not -path './.git/*' | grep -q .; then
    echo "test -z \"\$(gofmt -l .)\""; return 0
  fi
  if has_cmd cargo && [ -f Cargo.toml ]; then echo "cargo fmt --check"; return 0; fi
  if has_cmd ruff && find . -name '*.py' -type f -not -path './.git/*' | grep -q .; then
    echo "ruff format --check ."; return 0
  fi
  return 1
}

# Emit ALL candidate gates, strongest first, across ecosystems (for the ladder / --list).
gate_candidates() {
  detect_node_gate 2>/dev/null || true
  detect_make_gate 2>/dev/null || true
  detect_python_gate 2>/dev/null || true
  detect_rust_gate 2>/dev/null || true
  detect_go_gate 2>/dev/null || true
  detect_formatter_gate 2>/dev/null || true
}

detect_gate() {
  local first; first="$(gate_candidates | grep -v '^[[:space:]]*$' | head -1)"
  [ -n "$first" ] && { printf '%s\n' "$first"; return 0; }
  return 1
}

run_gate() {
  echo "token-eater gate: $GATE"
  if bash -lc "$GATE"; then
    echo "token-eater gate: PASS"
    return 0
  fi
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
