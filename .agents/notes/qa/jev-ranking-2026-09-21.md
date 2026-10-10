# Optional Jev clipboard ranking verification

Date: 2026-09-21. Base: PR #15, `f68189ca362719ac502b4623be6099f997ac9ceb`.
Owning branch: `codex/jev-clipboard-ranking`. Environment: macOS 27, arm64;
the deployment target remains macOS 14.

## Automated evidence

- Provider fixtures exercise fixed URL/model/body and score-ID mapping, authentication,
  rate limits, server errors, invalid score/model/usage payloads, bounded input, header
  injection rejection, pre-send cancellation and the absence of automatic retries.
  Fixtures intercept URLSession; no real account or paid request is used.
- Runtime fixtures exercise exact reviewed text, Unicode-safe clipping, file basenames,
  explicit one-use confirmation, missing keys, source restrictions, unavailable privacy,
  deletion and privacy changes before/during requests, and shutdown of a provider that
  ignores cancellation. Ranking leaves the Record catalog unchanged.
- UI state tests exercise actual workspace/quick-panel composition, filtered candidate
  scope, preserved list order/selection, query invalidation, late-result rejection,
  closed-panel submission rejection, and session-key lifetime.
- Native AppKit renders cover the Chinese/light and English/dark review/result sheets.
  Screenshot files are under the owning checkout's ignored `.artifacts/jev-renders`.
  All scores in these renders are deterministic fixtures, not measured Jev quality.

## Remaining acceptance

These tests and renders do not establish live TypeSafe availability or ranking quality.
The fixtures use a simulated provider; no real credentials or paid requests are used.
The existing installed Rill app was not replaced. Hosted CI is reported separately on
this branch's exact PR head; local development signing is not release trust evidence.

On a build of this branch, with harmless sample records:

1. Search `git`, open **Compare with Jev**, inspect the query and candidate excerpts.
   Confirm opening/review/key entry does not itself contact the provider.
2. Enter a test account key, save it, then explicitly send. Check that the secure field
   releases focus, a real response shows scores/usage, and choosing a record selects it
   without pasting or changing the local list order. Clear the key afterwards.
3. Exercise Return, Escape, IME composition, VoiceOver labels/values and Tab order in
   the floating panel's attached sheet; Escape must cancel only the sheet first.
4. Close during a slow request; reopen/change query and confirm no old response appears.
   Test invalid/revoked keys, unavailable network and sensitive-source restrictions.
   A request already sent may still be billed; Rill does not retry it automatically.
5. Verify explicit paste returns to the original target app after selecting a result.
   Repeat the affected interaction on macOS 14 and the intended release artifact.
