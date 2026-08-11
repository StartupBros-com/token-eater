#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "$3: expected $2, got $1"; pass "$3"; }

mkdir -p "$TMP/bin" "$TMP/source/.claude-plugin"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "$CURL_LOG"\n' > "$TMP/bin/curl"
chmod +x "$TMP/bin/curl"
printf '{"name":"token-eater","version":"0.1.1"}\n' > "$TMP/source/.claude-plugin/plugin.json"
git -C "$TMP/source" init -q
git -C "$TMP/source" config user.email test@example.com
git -C "$TMP/source" config user.name Test
git -C "$TMP/source" add .
git -C "$TMP/source" commit -qm source
git -C "$TMP/source" tag v0.1.1
SOURCE_SHA="$(git -C "$TMP/source" rev-parse HEAD)"

mkdir -p "$TMP/seed/.claude-plugin" "$TMP/seed/scripts"
printf '%s\n' '{"name":"hov","owner":{"name":"House of Vibe","url":"https://houseofvibe.ai"},"metadata":{"description":"test","version":"0.2.0"},"plugins":[{"name":"token-eater","description":"test","source":{"source":"url","url":"https://github.com/StartupBros-com/token-eater.git","sha":"0000000000000000000000000000000000000000"}},{"name":"pro-gate","description":"test","source":{"source":"url","url":"https://github.com/StartupBros-com/pro-gate.git","sha":"1111111111111111111111111111111111111111"}}]}' > "$TMP/seed/.claude-plugin/marketplace.json"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/seed/scripts/validate-marketplace.sh"
chmod +x "$TMP/seed/scripts/validate-marketplace.sh"
git -C "$TMP/seed" init -q
git -C "$TMP/seed" config user.email test@example.com
git -C "$TMP/seed" config user.name Test
git -C "$TMP/seed" add .
git -C "$TMP/seed" commit -qm seed
git -C "$TMP/seed" branch -M main
git clone -q --bare "$TMP/seed" "$TMP/marketplace.git"
git clone -q "$TMP/marketplace.git" "$TMP/marketplace"
git -C "$TMP/marketplace" config user.email test@example.com
git -C "$TMP/marketplace" config user.name Test

REAL_GIT="$(command -v git)"
cat > "$TMP/bin/git" <<'GIT_WRAPPER'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == push && "${RACE_ON_FIRST_PUSH:-0}" == 1 && ! -e "$RACE_MARKER" ]]; then
  touch "$RACE_MARKER"
  remote="$($REAL_GIT remote get-url origin)"
  competitor="$(mktemp -d)"
  "$REAL_GIT" clone -q "$remote" "$competitor"
  "$REAL_GIT" -C "$competitor" config user.email competitor@example.com
  "$REAL_GIT" -C "$competitor" config user.name Competitor
  output="$(mktemp)"
  jq '(.plugins[] | select(.name == "pro-gate")) |= (.metadata = {version:"0.1.0",releaseId:301,releaseTag:"v0.1.0"})' "$competitor/.claude-plugin/marketplace.json" > "$output"
  mv "$output" "$competitor/.claude-plugin/marketplace.json"
  "$REAL_GIT" -C "$competitor" add .claude-plugin/marketplace.json
  "$REAL_GIT" -C "$competitor" commit -qm 'competing pro-gate promotion'
  "$REAL_GIT" -C "$competitor" push -q origin HEAD:main
  rm -rf "$competitor"
fi
exec "$REAL_GIT" "$@"
GIT_WRAPPER
chmod +x "$TMP/bin/git"
export REAL_GIT RACE_MARKER="$TMP/race-marker" RACE_ON_FIRST_PUSH=1
export PATH="$TMP/bin:$PATH" CURL_LOG="$TMP/curl.log"
common=(
  EVENT_ACTION=published REPOSITORY=token-eater RELEASE_ID=101 RELEASE_TAG=v0.1.1
  RELEASE_NAME='Token Eater 0.1.1' RELEASE_URL='https://github.com/StartupBros-com/token-eater/releases/tag/v0.1.1'
  RELEASE_PRERELEASE=false RELEASE_DRAFT=false LATEST_STABLE_ID=101 SOURCE_ROOT="$TMP/source"
  SOURCE_SHA="$SOURCE_SHA" MARKETPLACE_DIR="$TMP/marketplace" ANNOUNCE_URL=https://example.test/tool-releases
  ANNOUNCE_SECRET=test-secret
)
env "${common[@]}" "$ROOT/scripts/release-train.sh" >/dev/null
fresh="$TMP/fresh"
git clone -q "$TMP/marketplace.git" "$fresh"
assert_eq "$(jq -r '.plugins[] | select(.name=="token-eater") | .metadata.releaseId' "$fresh/.claude-plugin/marketplace.json")" 101 'stable latest release promotes'
assert_eq "$(jq -r '.plugins[] | select(.name=="pro-gate") | .metadata.releaseId' "$fresh/.claude-plugin/marketplace.json")" 301 'push-race retry preserves competing promotion'
assert_eq "$(wc -l < "$TMP/curl.log")" 1 'promotion announces once'

env "${common[@]}" "$ROOT/scripts/release-train.sh" >/dev/null
assert_eq "$(wc -l < "$TMP/curl.log")" 2 'rerun calls idempotent announce operation'

env "${common[@]}" RELEASE_ID=100 LATEST_STABLE_ID=100 "$ROOT/scripts/release-train.sh" >/dev/null
assert_eq "$(wc -l < "$TMP/curl.log")" 2 'older release no-op does not announce'

env "${common[@]}" RELEASE_ID=102 LATEST_STABLE_ID=102 RELEASE_PRERELEASE=true "$ROOT/scripts/release-train.sh" >/dev/null
assert_eq "$(wc -l < "$TMP/curl.log")" 2 'prerelease is ignored'

assert_eq "$(git -C "$TMP/marketplace" config user.name)" hov-release-bot 'promotion configures repo-local bot name'
assert_eq "$(git -C "$TMP/marketplace" config user.email)" hov-release-bot@users.noreply.github.com 'promotion configures repo-local bot email'

env "${common[@]}" EVENT_ACTION=edited "$ROOT/scripts/release-train.sh" >/dev/null
assert_eq "$(wc -l < "$TMP/curl.log")" 3 'edited release announces when marketplace exactly matches'

corrupt="$TMP/corrupt"
git clone -q "$TMP/marketplace.git" "$corrupt"
git -C "$corrupt" config user.email test@example.com
git -C "$corrupt" config user.name Test
jq '(.plugins[] | select(.name == "token-eater") | .source.sha) = "2222222222222222222222222222222222222222"' \
  "$corrupt/.claude-plugin/marketplace.json" > "$corrupt/marketplace.tmp"
mv "$corrupt/marketplace.tmp" "$corrupt/.claude-plugin/marketplace.json"
git -C "$corrupt" add .claude-plugin/marketplace.json
git -C "$corrupt" commit -qm 'corrupt immutable promotion tuple'
git -C "$corrupt" push -q origin HEAD:main
if env "${common[@]}" EVENT_ACTION=edited "$ROOT/scripts/release-train.sh" >/dev/null 2>&1; then
  fail 'edited release repairs immutable drift under the same release ID'
fi
assert_eq "$(wc -l < "$TMP/curl.log")" 3 'same-ID drift fails closed without announcement'

RACE_ON_FIRST_PUSH=0
env "${common[@]}" EVENT_ACTION=edited RELEASE_ID=102 LATEST_STABLE_ID=102 "$ROOT/scripts/release-train.sh" >/dev/null
assert_eq "$(wc -l < "$TMP/curl.log")" 4 'newly stable edited release promotes and announces once'
assert_eq "$(jq -r '.plugins[] | select(.name=="token-eater") | .metadata.releaseId' "$TMP/marketplace/.claude-plugin/marketplace.json")" 102 'newly stable edited release advances marketplace'

env "${common[@]}" EVENT_ACTION=edited RELEASE_PRERELEASE=true "$ROOT/scripts/release-train.sh" >/dev/null
assert_eq "$(wc -l < "$TMP/curl.log")" 4 'edited prerelease remains production no-op'

# --- notes_summary: card-ready bullets for the What's-new announcement section ---
ns() { RELEASE_NOTES="$1" bash -c "source <(sed -n '/^notes_summary()/,/^}/p' '$ROOT/scripts/release-train.sh'); notes_summary"; }
AUTO="$(printf '%s\n' "## Whats Changed" "* feat(token-eater): safer cleanup passes (v0.5.0) by @u in https://x/pull/1" "* fix(token-eater): draft PR guard by @u in https://x/pull/2" "" "**Full Changelog**: https://x/compare/a...b")"
assert_eq "$(ns "$AUTO")" "$(printf 'safer cleanup passes\ndraft PR guard')" 'auto-notes bullets are cleaned'
HL="$(printf '%s\n' "## Highlights" "* Hand-picked one" "" "## Whats Changed" "* feat: noise by @u in https://x")"
assert_eq "$(ns "$HL")" 'Hand-picked one' 'Highlights section wins'
assert_eq "$(ns 'Prose only body.')" 'Prose only body. ' 'prose falls back to first paragraph (legacy trailing space; endpoint trims)'
CONTRIB="$(printf '%s\n' "## Whats Changed" '* feat: real change by @u in https://x/pull/1' '' '## New Contributors' '* @newbie made their first contribution in https://x/pull/1')"
assert_eq "$(ns "$CONTRIB")" 'real change' 'contributor-section bullets never become highlights'
CJK_OUT="$(ns "$(printf '* %s' "$(python3 -c "print('测' * 200)")")")"
assert_eq "$(printf '%s' "$CJK_OUT" | python3 -c 'import sys; print(len(sys.stdin.read()))')" '180' 'multibyte bullets slice at 180 characters'



# The legacy script still owns marketplace promotion, but production runs set
# PROMOTE_ONLY so the dependent OIDC reusable workflow is the ONE announcer.
before_promote_only="$(wc -l < "$TMP/curl.log")"
promote_only_out="$(PROMOTE_ONLY=true bash -c "source <(sed -n '/^announce()/,/^}/p' '$ROOT/scripts/release-train.sh'); announce")"
assert_eq "$promote_only_out" 'announcement delegated to the canonical OIDC job' 'promotion-only mode delegates announcement'
assert_eq "$(wc -l < "$TMP/curl.log")" "$before_promote_only" 'promotion-only mode never calls the secret-authenticated endpoint'

WF="$ROOT/.github/workflows/release-train.yml"
grep -q 'PROMOTE_ONLY: true' "$WF" || fail 'release workflow does not suppress the legacy announcer'; pass 'release workflow suppresses legacy announcer'
grep -q 'Announce via canonical OIDC train' "$WF" || fail 'canonical OIDC announce job missing'; pass 'canonical OIDC announce job present'
grep -q 'id-token: write' "$WF" || fail 'OIDC announce job lacks id-token permission'; pass 'OIDC permission present'
grep -q 'hov-tool-drop-announce.yml@c981b872ebf650805200ad72c8b7142232f8b3f6' "$WF" || fail 'canonical announce workflow is not SHA-pinned'; pass 'canonical announce workflow SHA-pinned'
! grep -q 'TOOL_RELEASE_ANNOUNCE_SECRET' "$WF" || fail 'static announce secret remains in the production workflow'; pass 'static announce secret removed from production workflow'

echo 'ALL PASS'
