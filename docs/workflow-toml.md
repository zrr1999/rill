# Rill workflow TOML specification

A workflow declares a deterministic input, sequential processing and ordered outputs. Rill owns service configuration, capability checks and authorization. Workflows never select a provider, model, credential or native reasoning parameter.

## Format and lifecycle

Each executable definition is one TOML file with this header:

```toml
schema_version = 1
```

This is a new layout. Previous workflow layouts, including old `schema_version = 1` files with a `pipeline`, retired `format` / `version` headers, JSON manifests and the retired settings library cannot execute. Reading never upgrades or rewrites them. Invalid files report a diagnostic; an invalid override blocks its workflow instead of reactivating a packaged definition.

User files live in `$XDG_CONFIG_HOME/rill/workflows`, defaulting to `~/.config/rill/workflows`. Backups live in `$XDG_STATE_HOME/rill/workflows`, defaulting to `~/.local/state/rill/workflows`. Relative or empty XDG values use these defaults. Reading does not create directories. New directories use `0700` and files use `0600`; existing directory permissions remain unchanged.

Discovery accepts up to 256 direct, non-hidden regular TOML files of at most 1 MiB each. Symlinks and oversized files produce diagnostics. Saves retain up to 20 previous versions, synchronize a temporary file and atomically replace the destination. Saving checks the originally loaded source; a second intervening edit remains a conflict. External editors own unsaved buffers. New/imported workflows start disabled, duplication creates a new UUID, and ordinary edits preserve workflow and step identity.

Packaged workflows use the same decoder and validator. Their index contains only resource locations and localized title keys. Missing or invalid packaged resources activate no fallback definitions. First configuring a packaged workflow creates a writable TOML override in the user directory.

## Declaration

```toml
schema_version = 1
id = "54B31E01-96AC-4A0F-BB82-0A8CB12DD629"
name = "Prepare a reply"
enabled = false

[trigger]
kind = "manual"

[input]
kind = "text"

[[process]]
id = "rewrite"
kind = "llm-rewrite"
reasoning = "none"
prompt = "Rewrite concisely, preserving the original language and meaning."
decision = { optional = true }

[output]
strategy = "immediate"

[[output.actions]]
id = "save"
kind = "record.store"

[[output.actions]]
id = "copy"
kind = "system-clipboard.copy"
optional = true
```

Root fields are `schema_version`, `id`, `name`, optional `description`, `enabled` (default false), `trigger`, `input`, optional `ui` and `setup`, `process` and `output`. Names contain 1–160 Unicode scalars. Unknown fields fail with a path diagnostic at every structural level. There are no open `options`, `metadata` or action `config` dictionaries.

`trigger.kind` is `manual`, `hotkey`, `menu-bar` or `wake-word`. A hotkey may provide `gesture` and `exclusive_group`. Wake-word phrases remain in `setup.wake_word.phrases`, with one to four distinct short phrases. Trigger conflicts and permissions remain Rill admission checks.

`input.kind` is `audio`, `text` or `record`. Audio requires `setup.speech` and one root `recognize-speech` step, first in the processing sequence. Text/Record input omits recognition. Explicit clipboard-text runs and Record replay reuse the text projection of the same processing plan. A run does not choose between alternative content sources or automatically merge unrelated inputs.

`ui` accepts `symbol` and `accent`. Speech setup accepts `language`, `live_preview`, `live_preview_placement` (`overlay` or `cursor`) and `streaming_profile`. ASR model selection, download, enablement and residency belong to the ASR service.

Vocabulary bindings use `id`, `collection`, `uses` (`recognition-hints`, `text-replacement`), `optional` (default false), and optional `when` (`app_bundle_id`, `record_collection`, `locale`). The file's bindings are authoritative.

A missing optional vocabulary collection is skipped; a missing required collection blocks compilation. These flags belong to input dependencies, independently of output switches.

Record collection event automation is unavailable in this format. Record reuse is an explicit manual invocation of the declared processing and outputs. A workflow may declare at most one output targeting the speech pending buffer. The pending and draft editor dictation commands each select their own built-in v1 declaration with a single Record destination. They do not alter the Fn definition.

## Processing and service dependencies

Process kinds are `recognize-speech`, `resolve-uncertainty`, `apply-vocabulary`, `normalize-whitespace`, `llm-rewrite`, `llm-answer`, `snippet-replacement` and `if`. Steps have stable `id` values of 1–128 ASCII letters, digits, underscores or hyphens; IDs are unique across processing branches and outputs. Runtime UUIDs are deterministically derived from workflow and document identity.

Every LLM step must explicitly provide `reasoning`: `none`, `low` or `high`. Task kind and reasoning are independent. Missing levels, native levels such as `medium`, and model-binding fields fail validation. Rill's service adapter maps the intent to verified native capabilities. Unsupported levels produce an error; Rill does not silently change the level or provider. Task budgets are independent of reasoning and model selection. Capability admission currently covers only the documented OpenAI and DeepSeek model/official-endpoint pairs; an arbitrary compatible URL cannot acquire capabilities merely by using the same model name.

A processing dependency is required unless `optional = true`. Rill checks the configured service. An unavailable optional LLM task is recorded as skipped and passes its input text onward. A required missing service blocks admission with configuration guidance. Optionality does not turn an actual request failure into an unconditional success. Rewrite tasks default to `on_failure = "fail"`. Explicit `on_failure = "preserve-input"` allows eligible provider failures to preserve the input, record a skipped step and continue; cancellation and authorization failures still stop the run. This policy does not depend on speech mode.

A rewrite may declare `decision = { optional = true }`. Without a configured Decision service, Rill skips classification and continues rewriting. With `optional = false`, the Decision service must be configured before admission. The transcript-only polishing prediction retains its session consent, conservative confidence threshold, bounded deadline and normal rewrite path on uncertainty or prediction failure. Authorized correction references bypass this prediction.

`preserve_content = true` explicitly enables transcript cleanup protection. This behavior belongs to the step and is independent of packaged identity, name, speech mode or prompt equality. Prompts describe the requested transformation; answer and rewrite tasks retain their distinct request contracts.

Optional `record_duration` controls measured process duration, defaulting on for recognition and LLM tasks. Unexecuted branches have no measurement; skipped LLM requests have no LLM trace or token usage. Timing does not change privacy retention.

An `if` has `condition` and optional ordered `then`/`else` arrays. Conditions compare `text`, `context.app_bundle_id`, `context.selected_text` or `context.clipboard_text` using `equals`, `contains` or `exists`, or combine conditions with `all`, `any` and a single-element `not` array. Conditions use already authorized context and never capture new context or request permission. Missing/redacted values fail comparisons; guard them with `exists`. Groups short-circuit in declaration order. Limits remain 256 process steps, 256 outputs and 16 nesting levels.

## Outputs and companion state

Outputs run in declaration order. Each action has `id`, `kind`, optional `description`, `condition` and `optional`:

- `optional = false` (default): automatically enabled; the user cannot disable it.
- `optional = true`: initially enabled; the user may turn it off independently.

All optional outputs may be off. Processing still completes and produces its normal privacy-bounded run receipt. Rill does not add an undeclared save, copy or insertion. Packaged dictation saves before insertion and exposes pending collection as a declared output.

Action parameters belong to their kind:

| Kind | Parameters |
| --- | --- |
| `record.store` | `collections` UUID array; optional `buffer = "speech"`; `exclude_from_capture` |
| `system-clipboard.copy` | No destination parameters |
| `focused-application.insert` | No destination parameters |
| `speech.speak` | `voice`, optional `language`; TTS service owns the model |
| `external.shortcuts.run` | `shortcut` |
| `external.markdown.append` | Absolute Markdown `path` |
| `external.webhook.post` | `webhook_reference`; plaintext URL/headers are not workflow fields |

`output.strategy` accepts `immediate`, `collection-first` and `system-clipboard-only`. It never changes action order or adds outputs.

For `cleanup.toml`, user output choices live in `cleanup.state.json`:

```json
{
  "format": "rill.workflow-state",
  "version": 1,
  "workflow_id": "54B31E01-96AC-4A0F-BB82-0A8CB12DD629",
  "outputs": { "copy": false }
}
```

Missing state uses the declaration defaults. Unknown output IDs, disabling an automatic output, malformed data or mismatched identity block the workflow with a diagnostic. The companion contains no executable steps, bodies or credentials. It uses the same atomic-save, backup, source-conflict and observation rules.

A run freezes its definition, output selection and service bindings. Changes apply to later runs; current privacy authorization and credential revocation are still checked at effect boundaries. Earlier committed outputs survive later failure or cancellation and are reflected in a partial receipt. Rill never implicitly repeats an external effect.

The [output state schema](schemas/workflow-state-v1.schema.json) describes the companion envelope. Runtime validation additionally checks output IDs and automatic-output constraints against the adjacent TOML.
