---
name: token-eater
description: "[BETA] Burn idle, about-to-expire model-subscription credits on safe, machine-verified maintenance chores. Auto-detects your Claude / Codex / Grok CLIs, runs low-stakes cleanups on a drain-vs-protect posture, and opens draft PRs you review. Manual invocation only during beta."
disable-model-invocation: true
argument-hint: "[setup | run] [provider:<id>] [dry-run]"
---

# token-eater

Turn the subscription credits you would otherwise let expire into a clean-up crew for your project. token-eater detects which model CLIs you have, finds safe machine-verifiable chores, runs them on whichever provider has idle or expiring capacity, and lands the results as draft PRs you review — never auto-merged.

This file is the orchestrator. The detailed playbooks live in `references/`; the provider registry is `adapters.yaml`.

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
2. **No config, or the `setup` token → first-run setup.** Run the onboarding flow in `references/setup-and-config.md`: detect adapters, assign drain/protect posture, set the idle window, choose on-demand vs. a recurring schedule, and persist config. If a schedule was chosen, install it per `references/schedule-install.md`.
3. **Config present → harvest loop.** Load config and run the loop in `references/harvest-loop.md`.
4. **No supported adapter installed → stop.** If `scripts/detect-adapters.sh` finds none of the registered CLIs, print a plain-language explanation and exit without changing anything.

## How a harvest run proceeds (overview)

Detail lives in the references; the shape is:

- Detect adapters and their posture and budget state — `references/adapter-contract.md`, `scripts/detect-adapters.sh`.
- Build the eligible chore backlog — only chores a deterministic gate can verify — `references/chore-discovery.md`.
- For each chore: route to the cheapest in-tier adapter with harvestable surplus, run it in an isolated worktree, verify with the gate, and keep or roll back — `references/harvest-loop.md`, `references/delegation-invocation.md`.
- Land gate-passing changes as draft PRs and summarize in plain language — `references/result-handling.md`.

## Safety invariants

- Never auto-merge to the default branch — gate-passing work lands as a draft PR or branch only.
- Only delegate chores whose correctness a deterministic gate can verify (tests, type check, lint, formatter idempotency, or build).
- Never harvest a provider the user is actively using; protect-posture providers are harvested only inside their idle window.
- Every delegated chore runs in a fresh git worktree; failures roll back without touching the working tree.

## Reference map

| File | Purpose | Plan unit |
|------|---------|-----------|
| `adapters.yaml` | Declarative provider registry | U2 |
| `references/adapter-contract.md` | The five-field adapter contract + the three v1 adapters | U2 |
| `references/setup-and-config.md` | First-run onboarding + config schema | U3 |
| `references/delegation-invocation.md` | Per-adapter headless delegation harness | U4 |
| `references/chore-discovery.md` | Chore discovery + deterministic-gate eligibility | U5 |
| `references/harvest-loop.md` | Drain/protect posture engine + stop conditions | U6 |
| `references/result-handling.md` | Draft PR + plain-language summary + run ledger | U7 |
| `references/schedule-install.md` | Cross-platform schedule installer | U8 |

The full plan is at `docs/plans/2026-06-26-001-feat-token-eater-credit-harvester-plan.md`.
