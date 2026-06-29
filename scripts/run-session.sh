#!/usr/bin/env bash
# run-session.sh - run ONE token-eater credit-burning session end to end.
#
# The whole product in one script: preflight (isolated worktree off fresh origin/main +
# baseline gate) -> hand the chosen service a self-contained recipe (run a token-heavy skill,
# keep the gate green, self-review + fix, open a DRAFT PR) -> independently re-verify the gate.
# The service does the work on ITS OWN credits; this script is the launcher + guardrail.
#
# Usage:
#   run-session.sh --repo <path> --skill <skill-name> --gate "<cmd>" [--target "<hint>"] \
#                  [--service grok] [--rounds 2] [--slug de-monolith] [--max-turns 150] \
#                  [--pace gentle|thorough] [--dry-run]
#
# --pace gentle (default): dispatch subagents serially - safe for a lightly-used / low-tier grok
#        account that 429s easily. --pace thorough: up to 3 in parallel, for accounts with headroom.
# Rate-limit resilience is built in: if grok makes no progress under heavy 429s, the engine backs
# off (exponential) and RESUMES via `grok --continue`, escalating to --no-subagents.
#
# Exit: 0 = draft PR opened and gate verified green
#       2 = bad usage / preflight failure (no changes made)
#       3 = baseline gate RED (refused to run; nothing attempted)
#       4 = service ran but the final gate is RED (worktree kept for inspection, NO PR)
#       5 = gate green but no PR could be opened (branch kept; see log)
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SERVICE=grok; ROUNDS=2; SLUG=session; MAXTURNS=150; DRYRUN=0; PACE=gentle
REPO=""; SKILL=""; GATE=""; TARGET=""

die() { echo "token-eater: $*" >&2; exit 2; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo) REPO="$2"; shift 2;;
    --skill) SKILL="$2"; shift 2;;
    --gate) GATE="$2"; shift 2;;
    --target) TARGET="$2"; shift 2;;
    --service) SERVICE="$2"; shift 2;;
    --rounds) ROUNDS="$2"; shift 2;;
    --slug) SLUG="$2"; shift 2;;
    --max-turns) MAXTURNS="$2"; shift 2;;
    --pace) PACE="$2"; shift 2;;
    --dry-run) DRYRUN=1; shift;;
    *) die "unknown arg: $1";;
  esac
done
[ -n "$REPO" ] && [ -n "$SKILL" ] && [ -n "$GATE" ] || die "need --repo --skill --gate (--target is an OPTIONAL hint; omit it to let the skill discover its own target on the service's credits)"
# Target selection belongs on the service, not here: most maintenance skills (de-monolithize's
# census, dead-code's gate scan, etc.) find their own targets via subagents. Pass --target only as
# a hint; with none, tell the skill to find the worst offenders itself.
if [ -n "$TARGET" ]; then
  GOAL_LINE="$TARGET"
  HINT="A starting hint (the skill's own analysis WINS if it disagrees): $TARGET"
else
  GOAL_LINE="Find and fix the best target(s) the /$SKILL skill identifies in this repository — let the skill's own analysis choose what and how much to touch."
  HINT="No target was pre-chosen — the skill must identify the target itself via its own analysis/census"
fi

# Pace controls subagent CONCURRENCY - the dominant 429 driver. A lightly-used grok account has a low
# rate-limit tier (it scales with historical spend), so a parallel subagent fan-out 429-storms it and
# the backoff sleeps dominate wall-clock. Default 'gentle' paces UNDER the limit (serial dispatch),
# which both protects a first-time/low-tier account and avoids the wasted 429+backoff cycles.
if [ "$PACE" = thorough ]; then
  CONC_SHORT="up to 3 in parallel"
  CONCURRENCY="You MAY run up to 3 subagents (Task tool) in parallel - this account has rate-limit headroom (thorough pace)."
else
  CONC_SHORT="ONE AT A TIME (serial)"
  CONCURRENCY="Run subagents (Task tool) ONE AT A TIME - never spawn the next until the current one returns. This account may be lightly used and heavily rate-limited; serial dispatch stays under the limit and avoids 429 storms."
fi
[ -d "$REPO/.git" ] || die "not a git repo: $REPO"
command -v "$SERVICE" >/dev/null 2>&1 || die "service CLI not found: $SERVICE"

REPO="$(cd "$REPO" && pwd)"
ORIGIN_SLUG="$(git -C "$REPO" remote get-url origin 2>/dev/null | sed -E 's#(git@[^:]+:|https?://[^/]+/)##; s#\.git$##')" || die "no origin remote"
RESULT_DIR="$REPO/.token-eater/runs"; mkdir -p "$RESULT_DIR"
RUNID="${SLUG}-$(date +%Y%m%d-%H%M%S)"
LOG="$RESULT_DIR/$RUNID"; mkdir -p "$LOG"

echo "== token-eater session =="
echo "  repo:    $ORIGIN_SLUG"
echo "  service: $SERVICE   skill: $SKILL   rounds: $ROUNDS"
echo "  target:  ${TARGET:-<skill discovers its own target on $SERVICE>}"
echo "  gate:    $GATE"

# 1. AUTH PREFLIGHT - never let an expired token hang the run
echo "-- auth preflight --"
if ! bash "$HERE/check-auth.sh" "$SERVICE"; then
  rc=$?; [ "$rc" = 3 ] && { echo "token-eater: $SERVICE needs re-auth; stopping."; exit 2; }
fi

# 2. FRESH BASE - branch the worktree off origin/main, not stale local state
echo "-- fetch origin + isolated worktree off origin/main --"
git -C "$REPO" fetch -q origin
BASE="$(git -C "$REPO" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's@^origin/@@' || true)"
[ -z "$BASE" ] && { git -C "$REPO" show-ref --verify -q refs/remotes/origin/main && BASE=main || BASE=master; }
WORKTREE="$(bash "$HERE/wt.sh" create "$REPO" "$RUNID" "$SLUG" "origin/$BASE")"
BRANCH="$(git -C "$WORKTREE" rev-parse --abbrev-ref HEAD)"
echo "  worktree: $WORKTREE"
echo "  branch:   $BRANCH (off origin/$BASE)"

# 3. BASELINE GATE - a gate that is red before we start can't prove anything
echo "-- baseline gate (must be green) --"
if bash "$HERE/run-gate.sh" "$WORKTREE" "$GATE" > "$LOG/baseline.log" 2>&1; then
  echo "  baseline: GREEN"
else
  echo "  baseline: RED - refusing to run (see $LOG/baseline.log)"; tail -5 "$LOG/baseline.log"
  bash "$HERE/wt.sh" cleanup "$REPO" "$WORKTREE" drop >/dev/null 2>&1 || true
  exit 3
fi

# 3b. DISCOVER the REAL /ce-code-review persona roster for the review fleet.
#     grok's ce-* SUBAGENT_TYPE dispatch is unreliable (its Task registry is inconsistent run-to-run;
#     native-4 dominates - proven across MCP/--agents/plugin-install/delay/warmup probes). But the
#     ce-* personas are just markdown prompts, and `general-purpose` IS available every run. So we run
#     /ce-code-review's GENUINE personas - the full tiered roster + its real selection logic - via
#     general-purpose subagents that read+adopt each persona file. Point grok at the actual
#     persona-catalog (selection rules) + agents dir rather than hardcoding a subset.
CE_SKILL_DIR="$(ls -d "$HOME"/.claude/plugins/marketplaces/*/plugins/compound-engineering/skills/ce-code-review 2>/dev/null | head -1)"
CE_AGENTS_DIR="$(ls -d "$HOME"/.claude/plugins/marketplaces/*/plugins/compound-engineering/agents 2>/dev/null | head -1)"
[ -z "$CE_AGENTS_DIR" ] && CE_AGENTS_DIR="$(ls -d "$HOME"/.claude/agents 2>/dev/null | head -1)"
CE_CATALOG=""
[ -n "$CE_SKILL_DIR" ] && [ -f "$CE_SKILL_DIR/references/persona-catalog.md" ] && CE_CATALOG="$CE_SKILL_DIR/references/persona-catalog.md"

if [ -n "$CE_AGENTS_DIR" ] && [ -f "$CE_AGENTS_DIR/ce-correctness-reviewer.md" ]; then
  REVIEW_INSTRUCTIONS="REVIEW your committed diff (\`git diff origin/$BASE..HEAD\`) by running the FULL
   /ce-code-review review with its REAL tiered persona roster and selection logic.
   MECHANISM (critical): grok's \`ce-*\` subagent_type dispatch is NOT reliable, so do NOT dispatch
   \`compound-engineering:ce-*\` Task types. Instead run EACH selected persona as a \`general-purpose\`
   subagent (always available) prompted EXACTLY: \"Read the file ${CE_AGENTS_DIR}/<persona>.md and FULLY
   ADOPT that reviewer persona. Then review this diff: <paste the full git diff origin/$BASE..HEAD>.
   Report findings as P0/P1 (must-fix) or P2/P3 (nits) with file:line.\"
   SELECTION: follow the real catalog${CE_CATALOG:+ at $CE_CATALOG}.
     ALWAYS-ON - spawn all 4 every time: ce-correctness-reviewer, ce-testing-reviewer,
       ce-maintainability-reviewer, ce-project-standards-reviewer.
     CROSS-CUTTING CONDITIONAL - read the diff and spawn each whose domain it genuinely touches (judgment,
       not keyword match): ce-security-reviewer (auth/endpoints/input/secrets), ce-performance-reviewer
       (DB queries/loops/caching/async), ce-api-contract-reviewer (routes/serializers/exported types/
       versioning), ce-data-migration-reviewer (migration or schema artifacts ONLY), ce-reliability-reviewer
       (error handling/retries/timeouts/background jobs), ce-adversarial-reviewer (>=50 changed non-test/
       non-generated lines OR auth/payments/data-mutation/external-API), ce-previous-comments-reviewer
       (ONLY when reviewing a PR that already has prior review comments).
     STACK-SPECIFIC CONDITIONAL - spawn only if the diff has real work for them: ce-julik-frontend-races-reviewer
       (Stimulus/Turbo/DOM/timers/async UI), ce-swift-ios-reviewer (Swift/SwiftUI/UIKit/iOS project files).
     All persona files live in ${CE_AGENTS_DIR}/. ANNOUNCE the selected team with a one-line justification
     per conditional persona before dispatching. (Skip the cross-model \`codex-reviewer\` CE agent - it needs
     the Codex CLI and is out of scope for a grok-only run.)
   CONCURRENCY + RATE LIMITS: dispatch subagents $CONC_SHORT, never a big fan-out; on a 429 back off and RETRY
   the same dispatch (per the rate-limit rule) - every SELECTED persona MUST complete, do not drop any.
   Aggregate all findings across personas."
else
  REVIEW_INSTRUCTIONS="REVIEW your committed diff (\`git diff origin/$BASE..HEAD\`) by running
   /ce-code-review's method as a FLEET of \`general-purpose\` subagents (always available) - one per lens:
   correctness, tests, maintainability, project-standards, plus security/performance/reliability/
   api-contract/data-migration WHERE the diff touches them - each given the relevant lens instructions and
   the diff. Dispatch them $CONC_SHORT; on a 429 back off and retry. Collect P0/P1 and nits."
fi

# 4. RENDER THE RECIPE - the self-contained instruction grok runs autonomously
RECIPE="$LOG/recipe.txt"
cat > "$RECIPE" <<EOF
You are token-eater's autonomous worker for ONE session. You are inside a fresh git worktree of
the $ORIGIN_SLUG repository, on branch \`$BRANCH\` (based on origin/$BASE). Do ALL work here.

GOAL: $GOAL_LINE
Use the \`/$SKILL\` skill as your method.

THE GATE (authoritative - it must pass at every commit):
    $GATE
node_modules / dependencies are already installed (symlinked). Run the gate yourself; do not
trust your own judgment over the gate.

PROCEDURE - do not stop until step 6 is done or you hit a hard blocker:

1. Run \`/$SKILL\`. Let the skill's OWN analysis pick the target(s): most maintenance skills scan
   the repo themselves to find their work - e.g. de-monolithize runs a census that RANKS monoliths
   and skips generated / justified-cohesive files; dead-code uses the gate's unused-symbol output.
   Spend real effort here (\`general-purpose\` subagents are encouraged, but dispatch them $CONC_SHORT -
   see the rate-limit rule) - choosing the right
   target IS part of the job. Do NOT fixate on one pre-chosen file. $HINT. Preserve all behavior, the public API
   surface, types, tests, validation, error handling, and security/auth. Never weaken or delete a test.

2. Run the gate (\`$GATE\`). It MUST pass. If it fails, fix until green. If you genuinely cannot,
   run \`git reset --hard\` to restore a clean state and STOP with a clear explanation - never open
   a PR for broken work.

3. Commit on the CURRENT branch (never \`$BASE\`):
       git add -A && git commit -m "<concise message>"

4. $REVIEW_INSTRUCTIONS

5. Re-run the gate (\`$GATE\`) - it MUST stay green after any review fixes; commit any fix the
   review skill did not already commit. If P0/P1 issues remain, fix, re-gate, and review again.
   Repeat steps 4-5 until no P0/P1 findings remain, OR you have done $ROUNDS review rounds.

6. Push the branch and open a DRAFT pull request against \`$BASE\` on $ORIGIN_SLUG:
       git push -u origin $BRANCH
       gh pr create --repo $ORIGIN_SLUG --base $BASE --draft --title "<title>" --body "<plain summary; note the gate passes>"
   The PR MUST be a draft. NEVER merge it, NEVER mark it ready, NEVER push to \`$BASE\`.

FINAL OUTPUT: a summary - files changed, final gate result, how many review rounds, any nits left
for the human, and the draft PR URL.

HARD RULES: stay in this worktree; keep the gate green at every commit; draft PR only; never merge;
never touch \`$BASE\`; never weaken tests, validation, error handling, or security checks.
EOF

if [ "$DRYRUN" = 1 ]; then
  echo "-- DRY RUN: recipe rendered, NOT launching $SERVICE --"
  echo "  recipe: $RECIPE"; echo "  worktree kept at: $WORKTREE"
  echo "----- recipe -----"; cat "$RECIPE"
  exit 0
fi

# 5. LAUNCH THE SERVICE - it runs the whole loop on its own credits.
#    NOTE: no --effort/--reasoning-effort (grok-composer-2.5-fast rejects it).
#    --rules appends a session-wide rate-limit discipline: grok accounts 429 hard under heavy
#    subagent fan-out, and the agent was abandoning rate-limited subagents (e.g. code-reviewer)
#    instead of backing off. This rule caps concurrency and forces backoff+retry over downgrade.
GROK_RULES="Rate-limit discipline (this account may 429 under load). $CONCURRENCY If ANY tool or subagent call returns 429 / 'Too Many Requests' / 'rate limit', do NOT abandon it and do NOT silently downgrade to a weaker subagent type: back off via the shell (sleep 30s, then 60s, then 120s) and retry the SAME call up to 3 times. Only give up after 3 failed retries, and say so explicitly in your summary."
echo "-- launching $SERVICE (this is the long-running part; it burns $SERVICE credits) --"
INVOKE_OK=1
if [ "$SERVICE" = grok ]; then
  # token-eater-OWNED rate-limit resilience (do NOT rely on grok self-policing - it is unreliable):
  # launch grok; if it makes NO progress (zero commits) AND the logs show rate-limiting, deterministically
  # back off (exponential, jittered, capped) and RESUME the same session via --continue - escalating to
  # --no-subagents (no fan-out -> minimal 429 pressure) so even a brand-new, low-tier grok account
  # eventually lands the core work. grok that simply grinds through 429s and commits is left alone.
  GROK_COMMON=(--cwd "$WORKTREE" --rules "$GROK_RULES" --always-approve --disable-web-search
               --no-memory --max-turns "$MAXTURNS" --output-format json
               --debug --debug-file "$LOG/service-debug.log")
  grok --prompt-file "$RECIPE" "${GROK_COMMON[@]}" > "$LOG/service-out.json" 2> "$LOG/service-err.log" || true
  resume=0; max_resumes=3
  while :; do
    commits="$(git -C "$WORKTREE" rev-list --count "origin/$BASE..HEAD" 2>/dev/null || echo 0)"
    [ "${commits:-0}" -ge 1 ] && break                       # grok produced work -> proceed to the gate
    if [ "$resume" -ge "$max_resumes" ] || ! grep -qiE '429|too many requests|rate.?limit' "$LOG/service-err.log" "$LOG/service-out.json" 2>/dev/null; then
      break                                                  # not rate-limited, or out of resume budget
    fi
    back=$(( 60 * (1 << resume) )); [ "$back" -gt 300 ] && back=300; back=$(( back + RANDOM % 25 ))
    gentle=""; [ "$resume" -ge 1 ] && gentle="--no-subagents"   # escalate gentleness after the 1st resume
    echo "  rate-limited with no progress; backing off ${back}s then resuming (resume $((resume+1))/$max_resumes${gentle:+ $gentle})"
    sleep "$back"
    grok --continue "${GROK_COMMON[@]}" $gentle \
         -p "Continue this token-eater session where you left off. You were rate-limited (429). Proceed gently: run any subagents ONE AT A TIME, and on a 429 sleep and retry rather than giving up. Finish the procedure - keep the gate green, review-and-fix, then open the DRAFT PR." \
         >> "$LOG/service-out.json" 2>> "$LOG/service-err.log" || true
    resume=$(( resume + 1 ))
  done
  commits="$(git -C "$WORKTREE" rev-list --count "origin/$BASE..HEAD" 2>/dev/null || echo 0)"
  [ "${commits:-0}" -ge 1 ] || INVOKE_OK=0
  [ "$resume" -gt 0 ] && echo "  (resumed $resume time/s through rate-limit backoff)"
else
  # codex / claude: delegate via their runner (single rich prompt; agentic loop inside)
  bash "$HERE/delegate-$SERVICE.sh" "$WORKTREE" "$RECIPE" > "$LOG/service-out.json" 2> "$LOG/service-err.log" || INVOKE_OK=0
fi
echo "  $SERVICE finished (invoke_ok=$INVOKE_OK); logs in $LOG/"

# 6. INDEPENDENT VERIFICATION - never trust the service's self-report; re-run the gate ourselves.
echo "-- independent gate verification --"
if bash "$HERE/run-gate.sh" "$WORKTREE" "$GATE" > "$LOG/verify.log" 2>&1; then
  GATEOK=1; echo "  gate: GREEN"
else
  GATEOK=0; echo "  gate: RED (see $LOG/verify.log)"; tail -6 "$LOG/verify.log"
fi
COMMITS="$(git -C "$WORKTREE" rev-list --count "origin/$BASE..HEAD" 2>/dev/null || echo 0)"
echo "  commits on branch: $COMMITS"

if [ "$GATEOK" = 0 ]; then
  echo "token-eater: final gate is RED - NOT opening a PR. Worktree kept for inspection: $WORKTREE"
  exit 4
fi
if [ "${COMMITS:-0}" -lt 1 ]; then
  echo "token-eater: gate green but the service made no commits - nothing to ship."
  bash "$HERE/wt.sh" cleanup "$REPO" "$WORKTREE" drop >/dev/null 2>&1 || true
  exit 0
fi

# 7. ENSURE A DRAFT PR EXISTS (the service usually opens it; if not, we do - draft, on origin).
PR_URL="$(gh pr list --repo "$ORIGIN_SLUG" --head "$BRANCH" --json url --jq '.[0].url' 2>/dev/null || true)"
if [ -z "$PR_URL" ]; then
  echo "-- service did not open a PR; opening a draft PR ourselves --"
  git -C "$WORKTREE" push -u origin "$BRANCH" >/dev/null 2>&1 || true
  PR_URL="$(gh pr create --repo "$ORIGIN_SLUG" --base "$BASE" --head "$BRANCH" --draft \
              --title "chore(token-eater): $SLUG" \
              --body "Automated $SKILL pass by token-eater via $SERVICE. Gate \`$GATE\` passes. Draft - review before merging; token-eater did not merge." \
              2>>"$LOG/pr.log" || true)"
fi
[ -z "$PR_URL" ] && { echo "token-eater: gate green but could not open a PR (see $LOG/pr.log). Branch kept: $BRANCH"; exit 5; }

# verify it is actually a draft
IS_DRAFT="$(gh pr view "$PR_URL" --repo "$ORIGIN_SLUG" --json isDraft --jq '.isDraft' 2>/dev/null || echo unknown)"
echo
echo "== DONE =="
echo "  draft PR: $PR_URL  (isDraft=$IS_DRAFT)"
echo "  gate:     GREEN ($COMMITS commit/s)"
echo "  review:   run /ce-code-review + your frontier-model review on the PR before merging."
echo "  worktree: $WORKTREE (remove with: bash $HERE/wt.sh cleanup $REPO $WORKTREE keep)"
