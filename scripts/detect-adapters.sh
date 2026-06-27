#!/usr/bin/env bash
# detect-adapters.sh — scan for installed model CLIs from the registry and report
# availability with each adapter's default posture and cost rank.
#
# Output: one TSV line per registered adapter:
#   <available|missing>\t<id>\t<default_posture>\t<cost_rank>\t<resolved_path|->
# Exit code: 0 if at least one adapter is available, 3 if none (R4 signal for the caller).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REG="${TOKEN_EATER_REGISTRY:-$ROOT/adapters.yaml}"
[ -f "$REG" ] || { echo "registry not found: $REG" >&2; exit 2; }

# Extract id / default_posture / cost_rank per adapter block from the flat YAML list.
# (Deliberately dependency-free: no yq/python required on a member's machine.)
parse_registry() {
  awk '
    /^[[:space:]]*-[[:space:]]*id:/ {
      if (id != "") print id "\t" posture "\t" cost
      id = $0; sub(/.*id:[[:space:]]*/, "", id); gsub(/"/, "", id)
      posture = ""; cost = ""
    }
    /^[[:space:]]*default_posture:/ { posture = $0; sub(/.*default_posture:[[:space:]]*/, "", posture); gsub(/"/, "", posture) }
    /^[[:space:]]*cost_rank:/       { cost = $0;    sub(/.*cost_rank:[[:space:]]*/, "", cost);       gsub(/[^0-9]/, "", cost) }
    END { if (id != "") print id "\t" posture "\t" cost }
  ' "$REG"
}

available=0
while IFS=$'\t' read -r id posture cost; do
  [ -n "$id" ] || continue
  if path="$(command -v "$id" 2>/dev/null)"; then
    printf 'available\t%s\t%s\t%s\t%s\n' "$id" "$posture" "$cost" "$path"
    available=$((available + 1))
  else
    printf 'missing\t%s\t%s\t%s\t-\n' "$id" "$posture" "$cost"
  fi
done < <(parse_registry)

[ "$available" -gt 0 ] || exit 3
