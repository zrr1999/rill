> 历史工程验证记录；保留原始候选和环境，不代表当前版本已经通过原生交互验收。

# Rill input method implementation evidence

## Source boundary

The original implementation was validated in `codex/rill-modules-input-method`
against the frozen dirty baseline tree `17fad434074215af2b22406899dba3a03cea997b`.
Its development artifact used source tree `9456c431488695007981602537c16bb900b46026`.
Those local snapshots and the original checkout are preserved.

PR preparation ports only the task delta onto main commit
`c396a8dc85e0d87bf37b9610ebd8b95ed346a729` in `codex/rill-input-method-pr`.
Review the PR against `main`; the inherited dirty baseline is not introduced as
new feature work. The port retains main's speech-worker contract target, catalog
mutation optimizations, workflow executor, settings and vocabulary state owners.

The module graph and state owners are documented in [architecture.md](../../architecture.md).
AppModel still provides compatibility properties and cross-feature settings
composition. The new feature models own the corresponding observable state;
this does not remove every legacy AppModel command extension.

The initial frozen-source compatibility fixes are historical validation details:
main now includes the current context-memory cancellation and persistence-barrier
implementations. This PR preserves those implementations while moving their
feature ownership.

## Migration of the current personal profile

Squirrel was paused for a 0.27-second snapshot copy and resumed immediately.
All subsequent deployment, backup and replay operations used private copies.
Neither the live source directory nor its input-source selection was changed.
Raw profile data and candidate text remain in ignored local artifacts.

| Check | Result |
| --- | --- |
| Full userdb files before/after deployment | 8 files, identical SHA-256 hashes |
| Reading–phrase rows in full database backups | 46,176, identical |
| Distinct phrases | 45,895 |
| Per-row commit count, dynamic weight and tick (`c`, `d`, `t`) | All identical |
| Fixed inputs | `nihao`, `shurufa`, `jianqieban`, `yuyinshibie`, `gongzuoliu`, `zhongwen`, `ceshi`, `rill` |
| Candidate order, preedit and committed text | 8/8 identical |
| Frozen input profiles after comparison | Unchanged |

Both replay processes used the packaged Rime 1.16.0 engine; the original copy
retained Squirrel's deployed configuration and the imported copy was redeployed.
This proves profile preservation for the tested sequences, not native client
compatibility or equivalent ranking for every possible input.

The comparison is reproducible with `scripts/tests/input_method_migration_test.py`.
Counts and equality results are in `.artifacts/input-method/profile-validation/migration-report.json`.

## Automated boundaries

Tests cover the real Unix datagram channel, private permissions, host restart,
policy revocation, duplicate events, composition/selection preservation, durable
confirmation and revocation recovery, failed persistence, shutdown during an
accepted confirmation, next-request hotword resolution and clipboard delivery
shutdown. The packaged-engine smoke test loads the pinned plugins, deploys a
synthetic dictionary and verifies candidates, commits and reopening a copied DB.

The initial implementation's `just ci` passed, including Prek, the Release build, signed nested-bundle checks,
the packaged Rime smoke test and the full test suite. XCTest reported 1,754 cases
with six opt-in render/stress skips and no failures. Swift Testing reported 74
cases with two opt-in skips and no failures. The frozen-profile migration test
was also enabled separately and passed; live pasteboard latency remains a device
check. Logs and machine-readable results are under `.artifacts/input-method/`.

## Independent installation follow-up

The installed development build 24 had only an import-and-install button. Its
runtime already used Rill's private directory, but installation required a source
profile and used Squirrel's SharedSupport directory to fill missing dictionaries.

The correction adds a default installation button and makes import an optional
first-install alternative. Rill bundles public, pinned Wanxiang Base 18.0.8, its
LTS model and standard OpenCC 1.1.9 data. Neither installation path reads Squirrel's
app bundle. Imported schemas, Lua, models and complete userdb stay intact; the
default profile is used only when no source is selected. Existing Rill profiles
and app installations are never overwritten.

The six installer tests passed with the packaged-engine options enabled. These
include a fresh install with no source or userdb, a check that the Squirrel
running-state callback is never consulted for that path, refusal when Rill's
input method is active, and real deployment of both bundled and imported data.
The five learning tests also passed, including next-request hotwords and undo.
The independent packaged probe produced six candidates and committed `你好`,
`输入法` and `中文` from full-pinyin inputs.

The frozen personal profile was imported again using only Rill's bundled shared
data. All eight database files and 46,176 reading/phrase/weight rows remained
identical; all eight fixed candidate/commit replays matched again. No live profile
or input-source selection was changed. Evidence is in
`.artifacts/input-method/independent-integration.log`, `independent-learning.log`,
`independent-package.log`, and `independent-validation/migration-report.json`.

## Lightweight default in the PR

The PR replaces the earlier bundled Wanxiang profile with Rime's
`pinyin_simp` dictionary at revision `0c6861ef7420ee780270ca6d993d18d4101049d0`
and a small Rill-owned full-pinyin schema. The dictionary source is 1,266,216 bytes.
No Wanxiang LTS model is downloaded or packaged. The packaging test also checks
that an old model is removed when rebuilding the default resources.

OpenCC and the runtime plugins remain available for optional personal-profile
imports. The earlier personal migration evidence describes that import path;
it does not imply the lightweight default has the same ranking as Wanxiang.

On 2026-09-23, `just ci` passed for this PR worktree: Prek, documentation and
module-boundary checks, the Release build, signed nested bundles, packaged Rime
probes, and the complete domain/platform/UI/app test suites. Opt-in device,
render and scale checks remain separate. The default profile contains only
`default.yaml`, `rill_pinyin.schema.yaml` and `pinyin_simp.dict.yaml` (1,267,591 bytes).
The packaged probe returned six candidates and committed `你好`, `输入法` and `中文`.

The production installer's packaged-default test was enabled separately and
passed without a migration source. Its five enabled checks passed; the optional
personal-profile migration was not repeated in that run. Current logs are in
`.artifacts/input-method-pr/ci-lightweight-3.log` and `minimal-installation.log`.

## Device and speech acceptance still required

Native UI automation initially timed out and later reported a locked Mac. After
the user's installation, an accessibility-tree/screenshot inspection successfully
located the original import-only section in `/Applications/Rill.app` (development
build 24). This established its visible entry, not native IMK compatibility.
No real-device IMK input-source acceptance is claimed. TextEdit,
browser, Codex, VS Code, WeChat and Terminal still need the marked-text,
keyboard/mouse selection, paging, focus/source switch, multi-display, Fn,
copy/paste and exit/restart checks in [input-method.md](../../input-method-development.md).
The generated app has not replaced the user's installed Rill or Squirrel.

No fixed recordings with reference transcripts were supplied for the hotword
A/B benchmark. Hotword propagation is verified; recognition improvement,
ordinary-sentence regressions, latency and edit cost are unmeasured.

This is a local personal-use build. Public distribution and notarization are
outside this delivery; pinned dependency licensing is documented separately in
[input-method-dependencies.md](../../input-method-dependencies.md).
