#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""One-shot performance scan of the local diagnostic export; no scheduler."""

import argparse
from collections import Counter, defaultdict
from datetime import datetime
import json
import math
import statistics

import export_diagnostics as exporter


LABELS = {
    "captureStopMillis": "音频源停止（单调计时）",
    "captureDrainMillis": "PCM 流排空（单调计时）",
    "capturePreviewRetireMillis": "预览取消及排空（单调计时）",
    "captureFinalizeMillis": "WAV 完成（单调计时）",
    "captureFinishMillis": "录音捕获整体收尾（单调计时）",
    "captureSealMillis": "授权捕获封存（单调计时）",
    "captureCueMillis": "停止反馈（单调计时）",
    "recognition_measured": "识别操作（单调计时）",
    "release_to_paste_posted": "松键 → 粘贴按键已发送（非文字可见确认）",
    "pasteDispatchMillis": "粘贴按键发送（单调计时）",
    "store_measured": "Record 存储动作及回执协调（单调计时）",
    "injection_measured": "注入动作及回执协调（单调计时）",
    "pasteSettleMillis": "粘贴后等待（单调计时）",
    "restore_measured": "剪贴板恢复尝试（单调计时）",
    "release_to_finishing": "松键 → 录音收尾事件",
    "queue_wait": "入队 → 开始处理",
    "recognition_stage": "识别阶段跨度（含阶段间开销）",
    "transform_to_api": "变换阶段 → 模型请求开始",
    "api_completed": "模型完整响应及解析（记录值）",
    "store_action": "输出开始 → Record 存储动作结束",
    "injection_action": "存储动作结束 → 文字注入动作结束",
    "release_to_injection": "松键 → 注入动作结束（含恢复等待）",
}


def stats(values):
    values = sorted(values)
    if not values:
        return {"n": 0, "p50_ms": None, "p95_ms": None}
    return {
        "n": len(values), "p50_ms": round(statistics.median(values), 1),
        "p95_ms": round(values[math.ceil(len(values) * .95) - 1], 1),
        "max_ms": round(values[-1], 1),
    }


def scan(header, events):
    by_run = defaultdict(list)
    for event in events:
        if event["run_id"]:
            by_run[event["run_id"]].append(event)
    runs = []
    for run_id, timeline in by_run.items():
        def only(code, key=None, value=None):
            matches = [e for e in timeline if e["event"] == code
                       and (key is None or e["metadata"].get(key) == value)]
            return matches[0] if len(matches) == 1 else None

        def stage(value):
            return only("session.stage", "stage", value)

        completed = stage("completed")
        if completed is None:
            continue
        release = only("recording.hotkey.released")
        if release is None:
            continue
        recognition = stage("recognizing")
        transform = stage("transforming")
        delivery = stage("delivering")
        actions = [e for e in timeline if e["event"] == "session.action"]
        store = only("session.action", "actionID", "record.store")
        injection = only("session.action", "actionID", "focused-application.insert")
        api = only("provider.openai.rewrite.completed")
        api_start = only("provider.openai.rewrite.started")
        measures = {}

        def gap(name, start, end):
            if start and end and end["timestamp"] >= start["timestamp"]:
                measures[name] = (end["timestamp"] - start["timestamp"]) * 1000

        gap("release_to_finishing", release, only("recording.finishing"))
        gap("queue_wait", only("audio-processing.enqueued"), only("audio-processing.started"))
        # Resolving/branching or repeated stages must not masquerade as STT time.
        if recognition and not any(e["event"] == "session.stage"
                                   and e["metadata"].get("stage") == "resolving" for e in timeline):
            gap("recognition_stage", recognition, transform or delivery)
        gap("transform_to_api", transform, api_start)
        if api and "durationMillis" in api["metadata"]:
            measures["api_completed"] = int(api["metadata"]["durationMillis"])
        if store and actions and actions[0]["id"] == store["id"]:
            gap("store_action", delivery, store)
        if store and injection and any(
            a["id"] == store["id"] and b["id"] == injection["id"]
            for a, b in zip(actions, actions[1:])
        ):
            gap("injection_action", store, injection)
        if injection and injection["metadata"].get("resultCode") == "injected":
            gap("release_to_injection", release, injection)
        for code in ("recording.finishing", "audio-processing.capture-timing", "clipboard.inject.paste.posted", "clipboard.inject.paste.end"):
            event = only(code)
            if event:
                for key in LABELS:
                    if key in event["metadata"]:
                        measures[key] = int(event["metadata"][key])
        recognition_timing = only("session.process.timing", "stepKind", "recognizeSpeech")
        if recognition_timing and "durationMillis" in recognition_timing["metadata"]:
            measures["recognition_measured"] = int(recognition_timing["metadata"]["durationMillis"])
        for metric, action in (("store_measured", store), ("injection_measured", injection)):
            if action and "durationMillis" in action["metadata"]:
                measures[metric] = int(action["metadata"]["durationMillis"])
        restore = only("clipboard.inject.restore")
        if restore and "durationMillis" in restore["metadata"]:
            measures["restore_measured"] = int(restore["metadata"]["durationMillis"])
        gap("release_to_paste_posted", release, only("clipboard.inject.paste.posted"))
        runs.append({
            "run_id": run_id, "completed_utc": completed["time_utc"],
            "completed_timestamp": completed["timestamp"],
            "has_completed_api": api is not None,
            "metrics_ms": {k: round(v, 3) for k, v in measures.items()},
        })
    runs.sort(key=lambda run: run["completed_timestamp"])
    cutoff = datetime.fromisoformat(header["exported_at_utc"]).timestamp() - 86400
    cohorts = {
        "7d_completed_voice": runs,
        "24h_completed_voice": [r for r in runs if r["completed_timestamp"] >= cutoff],
        "24h_completed_voice_with_api": [r for r in runs if r["completed_timestamp"] >= cutoff and r["has_completed_api"]],
        "latest_6_completed_voice_with_api": [r for r in runs if r["has_completed_api"]][-6:],
    }
    failures = Counter(
        e["metadata"].get("failureCode", "unknown")
        for e in events if e["event"] == "session.failure"
    )
    return {
        "exported_at_utc": header["exported_at_utc"],
        "installed_app_at_export": header.get("installed_app_at_export"),
        "event_count": len(events), "run_count": len(by_run),
        "invalid_event_count": header["invalid_event_count"],
        "failure_events_by_code": dict(failures),
        "cohorts": {name: {
            "runs": len(items),
            "metrics": {metric: stats([r["metrics_ms"][metric] for r in items
                                      if metric in r["metrics_ms"]]) for metric in LABELS},
        } for name, items in cohorts.items()},
        "runs": runs,
        "limitations": [
            "Stage gaps use wall-clock event timestamps, not pure model compute timers.",
            "Missing or repeated endpoints are excluded, not recorded as zero.",
            "Quantiles are nearest-rank; small-cohort p95 is descriptive only.",
            "Injection completion includes clipboard restoration, not observed text visibility.",
            "Legacy clipboard internal events may lack run_id; these are not assigned to runs by proximity.",
            "Historical events lack build identity, audio duration, and reliable model identity.",
            "API duration includes full response and parsing, not time to first token.",
        ],
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--refresh", action="store_true", help="Refresh read-only export first")
    args = parser.parse_args()
    if args.refresh:
        exporter.main()
    header, *events = [json.loads(line) for line in
                       (exporter.ROOT / "diagnostics.jsonl").read_text().splitlines()]
    if header["event_count"] != len(events):
        raise ValueError("Incomplete export")
    report = scan(header, events)
    exporter.atomic_write("performance-scan.json", json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    lines = ["# Rill 第一轮性能扫描", "", f"数据导出时间：{header['exported_at_utc']}",
             "", "单位为毫秒；下表统计完整语音运行。缺少端点的指标不计入，n 是有效样本数。", ""]
    for name, cohort in report["cohorts"].items():
        lines += [f"## {name}（{cohort['runs']} 次）", "",
                  "| 阶段 | n | P50 | P95 |", "|---|---:|---:|---:|"]
        for metric, item in cohort["metrics"].items():
            lines.append(f"| {LABELS[metric]} | {item['n']} | {item['p50_ms']} | {item['p95_ms']} |")
        lines.append("")
    lines += ["## 解释边界", ""] + [f"- {item}" for item in report["limitations"]]
    exporter.atomic_write("performance-scan.md", "\n".join(lines) + "\n")
    print(json.dumps({k: v for k, v in report.items() if k not in ("runs", "limitations")}, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
