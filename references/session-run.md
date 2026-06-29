# Session run

A token-eater run is **one session**: one service, one token-heavy skill, one polished draft PR. The engine is `scripts/run-session.sh`; this playbook is how `SKILL.md` drives it — pick the skill, pick the gate, pick the target, launch, report.

The credit-burn model: the chosen CLI (e.g. `grok`) is itself a coding agent that loads your installed skills and runs them on **its own** models. token-eater hands it one recipe — *"run this skill, keep this gate green, self-review and fix, open a draft PR"* — and it runs the whole loop. token-eater's job is the safe setup around that (isolated worktree off fresh `origin/main`, a verified gate) and the guardrail after (re-run the gate independently, draft-PR only, never merge).

## The menu

Offer the token-heavy maintenance skills that are **installed** (`scripts/detect-skills.sh`) and **applicable to this repo**. These are the credit-burners — judgment work a deterministic gate can still verify:

| Skill (menu label) | What it does | Typical gate | How to pick the target |
| --- | --- | --- | --- |
| **de-monolithize** (`de-monolithize-your-codebase-isomorphically`) | Split a large module into cohesive files, behavior-preserving | tests + typecheck | the largest source file(s) with test/type coverage |
| **simplify** (`simplify-and-refactor-code-isomorphically`) | Simplify/refactor in place, behavior-preserving | tests + typecheck | a chosen module or the most complex file |
| **de-slop** (`de-slopify`) | Tighten repetitive/placeholder/AI-looking prose and comments | tests + typecheck (for code) or docs build | README/docs, or noisy-comment files in an explicit set |
| **dead-code** (`ce-simplify-code` / unused-symbol cleanup) | Remove provably-unused code | tests + typecheck (`noUnused*`) or lint | what the type/lint gate flags as unused |
| **mock-removal** (`mock-code-finder`) | Remove dead/placeholder mock code | tests | files the mock-finder flags |

Resolve each menu label to a concrete installed skill via `skills-catalog.yaml`. If a skill isn't installed, either suggest its (stubbed) House of Vibe drop-in or omit it from the menu. Let the user pick exactly one (or honor the skill argument).

Skills that have **no machine gate** (pure prose de-slop with no docs check, perf "optimize" with no benchmark) are offered only when the user explicitly accepts that the deterministic safety net is weaker — otherwise omit them.

## Pick the gate

The gate is what makes an unattended run safe — it must be a deterministic check that is **green before the session starts** (`run-session.sh` enforces this baseline). Find it with `scripts/run-gate.sh <project>` (auto-detects format:check → typecheck → test → build → lint) or set it explicitly. For behavior-preserving skills (de-monolithize, simplify, dead-code), prefer a gate that actually proves behavior is unchanged: **`<test command> && <typecheck command>`** (e.g. `pnpm exec tsc --noEmit && pnpm test`). If the repo has no gate at all, **stop** — token-eater does not run skills it cannot verify.

## Target: let the skill choose it (on the service's credits)

Do **not** pre-pick the target with a crude heuristic. These maintenance skills find their own work, and they do it better — on the service's credits, which is exactly what we want to burn:
- **de-monolithize** runs a full census (`scripts/census.sh` + parallel `monolith-census-mapper` subagents per directory) that ranks files by size×complexity×churn, tags pathology buckets, and **skips generated files and justified-cohesive monoliths**. Its docs even warn that a file you hand-pick "may not be the worst offender."
- **dead-code** keys off the gate's own unused-symbol output; **mock-removal** scans for dead mocks; **de-slop** finds the sloppiest prose.

Choosing the right target is itself token-heavy analysis — that's a feature, not overhead. So leave `--target` off and let the skill discover it (the recipe tells the skill to spend real effort here, parallel `general-purpose` subagents encouraged). Pass `--target` **only** as an optional scope hint when you want to steer it (e.g. `--target "focus on the API layer if it's the worst"`); the recipe passes it as a hint the skill's own analysis can override.

## Launch

```bash
bash <skill-dir>/scripts/run-session.sh \
  --repo <project-path> --service <service> \
  --skill <skill-name> --gate "<gate command>" \
  --rounds 2 --slug <short-slug> [--target "<optional scope hint>"]
```

`run-session.sh` does, in order: auth preflight → `git fetch` + worktree off fresh `origin/main` → **baseline gate (must be green)** → render the recipe → **launch the service** (it runs the whole skill→gate→self-review→draft-PR loop on its own credits) → **independently re-run the gate** → ensure a **draft** PR exists on `origin`. Add `--dry-run` to render the recipe and stop (no launch, no spend).

Exit codes: `0` draft PR opened + gate verified green · `2` usage/preflight failure · `3` baseline gate red (refused) · `4` final gate red (worktree kept, no PR) · `5` gate green but no PR could be opened (branch kept).

### What the recipe tells the service (and why)

The rendered recipe (see `run-session.sh`) bakes in what the live runs taught us:
- **No `--effort` flag for grok** — `grok-composer-2.5-fast` rejects `reasoningEffort` (400). The engine never passes it.
- **The review stage runs `/ce-code-review` as a real subagent fleet — registry-adaptively.** The recipe tells the service to review-and-fix its committed diff by following `/ce-code-review`'s method (apply safe, verified fixes, commit on the branch, never push), looping until no P0/P1 remain or `--rounds` is hit. Key empirical finding (grok debug logs, 2026-06-29): **grok's Task subagent registry is inconsistent across runs.** Some runs expose only grok's four *native* types (`generalPurpose`, `code-reviewer`, `best-of-n-runner`, `cursor-guide`); other runs expose the full discovered `~/.claude` agent set — **including the genuine `compound-engineering:ce-*` reviewer personas** (`ce-correctness-reviewer`, `ce-security-reviewer`, …) that `/ce-code-review` natively dispatches. A dispatch to a type absent this run fails with `Unknown subagent type: X. Available types: …` (the error lists the valid set). Controlled probes (2026-06-29) showed the **native-four set is the reliable, common case** — short/early dispatches get it every time — while the `ce-*` "discovered" set is rare and appears only deep in some long sessions, consistent with grok's plugin/agent discovery being an async race that usually hasn't finished at dispatch time. **MCP on/off makes no difference** (8/8 probes native-four either way — the MCP-blocking-init hypothesis was tested and rejected). `--agents` injection also does *not* help — injected agents are rejected by the same Task enum (`unknown variant`). So the recipe leads with the **reliably-present native types**: one `code-reviewer` over the diff + one `general-purpose` subagent per lens (correctness / tests / maintainability / security); it uses the richer `ce-*` personas only opportunistically when that set happens to be active, and treats `general-purpose` as the guaranteed fallback. Either way this is the service reviewing **its own** work, so still not a substitute for your independent review.
- **The gate is authoritative; the service's self-report is not.** `run-session.sh` re-runs the gate itself after the service finishes and refuses to open a PR if it's red.

## Report

Relay what the engine returns:
- **Success:** the draft PR URL + that the gate was independently verified green. Note that the service already ran `/ce-code-review` over its own diff as a self-review pass. Then: **"Run your OWN independent review before merging — a fresh `/ce-code-review` in your Claude session (a different model than the one that wrote the diff) plus your frontier-model pass — token-eater did not merge anything."** The service reviewing its own work is a polish pass, not a substitute for an independent review.
- **Gate red (exit 4):** say plainly that the attempt didn't pass the project's own checks, so no PR was opened; the worktree is kept for inspection and your working tree was never touched.
- **No gate / not applicable:** explain why nothing ran.

One session, one PR. To burn more, run another session (another skill, or the same skill on another target).
