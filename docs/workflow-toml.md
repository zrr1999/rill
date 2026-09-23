# Rill workflow TOML specification

For setup and everyday use, start with the [README workflow guide](../README.md#工作流).
This document defines the file format and runtime contracts for maintainers and
advanced workflow authors.

User workflows are plain TOML files edited in an external text editor. Rill has
no built-in workflow editor. The Workflows page manages files, templates and activation.
A workflow runs sequentially, with structured `if` branches and ordered outputs.

## Location and lifecycle

- Configuration: `$XDG_CONFIG_HOME/rill/workflows/*.toml`, defaulting to
  `$HOME/.config/rill/workflows` when the variable is absent, empty or relative.
- Configuration backups: `$XDG_STATE_HOME/rill/workflows`,
  defaulting to `$HOME/.local/state/rill/workflows` using the same rule.
- Reading does not create directories or change their permissions. Rill creates
  new directories with `0700` and writes files with `0600`. Existing directory
  permissions remain unchanged. Runtime databases keep their existing locations.
- Discovery considers direct, non-hidden, regular TOML files, up to 256 files of
  at most 1 MiB each. Symlinks and oversized files produce diagnostics.
- Save writes a temporary file, synchronizes it and atomically renames it over
  the destination. A comparison against the source originally loaded detects
  external edits. A conflict requires comparing the disk version before replacing
  it; a second intervening edit produces another conflict.
- Rill retains the previous file before replacing it, with up to 20 backups under
  the state directory. Restore a backup using your external editor.
- Directory and file watches handle new files, atomic replacement, deletion and
  in-place writes. Valid changes apply to the next run; an active run retains its
  frozen definition. Invalid files are isolated. Identified invalid overrides
  block new runs instead of reactivating the built-in definition underneath.
- New and imported files are disabled until explicitly enabled. Opening an existing
  file preserves its source, comments and formatting. Rill no longer writes editor
  recovery drafts or owns unsaved edits; old drafts remain untouched on disk.
- Audio workflows run from their configured trigger or the Run button. For text
  workflows, Run clipboard text explicitly supplies the current clipboard text;
  normal privacy checks and cloud confirmation still apply.

The XDG layout follows the [Base Directory Specification](https://specifications.freedesktop.org/basedir/latest/).
Files use [TOML 1.0](https://toml.io/en/v1.0.0).

## Document v2

See the complete [conditional example](examples/conditional-workflow.toml) and
[JSON Schema](schemas/workflow-v2.schema.json). The schema describes the parsed
TOML data model; the application also checks identity, nesting, step ordering,
installed components and credential policy.

```toml
schema_version = 2
id = "54B31E01-96AC-4A0F-BB82-0A8CB12DD629"
name = "Prepare a reply"
enabled = false

[trigger]
kind = "manual"

[input]
kind = "text"

[[process]]
id = "clean"
kind = "normalize-whitespace"

[[process]]
id = "question"
kind = "if"
condition = { field = "text", op = "contains", value = "?" }

[[process.then]]
id = "rewrite"
kind = "llm-rewrite"
prompt = "Rewrite as a concise question. Keep the original language and meaning."

[output]
strategy = "immediate"

[[output.actions]]
id = "save"
kind = "record.store"

[[output.actions]]
id = "copy"
kind = "system-clipboard.copy"
```

| Field | Contract |
| --- | --- |
| `schema_version` | Required integer, currently `2`. Future versions fail validation and are not rewritten. |
| `id` | Required workflow UUID. Renaming a document preserves it; duplicating or importing creates a new UUID. |
| `name` | Required non-blank display name, up to 160 Unicode scalars. |
| `description` | Optional descriptive text. |
| `enabled` | Boolean, defaults to `false` in v2. Saving activates this preference; provider readiness and trigger conflicts are separate execution checks. |
| `trigger.kind` | `manual`, `hotkey`, `menu-bar`, `wake-word`. |
| `trigger.gesture` | Optional existing Rill gesture identifier. |
| `input.kind` | `audio`, `text`, `record`. Text can be supplied explicitly with Run clipboard text. |
| `ui` | Optional `{ symbol, accent }`; defaults to `sparkles` and `blue`. |
| `setup` | Optional speech route, vocabulary bindings and wake phrases. |
| `process` | Ordered array of steps; defaults to empty. |
| `output.actions` | Non-empty ordered output array. |
| `output.strategy` | Existing Rill delivery policy: `immediate`, `collection-first`, `system-clipboard-only`; defaults to `immediate`. It does not change array order or enable parallel execution. |
| `options` | String dictionary for existing runtime options, for example `record.target-collection-ids`. Component-owned keys are preserved. |
| `metadata` | Descriptive string dictionary. Keys start with `user.`; `workflow.origin` is retained for migration. |

Unknown structural fields fail with a path diagnostic. Open `options`, `metadata`
and action `config` dictionaries preserve their entries. Rill does not silently
remove unfamiliar dictionary keys. They do not register new executable components.

Saved output is deterministic: table keys are sorted while step and output array
order remains semantic. Canonical formatting may remove comments and alter quote
styles. Merely opening a hand-written file does not reformat it.

## Setup

Audio input requires `setup.speech` and exactly one root `recognize-speech` step,
placed first. Text and Record input omit both speech setup and recognition or
resolution steps. Fixed speech routes are preserved when files are loaded.

`setup.speech` requires `selection` (`automatic` or `fixed`) and `recognizer`.
Optional fields are `language`, `local_model`, `provider_model`, `live_preview`
(boolean), `live_preview_placement` (`overlay` or `cursor`) and
`streaming_profile`. Provider availability is checked separately from syntax.

Built-in workflows and bundled templates omit `local_model`. They use the selected
speech model while it is enabled, otherwise another enabled model from the
supported catalog. An explicit `local_model` remains an override and must be
enabled; Rill does not enable a disabled model on the user's behalf.

Each `[[setup.vocabulary]]` binding has its own UUID `id`, a `collection` UUID and
non-empty `uses` (`recognition-hints`, `text-replacement`, or both). Optional `when`
contains `app_bundle_id`, `locale` and the migration-compatible `clipboard_group`
UUID (a Record collection). The TOML bindings remain authoritative; global
vocabulary defaults do not replace bindings in a file-backed workflow.

Wake-word triggers use `setup.wake_word.phrases`, with one to four distinct short
phrases. The existing wake-word provider, permissions and readiness rules apply.

## Steps and conditions

Every process step and output has a document `id` of 1–128 ASCII letters, digits,
underscores or hyphens. IDs are unique across all branches and outputs. Process
UUIDs used internally are deterministically derived from workflow and document
identity. File order is execution order; display coordinates have no semantics.

Process kinds are `recognize-speech`, `resolve-uncertainty`, `apply-vocabulary`,
`normalize-whitespace`, `llm-rewrite`, `llm-answer`, `snippet-replacement`, and `if`.
A recognized kind still needs its installed production provider. Recognition and
resolution belong at the root. `prompt` belongs to generation/snippet steps;
`uncertainty` belongs to resolution and includes `mode`, `confidence_threshold`
and `timeout_seconds`. Optional step `description` is for the author.

Optional `record_duration` selects measured milliseconds for that process step.
It defaults to `true` for `recognize-speech`, `llm-rewrite` and `llm-answer`, and
`false` for other kinds. The setting also works in `then` and `else` steps. It
controls both content-free receipts and text history; execution, text retention
and privacy authorization are unchanged. Unexecuted branches have no measurement.
Failed, cancelled and fallback calls retain elapsed time when timing is enabled.

```toml
[[process]]
id = "polish"
kind = "llm-rewrite"
prompt = "Correct transcription errors while preserving meaning."
record_duration = true
```

Recognition timing covers the final recognition executor; LLM timing covers the
transformer call, including request preparation and response parsing. Neither
includes recording, queueing or delivery. Candidate resolution, when opted in,
measures its own wait. The run card separately shows captured audio length and
output-action timing; older records without measurements show “Not recorded”.
These are input diagnostics, not a workflow profiling requirement for ordinary
speech use.

### Optional Jev polishing prediction

In Settings → text provider, enter a TypeSafe API key and enable Jev polishing
prediction for the current app session. Smart Cleanup can then skip its
`llm-rewrite` request when Jev considers the complete text ready to use unchanged.
The normal ordered outputs still save and deliver that text. History records a
skipped rewrite with no LLM request trace, token count or LLM duration; prediction
latency is not reported as LLM execution time.

Custom cleanup workflows opt in through the existing options dictionary:

```toml
[options]
"text.polishing-gate" = "jev"
```

The switch defaults off, and neither the key nor the switch is persisted.
Enabling it authorizes sending the current transcript and that step's rewrite
instructions to `api.typesafe.ai`. Audio, clipboard/selection context, screen
images and memory references are excluded. Runs using correction references
continue directly to the configured LLM; answer steps and voice assistants never
use this gate. Current and source-app privacy rules are checked before and after
prediction; cancellation or a privacy restriction stops the run.

Only a validated `jev-1.13.0` score with both confidence and the probability of
“already usable unchanged” at least 0.9 skips rewriting. These are conservative
decision thresholds, not a measured accuracy claim. Uncertainty, service errors,
malformed responses, missing credentials or the two-second prediction deadline
keep the original rewrite path. Text over 1,800 UTF-8 bytes or instructions over
4,000 bytes also use that path without truncation. No automatic retries occur.

An `if` requires `condition` and may contain `then` and `else` step arrays. The
selected branch receives the current text and returns the text used by the next
step. The other branch is not executed. There are at most 256 process steps,
256 outputs, and 16 nesting levels. There are no general graph cycles, loops,
parallel nodes or sub-workflows in v2.

Conditions use exactly one form:

```toml
# Comparison; case-sensitive literal strings, without expression evaluation.
condition = { field = "text", op = "contains", value = "?" }
# Guard availability before comparing authorized context.
condition = { all = [{ field = "context.app_bundle_id", op = "exists" }, { field = "context.app_bundle_id", op = "equals", value = "com.apple.mail" }] }
# not is a single-element array so the recursive structure remains ordinary TOML.
condition = { not = [{ field = "text", op = "equals", value = "" }] }
```

Fields are `text`, `context.app_bundle_id`, `context.selected_text` and
`context.clipboard_text`. Context is the snapshot already permitted by the normal
privacy gate. Conditions never request additional permissions or capture context.
Missing/redacted context causes comparisons to fail the run; `exists` returns
false. Empty selection or clipboard text counts as unavailable. `all` and `any`
short-circuit in order, accept 1–64 children, and can nest with `not`.

## Outputs, tests and receipts

Outputs have `id`, executable `kind`, optional `description`, optional `condition`
and an optional string `config` dictionary. Shipped choices include:

| Kind | Relevant config |
| --- | --- |
| `record.store` | Existing Record routing options in `options`. |
| `system-clipboard.copy` | No required config. |
| `focused-application.insert` | Normal focus and input authorization. |
| `speech.speak` | `speech.provider`, `speech.model`, `speech.voice`, `speech.language`. |
| `external.shortcuts.run` | `shortcuts.name`. |
| `external.markdown.append` | `markdown.append.path`. |

Outputs execute once in array order. A false condition records a skipped output.
A failed output stops the remaining outputs; earlier effects remain committed and
produce a partial terminal receipt. Cancellation is checked between steps and
outputs. There is no automatic replay of side effects. Plaintext webhook files
remain rejected; credential-backed webhook editing is not exposed by this version.

A built-in speech recognition or cleanup workflow stores its final text in Voice
Input records, then inserts that same text into the active app. The voice assistant
stores its answer before speaking it. The speech templates also save before
delivery, so a later delivery failure does not discard the saved text. The explicit
"Save Voice Record Only" output mode omits insertion.

Durable receipt v2
stores only executed process positions, fixed step kinds, branch/result codes,
coarse duration buckets and ordered output receipts. It stores no prompts, names,
paths or sample bodies. History renders each receipt's own step kinds rather than
mapping an old run onto a newly edited workflow. Receipt v1 remains readable.

## Migration and built-ins

Document v1 remains readable. Its string trigger, speech setup, UUID process IDs,
legacy action aliases and metadata are converted in memory. Loading does not
rewrite a v1 file. Its first successful save creates a v2 file and retains the
original v1 source in history. Unknown v1 structural fields also fail validation.

A customization keeps the built-in workflow UUID and overrides that definition.
Restoring the default removes its override. Duplicating a workflow, importing a
file, or creating from a template creates a disabled document with a new UUID.
The bundled multi-workflow catalog is a separate internal format and is not a
user workflow file.

## LLM Provider and smart cleanup

Settings → Speech → **LLM Provider** is the single OpenAI-compatible Responses
API configuration for cleanup, assistant answers and custom text workflows.
Set the Base URL, API key and model there. Existing settings and Keychain storage
remain compatible; workflows do not select a separate provider or credential.

For DeepSeek V4.1 Flash, use `https://api.deepseek.com` (or its `/v1` base path)
and model `deepseek-flash`. A compatible gateway can use the same model ID.
Selecting a model preset changes only the model; the configured endpoint and key
remain under your control.

Enable **Smart Cleanup** from the Workflows page; this switches off the other
built-in Fn mode. Recognition stays local. After recognition and vocabulary
replacement, `llm-rewrite` sends only the current text and instruction to the
configured LLM Provider. Use the supplied `speech_to_text_polish.toml` template
for a custom workflow; no `text.provider` option is needed.

DeepSeek rewrite requests use `reasoning.effort = "none"`, temperature 0.1 and a
4096-token output limit. The rewrite has a 5-second budget; cancellation drains
the request before any fallback is delivered. Inputs above 12,000 UTF-8 bytes skip
cleanup whole. Assistant steps retain their existing thinking policy. Other
compatible models retain their existing request parameters. These initial
limits need real usage and latency evaluation.

For captured speech or explicitly supplied text, temporary network, rate-limit,
timeout, incomplete or invalid-result errors can retain the text before rewriting.
Activity reports the skipped cleanup and the receipt marks that step as skipped.
Cancellation, privacy restrictions, missing credentials, authentication failure and
refusal stop delivery. Each run selects one final text and delivers it once.

API contract references: [DeepSeek Responses API](https://api-docs.deepseek.com/guides/responses_api/)
and [thinking controls](https://api-docs.deepseek.com/zh-cn/guides/thinking_mode/).
