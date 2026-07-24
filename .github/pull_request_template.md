## User impact

Describe the user-visible problem and the resulting behavior.

## Scope and boundaries

List the components changed and any intentionally deferred work.

## Risk and rollback

- Risk level and failure modes:
- Privacy, security, persistence, or migration impact:
- Rollback plan:

## Automated evidence

- [ ] `prek -c prek.toml run --all-files`
- [ ] `bash scripts/preflight.sh`
- [ ] Additional focused tests are listed below

Evidence class (`working-source` or `clean-tagged-candidate`):

Test summary (`discovered / passed / skipped / failures`):

Expected skips (name and reason, or `none`):

Signing identity and distribution status (`unsigned`, `ad hoc`,
`Apple Development — local only`, or `Developer ID — notarized candidate`):

Do not describe an ad-hoc- or Apple Development-signed build as publicly
distributable.

Focused tests and results:

## Manual QA

List the packaged-App scenarios exercised, including macOS version, hardware
architecture, input method, and App language. Call out any required release QA
that remains unverified.

## Release notes

State whether release notes, documentation, stored-data migration, or a known
limitation update is required.
