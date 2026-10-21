# Quality evaluations

Performance workloads live in [Benchmarks](../Benchmarks/README.md).
Deterministic implementation tests stay in
`Tests` and `tools/tests`, including corpus validation and scorer regression tests.

The replay and analysis implementation is the internal `rill_dev.evaluation`
package in `tools/`. `just test-tools` runs its offline tests using the locked
Python environment; it neither loads models nor calls providers. The existing
`just` commands below are the supported entry points.

| Suite | Corpus | Quality rule | Execution |
| --- | --- | --- | --- |
| `asr` | Authorized local recordings; `ASR/collection-plan.json` is an unfilled collection plan | CER/WER, critical content, silence hallucination, paired noninferiority | Local replay and comparison |
| `text-rewrite` | `TextRewrite/cases.json` | All expected-content matches; ignores punctuation and whitespace, preserves case; protected literals match exactly | Explicit provider calls, three repetitions |
| `vocabulary-correction` | `VocabularyCorrection/cases.json` | Report exact matches after trimming surrounding whitespace, preservation mismatches and fallbacks | Explicit DeepSeek calls, three repetitions |
| `context-correction` | `ContextCorrection/cases.json` | Report content matches ignoring punctuation, whitespace and case, plus fallbacks | Explicit DeepSeek calls; fixed synthetic reference images |

The vocabulary and context suites have no automatic quality threshold. Their
completed reports say `not_assessed`; they do not manufacture a quality pass.
Text rewrite retains its all-matches requirement. A failed request cannot be
replaced by an expected answer. Small synthetic corpora are regression signals,
not estimates of production accuracy.

Text rewrite includes Chinese quantities, units, negation, conditions and natural
word repetitions. Optional `protected_literals` preserve URL, identifier, command
and filename spelling, including punctuation, case and Unicode composition. Each
literal must occur in both the input and expectation; its nonoverlapping occurrence
count in the output must match the expectation. Swift checks this during execution,
and the Python reporter independently checks the raw output against the corpus.
Other content retains the existing normalization rule.

## Run explicitly

```sh
# Set DEEPSEEK_API_KEY securely in the process environment.
just eval-quality vocabulary-correction
just eval-quality context-correction

# Set OPENAI_API_KEY, OPENAI_BASE_URL and OPENAI_MODEL securely.
just eval-quality text-rewrite
```

These commands send the selected corpus to the configured provider. They do not
read real screens, history or recordings. The optional local
`RILL_VOCABULARY_EVALUATION_CASES` path selects a different authorized corpus;
its ASR witness must meet the existing provenance and term-count contract.
Credentials are never command arguments or report fields.

The runner uses the locked `scripts/preflight.sh swift test-domain` entry point
and only enables the selected suite in `RillQualityEvaluations`. Ordinary
`just test` / `just ci` explicitly exclude that target from execution, even if
a live-evaluation environment flag was inherited. The target remains compiled.

Each invocation creates a fresh private directory under
`.artifacts/evals/<suite>/<run-id>/`; `--output-dir PATH` selects a new directory.
Existing run directories are never overwritten. Raw `observations.json` remains
private. The `summaries/quality-report.json` and `summaries/performance-report.json`
contain no input, reference or output bodies. They record the suite, source and
corpus identity, configured model and provider fingerprint, counts, scopes and incomplete evidence. Files use
0600 permissions and the run directory uses 0700.

`quality_by_category` groups the existing quality counts by the corpus's known
category names; custom categories become `other`. `paired_comparisons` compares
reference modes within one invocation using the same case and repetition: ordinary
versus contextual rewrite, text versus references, or text versus vocabulary.
Only complete ASR term evidence admits the additional ASR-vocabulary comparison.
Pairs report improved, regressed, both-matched and neither-matched outcomes, with
unrequested and incomplete pairs counted separately. These counts do not compare
source revisions or establish production accuracy or statistical significance.

Only unique expected observations contribute scores or timing. Missing, duplicate,
unknown or asymmetric-request observations make evidence incomplete; duplicate
coordinates never select a preferred result. A runner failure keeps `run_status`
incomplete even when observed quality already fails. Summary keys never repeat raw
sample IDs or arbitrary mode/category names. Vocabulary reports contain the integer
`skipped_asr_comparison_count`, derived from corpus eligibility, replacing the former
list of skipped sample IDs. Input, expected/output bodies and protected literals
remain in the private corpus or raw observations.

Quality and request latency use the same provider observations. The performance
summary has no comparison baseline and says `not_assessed`; it is not an
end-to-end latency or performance-regression verdict. Missing measurements stay
missing, and empty input that makes no request contributes no timing sample.

## Continuous Evaluation (CE)

`CE - Quality` runs all three LLM suites every Monday at 09:30 Asia/Shanghai
(01:30 UTC) on hosted macOS runners. Scheduled runs use the latest commit on the
default branch, so the schedule takes effect after the workflow is merged there.
Manual dispatch still supports a single-suite or all-suite selector. It has no PR
or push trigger and is not a required merge check. Configure these repository
settings before the first run:

- Secrets: `DEEPSEEK_API_KEY` for vocabulary/context; `OPENAI_API_KEY` for rewrite.
- Actions variables: `OPENAI_BASE_URL` and `OPENAI_MODEL` for rewrite.

Missing configuration fails explicitly. A matrix job may finish successfully with
a report-only quality result; inspect the report's `decision`, not just the job color.
CE uploads only the content-free `summaries/*-report.json` files, including partial
summaries after a runner failure when observations exist. Raw provider outputs are
not uploaded. Each artifact retains its source revision and expires after 30 days.

## ASR and experiment admission

ASR remains local: the repository contains collection slots, not an authorized,
annotated audio dataset. [ASR evaluation and replay](../docs/asr-evaluation.md)
documents corpus export, Release receipts, cache conditions and timing boundaries.

Use `just eval-quality asr` and `just bench-performance asr --target METRIC` on the
same raw runs. Quality needs human references, not memory measurements; performance
needs comparable valid work and its target metric, not human references. Both can
report small or synthetic experiments. `just accept-asr --goal quality|performance`
separately applies the microphone corpus, repetition, quality and performance
admission policy. A pass is not native macOS or release acceptance.
