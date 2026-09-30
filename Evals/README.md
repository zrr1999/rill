# Quality evaluations

Quality evaluations measure whether model output meets expectations. Performance
benchmarks measure time and resources; their workloads live in
[Benchmarks](../Benchmarks/README.md). Deterministic implementation tests stay in
`Tests` and `scripts/tests`, including corpus validation and scorer regression tests.

| Suite | Corpus | Quality rule | Execution |
| --- | --- | --- | --- |
| `asr` | Authorized local recordings; `ASR/collection-plan.json` is an unfilled collection plan | CER/WER, critical content, silence hallucination, paired noninferiority | Local replay and comparison |
| `text-rewrite` | `TextRewrite/cases.json` | All expected-content matches; ignores punctuation and whitespace, preserves case | Explicit provider calls, three repetitions |
| `vocabulary-correction` | `VocabularyCorrection/cases.json` | Report exact matches after trimming surrounding whitespace, preservation mismatches and fallbacks | Explicit DeepSeek calls, three repetitions |
| `context-correction` | `ContextCorrection/cases.json` | Report content matches ignoring punctuation, whitespace and case, plus fallbacks | Explicit DeepSeek calls; fixed synthetic reference images |

The vocabulary and context suites have no automatic quality threshold. Their
completed reports say `not_assessed`; they do not manufacture a quality pass.
Text rewrite retains its all-matches requirement. A failed request cannot be
replaced by an expected answer. Small synthetic corpora are regression signals,
not estimates of production accuracy.

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
corpus identity, configured model, counts, scopes and incomplete evidence. Files use
0600 permissions and the run directory uses 0700.

Quality and request latency use the same provider observations. The performance
summary has no comparison baseline and says `not_assessed`; it is not an
end-to-end latency or performance-regression verdict. Missing measurements stay
missing, and empty input that makes no request contributes no timing sample.

## Continuous Evaluation (CE)

`CE - Quality` is a manual GitHub Actions workflow, with a single-suite or all-suite
selector. It has no PR, push or scheduled trigger and is not a required merge check.
It runs the three LLM suites on hosted macOS runners. Configure these repository
settings before dispatch:

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
