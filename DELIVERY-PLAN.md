# Delivery plan — getting token-eater to House of Vibe members

Decisions (2026-06-29): ship token-eater as a **Claude Code plugin** in a **new HoV-branded
marketplace**, and **require the compound-engineering plugin** (for the genuine `ce-*` reviewer
personas). HoV members live in Claude Code, so the native plugin install is the right path — one
command, native versioning/updates, no `curl|bash`.

## Member install (target experience)

```
/plugin marketplace add StartupBros-com/hov-marketplace     # one time
/plugin install token-eater@hov                              # + compound-engineering (companion)
/token-eater                                                 # interactive preflight, then just runs
```

## Build steps

1. ✅ **Plugin manifest** — `.claude-plugin/plugin.json` (this PR). Makes token-eater installable as a
   Claude Code plugin (works today via a direct git source; via the marketplace once step 2 lands).
2. **HoV marketplace repo** — a new git repo `StartupBros-com/hov-marketplace` with
   `.claude-plugin/marketplace.json`:
   - lists `token-eater` (source = this repo),
   - lists `compound-engineering` (source = `EveryInc/compound-engineering-plugin`) as the required
     companion, so `marketplace add hov` then installing both is one flow.
   - room to grow into other HoV tools later.
3. **Dependency enforcement** (plugin manifests have NO hard-dependency field — verified). Two layers:
   - **Member-facing preflight** (SKILL.md): on first run, Claude checks whether the compound-engineering
     personas are available; if not, plain-language "I need the compound-engineering plugin for the code
     reviewers — install it?" → `/plugin install compound-engineering@hov` → continue.
   - **Engine fallback** (already shipped): if the personas aren't found, `run-session.sh` degrades to
     generic-lens reviewers rather than failing — the safety net.
4. **HoV course / vault content** in `~/SITES/prbot/apps/startupbros/content/` — a short lesson:
   "Put your expiring AI credits to work" → the two install commands + `/token-eater` + how to review
   the draft PR. Plain language, screenshots, no flags.

## Open / confirm before public release

- **License** — manifest defaults to `MIT`; confirm or change (no `LICENSE` file yet).
- **End-to-end install test** — `/plugin install` from the git source on a clean machine (ideally the
  mac), then `/token-eater` runs the preflight. (Pairs with the cross-platform checklist item.)
- **Repo home** — token-eater currently lives at `StartupBros/token-eater` (redirects to
  `StartupBros-com`); confirm the canonical owner before publishing the marketplace source URL.
- The 3 safety items + cross-platform are already DONE (see DISTRIBUTION-READINESS.md); the
  observability (per-run spend on grok) gap remains a known limitation to surface in the course copy.
