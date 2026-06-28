# Harvest loop

The harvest loop is token-eater's end-to-end runbook. It detects current adapters, builds a gate-backed chore backlog, runs deterministic tool chores directly, routes judgment chores to the cheapest adapter that is allowed to spend surplus, records the result, and repeats until no eligible work remains (F1).

The posture engine is the control surface. Drain providers are meant to exhaust expiring surplus and run blind until refusal. Protect providers are primary capacity and run only when idle, never while the user is active, and never below a reserve floor when a balance oracle exists (R7-R11).

## Loop invariants

- Do not execute a chore unless `references/chore-discovery.md` admitted it with a deterministic gate (R5).
- Do not route to an adapter whose `strength_tier` is below the chore tier (R6).
- Among eligible adapters, prefer the lowest `cost_rank` from `adapters.yaml` that has harvestable surplus (R6).
- Do not run a protect provider outside the saved idle window or while there is evidence the user is actively using it (R9).
- Do not check balance, reserve floors, or idle windows for a drain provider. Drain stops only on circuit-breaker exhaustion, provider parking, or an empty backlog (R8).
- Do not route `exec: tool` chores to any provider. Deterministic tool chores run through `scripts/apply-tool.sh`; they do not check posture, balances, or credits.
- Park a provider after the configured consecutive failure limit and continue with the others (R16).
- Every gate-passing result goes through `references/result-handling.md`; nothing merges to the default branch (R14).

## Inputs

Load these before the first routing decision:

1. **Merged config** from `references/setup-and-config.md`: configured providers, postures, idle window, reserve floors, `defaults.consecutive_failure_limit`, and `defaults.result_dir`.
2. **Adapter registry** from `adapters.yaml`: `strength_tier`, `cost_rank`, `balance_signal`, `circuit_breaker`, `reset_cadence`, and invocation metadata.
3. **Current detection output** from `scripts/detect-adapters.sh`: available vs. missing CLIs and their resolved paths.
4. **Backlog** from `references/chore-discovery.md`: admitted chores with id, tier, `exec`, gate, allowed files, disallowed paths, success criterion, prompt constraints for model chores, and `fixer_command` for tool chores.

Config is intent; detection is capability. A provider must be enabled in config, present in `adapters.yaml`, and currently available from detection before it may receive work.

## Provider run state

For each provider available this run, keep an in-memory state record:

```yaml
id: grok
posture: drain
tier: mechanical
cost_rank: 1
balance_signal: none
reserve_floor: 0
available: true
parked: false
park_reason: null
consecutive_failures: 0
preflight: unknown
auth_preflight: unknown
last_outcome: null
```

The state is per run. Parking does not permanently disable the provider; a later token-eater run may try again after reset or setup changes.

## Harvestability by posture

### Drain posture (R7, R8)

A drain provider is harvestable when all of these are true:

1. It is configured, enabled, detected, and not parked.
2. Its tier covers the chore.
3. The backlog is not empty.

Do not perform any of these checks for drain:

- No balance lookup, even if a future adapter grows a `balance_signal`.
- No reserve-floor comparison.
- No idle-window check.
- No active-session check.

Drain means: delegate until the adapter's `circuit_breaker` fires, the provider hits the failure limit, or no eligible chore remains. For v1, `grok` is the canonical drain provider: `balance_signal: none`, `strength_tier: mechanical`, `cost_rank: 1`.

### Protect posture (R7, R9, R10, R11)

A protect provider is harvestable only when all of these are true:

1. It is configured, enabled, detected, and not parked.
2. Its tier covers the chore.
3. The current local time is inside `idle_window.start` / `idle_window.end` on an allowed day. Windows may cross midnight.
4. `idle_window.never_while_active` does not block the run.
5. If `balance_signal` is not `none`, the oracle reports remaining capacity above `reserve_floor`.
6. If `balance_signal` is `none`, no reserve check is invented; harvest conservatively with the idle-window and active-use guards only, or skip the provider when the run cannot establish those guards.

Never run a protect provider while the user appears active in that provider. Treat these as active-use signals when present:

- The current Claude Code / Codex / provider session is interactive rather than a scheduled headless run.
- Provider-specific sandbox or session flags are present, such as `CLAUDE_CODE_SANDBOX`, `CODEX_SANDBOX`, `CLAUDECODE`, `CURSOR_AGENT`, or another documented model-session flag.
- A provider process for the same account appears to be foregrounded by the user.
- The invocation is not inside the configured idle window and the user did not explicitly request a one-off run.

When the active-use signal is ambiguous, err conservative for protect providers: park the provider for this run with reason `active-or-not-idle`. This is the AE1 behavior.

The `balance_signal` field remains load-bearing even when it is `none` (R11). Do not remove or ignore it: future oracle-backed protect providers should use the same routing branch and add only the reserve-floor check. AE5 is the deferred oracle case: once a real Anthropic/OpenAI oracle exists, the loop holds the reserve floor from that signal before delegating.

## End-to-end procedure (F1)

1. **Detect adapters.** Run `scripts/detect-adapters.sh` from the token-eater package root. If it exits `3`, stop with the R4 plain explanation and make no changes. Merge the available rows with config and `adapters.yaml`.
2. **Initialize provider state.** Exclude configured providers that are missing from detection, disabled in config, absent from the registry, or whose posture violates the registry invariant that non-expiring providers must not be drain (R7). Record exclusions for the summary.
3. **Build the eligible backlog.** Follow `references/chore-discovery.md`. The backlog must contain only gate-backed chores with explicit file scope. If the backlog is empty, end the run and summarize what was skipped and why.
4. **Pick the next chore.** Choose the first remaining backlog item in discovery order: mechanical before standard before high, then smaller/faster gates first.
5. **Branch by execution mode before provider routing.** If the chore is `exec: tool`, do not build a route set and do not inspect provider posture, balance, reserve floors, idle windows, or credits. Create the worktree, write the allowed-files list, and run the deterministic fixer directly:

   ```bash
   bash <skill-dir>/scripts/apply-tool.sh <worktree> "<fixer-command>" <allowed-files-file>
   ```

   `apply-tool.sh` returns the same JSON shape and exit-code family the loop already understands: `0` ok, `2` invoke-error, `4` scope-violation. After it returns, run the chore's deterministic gate and hand the normalized outcome to `references/result-handling.md` exactly like a model chore. Deterministic chores never spend credits; the credit-burn is for judgment chores.
6. **For `exec: model`, build the route set.** From unparked providers, keep only those whose `strength_tier` covers the chore tier and whose posture is harvestable now. Sort by `cost_rank` ascending. This implements the cheapest in-tier rule (R6).
7. **Handle no route.** If no provider can run the current model chore, mark that chore blocked for this run with the plain reason. Try the next backlog item. If no backlog item has a route, end the run.
8. **Preflight the selected adapter lazily before its first model chore.** Run the auth preflight first:

   ```bash
   bash <skill-dir>/scripts/check-auth.sh <adapter>
   ```

   On exit `3` / `needs-reauth`, park the adapter for the run with the printed plain-language message. If this is the configured implementer and the grok-tapped posture says `pause-on-tapped`, pause the run. Do not invoke a CLI that could hang on interactive sign-in. On exit `2` / `unknown`, proceed but add the printed risk message to `issues[]`. On exit `0`, proceed. Only after this auth check may the loop run the one-time headless-contract preflight in `references/delegation-invocation.md`; if that preflight fails, park the provider for the run and continue.
9. **Delegate to the selected provider.** Use `references/delegation-invocation.md` to create the worktree, assemble the prompt, launch the adapter headlessly, poll, classify the model result, and run the deterministic gate.
10. **Apply stop and failure handling.** If model output matches the provider's `circuit_breaker`, park it immediately. If a model delegation or gate fails for another reason, increment `consecutive_failures`; park the provider when it reaches `defaults.consecutive_failure_limit` (default `3`). Reset `consecutive_failures` to `0` after a gate-passing model chore. Tool-chore failures do not count against any provider because no provider ran.
11. **Record and summarize the chore.** Hand the outcome to `references/result-handling.md`: create a draft PR or branch for gate-passing work, append the ledger entry, and keep a member-facing sentence for the run summary (R17, R20).
12. **Repeat.** Remove completed chores from the backlog. Re-evaluate posture before every model delegation, because idle windows can close and active-use state can change. Stop when the backlog is empty or every provider that could cover remaining model chores is parked or not harvestable.

## Model routing details

This section applies only to `exec: model` chores. `exec: tool` chores already ran through `scripts/apply-tool.sh` before provider routing.

Use the tier order `mechanical < standard < high`. An adapter covers a chore when its tier is equal or higher.

```text
routeable(provider, chore) =
  provider.enabled
  and provider.detected
  and not provider.parked
  and tier_rank(provider.strength_tier) >= tier_rank(chore.tier)
  and posture_allows_harvest(provider)
```

Sort routeable providers by:

1. `cost_rank` ascending.
2. Drain before protect only when `cost_rank` ties and both are in tier.
3. Provider id alphabetically as a deterministic tiebreaker.

A stronger provider may do weaker work only when it is still the cheapest currently harvestable in-tier adapter or when lower-tier/cheaper surplus is unavailable. Do not spend a protect provider just because it is stronger.

## Circuit breaker and provider parking (R16)

Park a provider for the current run when any of these happens:

- Its preflight fails.
- Its stdout/stderr/result matches `circuit_breaker` from `adapters.yaml`.
- It reaches `defaults.consecutive_failure_limit` consecutive failures.
- A protect provider leaves the idle window or becomes active during the run.
- A protect provider with a real `balance_signal` falls to or below `reserve_floor`.

Parking means: do not route more chores to that provider in this run. Continue routing with other providers. Record the park reason in the ledger and final summary.

For drain providers, a circuit-breaker match is a normal stop condition, not a scary failure. Say plainly that the expiring capacity appears exhausted and token-eater moved on.

## Acceptance examples

### AE1: only protect provider is active

State:

- Configured providers: `claude` only.
- Posture: `protect`.
- User is actively in a Claude Code session or the run is outside the idle window.

Expected behavior: do not delegate anything. Park `claude` for this run with reason `active-or-not-idle`, leave the working tree untouched, and report: "No spare model capacity was available; Claude is protected while you are using it." This covers R9.

### AE2: deterministic formatter chore uses the tool path

State:

- Backlog contains a formatting chore tagged `mechanical` with `exec: tool`.
- Available providers include `grok` (`mechanical`, `cost_rank: 1`, `drain`) and `claude` (`high`, `cost_rank: 3`, `protect`).

Expected behavior: run the formatter through `scripts/apply-tool.sh`, then run the gate and send the result to `references/result-handling.md`. Do not route the chore to Grok or Claude, and do not spend credits. This preserves R6 for model chores while keeping deterministic chores free.

### AE3: cheapest in-tier model routing

State:

- Backlog contains a dead-code cleanup chore tagged `mechanical` with `exec: model` because it needs judgment beyond a linter's safe autofix.
- Available providers include `grok` (`mechanical`, `cost_rank: 1`, `drain`) and `claude` (`high`, `cost_rank: 3`, `protect`).

Expected behavior: route the chore to `grok` after auth preflight and headless-contract preflight pass. Its tier covers mechanical model work and it is the cheapest harvestable adapter. Do not use Claude merely because it is stronger. This covers R6.

### AE4: grok drain runs blind

State:

- `grok` is configured as `drain`.
- Backlog has multiple mechanical chores.
- `grok` has `balance_signal: none`.

Expected behavior: keep delegating eligible `exec: model` mechanical chores to `grok`, with no balance check, reserve-floor check, or idle-window check, until either the backlog empties or output matches the `grok` `circuit_breaker` regex. `exec: tool` mechanical chores still bypass Grok. This covers R7 and R8.

### AE5: gate failure rolls back

State:

- A delegated chore returns schema-valid success but `scripts/run-gate.sh` fails.

Expected behavior: `references/delegation-invocation.md` removes the worktree/temporary branch, opens no PR, leaves the user's working tree untouched, increments the provider failure count, and `references/result-handling.md` records the failed gate. This covers R13-R15.

### AE6: oracle-backed protect provider, deferred

State:

- A future protect provider has `balance_signal: onwatch-anthropic` and `reserve_floor: 20`.
- The run is inside the idle window and the user is not active.

Expected behavior: call the oracle before delegation and skip/park the provider when remaining capacity is at or below `20%`. With balance above the floor, the provider may run. This covers R10 once the oracle ships.

## Stop conditions

End the harvest run when any of these is true:

- The backlog is empty.
- Every remaining chore lacks a currently harvestable provider.
- All providers are parked.
- All protect providers are outside the idle window, active, or below an oracle-backed reserve floor.
- The user requested `dry-run`, in which case stop after detection, backlog construction, and route planning without delegation or PR creation.

Always finish through `references/result-handling.md` so the member sees a plain-language summary and the ledger reflects every attempted, skipped, failed, or completed chore (R17, R20).
