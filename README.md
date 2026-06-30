# token-eater 🍔

Got AI credits about to expire? token-eater puts them to work.

**Just run `/token-eater`.** It tidies up your code in an isolated copy of your project, double-checks nothing broke, and opens a **draft pull request** for you to review. It **never merges** — you decide.

```
/token-eater
```

The first time, it asks a couple of plain questions (what to clean up, which credits to spend) and remembers them — after that, `/token-eater` just runs. No flags to learn.

## How it works

1. **Run `/token-eater`.** First time on a project, pick what to do and which credits from a short menu; it saves your choices so it never asks again.
2. **token-eater does the cleanup** in an isolated copy of your project and checks the result — with your project's own tests/type-check when it has them, or an AI code review when it doesn't (clearly labeled either way).
3. **You get a draft PR** with a plain-language summary of what changed. Review it — or have AI review it (`/ce-code-review`) — before merging.

> Power users: you can still pass `/token-eater grok de-monolithize`, `--gate`, `--install-deps`, etc. — see `SKILL.md`. Everyone else can ignore that.

## Safety

- **Prefers proof, degrades honestly.** When your project has tests/type-check, it runs them and re-verifies the result independently. When it doesn't, it still helps but the PR is clearly labeled "AI-reviewed only — please read before merging."
- **Runs your project's own code** (its tests/build; with opt-in, its install scripts), so it asks before running an unfamiliar project and remembers your answer. Point it only at projects you trust.
- Every run happens in an isolated copy of your project. Your branch and uncommitted work are never touched.
- Never merges, never marks a PR ready, never auto-pushes to main.
- Only spends the credits you chose.

## Status

🧪 Beta. Run it manually for now (`disable-model-invocation: true` — a human must type `/token-eater`).

## For builders

token-eater is a Claude Code skill. The orchestrator is `SKILL.md`; the playbooks are in `references/`; the provider registry is `adapters.yaml`. (The `docs/` design notes predate the simplification — `SKILL.md` and `references/` are the source of truth.)
