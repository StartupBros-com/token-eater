---
name: token-eater
description: "[BETA] Burn idle, about-to-expire model-subscription credits on safe, machine-verified maintenance chores. Auto-detects your Claude / Codex / Grok CLIs, runs low-stakes cleanups on a drain-vs-protect posture, and opens draft PRs you review. Manual invocation only during beta."
disable-model-invocation: true
argument-hint: "[setup | run] [provider:<id>] [dry-run]"
---

# token-eater

Turn the subscription credits you would otherwise let expire into a clean-up crew for your project. token-eater detects which model CLIs you have, finds safe machine-verifiable chores, runs them on whichever provider has idle or expiring capacity, and lands the results as draft PRs you review — never auto-merged.

This file is the orchestrator. The detailed playbooks live in `references/`; the provider registry is `adapters.yaml`.

**Skill files resolve from THIS skill's base directory, not the user's project.** Every `scripts/...`, `references/...`, `adapters.yaml`, and `skills-catalog.yaml` path below is relative to the directory this `SKILL.md` lives in (the base directory the harness reports when the skill is invoked). Invoke scripts by their absolute path inside the skill — e.g. `bash <skill-dir>/scripts/detect-adapters.sh`. The *chores* run in the user's project (a worktree of it); the *tooling* lives with the skill.

## Status

`[BETA]` — manual invocation only (`disable-model-invocation: true`). Do not wire token-eater into other skills' handoffs during the beta.

## Input

<input> #$ARGUMENTS </input>

## Argument parsing

Parse `$ARGUMENTS` for optional tokens; strip each recognized token before interpreting the remainder.

| Token | Effect |
|-------|--------|
| `setup` | Force the first-run setup flow even if config exists (re-onboard). |
| `run` | Skip setup and run the harvest loop using saved config. |
| `provider:<id>` | Restrict this run to one adapter (e.g., `provider:grok`). |
| `dry-run` | Plan the run — discover chores and show what would happen — without delegating or opening PRs. |

## Entry: resolve config, then branch

1. **Locate config.** Look for token-eater config (user-scoped, with an optional per-project override). See `references/setup-and-config.md` for the path and schema.
2. **No config, or the `setup` token → first-run setup.** Run the onboarding flow in `references/setup-and-config.md`: detect adapters, assign drain/protect posture, set the idle window, choose on-demand vs. a recurring schedule, and elicit the run preferences (implementer, intermediate-review mode, review/fix rounds, grok-tapped fallback, review depth). Persist config. If a schedule was chosen, install it per `references/schedule-install.md`.
3. **Config present → harvest loop.** Load config and run the loop in `references/harvest-loop.md`.
4. **No supported adapter installed → stop.** If `scripts/detect-adapters.sh` finds none of the registered CLIs, print a plain-language explanation and exit without changing anything.

## How a harvest run proceeds (overview)

Detail lives in the references; the shape is:

- Detect adapters and read each provider's real balance (reset-aware) when onwatch is present — `references/adapter-contract.md`, `scripts/detect-adapters.sh`, `scripts/onwatch-usage.sh`.
- Build the eligible chore backlog — only chores a deterministic gate can verify — resolving each archetype to an installed skill, a (stubbed) House of Vibe drop-in, or a bundled prompt — `references/chore-discovery.md`, `skills-catalog.yaml`, `scripts/detect-skills.sh`.
- For each chore: route to the cheapest in-tier adapter with harvestable surplus, run it in an isolated worktree via its runner (`scripts/delegate-<adapter>.sh`), verify with the gate, and keep or roll back — `references/harvest-loop.md`, `references/delegation-invocation.md`.
- Run the optional review/fix pipeline — independence is guaranteed by the always-final frontier review, so the intermediate review may even be grok reviewing itself with subagents — `references/review-pipeline.md`.
- Land gate-passing changes as draft PRs and summarize in plain language — `references/result-handling.md`.

## Safety invariants

- Never auto-merge AND never auto-mark-ready — gate-passing work lands as a draft PR; PRs are independently-reviewable slices, and the final frontier review and merge are always the human's.
- Only delegate chores whose correctness a deterministic gate can verify (tests, type check, lint, formatter idempotency, or build).
- Never harvest a provider the user is actively using; protect-posture providers are harvested only inside their idle window.
- Every delegated chore runs in a fresh git worktree; failures roll back without touching the working tree.

## Reference map

| File | Purpose | Plan unit |
|------|---------|-----------|
| `adapters.yaml` | Declarative provider registry | U2 |
| `skills-catalog.yaml` | Chore archetype → skill catalog (installed skills + stubbed HoV drop-ins) | U5 |
| `references/adapter-contract.md` | The five-field adapter contract + the three v1 adapters + the balance oracle | U2 |
| `references/setup-and-config.md` | First-run onboarding + config schema + interactive run-config | U3 |
| `references/delegation-invocation.md` | Per-adapter headless delegation harness + the `delegate-<adapter>.sh` runners | U4 |
| `references/chore-discovery.md` | Chore discovery + deterministic-gate eligibility + skill-aware resolution | U5 |
| `references/harvest-loop.md` | Drain/protect posture engine + stop conditions | U6 |
| `references/review-pipeline.md` | Optional review/fix loop + frontier-review recommendation | U7+ |
| `references/result-handling.md` | Draft PR + plain-language summary + run ledger | U7 |
| `references/schedule-install.md` | Cross-platform schedule installer | U8 |

Scripts: `detect-adapters.sh` (registry scan) · `detect-skills.sh` (catalog scan) · `onwatch-usage.sh` (balance oracle) · `run-gate.sh` (deterministic gate) · `delegate-{grok,codex,claude}.sh` (per-adapter runners).

The full plan is at `docs/plans/2026-06-26-001-feat-token-eater-credit-harvester-plan.md`.
