---
name: rill-code-review
description: Review Rill PRs, commit ranges, or working-tree changes for reachable defects and costly structural mistakes. Use for requested code review or pre-submit review, not routine implementation, formatting, or commit-message drafting.
---

# Rill Code Review

Produce evidence-backed findings about both behavior and the cost of the chosen
structure. Review is read-only unless the user has already requested fixes; keep
any authorized fixes within that scope. Respond in the user's language.

## Establish the comparison

Identify the requested base, head, and local changes before reviewing. For a
working-tree review, include staged, unstaged, and relevant untracked files. For
a branch or PR, resolve the intended comparison and record the revisions used.
Separate pre-existing behavior from regressions introduced by the change. If the
scope or source is incomplete, state the resulting limit on the review.

Read [architecture](../../../docs/architecture.md) for ownership and dependency
boundaries and [CONTRIBUTING.md](../../../CONTRIBUTING.md) for validation rules.
Follow the affected domain contract only as needed:

- Workflow definitions and effects: [workflow TOML](../../../docs/workflow-toml.md).
- Record state, routes, and persistence: [Record architecture](../../../docs/record-architecture.md).
- Native interaction claims: [macOS acceptance](../../../docs/release-qa-checklist.md).

## Trace behavior and ownership

Read complete changed functions, their callers, and the production composition
path. Check who owns each state transition and side effect, including failure,
cancellation, retry, privacy changes, and shutdown when reachable. Validate API
and compatibility assumptions against the actual implementation or dependency.

An actor or cancellation call alone does not prove ordering or completed cleanup.
Follow work across suspension points and inspect which owner retains it until it
settles. For persistence, distinguish accepted work, committed state, published
events, and stale completions. For output, inspect irreversible effects and
partial completion instead of assuming an all-or-nothing operation.

Challenge structural additions with a deletion test: what concrete behavior,
invariant, or boundary would be lost if this helper, cache, adapter, queue, or
extra state were removed? Trace duplicated decisions and competing sources of
truth to their synchronization, failure, or maintenance costs. A single
implementation can justify an interface; a long file alone does not justify
splitting a transaction owner. Generic design slogans, wrapper counts, and
personal formatting preferences are not findings.

Check that tests observe the affected contract through a reachable caller. For
races, look for controlled suspension, barriers, or leases that expose the bad
ordering. Assertions that mirror implementation details or only match source
text do not establish behavior. Run targeted checks when they can resolve a
specific uncertainty, and distinguish executed evidence from source inspection.

## Admit and report findings

Before reporting a defect, establish a reachable trigger, the violated contract,
the mechanism, and the practical impact. Attempt to disprove it by checking
upstream validation, caller constraints, cleanup, and existing tests. Give a
precise source location and the evidence connecting it to the failure. Do not
invent a failure to fill a quota or report a deliberate, authorized product
decision as accidental scope growth.

Lead with actionable findings, ordered by severity. Use P0 for an immediate
critical failure, P1 for a serious failure in common use, P2 for a bounded defect,
and P3 for a smaller but concrete issue; calibrate to reachability and impact.
Each finding should explain its trigger, mechanism, consequence, and repair
direction. For structural findings, include the deletion test and concrete cost.
Keep optional simplifications and missing verification separate from defects.

If none are confirmed, say so. Close with the reviewed scope, checks actually
performed, and material gaps. Passing unit tests is not evidence of physical
Fn, microphone, IME, paste, VoiceOver, or release-artifact acceptance.
