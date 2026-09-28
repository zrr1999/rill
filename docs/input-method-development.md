# Rill input method development

Rill uses a separate InputMethodKit app with the pinned Rime 1.16.0 engine,
Lua, Octagram and Predict. The input method depends only on that runtime and the
small local communication contract. It keeps typing when Rill is closed.
Dependency provenance and licenses are in [input-method-dependencies.md](input-method-dependencies.md).

用户安装、可选导入与学习说明见[输入法指南](input-method.md)。

## Build and package

Run `just ci` to validate the complete package, or use the local assembly commands
in [CONTRIBUTING.md](../CONTRIBUTING.md). The assembled Rill app contains
`Contents/Helpers/RillInputMethod.app`; signing covers nested libraries and helpers
before the outer app. Ad-hoc builds cannot validate an authorized learning connection.

The bundle identifier is `dev.zrr.inputmethod.Rill`; the literal `.inputmethod.`
segment is required for macOS discovery. The selectable mode is the same identifier
with `.Hans` appended. Keep the packaged plist, IMK server and IPC signature identity
aligned through `InputMethodPaths`. The old `dev.zrr.Rill.InputMethod` identifier is
only used to detect a running legacy component before repair.

Registration must verify that TIS enumerates the selectable mode even when
`TISRegisterInputSource` returns `noErr`. Repair atomically replaces the component
while leaving the existing profile untouched. A complete component whose sources
are not yet enumerated is pending system registration, not a broken installation.
Adding and selecting the source happens in System Settings. On the tested macOS 27
session, `TISEnableInputSource` returned `noErr` without enabling the parent or
adding Rill to System Settings; do not offer a programmatic activation button.
A mode's default-enabled flag alone does not mean its parent is enabled. Settings
project the current filesystem/TIS state and explain the logout/login step when
a newly installed source is absent from System Settings.

## Reproducible checks

`uv run --script scripts/tests/input_method_test.py PATH/TO/RillInputMethod.app`
checks the signed bundle with both a synthetic profile and the bundled default:
deployment, plugin loading, six candidates, full-pinyin commits and copied userdb
reopening. All resources come from the app. It does not modify real input sources
or the user's profile. `RILL_IME_VALIDATION_BUNDLE=/path/to/RillInputMethod.app
scripts/preflight.sh swift test --filter RimeProfileInstallerTests` also exercises
the production installer with the default data in temporary directories.

The packaged executable also supports
`--probe-profile COPIED_PROFILE INPUTS_JSON OUTPUT_JSON` for controlled replay.
The JSON input is an array of at most 32 keystroke strings. Always use a disposable
copy: replay commits text and can change Rime frequencies. The output contains
candidates and commits and must remain private when using personal dictionaries.

For migration acceptance, stop Squirrel, copy its complete profile and compare
all `.userdb` file hashes before deployment. Compare `rime_dict_manager` backups
from the copies for text, reading, commit count and dynamic weight. Run the same
input sequence on separate copies of the original and imported profiles; compare
candidate order without sharing either user's data in logs or commits.

`uv run --script scripts/tests/input_method_migration_test.py --original FROZEN_PROFILE
--migrated IMPORTED_PROFILE --bundle PATH/TO/RillInputMethod.app --report REPORT.json`
automates that comparison on disposable copies and emits only counts and equality
results. It checks complete database bytes, all reading/phrase/count/weight/tick
rows, and eight fixed candidate/commit replays with the packaged engine.

## Mac acceptance

Automation and the headless Rime probe do not establish physical input quality.
Record results for TextEdit, browser, Codex, VS Code, WeChat and Terminal, covering:

- Marked text, six vertical candidates, digits/arrows/Return/Escape, paging, mouse
  choice, English/Chinese switching, and existing selected-text preservation.
- Same-app field changes, mouse cursor moves, app/source switches while composing,
  and no late commit to a newly focused client.
- Light/dark appearance, long candidates, display edges and multiple displays.
- Fn voice input, normal copy/paste, Rill exit, lost socket, IME restart and userdb
  recovery after normal exit.
- Learning disabled, empty allowlist, sensitive apps, revoked authorization, repeat
  events, confirmation/undo, and restart during accepted writes.

Speech accuracy uses fixed recordings and reference transcripts with the same
model/settings, alternately enabling and disabling confirmed hotwords. Report term
hits, ordinary-sentence regressions, latency and manual edit cost. A passing hint
propagation test is not evidence of an accuracy improvement.
