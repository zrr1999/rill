# Jev hotword selection acceptance

The feature is experimental and off by default. Automated tests establish
ordering, privacy, cancellation and snapshot behavior; they do not establish
speech quality or native microphone latency.

## Fixed-recording comparison

Use explicitly authorized recordings, their reference transcripts, and the
application/workflow/selection captured **before** each recording. Do not derive
ranking context or candidates from the reference transcript or ASR output.
Keep model, device, app commit, vocabulary and Qwen budgets identical across:

1. No recognition hints.
2. Existing rule-based selection.
3. Jev-ranked selection with a prepared matching cache entry.

Also measure the normal cold-cache path: it must use exactly the rule baseline,
without waiting for Jev. A cloud failure must not add a wait to microphone startup
or final recognition. Record actual cache hit rate during subsequent dogfood;
high accuracy on manually warmed cases alone does not establish everyday value.

Include mixed Chinese/English project names, identifiers, numbers, ordinary
sentences, phonetically similar non-hotwords, silence and noise. Keep negative
cases where an available hotword was never spoken. For each arm, record:

```text
case_id,arm,app_commit,model,cache_status,target_terms_correct,target_terms_total,edit_count,unspoken_hotword_insertions,startup_ms,first_preview_ms,release_to_raw_final_ms,release_to_delivery_ms
```

Measure startup from the trigger to capture beginning, preview from capture
beginning to the first readable preview, and both final latencies from key
release. Keep cold and warm model runs separate. Compare paired recordings;
do not select the better of repeated takes. Protect any retained audio, context
or transcript under the corpus consent and retention policy.

## Decision rule

Relative to rule-based selection, Jev must improve target-term correctness,
reduce total editing, and introduce no additional unspoken hotwords in the
negative cases. Record latency distributions and cache hit rate alongside
quality. Do not expand automatic use when this gate is unmet; retain the
experimental switch. The 0.9 ranking thresholds are conservative implementation
defaults, not calibrated business accuracy.

## Evidence status

No consented human recording corpus or production Jev quality measurement is
bundled with this change. Real microphone, key-release, delivery and quality
acceptance remain pending. Synthetic provider scores used by automated tests
must never be reported as Jev speech-recognition improvement.
