# Setup and config

Setup is the first-run contract for token-eater. It detects usable model CLIs, proposes conservative postures, records the user's scheduling preference, and writes a small config file that later runs load without asking again (R18, R22). The `setup` argument always forces this flow, even when config already exists.

The setup flow is deliberately plain: no oracle, auth manager, curated backlog, or project-specific scaffolding is required. Defaults protect primary providers unless the user explicitly loosens them (R7, R9, R21).

## Config locations

Load config in this order:

1. **Per-project override:** `./.token-eater.yaml` in the repository where the skill is running.
2. **User-scoped config:** `${XDG_CONFIG_HOME:-~/.config}/token-eater/config.yaml` on Linux and other XDG systems.
3. **macOS user config fallback:** `$HOME/Library/Application Support/token-eater/config.yaml` when XDG is unset and that is the user's normal config convention.
4. **Windows user config fallback:** `%APPDATA%\token-eater\config.yaml` when running under Windows-native Claude Code.

Write the user-scoped config by default. Write `./.token-eater.yaml` only when the user asks for project-specific behavior, such as a different provider posture or a tighter idle window for this repo. A project override may be partial: merge it over the user config, with arrays replaced by provider `id` rather than blindly concatenated.

Do not write secrets. The config records orchestration choices only.

## First-run flow

Run these steps in order.

1. **Detect adapters.** Run `scripts/detect-adapters.sh` from the token-eater package root. It prints one TSV row per registry entry: availability, adapter id, default posture, cost rank, and resolved path. If it exits `3`, no supported adapter is installed; stop with the R4 plain explanation and do not write config.
2. **Confirm the installed set.** Show only `available` adapters as candidates. Keep `missing` adapters out of `providers[]`; a future setup run can add them after installation.
3. **Propose postures per provider.** Use the registry defaults from `adapters.yaml`: `grok` -> `drain`, `claude` -> `protect`, `codex` -> `protect`. Explain the effect in one sentence per provider. Let the user override, but enforce the invariant that a non-expiring provider is never `drain` (R7).
4. **Set the idle window.** Default to an overnight window in the user's local time, `22:00` to `07:00`. Store the timezone as an IANA name when available, otherwise `local`. Protect-posture providers may run only inside this window (R9, R21).
5. **Enable the never-while-active guard.** Default `never_while_active: true` and keep it on unless the user explicitly disables it. The guard means token-eater must skip protect providers when there is evidence the user is actively using that provider or the current model sandbox (R9, R21).
6. **Choose reserve floors.** For v1, all three bundled adapters have `balance_signal: none`, so reserve floors are policy defaults rather than enforced balance checks. Persist them anyway so a future oracle can drop in without changing config shape (R10, R11). Defaults: `claude: 20%`, `codex: 20%`, `grok: 0%`. Drain providers ignore reserve floors (R8).
7. **Choose run mode.** Ask whether token-eater should be `on_demand` only or install a recurring schedule. Default to `on_demand`. If the user chooses `recurring`, persist the schedule choice and hand off to `references/schedule-install.md` after writing config (R22).
8. **Write config atomically.** Create the parent directory, write to a temporary file in the same directory, then rename it into place. Preserve unrelated existing keys only if the file already has a higher `version` that token-eater can read; otherwise rewrite the known schema and report that older/unknown fields were ignored.
9. **Round-trip before continuing.** Re-load the file you just wrote, merge the optional project override if present, and confirm the detected postures, idle window, reserve floors, and schedule match what will be used for the run.

Setup should ask the minimum number of questions needed. Prefer defaults and a final "use these settings?" confirmation over one prompt per field. Ask for clarification only when the user chooses an unsafe or contradictory combination.

## Persisted schema

Schema version `1` is YAML and intentionally simple enough for an agent to read and update without a YAML library.

```yaml
version: 1
providers:
  - id: grok
    posture: drain
    tier: mechanical
    enabled: true
    reserve_floor: 0
  - id: codex
    posture: protect
    tier: high
    enabled: true
    reserve_floor: 20
  - id: claude
    posture: protect
    tier: high
    enabled: true
    reserve_floor: 20
idle_window:
  timezone: local
  start: "22:00"
  end: "07:00"
  days: [mon, tue, wed, thu, fri, sat, sun]
  never_while_active: true
schedule:
  mode: on_demand
  native_id: null
  command: null
  installed_at: null
defaults:
  consecutive_failure_limit: 3
  result_dir: .token-eater/runs
```

Field meanings:

| Field                                | Meaning                                                                                                                                                                |
| ------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `version`                            | Config schema version. Current value: `1`. Unknown future versions should stop and ask for setup rather than guessing.                                                 |
| `providers[].id`                     | Adapter id from `adapters.yaml`; must match a detected CLI before use.                                                                                                 |
| `providers[].posture`                | `drain` or `protect`. Drain exhausts expiring surplus; protect only uses spare capacity inside guardrails (R7-R9).                                                     |
| `providers[].tier`                   | Highest chore tier this provider may receive: `mechanical`, `standard`, or `high`, copied from the registry unless explicitly lowered.                                 |
| `providers[].enabled`                | Whether token-eater may route work to this provider. Missing means `true` for schema v1.                                                                               |
| `providers[].reserve_floor`          | Percent of quota to preserve for protect providers when a balance oracle exists. With `balance_signal: none`, it is advisory and protect runs stay conservative (R10). |
| `idle_window.timezone`               | IANA timezone or `local`. Use it to evaluate overnight windows correctly across midnight.                                                                              |
| `idle_window.start` / `end`          | 24-hour `HH:MM` local times. A window whose end is earlier than start crosses midnight.                                                                                |
| `idle_window.days`                   | Days on which the window may start. Omit or empty means every day.                                                                                                     |
| `idle_window.never_while_active`     | Guard that blocks protect-provider delegation while the user appears active. Defaults to `true` (R9, R21).                                                             |
| `schedule.mode`                      | `on_demand` or `recurring`. On-demand means no native schedule should be installed.                                                                                    |
| `schedule.native_id`                 | Scheduler id written by `schedule-install.md`, such as a cron marker, launchd label, systemd unit, or Task Scheduler name.                                             |
| `schedule.command`                   | The headless command installed by the scheduler, if any.                                                                                                               |
| `schedule.installed_at`              | ISO-8601 timestamp for the schedule installation, or `null`.                                                                                                           |
| `defaults.consecutive_failure_limit` | Provider circuit-breaker threshold before parking it for the run (R16).                                                                                                |
| `defaults.result_dir`                | Repo-relative directory for run artifacts and ledgers used by later units.                                                                                             |

Only include providers that were detected at setup time. Later harvest runs should re-run detection and silently skip a configured provider that is no longer installed, reporting it in the summary.

## Posture defaults and overrides

Use these defaults unless the user overrides them:

| Provider | Default posture | Why                                                                                                     |
| -------- | --------------- | ------------------------------------------------------------------------------------------------------- |
| `grok`   | `drain`         | Bundled as cheap mechanical surplus with no balance signal; run until exhaustion or backlog empty (R8). |
| `codex`  | `protect`       | Primary-capacity high-tier provider; only spare capacity should be used (R9, R21).                      |
| `claude` | `protect`       | Primary-capacity high-tier provider; protect by default and never run while active (R9, R21).           |

If the user loosens a protect provider to drain, record the override only after confirming that the provider's credits expire and that the user accepts exhausting them. If that cannot be established from `adapters.yaml`, keep `protect`.

## Round-trip behavior

Every normal token-eater invocation resolves config before doing work:

1. If the `setup` token is present, ignore existing config and re-run this playbook.
2. If a readable config exists, load it, merge the project override if present, and skip onboarding (R22).
3. If no config exists, run first-run setup.
4. If config parsing fails, do not guess. Report the path and the parse issue, then offer to re-run setup and replace the invalid file.

After loading config, the harvest loop still runs `scripts/detect-adapters.sh`. Config is intent; detection is current capability. A provider must be both configured and currently available to receive work.

## Conservative protect guard

For protect providers, the saved config is not sufficient permission to run. Before delegation, the harvest loop must also confirm:

- The current time falls inside `idle_window`.
- `never_while_active` is not blocking the run.
- If the adapter has a non-`none` `balance_signal`, the reported balance is above `reserve_floor`.
- If the adapter has `balance_signal: none`, use only the time/activity guards and keep the run conservative; do not invent a balance check (R10, R11).

These defaults make zero-setup safe for members while allowing power users to loosen posture and schedule later (R18, R21, R22).
