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
6. **Choose reserve floors.** Persist reserve floors for every provider so optional balance signals can enforce them when available (R10, R11). The bundled adapters currently point at the optional `onwatch` signal; most members will not have it running, so protect providers fall back to conservative idle/activity guards. Defaults: `claude: 20%`, `codex: 20%`, `grok: 0%`. Drain providers ignore reserve floors (R8).
7. **Choose run mode.** Ask whether token-eater should be `on_demand` only or install a recurring schedule. Default to `on_demand`. If the user chooses `recurring`, persist the schedule choice and hand off to `references/schedule-install.md` after writing config (R22).
8. **Write config atomically.** Create the parent directory, write to a temporary file in the same directory, then rename it into place. Preserve unrelated existing keys only if the file already has a higher `version` that token-eater can read; otherwise rewrite the known schema and report that older/unknown fields were ignored.
9. **Round-trip before continuing.** Re-load the file you just wrote, merge the optional project override if present, and confirm the detected postures, idle window, reserve floors, and schedule match what will be used for the run.

Setup should ask the minimum number of questions needed. Prefer defaults and a final "use these settings?" confirmation over one prompt per field. Ask for clarification only when the user chooses an unsafe or contradictory combination.

## Interactive run configuration

After adapter posture and schedule are set, ask the member how token-eater should run and review chores. These preferences are plain-language defaults: first run persists them, later runs load them without asking, and a single run may override them with explicit arguments or project config (R18, R22).

Ask as a compact confirmation table, with the first option as the default. Do not make members understand adapter internals; describe the effect in everyday terms.

| Setting                        | Options (default first)                                                                                        |
| ------------------------------ | -------------------------------------------------------------------------------------------------------------- |
| Implement with                 | `grok` / `codex` / `claude` / `auto-cheapest-with-surplus`                                                     |
| Intermediate review            | `grok self-review with N subagents` / `Claude via a review skill` / `none (rely on the final frontier review)` |
| Inline grok verification       | `yes` / `no`                                                                                                   |
| Review/fix rounds              | `2` (range `0`-`3`)                                                                                            |
| If grok is tapped (no surplus) | `fall back to codex/claude` / `pause for me` / `ship PR as-is`                                                 |
| Review depth                   | `auto risk-tiered` / `always-full` / `minimal`                                                                 |

Field behavior:

- **Implement with** controls the preferred implementer before normal posture and surplus checks. `grok` means spend Grok first when its tier covers the chore. `codex` or `claude` pins implementation to that provider only when it is configured, detected, and harvestable. `auto-cheapest-with-surplus` uses the harvest loop's normal cheapest in-tier route (R6).
- **Intermediate review** controls the optional review/fix loop before the final draft PR. Grok self-review may use the grok CLI's `--agents` / best-of-N mode; store `N` as a number and default it to `12` when the user picks this mode without specifying one. Claude review uses a plug-in review skill chosen later; do not hardcode which review skill runs.
- **Inline grok verification** lets grok do extra local checking while it implements mechanical work. Even when this is `yes`, token-eater still recommends a frontier-model review before the human merges.
- **Review/fix rounds** caps intermediate review/fix loops. Accept only integers from `0` through `3`; default `2`.
- **If grok is tapped** says what to do when Grok has no surplus or its circuit breaker fires. `fall back to codex/claude` still respects protect posture, idle windows, reserve floors, and active-use guards (R7-R10). `pause for me` stops before spending protected capacity. `ship PR as-is` means no more intermediate fixing from Grok; the deterministic gate and final review recommendation still apply.
- **Review depth** tunes how much intermediate review to do. `auto risk-tiered` gives gate-verified mechanical chores little or no intermediate review and gives semantic chores the full configured loop. `always-full` applies the loop whenever possible. `minimal` relies mostly on the deterministic gate plus the final frontier review recommendation.

Persist these under `run_config` in the same config file. Project overrides may replace individual `run_config` keys. Later playbooks read this block before routing implementation, review, and fix work.

If the user chooses an option that conflicts with current capability, save the preference but explain the immediate fallback. Example: if `grok` is preferred but `grok` is not detected, store the preference only when the user asks for it; otherwise use `auto-cheapest-with-surplus` for this setup. Never silently spend a protect provider outside its guardrails.

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
run_config:
  implement_with: grok
  intermediate_review:
    mode: grok_self_review
    grok_agents: 12
  inline_grok_verification: true
  review_fix_rounds: 2
  grok_tapped_action: fall_back_to_codex_claude
  review_depth: auto_risk_tiered
defaults:
  consecutive_failure_limit: 3
  result_dir: .token-eater/runs
```

Field meanings:

| Field                                        | Meaning                                                                                                                                                                |
| -------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `version`                                    | Config schema version. Current value: `1`. Unknown future versions should stop and ask for setup rather than guessing.                                                 |
| `providers[].id`                             | Adapter id from `adapters.yaml`; must match a detected CLI before use.                                                                                                 |
| `providers[].posture`                        | `drain` or `protect`. Drain exhausts expiring surplus; protect only uses spare capacity inside guardrails (R7-R9).                                                     |
| `providers[].tier`                           | Highest chore tier this provider may receive: `mechanical`, `standard`, or `high`, copied from the registry unless explicitly lowered.                                 |
| `providers[].enabled`                        | Whether token-eater may route work to this provider. Missing means `true` for schema v1.                                                                               |
| `providers[].reserve_floor`                  | Percent of quota to preserve for protect providers when a balance oracle exists. With `balance_signal: none`, it is advisory and protect runs stay conservative (R10). |
| `idle_window.timezone`                       | IANA timezone or `local`. Use it to evaluate overnight windows correctly across midnight.                                                                              |
| `idle_window.start` / `end`                  | 24-hour `HH:MM` local times. A window whose end is earlier than start crosses midnight.                                                                                |
| `idle_window.days`                           | Days on which the window may start. Omit or empty means every day.                                                                                                     |
| `idle_window.never_while_active`             | Guard that blocks protect-provider delegation while the user appears active. Defaults to `true` (R9, R21).                                                             |
| `schedule.mode`                              | `on_demand` or `recurring`. On-demand means no native schedule should be installed.                                                                                    |
| `schedule.native_id`                         | Scheduler id written by `schedule-install.md`, such as a cron marker, launchd label, systemd unit, or Task Scheduler name.                                             |
| `schedule.command`                           | The headless command installed by the scheduler, if any.                                                                                                               |
| `schedule.installed_at`                      | ISO-8601 timestamp for the schedule installation, or `null`.                                                                                                           |
| `run_config.implement_with`                  | Preferred implementer: `grok`, `codex`, `claude`, or `auto-cheapest-with-surplus`. Routing still enforces tier, posture, and surplus (R6-R10).                         |
| `run_config.intermediate_review.mode`        | `grok_self_review`, `claude_review_skill`, or `none`. This controls only the intermediate loop; final frontier review is still recommended.                            |
| `run_config.intermediate_review.grok_agents` | Best-of-N subagent count for Grok self-review via the grok CLI's `--agents` mode. Used only when `mode: grok_self_review`.                                             |
| `run_config.inline_grok_verification`        | Whether Grok should do extra inline verification during implementation. This never replaces the deterministic gate or final review recommendation.                     |
| `run_config.review_fix_rounds`               | Maximum intermediate review/fix rounds, integer `0`-`3`; default `2`.                                                                                                  |
| `run_config.grok_tapped_action`              | What to do when Grok has no surplus: `fall_back_to_codex_claude`, `pause_for_me`, or `ship_pr_as_is`.                                                                  |
| `run_config.review_depth`                    | `auto_risk_tiered`, `always_full`, or `minimal`; used by `references/review-pipeline.md`.                                                                              |
| `defaults.consecutive_failure_limit`         | Provider circuit-breaker threshold before parking it for the run (R16).                                                                                                |
| `defaults.result_dir`                        | Repo-relative directory for run artifacts and ledgers used by later units.                                                                                             |

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

`adapters.yaml` currently declares `onwatch` as the optional balance signal for the bundled providers. On a typical member machine, `scripts/onwatch-usage.sh <provider>` exits `3` because onwatch is not installed or not running; treat that as "no oracle available" and use the conservative fallback above. When onwatch is present, protect providers must honor the saved reserve floor before spending (R10, R11).
