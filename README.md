# token-eater 🍔

Got leftover AI credits every week that just... expire? token-eater puts them to work.

It looks at which AI coding tools you already have (Claude, Codex / ChatGPT, Grok), finds the safe, boring cleanup jobs in your project — formatting, dead code, removing AI slop, missing tests — and runs them on whatever credits you are not using. Everything it does shows up as a **draft pull request** you review before anything is final. Nothing gets merged automatically. Nothing touches the work you are actively doing.

## How it works

1. **First run** walks you through a quick setup: it detects your tools, asks how you want to use them, and — if you want — sets up a schedule so it runs on its own.
2. **After that**, run it whenever you like (or let the schedule fire it) and it burns idle credits on safe chores.
3. **You review** the draft PRs it opens, alongside a plain-English summary of what it cleaned up.

## Safety

token-eater only does work a machine can check — your tests, type checker, linter, or formatter have to pass. It always works in an isolated copy of your project, and it never merges anything itself. If it cannot prove a change is safe, it does not make it.

## Status

🧪 Beta. Run it manually for now.

## For builders

token-eater is a Claude Code skill. The orchestrator is `SKILL.md`; the playbooks are in `references/`; the provider registry is `adapters.yaml`. The design and build plan live in `docs/plans/`.
