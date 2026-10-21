# Working on Rill

Use [CONTRIBUTING.md](CONTRIBUTING.md) for development commands, generated
files, validation, and Git delivery conventions. Check the current implementation
before relying on older plans or acceptance notes.

Working notes (research, plans, acceptance records) live in `.agents/notes/`,
indexed by `.agents/notes/README.md`; read them on demand and never treat them as
current truth. Formal docs (`docs/`, README, CONTRIBUTING, site pages) must not
reference notes; only AGENTS.md, skills, and the notes index may point to them.

Keep notes sparse and brief. Update an existing note first; create a new file
only for distinct, lasting context. Record conclusions, essential evidence,
and open questions; omit task diaries, transcripts, and full logs.

## Repository layout

- Preserve the existing repository layout. Do not add new tracked directories,
  including under `.github/`, without the user's explicit request or approval.
- Do not commit PR screenshots, screen recordings, or temporary acceptance
  artifacts. Attach media to the PR and keep local evidence in the ignored
  `.artifacts/` directory.
- Preserve unrelated working-tree changes; do not overwrite them or fold
  another task's edits into the current PR.

## Delivery and reporting

- Wait until every check for the current head commit has finished before
  reporting CI as passing; never reuse a green result from an older commit.
- After a base or head update, recheck the affected validation. In a dependent
  stack, fix the owning layer before propagating the repair upward.
- Keep detailed validation records with the source revision and actual
  environment. Distinguish local checks, hosted CI, and observed interaction;
  report failed prerequisites and unexecuted stages explicitly.

## Pull requests

Independent changes should be separate PRs targeting `main`, even when created
in the same conversation. Use a linear GitHub native stack only for real code
dependencies; each dependent PR targets the branch it needs.

PRs that change UI must include screenshots in the PR body, as specified in
[CONTRIBUTING.md](CONTRIBUTING.md) and the PR template.

Omit task diaries, stack bookkeeping, full hashes, source fingerprints, and
local artifact paths from the PR body. Keep those details in local validation
records. List unfinished acceptance in the current PR's limitations, not as
roadmap work, and do not invent future work to fill an optional section.

## Maintaining shared documentation

Keep CONTRIBUTING focused on setup, validation, and PR requirements. Link to
configuration for versions and checksums instead of copying them into the guide.
Keep build details in [docs/development.md](docs/development.md) and domain details
in their reference documents.
Agent-specific task, orchestration, and reporting instructions belong here or
in the matching repository skill.

## Repository skills

Load the skill that matches the task. Combine skills only when the work crosses
their boundaries; an ordinary edit does not require running all six workflows.

| Task | Skill |
| --- | --- |
| Review a PR, commit range, or working-tree change | [rill-code-review](.agents/skills/rill-code-review/SKILL.md) |
| Change workflow TOML, built-ins, compilation, or ordered execution | [rill-workflow-change](.agents/skills/rill-workflow-change/SKILL.md) |
| Change Record storage, memberships, routing, capture, or delivery | [rill-record-change](.agents/skills/rill-record-change/SKILL.md) |
| Diagnose recording, worker, cancellation, or shutdown failures | [rill-runtime-debug](.agents/skills/rill-runtime-debug/SKILL.md) |
| Verify macOS interaction, permissions, focus, or release artifacts | [rill-macos-qa](.agents/skills/rill-macos-qa/SKILL.md) |
| Change visual presentation, materials, type, or floating chrome | [rill-ui-change](.agents/skills/rill-ui-change/SKILL.md) |

Link to the project contracts from skills rather than maintaining another copy.

## Project contracts

- [Development and build reference](docs/development.md)
- [Architecture and state ownership](docs/architecture.md)
- [Record storage and delivery](docs/record-architecture.md)
- [Workflow TOML and execution](docs/workflow-toml.md)
- [UI direction](docs/ui-direction.md)
- [macOS and release acceptance](docs/release-qa-checklist.md)
