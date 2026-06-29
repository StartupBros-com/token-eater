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

## Pick the target

Give the skill one short, plain-language focus (it becomes the recipe's `GOAL`). Examples:
- de-monolithize → "Split `src/services/renpho-api.ts` (the largest module) into cohesive files without changing behavior."
- de-slop → "Tighten the repetitive prose in `README.md` and `docs/` without changing technical meaning."
- dead-code → "Remove the unused exports the typecheck/lint gate reports."

Keep the target scoped and concrete; the skill itself handles the how.

## Launch

```bash
bash <skill-dir>/scripts/run-session.sh \
  --repo <project-path> --service <service> \
  --skill <skill-name> --gate "<gate command>" \
  --target "<plain-language target>" --rounds 2 --slug <short-slug>
```

`run-session.sh` does, in order: auth preflight → `git fetch` + worktree off fresh `origin/main` → **baseline gate (must be green)** → render the recipe → **launch the service** (it runs the whole skill→gate→self-review→draft-PR loop on its own credits) → **independently re-run the gate** → ensure a **draft** PR exists on `origin`. Add `--dry-run` to render the recipe and stop (no launch, no spend).

Exit codes: `0` draft PR opened + gate verified green · `2` usage/preflight failure · `3` baseline gate red (refused) · `4` final gate red (worktree kept, no PR) · `5` gate green but no PR could be opened (branch kept).

### What the recipe tells the service (and why)

The rendered recipe (see `run-session.sh`) bakes in what the live runs taught us:
- **No `--effort` flag for grok** — `grok-composer-2.5-fast` rejects `reasoningEffort` (400). The engine never passes it.
- **Self-review uses only `general-purpose` subagents (or inline).** grok's Task registry is inconsistent across runs — specialized `ce-*` / `code-reviewer` subagent types are not reliably available, but `general-purpose` always is. So the recipe asks for a lens-based review (correctness / tests / maintainability / security) via `general-purpose` subagents, not a specific reviewer skill. This self-review is a **best-effort polish pass only**.
- **The gate is authoritative; the service's self-report is not.** `run-session.sh` re-runs the gate itself after the service finishes and refuses to open a PR if it's red.

## Report

Relay what the engine returns:
- **Success:** the draft PR URL + that the gate was independently verified green. Then: **"Run `/ce-code-review` and your frontier-model review on this PR before merging — token-eater did not merge anything."** The service's self-review is not a substitute for that.
- **Gate red (exit 4):** say plainly that the attempt didn't pass the project's own checks, so no PR was opened; the worktree is kept for inspection and your working tree was never touched.
- **No gate / not applicable:** explain why nothing ran.

One session, one PR. To burn more, run another session (another skill, or the same skill on another target).
