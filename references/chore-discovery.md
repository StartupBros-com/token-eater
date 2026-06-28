# Chore discovery

Chore discovery builds the backlog token-eater may delegate. The trust boundary is simple: admit a chore only when a deterministic gate can verify it (KTD9, R5). Everything else stays out of the unattended path, even if it looks useful.

The member path is fully automatic. Do not ask the user to curate a backlog, pick files, or classify chores (R19). The agent discovers cheap signals, attaches a gate and tier, and passes the resulting backlog to the harvest loop for provider routing (R6, R20).

## Deterministic-gate eligibility rule

A candidate chore is eligible only when all of these are true:

1. The chore has a concrete success criterion.
2. A deterministic gate exists and can be run by `scripts/run-gate.sh` or an explicit command.
3. The gate is relevant to the changed files, not merely present somewhere in the project.
4. The chore can be scope-fenced to an explicit file list for delegation.
5. The chore is not security-sensitive, architectural, speculative, or dependent on unstated product intent.

Allowed gate types are:

- Formatter idempotency or formatter check.
- Lint.
- Typecheck.
- Test suite or targeted tests.
- Build.

If no gate exists, exclude the candidate and record the reason in the run summary. Do not send ungated work to a model, no matter how mechanical it seems (R5, KTD9).

## Skill-aware discovery

Discovery is skill-aware, but still gate-first. `skills-catalog.yaml` maps chore archetypes to the skill or bundled prompt that may perform them; `scripts/detect-skills.sh` resolves that catalog on the member's machine. Use the detector before creating chore candidates so token-eater can reuse installed skills without making them a hard dependency (KTD6, R18, R19).

Run from the token-eater package root:

```bash
scripts/detect-skills.sh
```

The detector prints one TSV row per catalog archetype:

```text
<status>    <archetype>    <skill-or-detail>
```

Statuses mean:

| Status                 | Meaning                                                                            | Discovery action                                                                                                                                        |
| ---------------------- | ---------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `installed`            | A skill or command declared by the catalog is present.                             | Use that catalog-declared skill/tool as the prompt source for matching chores.                                                                          |
| `hov-dropin-available` | No installed skill was found, but the catalog names a House of Vibe drop-in.       | Suggest the HoV drop-in in the plain summary, clearly saying it is STUBBED / not built yet and only a registry placeholder today. Do not block the run. |
| `bundled`              | token-eater can drive the archetype directly with a built-in prompt or local tool. | Use the bundled safe-chore constraints below.                                                                                                           |
| `missing`              | No installed skill, no HoV drop-in, and no bundled path.                           | Skip that archetype and summarize why.                                                                                                                  |

Resolution order is per archetype:

1. Use the installed skill/tool declared by `skills-catalog.yaml`.
2. Else suggest the catalog's HoV drop-in, if present. Say plainly that the HoV drop-in is stubbed and not available yet; it is a placeholder for a future member-friendly skill download.
3. Else use token-eater's bundled prompt/tool, if the detector reports `bundled`.
4. Else skip the archetype.

Do not hardcode skill names in this playbook. The catalog is the plug-in point: it declares which specific skill belongs to which archetype, and the detector resolves what exists on this machine. If the catalog changes later, discovery follows the catalog rather than this prose.

**`cmd:`-detected archetypes are machine-level, not project-level.** `detect-skills.sh` reports `installed` for `formatter-idempotency` / `lint-autofix` when the *binary* exists on the machine (e.g. global `prettier` or `ruff`) - it does NOT mean THIS project uses that tool. Before admitting such a chore, confirm a project-local config or script (a `.prettierrc`/`eslint.config.*`/`ruff.toml`, or a `package.json` `format`/`lint` script). If none exists, the gate would be irrelevant to the project (eligibility rule 3) - exclude the chore and say so. `scripts/run-gate.sh`'s own detection already keys on project config, so trust the gate over the bare detector here.

The deterministic-gate rule still controls admission. A resolved skill only says _how_ to draft the chore; it does not make ungated work safe. After skill resolution, apply the same success criterion, gate relevance, explicit file scope, and tier checks as every other chore (R5, R6). If an installed skill wants to touch files outside the chore's allowed file list, narrow the prompt or skip the chore.

Special cases:

- `prose-deslop` is `review-only` in the catalog. It has no deterministic gate and runs only when the user explicitly opted into review-only mode. In normal unattended harvesting, skip it and explain: "Skipped prose cleanup because you did not enable review-only chores."
- High-stakes skills such as bug hunting, deadlock fixing, and security auditing are deliberately not in `skills-catalog.yaml`. Leave them with Claude or a human reviewer. Do not discover or delegate them through token-eater's cheap-credit path, even if such skills are installed.
- A HoV drop-in suggestion is member education, not execution. Do not pretend the stubbed registry item is downloadable until the catalog says it is real.

## Cheap discovery signals

Use cheap, local signals first. Avoid expensive whole-repo analysis unless a gate is already available.

| Signal                  | How to discover                                                                                                       | Candidate                                                                                              |
| ----------------------- | --------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------ |
| Formatter debt          | `scripts/run-gate.sh` detects Prettier/Biome/Ruff/Gofmt/Rustfmt, or project scripts expose `format` / `format:check`. | Normalize formatting or make formatter idempotent.                                                     |
| Lint debt               | `package.json` `lint`, Makefile `lint`, ESLint config, Ruff config, Cargo/Go lint tooling.                            | Fix lint findings that are local and behavior-preserving.                                              |
| Type errors             | `package.json` `typecheck`, `tsconfig.json`, Makefile `typecheck`, `mypy` config.                                     | Fix local type errors when the gate points to explicit files.                                          |
| Dead code               | Linter reports unused imports/vars, TypeScript `noUnused*`, Ruff `F401/F841`, Go compiler unused errors.              | Remove unused imports/locals only when the lint/type gate proves it.                                   |
| AI slop                 | Repetitive comments, placeholder prose, vague TODOs, duplicated helper code, over-broad catch-all wording.            | De-slopify docs or code only when lint/type/test/build or doc-specific checks cover the touched files. |
| Inferable missing tests | Changed or uncovered pure functions with existing adjacent test patterns and a runnable test gate.                    | Add focused tests for behavior already inferable from code and existing tests.                         |
| Build drift             | `build` script/target fails due to local, obvious issues.                                                             | Repair build-only failures when the fix can be scoped.                                                 |

Signals identify candidates; gates decide eligibility.

## Tiers

Tag every admitted chore with one tier:

| Tier         | Meaning                                                                                                                                          | Minimum adapter tier |
| ------------ | ------------------------------------------------------------------------------------------------------------------------------------------------ | -------------------- |
| `mechanical` | Formatting, import sorting, generated obvious lint fixes, small dead-code removals proven by lint/type gates.                                    | `mechanical`         |
| `standard`   | Local code cleanup, de-slopifying comments/docs, straightforward test backfills from existing patterns, simple dependency-safe repairs.          | `standard`           |
| `high`       | Multi-file changes, type repairs crossing module boundaries, tests requiring nuanced behavior inference, build fixes with moderate blast radius. | `high`               |

Routing uses the cheapest available adapter whose `strength_tier` covers the chore tier (R6). A high-tier provider may do mechanical work only when cheaper or lower-tier surplus is unavailable and the provider posture permits harvesting.

## Execution mode

Every admitted chore also carries an execution mode from `skills-catalog.yaml`:

- `exec: tool` means a deterministic fixer does the work perfectly. Run the fixer directly through `scripts/apply-tool.sh`; do not route the chore to a model, do not check model posture, and do not spend credits. Formatter idempotency and lint autofix are the canonical tool chores.
- `exec: model` means judgment is needed. Build the scope-fenced prompt as usual and let the harvest loop route it to an adapter whose tier, posture, and available surplus permit the run.

If the catalog omits `exec`, default to `model`. The credit-burn belongs on judgment chores, not on work a tool already performs deterministically.

`tool` chores must name a concrete fixer command as part of the backlog item. Examples: `pnpm format`, `pnpm lint -- --fix`, `pnpm exec prettier --write <files>`, `pnpm exec eslint --fix <files>`, `ruff check --fix <files>`, `ruff format <files>`, or `gofmt -w <files>`. The gate remains separate and authoritative; the fixer changes files, then the gate proves the result.

`model` chores carry the scope-fenced prompt constraints described below.

## Prefer the project's own scripts

For formatter and lint debt, prefer the project's own script or target over an ad-hoc root-level tool invocation. Good discovery and fixer sources include `pnpm format`, `pnpm format:check`, `pnpm lint`, `pnpm lint -- --fix`, a Makefile `format` / `lint` target, or a per-package `turbo` command already used by the repository.

This is not just style. Project scripts encode the repo's real globs, package boundaries, ignore files, and framework path conventions. A root-level ad-hoc command such as `pnpm exec prettier --check .` can misread framework paths like Next.js route groups `(group)` or dynamic routes `[param]`, or scan files the project intentionally excludes, producing false signals. Use the per-package or project-owned gate as both the discovery signal and the chore's gate whenever it exists.

Ad-hoc tool commands are fallback only after checking for project-owned scripts/targets and local tool config. When falling back, keep the file list explicit and quote paths safely.

## Bundled safe-chore set

Start with the safest mechanical chores. Add higher-tier chores only when their gate and file scope are clear.

| Chore                       | What it does                                                                                         | Gate                                                                                   | Tier         |
| --------------------------- | ---------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------- | ------------ |
| Formatter idempotency       | Run the project formatter or make already-formatted files pass formatter check. No behavior changes. | Formatter check or run-twice idempotency through `scripts/run-gate.sh`.                | `mechanical` |
| Unused import/local cleanup | Remove imports, variables, or declarations already reported unused by lint/type/compiler output.     | Lint, typecheck, compiler, or build.                                                   | `mechanical` |
| Simple lint autofix         | Apply safe lint fixes for a named rule and explicit file list.                                       | Lint.                                                                                  | `mechanical` |
| Documentation de-slop       | Tighten repetitive, placeholder, or AI-looking prose in docs without changing technical meaning.     | Markdown/documentation check if present, otherwise build/test/lint gate covering docs. | `standard`   |
| Local code de-slop          | Simplify obvious duplication or noisy comments inside an explicit file set without behavior changes. | Existing tests plus lint/typecheck/build relevant to those files.                      | `standard`   |
| Inferable test backfill     | Add a narrow test for behavior already expressed in code or neighboring tests.                       | Targeted test command or full test suite.                                              | `standard`   |
| Build-script repair         | Fix a local build break with an obvious cause and constrained file list.                             | Build.                                                                                 | `high`       |

The backlog should usually begin with formatter idempotency. It is cheap, low-risk, and often unlocks cleaner lint/test diffs for later chores.

## Optional skill routing

token-eater is self-contained, but it may use catalog-declared installed skills as prompt sources when they are present. The skill-aware discovery section is authoritative: use `skills-catalog.yaml` plus `scripts/detect-skills.sh` to decide, per archetype, whether the route is `installed`, `hov-dropin-available`, `bundled`, or `missing`.

Do not make optional skills required. Their absence must not block member use (KTD6, R18). When a skill is absent and no bundled route exists, skip that archetype rather than improvising an ungated prompt.

For catalog-declared deslop and simplify-style chores, always embed this safety constraint in the delegated prompt:

> Never simplify away a safety check, validation, permission check, rate-limit check, error handling branch, logging needed for diagnosis, or test assertion that protects behavior.

## Backlog item shape

Each admitted chore should be represented in prose or YAML with these fields before routing:

```yaml
- id: formatter-idempotency-001
  title: Make formatter check pass
  tier: mechanical
  exec: tool
  fixer_command: "pnpm format"
  gate:
    type: formatter
    command: "scripts/run-gate.sh <worktree> 'pnpm format:check'"
  allowed_files:
    - src/example.ts
    - README.md
  disallowed_paths:
    - .git/
    - .token-eater/
  success_criterion: "Formatter check exits 0 and a second formatter run produces no diff."
  prompt_constraints:
    - "Stay inside the allowed file list."
    - "Do not change behavior."
    - "Do not create commits, push, install dependencies, or edit token-eater config."
```

Use repo-relative paths. Keep `allowed_files` as small as practical; a chore with no explicit file list is not ready for execution. For `exec: tool`, `fixer_command` is required and `prompt_constraints` may be omitted because no model prompt is built. For `exec: model`, omit `fixer_command` and keep the scope-fenced prompt constraints.

## Discovery procedure

1. **Detect gates.** Run `scripts/run-gate.sh <repo>` once to see whether it can auto-detect a broad gate. Also inspect project markers cheaply: `package.json`, `Makefile`, `pyproject.toml`, `Cargo.toml`, `go.mod`, formatter/linter configs, and existing test directories. For formatter/lint debt, look for the project's own scripts or package targets before trying an ad-hoc tool command.
2. **Collect candidate files.** Use gate output, formatter/lint output, and local file patterns to identify a small candidate file set. Prefer files already implicated by a failing or checkable gate. If a project-owned script reports the debt, use that same script family for the chore's fixer/gate.
3. **Create candidates.** Map each signal to one of the bundled chores or an installed skill route, and copy the catalog execution mode (`tool` or `model`) onto the backlog item. If the catalog has no `exec`, use `model`.
4. **Apply the eligibility rule.** Drop any candidate without a deterministic gate, explicit allowed files, or clear success criterion (R5).
5. **Tier admitted chores.** Use the tier table above. When uncertain between two tiers, choose the higher tier or exclude the chore.
6. **Order the backlog.** Mechanical first, then standard, then high. Within a tier, prefer smaller file sets and faster gates.
7. **Pass to routing.** The harvest loop picks providers by adapter tier, cost rank, and posture; discovery does not pick providers directly (R6).

## Gate examples

Use explicit gates when known:

```bash
scripts/run-gate.sh "$WORKTREE" "pnpm format:check"
scripts/run-gate.sh "$WORKTREE" "pnpm lint"
scripts/run-gate.sh "$WORKTREE" "pnpm typecheck"
scripts/run-gate.sh "$WORKTREE" "pnpm test -- --runInBand"
scripts/run-gate.sh "$WORKTREE" "ruff check ."
scripts/run-gate.sh "$WORKTREE" "cargo test"
scripts/run-gate.sh "$WORKTREE" "go test ./..."
```

Auto-detected gates are acceptable for coarse validation, but the chore prompt should still name the specific gate token-eater will run after delegation.

## Exclusion examples

Exclude these from unattended delegation:

- "Refactor the auth layer" with no targeted tests.
- "Improve security" without a deterministic security test or linter rule.
- "Update dependencies" when the project has no test/build gate.
- "Clean up all AI slop" across the whole repository with no file list.
- "Fix flaky tests" when the failure is nondeterministic.
- Any change that requires product judgment, credentials, production access, or user approval.

These may be useful human tasks; they are not token-eater chores.

## Member-facing summary input

For every admitted or excluded candidate, keep one plain-language sentence for `references/result-handling.md`:

- Admitted: "Formatted two TypeScript files because the formatter can verify the result."
- Excluded: "Skipped dependency updates because this project has no test or build gate to verify them."

This preserves R20 without asking members to understand the adapter mechanics.
