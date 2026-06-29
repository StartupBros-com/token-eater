# token-eater 🍔

Got AI credits about to expire? token-eater puts them to work.

**You point it at a service. It spends that service's credits on safe, gate-verified cleanup work — de-slop, dead code, simplification, formatting — and opens draft PRs you review. Never merges.**

```
/token-eater grok
/token-eater codex
/token-eater grok codex   # spend them in order
```

The service you name is the only real setting. There is no posture, tier, or routing economy. You pick what gets spent; token-eater does the chores.

## How it works

1. **Name the service** on the command line, or run a one-question setup to save a default.
2. **token-eater finds the chores** — only work whose correctness a deterministic check (tests, type check, lint, formatter) can prove. Each chore runs in an isolated copy of your project.
3. **You get draft PRs** with a plain-language summary of what was cleaned. Review them yourself — or use `/ce-code-review` — before merging.

## Safety

- Only does work a machine can verify. If the project's own checks cannot prove it, token-eater does not do it.
- Every chore runs in an isolated git worktree. Your branch and uncommitted work are never touched.
- Never merges, never marks a PR ready, never auto-pushes to main.
- Only spends the service(s) you named. It never reaches for a service you did not choose.

## Status

🧪 Beta. Run it manually for now (`disable-model-invocation: true` — a human must type `/token-eater`).

## For builders

token-eater is a Claude Code skill. The orchestrator is `SKILL.md`; the playbooks are in `references/`; the provider registry is `adapters.yaml`. (The `docs/` design notes predate the simplification — `SKILL.md` and `references/` are the source of truth.)
