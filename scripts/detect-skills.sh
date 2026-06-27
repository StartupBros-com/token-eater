#!/usr/bin/env bash
# detect-skills.sh — resolve each chore archetype in skills-catalog.yaml to one of:
#   installed             -> a skill that performs it is present; use it
#   hov-dropin-available  -> nothing installed, but a (stubbed) House of Vibe drop-in exists; suggest it
#   bundled               -> token-eater drives it directly with a bundled prompt / tool
#   missing               -> nothing installed and no drop-in; skip the archetype
#
# Output: one TSV line per archetype: <status>\t<archetype>\t<tier-or-detail>
# Dependency-free (awk + filesystem + command -v). Skills are detected by filesystem
# presence so it works for House of Vibe members, not just this machine.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CAT="${TOKEN_EATER_CATALOG:-$ROOT/skills-catalog.yaml}"
[ -f "$CAT" ] || { echo "catalog not found: $CAT" >&2; exit 2; }

claude_skill_present() {
  local n="$1"
  [ -d "$HOME/.claude/skills/$n" ] && return 0
  find "$HOME/.claude/plugins" -maxdepth 7 -type d -name "$n" -path '*/skills/*' 2>/dev/null | grep -q . && return 0
  return 1
}
grok_skill_present() { [ -d "$HOME/.grok/skills/$1" ]; }

# Extract archetype / detect / hov_dropin per block from the (flat-list) catalog.
parse_catalog() {
  awk '
    /^[[:space:]]*-[[:space:]]*archetype:/ { if (a!="") print a "\t" d "\t" h; a=$0; sub(/.*archetype:[[:space:]]*/,"",a); d=""; h="" }
    /^[[:space:]]*detect:/     { d=$0; sub(/.*detect:[[:space:]]*/,"",d); gsub(/"/,"",d) }
    /^[[:space:]]*hov_dropin:/ { h=$0; sub(/.*hov_dropin:[[:space:]]*/,"",h); gsub(/"/,"",h) }
    /^hov_registry:/ { if (a!="") { print a "\t" d "\t" h; a="" } }   # stop at the registry section
    END { if (a!="") print a "\t" d "\t" h }
  ' "$CAT"
}

while IFS=$'\t' read -r arch detect hov; do
  [ -n "$arch" ] || continue
  if [ -z "$detect" ] || [ "$detect" = "null" ]; then
    printf 'bundled\t%s\t-\n' "$arch"; continue
  fi
  present=0
  for tok in $detect; do
    kind="${tok%%:*}"; name="${tok#*:}"
    case "$kind" in
      claude-skill) claude_skill_present "$name" && { present=1; break; } ;;
      grok-skill)   grok_skill_present  "$name" && { present=1; break; } ;;
      cmd)          command -v "$name" >/dev/null 2>&1 && { present=1; break; } ;;
    esac
  done
  if [ "$present" = 1 ]; then
    printf 'installed\t%s\t%s\n' "$arch" "$name"
  elif [ -n "$hov" ] && [ "$hov" != "null" ]; then
    printf 'hov-dropin-available\t%s\t%s\n' "$arch" "$hov"
  else
    printf 'missing\t%s\t-\n' "$arch"
  fi
done < <(parse_catalog)
