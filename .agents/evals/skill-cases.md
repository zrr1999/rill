# Rill skill evaluation cases

Author material for maintaining the skills; do not preload this file during
ordinary skill use. These are behavioral scenarios, not source-text assertions
or a record of passing runs.

Run a case against a recorded repository revision with the stated fixture.
Evaluate skill selection using names and descriptions before loading bodies.
Keep fixture mutations in a disposable checkout and substitute fakes for external
effects. Record model/host, revision, available tools, selected skills, observed
actions, artifacts, and unmet expectations. An unavailable observation is not a
pass. Compare equivalent runs with and without the skill before claiming an
improvement; structural validation alone establishes neither behavior nor gain.

Each group covers a positive task, a nearby task that should not trigger the
skill, and a misleading or incomplete-evidence case. Other skills may apply to
the nearby task. Judge decisions and resulting behavior, not wording or headings.

## rill-code-review

### CR-1 — Cancellation does not serialize replacement writes

Request: “审查这个改动，暂时不要修。” Fixture: a diff removes the wait for the
previous write in `PersistenceWriteCoordinator.replace`; the old fake store can
ignore cancellation and complete after the replacement write.

Expected: read the complete owner and callers, identify the reachable stale
overwrite and its ordering contract, cite the changed location, and explain a
barrier-based reproduction. Keep the fixture unchanged. Merely observing
`cancel()` or `@MainActor` must not dismiss the defect.

### CR-2 — Drafting a commit message

Request: “根据这段 diff 写一条符合仓库规范的提交信息，不做代码审查。”

Expected: produce the requested message using repository conventions without
loading or running the review workflow, inventing findings, or editing code.

### CR-3 — A large transaction owner is not itself a defect

Request: “这个 SQLite actor 很长，只有一个实现的协议也很多，帮我审查。”
Fixture: domain extensions share one connection; a suspected invalid value is
rejected by a reachable upstream validator.

Expected: trace ownership and the validator before judging. Do not report the
guarded path as reachable or recommend splitting the transaction across actors
based on file size. Any structural finding needs a concrete cost and deletion
test. Missing execution evidence stays separate from confirmed defects.

## rill-workflow-change

### WF-1 — Store the answer before speaking

Request: “调整语音助手内建工作流，让结果先保存，再朗读。” Fixture: the
definition has speech before storage and a fake speech sink can fail.

Expected: edit the authoritative built-in TOML, regenerate through repository
commands, and verify storage precedes speech and survives speech failure with a
partial receipt. Do not patch generated output alone or add storage to unrelated
custom workflows. Verify that the runtime uses the updated definition.

### WF-2 — Presentation copy only

Request: “把工作流页面的按钮文案改短，行为和文件格式不变。”

Expected: make the scoped presentation change without invoking workflow
compilation/migration work or rewriting any TOML documents.

### WF-3 — External edits and a frozen active run

Request: “修复工作流保存冲突，运行中的任务不能受到影响。” Fixture: Rill loads
source A, an external editor writes B, a save based on A detects conflict, and
the editor writes C before the proposed replacement of B. A run started from A
is suspended at a controlled provider boundary.

Expected: detect both intervening edits and preserve C, keep the active run's A
definition, and apply a valid resolved definition only to later runs. Verify
that invalid reloads do not silently reactivate a built-in. Do not introduce an
in-app text editor or overwrite newer disk contents as conflict recovery.

## rill-record-change

### RC-1 — Retry a failed queued delivery

Request: “队列中的 Record 输出失败后应该能重试，检查并修复。” Fixture: one
Record has two memberships, the selected origin has a lease, and its fake sink
first fails then succeeds while persistence accepts settlement writes.

Expected: failure releases the lease without consuming either membership;
successful retry consumes only the leased origin according to its policy.
Verify the persisted graph, events, and sink calls without mutable payloads or
UI-owned consumption state.

### RC-2 — Record row spacing

Request: “调整 Record 列表行间距，不改排序、内容或交互。”

Expected: limit the edit to presentation; do not load the Record mutation
workflow, introduce a catalog migration, or add storage tests for spacing.

### RC-3 — Rejected persistence must not publish success

Request: “修复导入失败后仍然出现的 Record。” Fixture: force the store's
persistence revision check or transaction to fail after preparing an ingestion.

Expected: reproduce the rejected commit, then verify both durable and in-memory
graphs remain unchanged and no success event escapes. Repeat the rejected write
at membership delivery settlement: preserve the lease for settlement retry and
distinguish that retry from repeating the sink effect. A caught error alone is
insufficient evidence. Do not delete real user records to reset the test.

## rill-runtime-debug

### RT-1 — Late result after cancellation

Request: “取消录音后旧结果还会插入，定位并修复。” Fixture: a fake worker holds
an old request while cancellation and a new run occur, then returns the old result.

Expected: correlate run identity, find the first invalid transition, block stale
delivery, and retain pending ownership until cleanup drains. A controlled
regression observes both output and cleanup through the production caller;
adding sleep or dropping the task handle does not count as a repair.

### RT-2 — Provider design proposal

Request: “只讨论未来增加一个识别 provider 的模块边界，不排查运行故障。”

Expected: answer the design request from architecture without invoking runtime
diagnostics, launching an app, collecting logs, or claiming a root cause.

### RT-3 — Unknown running artifact

Request: “测试都过了，但是正在运行的 Rill 仍然卡住，告诉我原因。” Fixture:
the available logs omit run identity and the installed app's provenance is unknown.

Expected: inspect available process/artifact evidence, separate hypotheses from
confirmed causes, and identify the smallest missing observation. Do not claim
the latest source is running, kill all Rill/worker processes, or reset live data.

## rill-macos-qa

### QA-1 — Fn and insertion acceptance

Request: “验证这次 Fn 录音到插入的修改。” Fixture: an identified app artifact,
available microphone/accessibility permissions, and a harmless local text target
with an IME enabled; physical interaction is available for this case.

Expected: record app/environment identity, exercise the relevant gesture,
recording, focus, insertion, cancellation, and IME paths from the current
checklist, and report observed outcomes. Avoid signing off unrelated release
checks or sending sample content to a real recipient.

### QA-2 — Pure model validation

Request: “给这个不涉及系统 API 的枚举解码修复补一个定向测试。”

Expected: verify the model boundary without loading native acceptance work,
requesting microphone access, or launching the installed app.

### QA-3 — Green tests without physical input

Request: “单测通过，截图也正常，能确认 Fn、VoiceOver 和发布包都验收通过吗？”
Fixture: only unit results and screenshots are available; physical Fn input,
VoiceOver observation, and the notarized candidate are unavailable.

Expected: accept the evidence only for what it establishes; leave the named
native and release checks unverified, with precise missing observations/manual
steps. Do not reinterpret synthetic keys, screenshots, or development signing
as those acceptance results.
