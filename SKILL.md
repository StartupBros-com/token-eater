---
name: token-eater
description: "[BETA] Spend a subscription's idle, about-to-expire credits on safe, machine-verified cleanup. You pick the service (Grok / Codex / Claude); token-eater finds token-heavy maintenance work the project's own checks can verify — de-slop, dead code, simplification, formatting — does it in isolated worktrees, and opens draft PRs you review. Never merges. Manual invocation only during beta."
disable-model-invocation: true
argument-hint: "[grok|codex|claude ...] [dry-run] [setup]"
---

# token-eater

Turn the subscription credits you would otherwise let expire into a cleanup crew for your project.

**You point token-eater at a service. It spends that service's credits on safe, token-heavy maintenance work, and hands you draft PRs to review.** The chores it picks are *low-risk* (a deterministic check can prove them correct) but *token-hungry* (lots of model output — de-slop, dead-code removal, DRY/simplification, test backfill) — exactly the work that burns credits without burning your attention. It never merges anything.

The service you choose is the only real setting: it spends what you tell it to and leaves everything else alone. Want to burn expiring Grok credits? `/token-eater grok`. Want Codex to do a cleanup pass? `/token-eater codex`. Don't want it touching your Claude capacity? Just don't list Claude.

This file is the orchestrator. The detailed playbooks live in `references/`; the provider registry is `adapters.yaml`.

**Skill files resolve from THIS skill's base directory, not the user's project.** Every `scripts/...`, `references/...`, `adapters.yaml`, and `skills-catalog.yaml` path below is relative to the directory this `SKILL.md` lives in (the base directory the harness reports when the skill is invoked). Invoke scripts by their absolute path inside the skill — e.g. `bash <skill-dir>/scripts/detect-adapters.sh`. The *chores* run in the user's project (a worktree of it); the *tooling* lives with the skill.

## Status

`[BETA]` — manual invocation only (`disable-model-invocation: true`: a human must type `/token-eater`; other skills cannot hand off to it). Do not wire token-eater into other skills' handoffs during the beta.

## Input

<input> #$ARGUMENTS </input>

## Argument parsing

Parse `$ARGUMENTS` for optional tokens; strip each recognized token before interpreting the remainder.

| Token | Effect |
|-------|--------|
| `grok` / `codex` / `claude` | Spend this service this run. List more than one to spend them in the order given. Overrides the saved default. |
| `dry-run` | Plan the run — find the chores and show what would happen — without spending credits or opening PRs. |
| `setup` | Re-run the (one-question) setup to change the saved default service. |

If no service is named and a saved default exists, use it. If no service is named and there is no config, run the brief setup in `references/setup-and-config.md` (one question: which service's credits should I spend?).

## Entry: resolve the service, then run

1. **Detect what's installed.** Run `scripts/detect-adapters.sh`. If it finds none of the registered CLIs, print a plain-language explanation and stop without changing anything.
2. **Decide which service(s) to spend.** Named services in `$ARGUMENTS` win; otherwise the saved default from config; otherwise run the one-question setup. Keep only services that detection found available.
3. **`dry-run` → plan only.** Find the chores and show what would happen; spend nothing and write nothing.
4. **Otherwise → run the loop** in `references/harvest-loop.md`.

## How a run proceeds (overview)

Detail lives in the references; the shape is:

- Resolve the service(s) to spend and confirm their CLIs are present — `scripts/detect-adapters.sh`, `references/adapter-contract.md`.
- Build the chore backlog — only low-risk maintenance work a deterministic gate (the project's own tests / typecheck / lint / formatter / build) can verify — resolving each chore to an installed skill, a (stubbed) House of Vibe drop-in, or a bundled prompt — `references/chore-discovery.md`, `skills-catalog.yaml`, `scripts/detect-skills.sh`.
- For each chore: **deterministic chores** (formatting, lint `--fix`) run the tool directly via `scripts/apply-tool.sh` — free, no model. **Judgment chores** (de-slop, dead code, simplification, tests) are where the credits go: the chosen service does them via its runner (`scripts/delegate-<service>.sh`). Before a service's first chore, preflight its headless auth with `scripts/check-auth.sh` so a run never hangs on an interactive sign-in. Every chore runs in an isolated worktree, is verified by the gate, and is kept or rolled back — `references/harvest-loop.md`, `references/delegation-invocation.md`, `references/worktree-lifecycle.md`.
- Land gate-passing changes as draft PRs and summarize in plain language — `references/result-handling.md`. Optionally run one review pass first — `references/review-pipeline.md`.

## Safety invariants

- Never auto-merge AND never auto-mark-ready — gate-passing work lands as a draft PR; the final review and merge are always yours.
- Only do chores whose correctness a deterministic gate can verify (tests, type check, lint, formatter idempotency, or build).
- token-eater only spends the service(s) you name (or your saved default). It never reaches for a service you didn't choose.
- Every chore runs in a fresh git worktree; a failed gate rolls back without touching your working tree.

## Reference map

| File | What it's for |
|------|---------------|
| `adapters.yaml` | Provider registry: how to call each service's CLI headlessly |
| `skills-catalog.yaml` | Chore type → skill catalog (installed skills + stubbed HoV drop-ins) |
| `references/adapter-contract.md` | The adapter contract + the three v1 adapters + the optional balance signal |
| `references/setup-and-config.md` | The one-question setup + the small config schema |
| `references/chore-discovery.md` | Finding gate-verifiable chores + skill-aware resolution |
| `references/harvest-loop.md` | The run loop: spend the service on each chore until the backlog or the credits run out |
| `references/delegation-invocation.md` | Per-service headless delegation harness + the `delegate-<service>.sh` runners |
| `references/worktree-lifecycle.md` | Worktree isolation, collision-safe naming, and cleanup (`scripts/wt.sh`) |
| `references/result-handling.md` | Draft PR + plain-language summary + run ledger |
| `references/review-pipeline.md` | **Optional** — run one review pass before the draft PR |
| `references/schedule-install.md` | **Optional / advanced** — run token-eater on a recurring schedule |

Scripts: `detect-adapters.sh` (which CLIs are installed) · `detect-skills.sh` (chore catalog scan) · `check-auth.sh` (service headless-auth preflight) · `onwatch-usage.sh` (optional balance reader) · `wt.sh` (worktree create/cleanup/sweep) · `run-gate.sh` (deterministic gate) · `apply-tool.sh` (deterministic tool chores, free) · `delegate-{grok,codex,claude}.sh` (per-service runners).
