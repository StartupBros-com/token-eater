#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "$3: expected $2, got $1"; pass "$3"; }

pages='[[{"id":9,"created_at":"2026-02-01T00:00:00Z","draft":false,"prerelease":false},{"id":10,"created_at":"2026-03-01T00:00:00Z","draft":true,"prerelease":false}],[{"id":11,"created_at":"2026-04-01T00:00:00Z","draft":false,"prerelease":true},{"id":12,"created_at":"2026-05-01T00:00:00Z","draft":false,"prerelease":false}]]'
assert_eq "$(printf '%s\n' "$pages" | "$ROOT/scripts/latest-stable-release-id.sh")" 12 'paginated releases yield one global latest stable ID'
assert_eq "$(printf '%s\n' "$pages" | "$ROOT/scripts/latest-stable-release-id.sh" | wc -l)" 1 'latest stable selector emits exactly one line'
if printf '%s\n' '{"id":12}' | "$ROOT/scripts/latest-stable-release-id.sh" >/dev/null 2>&1; then
  fail 'latest stable selector accepts non-paginated input'
fi
pass 'latest stable selector rejects malformed page shape'

ci="$ROOT/.github/workflows/ci.yml"
release="$ROOT/.github/workflows/release-train.yml"
grep -q 'runs-on: ubuntu-24.04' "$ci" || fail 'PR CI is not GitHub-hosted'
! grep -q 'self-hosted' "$ci" || fail 'PR CI still uses a secret-bearing self-hosted runner'
grep -q 'persist-credentials: false' "$ci" || fail 'PR checkout persists credentials'
grep -q './scripts/validate-data.sh' "$ci" || fail 'PR data validation is not fail-closed'
pass 'PR CI is isolated and data validation fails closed'

mkdir -p "$TMP/data"
printf '{bad json\n' > "$TMP/data/bad.json"
if "$ROOT/scripts/validate-data.sh" "$TMP/data" >/dev/null 2>&1; then
  fail 'malformed public PR JSON passes validation'
fi
printf '{}\n' > "$TMP/data/bad.json"
printf 'bad: [yaml\n' > "$TMP/data/bad.yaml"
if "$ROOT/scripts/validate-data.sh" "$TMP/data" >/dev/null 2>&1; then
  fail 'malformed public PR YAML passes validation'
fi
pass 'malformed public PR JSON and YAML fail'

grep -q 'gh api --paginate --slurp' "$release" || fail 'release pagination is not globally aggregated'
grep -q 'runs-on: ubuntu-24.04' "$release" || fail 'release train is not isolated on a GitHub-hosted runner'
! grep -q 'self-hosted' "$release" || fail 'release train still shares the persistent PR runner pool'
grep -q 'HOV_MARKETPLACE_PAT' "$release" || fail 'release execution lost required marketplace credential'
pass 'secret-bearing release execution is isolated from persistent PR runners'

grep -q 'gh_2.74.2_linux_amd64.tar.gz' "$ROOT/scripts/provision-ci-tools.sh" || fail 'pinned gh archive missing'
grep -q 'c421091ae5800390e6aef1f50bfda59cc1d4f2ef2200bcd4e1a662c05c28c444' "$ROOT/scripts/provision-ci-tools.sh" || fail 'pinned gh checksum missing'
pass 'clean runners checksum-provision pinned gh'

printf 'workflows: PASS\n'
