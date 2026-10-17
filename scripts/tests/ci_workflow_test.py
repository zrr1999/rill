#!/usr/bin/env python3
"""Offline regression tests for CI's fail-closed gate and lane cache policy."""

import ast
import itertools
import os
from pathlib import Path
import re
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = (ROOT / ".github/workflows/ci-tests.yml").read_text()


def block(name):
    """Read one named step without adding a YAML dependency to script tests."""
    marker = f"      - name: {name}\n"
    return WORKFLOW.split(marker, 1)[1].split("      - name:", 1)[0]


def condition(step):
    return re.search(r"if: \$\{\{ (.*?) \}\}", block(step)).group(1)


def evaluate(expression, values):
    """Evaluate the boolean/equality subset used by the actual workflow guards."""
    for key in sorted(values, key=len, reverse=True):
        expression = expression.replace(key, repr(values[key]))
    expression = expression.replace("&&", " and ").replace("||", " or ")

    def visit(node):
        if isinstance(node, ast.Constant):
            return node.value
        if isinstance(node, ast.BoolOp):
            results = [visit(value) for value in node.values]
            return all(results) if isinstance(node.op, ast.And) else any(results)
        if isinstance(node, ast.Compare) and len(node.ops) == 1:
            left, right = visit(node.left), visit(node.comparators[0])
            if isinstance(node.ops[0], ast.Eq):
                return left == right
            if isinstance(node.ops[0], ast.NotEq):
                return left != right
        raise AssertionError(f"Unsupported workflow expression: {ast.dump(node)}")

    return visit(ast.parse(expression, mode="eval").body)


class AggregateTests(unittest.TestCase):
    def result(self, docs, app, preflight, scope, workload):
        env = dict(os.environ)
        env.update(
            DOCS_RESULT=docs,
            APP_SCOPE=app,
            PREFLIGHT_RESULT=preflight,
            WORKLOAD_SCOPE=scope,
            WORKLOAD_RESULT=workload,
        )
        return subprocess.run(
            ["bash", str(ROOT / "scripts/check_ci_results.sh")],
            env=env,
            capture_output=True,
            check=False,
        ).returncode

    def test_all_result_and_scope_combinations_fail_closed(self):
        # Include missing/invalid outputs and every dependency terminal state.
        states = ("success", "failure", "cancelled", "skipped", "")
        scopes = ("true", "false", "", "invalid")
        for docs, app, preflight, scope, workload in itertools.product(
            states, scopes, states, scopes, states
        ):
            expected = (
                docs == "success"
                and (app, preflight) in (("true", "success"), ("false", "skipped"))
                and (scope, workload) in (("true", "success"), ("false", "skipped"))
            )
            with self.subTest(
                docs=docs, app=app, preflight=preflight, scope=scope, workload=workload
            ):
                self.assertEqual(self.result(docs, app, preflight, scope, workload) == 0, expected)

    def test_gate_wiring_and_matrix(self):
        gate = WORKFLOW.split("\n  preflight:\n", 1)[1]
        self.assertIn("name: Release preflight", gate)
        self.assertIn("needs: [docs, preflight-lanes, record-workloads]", gate)
        self.assertIn("if: ${{ always() }}", gate)
        self.assertIn("run: bash scripts/check_ci_results.sh", gate)
        for variable, value in {
            "DOCS_RESULT": "needs.docs.result",
            "APP_SCOPE": "needs.docs.outputs.app",
            "PREFLIGHT_RESULT": "needs.preflight-lanes.result",
            "WORKLOAD_SCOPE": "needs.docs.outputs.performance_workloads",
            "WORKLOAD_RESULT": "needs.record-workloads.result",
        }.items():
            self.assertIn(f"{variable}: ${{{{ {value} }}}}", gate)
        lanes = WORKFLOW.split("\n  preflight-lanes:\n", 1)[1].split("\n  record-workloads:", 1)[0]
        self.assertIn("fail-fast: false", lanes)
        self.assertEqual(re.findall(r"- lane: (\w+)", lanes), ["tests", "release"])
        self.assertNotIn("continue-on-error", lanes)
        self.assertIn("if: ${{ needs.docs.outputs.app == 'true' }}", lanes)
        self.assertIn('bash scripts/preflight.sh --lane "$LANE"', lanes)
        self.assertIn('bash scripts/preflight.sh --clean --lane "$LANE"', lanes)


class CachePolicyTests(unittest.TestCase):
    def test_only_successful_main_lanes_save(self):
        guard = condition("Save successful trusted lane build arena")
        for success, ref, event, lane, hit in itertools.product(
            (True, False),
            ("refs/heads/main", "refs/heads/feature", "refs/pull/1/merge"),
            ("push", "pull_request", "workflow_dispatch"),
            ("success", "failure", "cancelled", "skipped", ""),
            ("true", "false", ""),
        ):
            values = {
                "success()": success,
                "github.ref": ref,
                "github.event_name": event,
                "steps.lane.outcome": lane,
                "steps.build-cache.outputs.cache-hit": hit,
            }
            expected = (
                success
                and ref == "refs/heads/main"
                and event in ("push", "workflow_dispatch")
                and lane == "success"
                and hit != "true"
            )
            with self.subTest(values=values):
                self.assertEqual(evaluate(guard, values), expected)
        # A clean main run skips restore but must still have a computed save key.
        save = block("Save successful trusted lane build arena")
        self.assertNotIn("steps.build-cache.outcome", save)
        self.assertIn("key: ${{ steps.cache-key.outputs.primary }}", save)

    def test_clean_runs_do_not_restore(self):
        guard = condition("Restore Swift build arena")
        for event in ("pull_request", "push", "workflow_dispatch"):
            self.assertEqual(evaluate(guard, {"github.event_name": event}), event == "pull_request")

    def test_arenas_and_keys_are_separate(self):
        self.assertIn("- lane: tests\n            cache-path: .build", WORKFLOW)
        self.assertIn("- lane: release\n            cache-path: .artifacts/build/release", WORKFLOW)
        self.assertIn("CACHE_PREFIX: swift-v2-${{ matrix.lane }}-${{ runner.os }}-${{ runner.arch }}", WORKFLOW)
        self.assertIn("${{ steps.toolchain.outputs.key }}-${{ hashFiles('Package.swift', 'Package.resolved', 'scripts/build_driver.py') }}-", WORKFLOW)
        for step in ("Restore Swift build arena", "Save successful trusted lane build arena"):
            self.assertIn("path: ${{ matrix.cache-path }}", block(step))
        self.assertNotIn("worker-cache on", WORKFLOW)

    def test_security_and_evidence_preserved(self):
        self.assertIn("permissions:\n  contents: read", WORKFLOW)
        self.assertIn("scripts/check_dependency_security.py --live-osv", WORKFLOW)
        self.assertIn("run: bash scripts/check_secrets.sh", WORKFLOW)
        self.assertIn('RILL_RECORD_STRESS: "1"', WORKFLOW)
        self.assertIn("steps.build-cache.outputs.cache-matched-key", WORKFLOW)
        self.assertIn('"$(git rev-parse HEAD)"', WORKFLOW)
        for step in ("Save native render evidence", "Save verified preflight app", "Upload preflight reports"):
            self.assertRegex(block(step), r"name: .+\$\{\{ matrix.lane \}\}-\$\{\{ github.run_id \}\}-\$\{\{ github.run_attempt \}\}")


if __name__ == "__main__":
    unittest.main()
