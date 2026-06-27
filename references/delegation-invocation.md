# Delegation invocation

This playbook runs one eligible chore on one adapter. It is the isolation and verification boundary for token-eater: every delegated task runs in a fresh git worktree, returns a constrained 5-field result, and survives only if the deterministic gate passes (R12, R13, R15). Provider failures are classified so the harvest loop can park noisy adapters and continue with the others (R16).

The shape mirrors the proven Codex delegation harness: pass file paths instead of large file contents, launch headless work in the background, poll separately, and roll back the worktree on red.

## Do not delegate from inside a model sandbox

Before creating a worktree, check whether this process is already running inside a model sandbox. If so, skip delegation and finish the chore locally or defer it. Do not recursively launch model CLIs from inside another model-controlled sandbox.

Treat these as blocking signals when present and non-empty:

- `CODEX_SANDBOX`
- `CLAUDE_CODE_SANDBOX`
- `CLAUDECODE`
- `CURSOR_AGENT`
- `AIDER_MODEL`
- Any provider-specific sandbox flag documented by the current environment

Report the skip as `issues[]` in the chore summary; it is not a gate failure.

## Result schema

Every delegated run must produce exactly this JSON shape. Extra keys are ignored by the orchestrator; missing or wrongly typed required keys make the result malformed.

```json
{
  "type": "object",
  "required": [
    "status",
    "files_modified",
    "issues",
    "summary",
    "verification_summary"
  ],
  "properties": {
    "status": {
      "type": "string",
      "enum": ["completed", "partial", "failed"]
    },
    "files_modified": {
      "type": "array",
      "items": { "type": "string" }
    },
    "issues": {
      "type": "array",
      "items": { "type": "string" }
    },
    "summary": { "type": "string" },
    "verification_summary": { "type": "string" }
  },
  "additionalProperties": false
}
```

Write this schema to a per-run `schema.json` file and pass its path as `{schema_file}` in the adapter `invoke` template.

## One-time headless-contract preflight

Run this once per adapter before its first real chore in a token-eater run. Cache the outcome in the run ledger; do not keep trying a failing adapter.

The preflight proves three things:

1. **Closed stdin does not hang.** Invoke the adapter with stdin closed or redirected from `/dev/null` unless the adapter template intentionally consumes `{prompt_file}` on stdin.
2. **Structured output works on success and error paths.** A trivial prompt must produce the 5-field schema on success; an intentionally impossible prompt must either produce schema-valid `status: failed` JSON or exit non-zero.
3. **Failures are signaled.** A CLI transport/auth/rate-limit failure must exit non-zero or match the adapter's `circuit_breaker` regex. Silent success with no result file is a task failure, not a usable adapter.

Preflight prompt:

```text
You are being preflighted by token-eater. Do not edit files. Return only the required JSON result schema. Use status "completed", files_modified [], issues [], summary "preflight ok", and verification_summary "no project gate run".
```

Preflight steps:

1. Create a temporary directory outside the project worktree.
2. Write `prompt.txt`, `schema.json`, `result.json`, `stdout.log`, and `stderr.log` paths there.
3. Read the adapter's `invoke` template from `adapters.yaml` and substitute `{prompt_file}`, `{schema_file}`, and `{result_file}`. Use shell-safe absolute paths.
4. Launch it with closed stdin where possible. If it fails to exit within the local preflight timeout, kill it and park the provider.
5. Parse `result.json` if the template writes one; otherwise parse stdout only if the adapter contract says stdout is the result channel.
6. Validate the 5 fields and types.

Claude note: `adapters.yaml` marks `claude` `structured_output: tbd-preflight`. Resolve that during this preflight. If the installed `claude -p` cannot be made to emit schema-valid JSON headlessly and non-interactively, park `claude` for this run and record that its structured-output contract is unresolved. Do not send chores to Claude until the preflight is green.

## Per-chore harness

Run these steps for each chore selected by the harvest loop.

1. **Prepare names.** Pick a stable run id such as `token-eater-YYYYMMDD-HHMMSS-<provider>-<slug>`. Keep all run artifacts under `.token-eater/runs/<run-id>/` in the main repository and copy the prompt/schema/result paths into the worktree as needed.
2. **Create a fresh worktree.** From the repository root, create a new branch and worktree, for example:

   ```bash
   git worktree add -b token-eater/<run-id> ../token-eater-<run-id> HEAD
   ```

   If the repository has uncommitted user changes, do not touch or stash them. Worktree isolation is what protects the user's current tree (R12).

3. **Assemble a scope-fenced prompt.** The prompt must include only the chore the provider is allowed to do:
   - Task title and one-paragraph objective.
   - Explicit repo-relative file list the adapter may read and modify.
   - Explicit files or paths it must not touch.
   - Success criterion tied to the deterministic gate.
   - The gate command token-eater will run after delegation.
   - Chore tier and adapter id.
   - Safety constraints from `references/chore-discovery.md`, including "never simplify away a safety check" for deslop/simplify chores.
   - The required 5-field JSON result schema.

   The file list is load-bearing. Do not delegate a vague "clean up the repo" prompt.

4. **Write schema and result paths.** Put `prompt.txt`, `schema.json`, `result.json`, `stdout.log`, `stderr.log`, and `pid` under the run artifact directory. Use absolute paths when substituting the invoke template.
5. **Build the adapter command.** Read the adapter's `invoke` value from `adapters.yaml`. Replace `{prompt_file}`, `{schema_file}`, and `{result_file}` with shell-escaped absolute paths. Run the command with the worktree as its current directory.
6. **Launch in the background.** Start the adapter as a background process and return control immediately:

   ```bash
   (cd "$WORKTREE" && eval "$ADAPTER_COMMAND") >"$STDOUT_LOG" 2>"$STDERR_LOG" &
   echo $! >"$PID_FILE"
   ```

   Do not foreground a long-running model command with `&` and then wait in the same tool call. The foregrounded wait hits the approximately two-minute host timeout. Launch and poll are separate steps.

7. **Poll separately.** In a later step, read the PID and check whether it is still running. While running, report concise progress and keep polling at a reasonable interval. When it exits, capture the exit code. If the shell cannot recover the original exit code, classify the result by the presence and validity of `result.json` plus circuit-breaker output, then err conservative.
8. **Classify the adapter result.** Use the table below before touching the diff.
9. **Run the deterministic gate.** If the adapter result is usable, run `scripts/run-gate.sh "$WORKTREE" "$GATE_COMMAND"` when the chore supplied an explicit gate. If no explicit command was supplied, run `scripts/run-gate.sh "$WORKTREE"` and let it auto-detect. Gate exit code is authoritative (R13).
10. **Keep or roll back.** Keep gate-passing worktree changes for `references/result-handling.md` to branch/PR. Remove the worktree with `git worktree remove --force "$WORKTREE"` on gate failure, malformed result, `status: failed`, or CLI failure (R15).

## Result classification

| Adapter exit / result                          | Classification    | Action                                                                                                                                              |
| ---------------------------------------------- | ----------------- | --------------------------------------------------------------------------------------------------------------------------------------------------- |
| Exit code non-zero                             | CLI failure       | Park provider for this run if the output matches `circuit_breaker`; otherwise count toward the consecutive failure limit (R16). Roll back worktree. |
| Exit code zero, missing result                 | Task failure      | Treat as malformed delegation. Roll back worktree.                                                                                                  |
| Exit code zero, malformed JSON or wrong schema | Task failure      | Roll back worktree. Count a provider failure.                                                                                                       |
| Schema-valid `status: failed`                  | Task failure      | Roll back worktree. Keep the issue text for the run summary.                                                                                        |
| Schema-valid `status: partial`                 | Partial success   | Run the gate. If green, keep the worktree and finish remaining cleanup locally before result handling; if red, roll back.                           |
| Schema-valid `status: completed`               | Candidate success | Run the gate. Keep only if the gate passes.                                                                                                         |

The deterministic gate is still required for `status: completed`. A model's self-report never substitutes for the project gate.

## Worktree rollback rules

Rollback means:

1. Capture `stdout.log`, `stderr.log`, `result.json` if present, and the gate output in the run artifact directory.
2. From the main repository, run `git worktree remove --force <worktree>`.
3. Delete the temporary branch if it was created and no PR/branch result should remain:

   ```bash
   git branch -D token-eater/<run-id>
   ```

4. Confirm the main working tree was not modified by the delegation. If it changed, stop and report the exact files; do not attempt broad cleanup.

Never roll back or reset the user's original worktree. The only destructive operation permitted here is removing the token-eater-created worktree/branch.

## Gate invocation

`scripts/run-gate.sh` is the standard gate runner. It accepts:

```bash
scripts/run-gate.sh [target-dir] [explicit gate command...]
```

Examples:

```bash
scripts/run-gate.sh "$WORKTREE" "pnpm exec prettier --check ."
scripts/run-gate.sh "$WORKTREE" "pnpm test"
scripts/run-gate.sh "$WORKTREE"
```

When the chore has a known gate, pass it explicitly. Auto-detection is a fallback for broad project gates only.

## Prompt skeleton

Use this structure, filling every bracketed field:

```text
You are running one token-eater maintenance chore in an isolated git worktree.

Task: [specific chore]
Adapter: [provider id]
Tier: [mechanical|standard|high]

Allowed files:
- [repo-relative path]

Do not touch:
- [repo-relative path or glob]

Success criterion:
[A concrete condition that the deterministic gate verifies.]

Gate token-eater will run after you finish:
[gate command]

Safety constraints:
- Stay inside the allowed file list.
- Make the smallest maintainable change that satisfies the task.
- Do not change public behavior unless the chore explicitly asks for it and the gate covers it.
- Never simplify away a safety check, validation, permission check, rate-limit check, or error handling branch.
- Do not create commits, push branches, open PRs, install dependencies, or edit token-eater config.

Return only JSON matching the required 5-field result schema:
{status, files_modified, issues, summary, verification_summary}
```

## Provider parking

Park a provider for the current harvest run when:

- The preflight fails.
- The adapter output matches its `circuit_breaker` regex.
- It reaches the configured consecutive failure limit.
- It repeatedly produces malformed or missing result JSON.

Parking is per run, not permanent. Later runs may try the provider again after the reset cadence or after setup changes.
