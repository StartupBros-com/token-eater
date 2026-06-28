# Setup and config

token-eater needs almost no configuration. The only thing it has to know is **which service's credits you want to spend** — and you can answer that on the command line every time (`/token-eater grok`) and never set up anything. Config just remembers a default so you can type `/token-eater` on its own.

There is no posture, tier, idle window, or reserve-floor setup. Those concepts are gone: you choose the service, and that choice is the whole policy.

## One-question setup

Run setup when there is no config and no service was named on the command line, or when the `setup` token is passed.

Ask exactly one question, in plain language:

> **Which service's credits should I spend by default?** (Grok / Codex / Claude — you can list more than one, and they'll be spent in that order. You can always override this per run, e.g. `/token-eater codex`.)

Offer only services that `scripts/detect-adapters.sh` reports `available`. Save the answer and continue into the run. Do not ask about schedules, review depth, postures, or reserve floors — those are either gone or live as optional settings a power user can add to the config file by hand (see below).

If a service is named on the command line, skip setup entirely and just use it (optionally offering to save it as the new default).

## Config locations

Load config in this order; the first one found wins (a project file overrides the user default):

1. **Per-project:** `./.token-eater.yaml` in the repository where the skill is running.
2. **User-scoped:** `${XDG_CONFIG_HOME:-~/.config}/token-eater/config.yaml` (Linux / XDG).
3. **macOS fallback:** `$HOME/Library/Application Support/token-eater/config.yaml` when XDG is unset.
4. **Windows fallback:** `%APPDATA%\token-eater\config.yaml` under Windows-native Claude Code.

Write the user-scoped config by default. Write `./.token-eater.yaml` only when the user wants a different default service for one specific project. Never write secrets — config records the choice of service only.

## Schema

Schema version `2` is YAML, intentionally small enough for an agent to read and edit without a YAML library.

```yaml
version: 2
services: [grok]              # which service(s) to spend by default, in order. The first available,
                              # un-parked service does each model chore; later ones pick up the rest.
review_before_pr: false       # optional: run one review pass before opening each draft PR
                              # (default off — review the draft PR yourself, e.g. with /ce-code-review)
stop_when_low: null           # optional/advanced: e.g. "20%" to stop spending a service when onwatch
                              # reports it near its limit. Needs onwatch; ignored if onwatch is absent.
result_dir: .token-eater/runs # where run artifacts and the ledger live (local audit trail)
```

Field meanings:

| Field | Meaning |
| ----- | ------- |
| `version` | Config schema version. Current value: `2`. An unknown version should stop and ask to re-run setup rather than guess. |
| `services` | Ordered list of service ids from `adapters.yaml` to spend. A service must also be detected before it can be used. A command-line service argument overrides this list for that run. |
| `review_before_pr` | When `true`, run the optional pass in `references/review-pipeline.md` before each draft PR. Default `false`. |
| `stop_when_low` | Optional balance guard, e.g. `"20%"`. Only has effect when onwatch is available (`scripts/onwatch-usage.sh`); otherwise the run simply continues until each service's circuit breaker fires. |
| `result_dir` | Repo-relative directory for run artifacts and the ledger. Defaults to `.token-eater/runs`. |

Anything not listed here (old `posture`, `tier`, `idle_window`, `reserve_floor`, `run_config`, `schedule` keys from schema v1) is obsolete. If you load a v1 config, treat its `providers[].id` list as the new `services` list, ignore the rest, and offer to re-run setup to write a clean v2 file.

## Round-trip behavior

Every normal invocation resolves the service before doing work:

1. If a service is named on the command line, use it (services in `$ARGUMENTS`, in order).
2. Else if the `setup` token is present, run the one-question setup.
3. Else if a readable config exists, load it and use its `services`.
4. Else run the one-question setup.
5. If config parsing fails, do not guess — report the path and the problem, and offer to re-run setup and replace the file.

After resolving the service, the run loop still runs `scripts/detect-adapters.sh`: config is intent, detection is current capability. A service must be both chosen and currently installed to be spent.
