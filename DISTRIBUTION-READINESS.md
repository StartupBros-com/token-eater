# Distribution readiness — House of Vibe

token-eater is **internal-ready on `main`** (works for power users on Linux/macOS). This is the gate
checklist before distributing it to House of Vibe members (non-technical Claude Code users, mostly on
macOS). Two threads: make it **safe** for untrusted users, and make it **installable**.

## Done

- **Layered review proven on the tool itself.** `/ce-code-review` (Claude `ce-*` fleet) → fixes →
  merge → `/pro-gate` (GPT-5.5 Pro Extended, cross-model) → fixes → merge. Each tier caught
  complementary bugs the others missed.
- **Cross-platform validated (PR #14).** Runs on macOS stock **bash 3.2.57** + BSD tools (no
  pnpm/timeout/flock), verified on a real Mac — the realistic member environment. Fixed: empty-array
  `set -u` aborts, `mapfile`, pnpm-hardcoding, `stat -c`, `timeout`.

## Open — SAFETY (makes it safe to point at untrusted repos)

A member cannot judge "is this repo trusted?", so the trust note is not enough on its own.

1. **Gate sandbox / allowlist.** The auto-detected gate runs the repo's own code (`bash -lc "$GATE"`,
   e.g. `npm test` = arbitrary script). Add a real technical control — run gates in a sandbox/container,
   or restrict auto-detected gates to a known-binary allowlist and refuse arbitrary `package.json`
   script bodies. (`--install-deps` is already opt-in for the install-script RCE path.)
2. **Validate repo-derived strings.** `ORIGIN_SLUG` / `BASE` / `BRANCH` come from the target repo and
   flow into `gh pr create --repo` and the agent recipe. Validate against strict charsets
   (`^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$`, git ref rules) before use.
3. **Stop copying `.env` into the worktree.** `wt.sh` copies the target repo's `.env`/`.env.*` where
   the autonomous service can read/exfiltrate them. Don't copy secrets by default.

## Open — DELIVERY (makes it installable by a member)

The HoV app (`~/SITES/prbot/apps/startupbros`) is course/challenge/vault-based with **no skill-install
mechanism yet**. Needs a design:
- Bundle format + install path into `~/.claude/skills/` (and how members run `/token-eater`).
- Versioning / updates.
- The **compound-engineering plugin dependency** — the genuine `ce-*` persona fleet needs it; without
  it the review falls back to generic lenses. Either bundle/recommend it, or make the fallback a
  first-class, honestly-labeled experience.
- Course lesson / vault resource that teaches install + use.

## Standing rule (added 2026-06-29)

Cross-platform validation on a real **macOS bash 3.2** target is part of the pre-distribution checklist
for any shell tooling shipped to members — a whole bug class (bash-4 features, GNU-vs-BSD tools) that a
Linux/bash-5 dev box structurally cannot surface. Same spirit as the cross-model `/pro-gate` tier.
