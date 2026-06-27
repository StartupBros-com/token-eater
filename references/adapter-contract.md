# Adapter contract

An **adapter** is the thin description of one model CLI that token-eater can delegate to. Adapters live as entries in `adapters.yaml`. The harvest loop reads them generically, so adding a provider is a registry entry, never a change to the loop (R3).

## The contract (five load-bearing fields + routing metadata)

Each adapter declares:

1. **invoke** — the headless invocation template. token-eater substitutes `{prompt_file}`, `{schema_file}`, and `{result_file}` at run time. The call must be non-interactive and must not open a TUI.
2. **reset_cadence** — how the subscription's quota resets. Informational for drain providers; for protect providers it informs the idle-window / pre-reset timing.
3. **balance_signal** — `none`, or the name of an oracle that can report remaining budget. Optional by design: most providers expose no headless balance, so `none` is a first-class value. A protect provider with `none` is harvested conservatively (idle window only); a future signal drops in here with no loop change (R10, R11).
4. **strength_tier** — the highest chore tier the adapter is trusted for: `mechanical`, `standard`, or `high`. Routing never sends a chore to an adapter whose tier is below the chore's tier.
5. **circuit_breaker** — a regex that matches the CLI's rate-limit / credit-exhaustion output. When it fires, the provider is parked for the run (R16); for a drain provider this regex doubling as the "blow through until it refuses" stop signal (R8).

Plus two routing fields:

- **default_posture** — `drain` or `protect` (R7). The setup flow proposes this; the user can override. A provider whose credits do not expire must never be `drain`.
- **cost_rank** — integer, lower is cheaper. Among adapters whose tier covers a chore, routing picks the lowest `cost_rank` with harvestable surplus (R6).

A sixth field, **structured_output**, names the flag/mechanism that constrains the CLI to emit the 5-field result schema (`status`, `files_modified`, `issues`, `summary`, `verification_summary`) consumed by the delegation harness (see `delegation-invocation.md`).

## The three v1 adapters

| id | tier | posture | cost | balance | invoke (headless) |
|----|------|---------|------|---------|-------------------|
| `grok` | mechanical | drain | 1 | none | `grok -p --output-format json --json-schema …` |
| `codex` | high | protect | 2 | none | `codex exec --output-schema … -o … - < …` |
| `claude` | high | protect | 3 | none | `claude -p …` |

Notes:

- **grok** is the safe first adapter: pure expiring surplus, mechanical tier, run drain — blow through until it signals exhaustion or the backlog empties. No balance check needed. Verified flags: `-p`, `--output-format json`, `--json-schema`, `--effort`, `--best-of-n`, `--check`.
- **codex** reuses the established `codex exec --output-schema` contract; protect posture (it is a primary provider), high tier.
- **claude** runs the user's own primary capacity; protect posture, high tier. Its structured-output mechanism is marked `tbd-preflight` — the U4 headless-contract preflight confirms whether `claude -p` can emit the result schema (and how) before the adapter is trusted.

## Detection

`scripts/detect-adapters.sh` reads the registry, runs `command -v` for each `id`, and reports which adapters are available with their default posture and cost rank. With none available, token-eater stops and changes nothing (R4).

## Adding a provider

Append an entry to `adapters.yaml` with all contract fields. Pick `strength_tier` conservatively (a weaker model earns higher tiers only after the eval harness shows it clears the gate reliably), set `default_posture` by whether its credits expire, and confirm the headless contract with the U4 preflight before first use. No loop code changes (R3).
