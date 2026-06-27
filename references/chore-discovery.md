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

token-eater is self-contained, but it may use installed skills as prompt sources when they are present:

- If `de-slopify` is installed and the chore is documentation or local code de-slop, route the chore prompt through that skill's constraints.
- If `ce-simplify-code` or an equivalent simplify-code skill is installed and the chore is a simplification task, route the matching tier through it.
- If neither is installed, use the bundled prompt constraints below.

Do not make these skills required. Their absence must not block member use (KTD6, R18).

For de-slopify and simplify chores, always embed this safety constraint in the delegated prompt:

> Never simplify away a safety check, validation, permission check, rate-limit check, error handling branch, logging needed for diagnosis, or test assertion that protects behavior.

## Backlog item shape

Each admitted chore should be represented in prose or YAML with these fields before routing:

```yaml
- id: formatter-idempotency-001
  title: Make formatter check pass
  tier: mechanical
  gate:
    type: formatter
    command: "scripts/run-gate.sh <worktree> 'pnpm exec prettier --check .'"
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

Use repo-relative paths. Keep `allowed_files` as small as practical; a chore with no explicit file list is not ready for delegation.

## Discovery procedure

1. **Detect gates.** Run `scripts/run-gate.sh <repo>` once to see whether it can auto-detect a broad gate. Also inspect project markers cheaply: `package.json`, `Makefile`, `pyproject.toml`, `Cargo.toml`, `go.mod`, formatter/linter configs, and existing test directories.
2. **Collect candidate files.** Use gate output, formatter/lint output, and local file patterns to identify a small candidate file set. Prefer files already implicated by a failing or checkable gate.
3. **Create candidates.** Map each signal to one of the bundled chores or an installed skill route.
4. **Apply the eligibility rule.** Drop any candidate without a deterministic gate, explicit allowed files, or clear success criterion (R5).
5. **Tier admitted chores.** Use the tier table above. When uncertain between two tiers, choose the higher tier or exclude the chore.
6. **Order the backlog.** Mechanical first, then standard, then high. Within a tier, prefer smaller file sets and faster gates.
7. **Pass to routing.** The harvest loop picks providers by adapter tier, cost rank, and posture; discovery does not pick providers directly (R6).

## Gate examples

Use explicit gates when known:

```bash
scripts/run-gate.sh "$WORKTREE" "pnpm exec prettier --check ."
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
