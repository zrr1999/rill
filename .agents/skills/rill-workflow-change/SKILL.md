---
name: rill-workflow-change
description: Change Rill workflow TOML, built-in definitions, parsing, validation, compilation, conditions, or ordered outputs. Use when workflow behavior or file lifecycle changes, not for unrelated UI copy or layout.
---

# Rill Workflow Change

Carry the requested behavior from its authoritative definition through the real
execution path. Respond in the user's language.

## Locate the contract

Read the relevant sections of [workflow TOML](../../../docs/workflow-toml.md)
and [architecture](../../../docs/architecture.md). Trace the affected path:
source file → parsed document → validated plan → compiled providers → frozen
run → ordered effects → durable receipt. Change only the layers needed by the
request, but verify that production assembly reaches the implementation.

Start with `WorkflowDocument`, `WorkflowDocumentCodec`, `WorkflowPlanCompiler`,
and `SessionCoordinator`; follow actual callers for the affected feature.
Consult current schemas and validation constants instead of copying versions,
limits, or supported provider lists into new code or instructions.

## Preserve definition and run ownership

- User workflows are plain TOML edited externally. File management, activation,
  and diagnostics belong to Rill; unsaved editor buffers do not. Use the current
  file-store contract for atomic replacement, backups, and comparisons against
  loaded source. An external edit must not be silently overwritten; a second
  intervening edit must still be detected after a conflict is reviewed.
- An active run retains its definition, context, and resolved provider plan.
  Reloads and settings changes apply to later runs. Revalidate authorization at
  effect boundaries when privacy or target identity can change; a frozen plan
  does not freeze permission to perform an effect.
- Preserve workflow and step identity when editing. Duplication, imports,
  activation, invalid overrides, and legacy normalization must follow the
  documented lifecycle. Do not silently repair malformed structure into an
  executable plan or rewrite a user's file merely by reading it.
- Replay and text-input projection must reuse `WorkflowPlan.acceptingTextInput()`
  where applicable. Preserve branches, identity, vocabulary, and output order;
  invalid nested speech steps must remain visible to validation.

## Preserve effect semantics

Execute steps and outputs in their declared order, including short-circuit
conditions. Missing or redacted context follows the condition contract; do not
capture new context or request permissions merely to evaluate a condition.

Built-in voice input and cleanup store final text before insertion; the voice
assistant stores its answer before speech. Edit
[BuiltinWorkflows.toml](../../../Sources/RillApp/Resources/BuiltinWorkflows.toml)
and regenerate through the commands in
[CONTRIBUTING.md](../../../CONTRIBUTING.md), never by editing generated output.
General user workflows retain their declared output order; do not inject
`record.store` into every workflow.

A later failure or cancellation must preserve earlier committed effects and
produce the appropriate partial receipt. Do not replay side effects implicitly.
Persist only the receipt fields allowed by the contract, without bodies, prompts,
paths, or credentials. History must describe the executed snapshot rather than
reconstructing an old run from today's definition.

## Verify the changed boundary

Select checks for the actual change: codec and validation for syntax; compiler
and production registration for new steps; controlled provider/sink failures for
ordered effects; file-store tests for external edits and invalid reloads. Include
the failure or cancellation path that would invalidate the requested behavior.
Use the repository's locked Swift wrapper and generator checks from CONTRIBUTING.

Report the behavior changed, relevant compatibility effects, checks run, and
remaining native interaction evidence. Use macOS QA only when the change crosses
a physical or system interaction boundary.
