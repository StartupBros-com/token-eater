# Review pipeline

This playbook starts after a chore's deterministic gate passes and token-eater has a reviewable branch or draft PR candidate. The goal is to spend optional surplus on review/fix loops without weakening the core safety rule: the final PR is reviewed by a frontier model that did not implement it, then token-eater stops. The human reviews and merges.

Independence lives at the final gate, not every step. Intermediate review may be cheap, noisy, or deliberately credit-burning. It can even be Grok reviewing Grok's own diff with `--agents` / best-of-N subagents when the member configured that mode. The independence guarantee is the final frontier-model review by a model that did not implement the PR.

## Invariants

- Never auto-merge to the default branch (R14).
- Never auto-mark a PR ready for review. token-eater opens or updates draft PRs only.
- Never treat model self-review as the deterministic gate. The project gate from `references/delegation-invocation.md` remains authoritative (R5, R13).
- Every PR must be independently reviewable and mergeable as its own slice. Do not pile unrelated chores into one PR just because surplus remains.
- The final review must be performed by a frontier model that did not implement the change. If the implementer was `claude`, use a non-Claude frontier reviewer when available; if the implementer was `codex`, use a non-Codex frontier reviewer when available. If no independent frontier reviewer is available, say so plainly and leave the PR draft for the human.
- After posting the final review summary, stop. The human decides whether to merge.

## Inputs

Read these before starting review/fix work:

1. The gate-passing chore result from `references/result-handling.md`: branch or draft PR reference, files modified, gate command, provider, posture, spend estimate, and plain summary sentence.
2. `run_config` from `references/setup-and-config.md`: `intermediate_review`, `inline_grok_verification`, `review_fix_rounds`, `grok_tapped_action`, and `review_depth`.
3. Adapter state from `references/harvest-loop.md`: configured providers, parked providers, posture, tier, cost rank, and current surplus/guard signals.
4. Balance signals from `scripts/onwatch-usage.sh <provider>` when the adapter declares `balance_signal: onwatch`. Exit `3` means no oracle is available; fall back to posture rules rather than guessing (R10, R11).
5. The review skill options installed or known to the member environment. Candidate options include `ce-code-review --comment`, `code-review-gemini-swarm-with-ntm`, and `multi-model-triangulation`, but this playbook does not commit to which one runs where. Review skills are plug-in / TBD.

## Pipeline

Use this shape for each gate-passing chore:

```text
chore
  -> deterministic gate passes
  -> [intermediate review -> implement fixes -> repeat up to rounds]
  -> final draft PR
  -> recommend and optionally run independent frontier review
  -> post summary
  -> stop for human review and merge
```

Procedure:

1. **Classify review depth.** Use `run_config.review_depth` and the chore tier.
   - `auto_risk_tiered`: mechanical, gate-verified chores such as formatter or dead-code cleanup get little or no intermediate review; semantic chores such as refactors, mock removal, de-monolithizing, or test backfills get the full configured loop.
   - `always_full`: run the configured intermediate loop whenever a reviewer and fixer are available.
   - `minimal`: skip intermediate review unless the chore is high tier or the deterministic gate passed with warnings.
2. **Set the round cap.** Read `run_config.review_fix_rounds`; default `2`, allowed range `0`-`3`. If it is `0`, skip intermediate review and go straight to the final draft PR path.
3. **Run intermediate review according to mode.** Use the configured mode only when depth says an intermediate pass is useful.
4. **Route fixes by finding.** Mechanical findings may go back to Grok when Grok is harvestable. Judgment-needing findings go to the cheapest high-tier adapter with surplus and posture permission, usually Codex or Claude. If no high-tier adapter has surplus, defer those findings to the human.
5. **Re-run the deterministic gate after every fix batch.** A fix that fails the gate is rolled back or corrected before continuing. Do not advance a red diff to the final PR path (R13-R15).
6. **Early-exit on clean review.** If a review round returns no actionable findings, stop the loop even if rounds remain.
7. **Stop at the cap.** After `rounds` review/fix cycles, surface any remaining findings to the human instead of looping.
8. **Finalize the draft PR.** Use `references/result-handling.md` to ensure the branch or draft PR body includes the gate result and review notes. Do not mark it ready.
9. **Recommend final frontier review.** Say plainly: "I recommend an independent frontier-model review before merge." Offer to run it when an eligible independent reviewer is available and posture/surplus permit.
10. **Post the final review summary and stop.** Include actionable findings, fixed findings, deferred findings, the gate command, and the draft PR or branch reference. Do not keep editing unless the human explicitly asks.

## Intermediate review modes

### Grok self-review with N subagents

Use this when `run_config.intermediate_review.mode: grok_self_review` and Grok is available, not parked, and posture allows spending. Invoke Grok's best-of-N / subagent mode with the configured `grok_agents` value using the grok CLI's `--agents` flag when supported by the installed CLI. The member-facing explanation is simple: "Grok will spend extra surplus asking several Grok reviewers to look for obvious issues."

This is a deliberate burn-credits mode. It is allowed even when Grok implemented the diff, because final independence is enforced later by the frontier review. Treat Grok's findings as advisory: require concrete file/line references and route only actionable items into fixes.

If Grok is tapped, rate-limited, or has no surplus:

- `fall_back_to_codex_claude`: try the cheapest high-tier protect provider with surplus, respecting idle windows, active-use guards, and reserve floors (R7-R10).
- `pause_for_me`: stop intermediate work and ask the human before spending protected capacity.
- `ship_pr_as_is`: skip remaining intermediate review/fix rounds, keep the draft PR, and proceed to the final review recommendation.

### Claude via a review skill

Use this when `run_config.intermediate_review.mode: claude_review_skill` and a plug-in review skill has been chosen for this member or project. Candidate review skills include `ce-code-review --comment`, `code-review-gemini-swarm-with-ntm`, and `multi-model-triangulation`, but do not hardcode one here. The chosen skill must be told:

- The draft PR or branch reference.
- The exact files changed.
- The deterministic gate that already passed.
- The chore's original success criterion.
- That token-eater will not auto-merge or mark ready.

Claude review still respects protect posture. Do not spend Claude while active or outside the idle window unless the user explicitly requested this run and accepted the spend.

### None

Use this when `run_config.intermediate_review.mode: none`, review depth is `minimal`, or no reviewer is safely available. Rely on the deterministic gate, produce the draft PR, recommend the final independent frontier review, and stop.

## Fix routing

Classify each review finding before assigning fixes.

| Finding type       | Examples                                                                                                             | Fix route                                                                                                                         |
| ------------------ | -------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------- |
| Clearly mechanical | Formatting residue, unused import, obvious typo, stale generated line, lint rule with a single local fix.            | Send back to Grok when Grok is harvestable and the chore tier allows it; otherwise use the cheapest in-tier adapter with surplus. |
| Gate-local repair  | A failing targeted test caused by the chore, a typecheck miss in touched files, an obvious build script mismatch.    | Use the cheapest adapter whose tier covers the original chore and whose posture permits spending.                                 |
| Judgment-needing   | API behavior ambiguity, product wording, architecture tradeoff, safety/permission logic, security-sensitive concern. | Route to the cheapest high-tier adapter with surplus and posture permission. If none has surplus, defer to the human.             |
| Out of scope       | Requests to refactor unrelated files, expand the chore, update dependencies broadly, or redesign behavior.           | Do not fix in this PR. Record as deferred or excluded.                                                                            |

Use provider posture and surplus signals before every fix batch. `scripts/onwatch-usage.sh` is advisory for drain providers and load-bearing for protect reserve floors when available. A protect provider with no oracle still needs idle-window and active-use guards. A drain provider stops when its circuit breaker fires, it parks, or the backlog/fix list empties (R8-R10, R16).

After applying fixes, run the original deterministic gate and any narrower gate implicated by the finding. If the review finding requires a new gate that does not exist, do not invent confidence; defer it to the human.

## Round control

One round is: intermediate review, finding classification, fix routing, fix implementation, and gate verification.

- Cap rounds at `run_config.review_fix_rounds`; never exceed `3` without an explicit human instruction.
- Early-exit when a review returns no actionable findings.
- Early-exit when all actionable findings are fixed and the gate passes.
- Stop when every remaining finding is judgment-needing and no high-tier adapter has surplus.
- Stop when the only available fixes would touch files outside the PR's intended slice.

At the cap, summarize remaining findings under "Needs human review" rather than launching another model pass.

## Final frontier review

The final review is the independence guarantee. token-eater recommends it for every draft PR, and may offer to run it when an independent frontier model is configured, available, and allowed by posture/surplus.

Final review requirements:

1. The reviewer did not implement the PR.
2. The reviewer receives the PR/branch diff, changed file list, chore objective, deterministic gate command and output, intermediate review/fix summary, and any deferred findings.
3. The reviewer returns a summary with actionable findings separated from non-blocking notes.
4. token-eater posts or prints the summary in plain language and then stops.

If the final reviewer finds more issues, leave the PR draft with the findings attached and stop. If the human later explicitly asks token-eater to apply those findings, treat that as a new bounded review/fix run. Do not auto-mark-ready after a clean final review.

## Member-facing summary

Keep the final summary plain:

```markdown
Review pipeline:

- Grok made the cleanup and the project check passed.
- Grok self-reviewed the diff with 12 agents and found two small issues; both were fixed.
- I recommend an independent frontier-model review before merge.
- Final review summary: <short result or "not run because no independent reviewer had spare capacity">.

Needs human review:

- Draft PR: <url>
- Remaining finding: <plain finding, or "none reported">
- token-eater did not merge or mark this PR ready.
```

Avoid provider jargon unless it explains a decision the member cares about. Prefer "Grok was out of surplus, so I stopped before spending Claude" over "no routeable high-tier protect adapter met posture constraints."
