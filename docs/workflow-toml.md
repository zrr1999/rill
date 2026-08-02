# Rill workflow TOML specification

Rill stores every user workflow as one TOML document. These files are the
source of truth; the Workflow window is a visual editor for the same documents.

## Location and discovery

Rill reads direct, non-hidden `*.toml` children of:

```text
$XDG_CONFIG_HOME/rill/workflows
```

When `XDG_CONFIG_HOME` is unset, empty, or relative, Rill uses the XDG default:

```text
$HOME/.config/rill/workflows
```

The directory is created with mode `0700`; files written by Rill use `0600`.
Symbolic links and non-regular files are not loaded. At most 256 files are read,
and each file is limited to 1 MiB. A malformed file is reported by filename in
the Workflow window without hiding other valid files.

## Version 1 document

All UUIDs must be unique within their scope. A voice workflow has a
`setup.speech` table and begins `process` with `recognize-speech`. A text-only
workflow omits `setup.speech` and must not contain `recognize-speech`.

```toml
schema_version = 1
enabled = true
id = "11111111-2222-3333-4444-555555555555"
name = "Manual Dictation"
trigger = "hotkey"

[ui]
symbol = "mic.fill"
accent = "blue"

[setup.speech]
selection = "automatic"
recognizer = "sherpa-onnx.local"
language = "zh-CN"
live_preview = true
live_preview_placement = "overlay"

[[setup.vocabulary]]
id = "99999999-2222-3333-4444-555555555555"
collection = "E79EF7C7-8867-5D6C-8E88-1119C62B9702"
uses = ["recognition-hints", "text-replacement"]

[[process]]
id = "77777777-2222-3333-4444-555555555555"
kind = "recognize-speech"

[[process]]
id = "88888888-2222-3333-4444-555555555555"
kind = "apply-vocabulary"

[[process]]
id = "AAAAAAAA-2222-3333-4444-555555555555"
kind = "normalize-whitespace"

[output]
strategy = "immediate"

[[output.actions]]
id = "inject.text"

[metadata]
"workflow.origin" = "user"
"trigger.gesture" = "control-option-shift-space"
```

`enabled` defaults to `true`. `metadata`, `setup.vocabulary`, and each action's
`config` table may be omitted when empty. Rill writes a deterministic canonical
form when the visual editor saves; hand-written comments may therefore be
removed on the next visual save.

## Enumerated values

- `trigger`: `manual`, `hotkey`, `menu-bar`, `wake-word`
- `setup.speech.selection`: `automatic`, `fixed`
- `setup.speech.live_preview_placement`: `overlay`, `cursor`. It defaults to
  `overlay` when omitted and is ignored while `live_preview` is disabled.
- vocabulary `uses`: `recognition-hints`, `text-replacement`
- process `kind`: `recognize-speech`, `resolve-uncertainty`,
  `apply-vocabulary`, `snippet-replacement`, `llm-rewrite`,
  `normalize-whitespace`
- uncertainty `mode`: `off`, `non-blocking`, `blocking`
- output `strategy`: `immediate`, `stack-first`, `clipboard-only`

Optional vocabulary conditions use a `when` subtable with `app_bundle_id`,
`clipboard_group`, and/or `locale`. Wake-word workflows use
`[setup.wake_word]` with `phrases = ["Hey Rill"]`. An action may include a
string-to-string `[output.actions.config]` table.

Plaintext webhook URLs and headers are rejected. Secrets belong in Rill's
secure credential store and should be referenced by a non-secret identifier.

## Editing and reload behavior

The Workflow window remains a separate macOS window. It displays the resolved
XDG directory and provides **Open Folder** and **Reload** actions. Rill reloads
the directory when the window opens; use **Reload** after changing files in an
external editor. A workflow run freezes its validated plan before recognition,
so an edit affects the next run rather than mutating one already in progress.

On the first launch after this format is introduced, Rill migrates the legacy
JSON workflow library only when the XDG directory contains no TOML files. It
writes each workflow independently, reloads all files for verification, and
rolls back the newly created files if verification fails.
