# Working on Rill

Use [CONTRIBUTING.md](CONTRIBUTING.md) for development commands, generated
files, validation, and Git delivery conventions. Check the current implementation
before relying on older plans or acceptance notes.

## Repository skills

Load the skill that matches the task. Combine skills only when the work crosses
their boundaries; an ordinary edit does not require running all five workflows.

| Task | Skill |
| --- | --- |
| Review a PR, commit range, or working-tree change | [rill-code-review](.agents/skills/rill-code-review/SKILL.md) |
| Change workflow TOML, built-ins, compilation, or ordered execution | [rill-workflow-change](.agents/skills/rill-workflow-change/SKILL.md) |
| Change Record storage, memberships, routing, capture, or delivery | [rill-record-change](.agents/skills/rill-record-change/SKILL.md) |
| Diagnose recording, worker, cancellation, or shutdown failures | [rill-runtime-debug](.agents/skills/rill-runtime-debug/SKILL.md) |
| Verify macOS interaction, permissions, focus, or release artifacts | [rill-macos-qa](.agents/skills/rill-macos-qa/SKILL.md) |

These skills are maintained with this repository and require no personal skill
installation. Keep shared project facts in the documents below and link to them
from skills rather than maintaining another copy.

## Project contracts

- [Architecture and state ownership](docs/architecture.md)
- [Record storage and delivery](docs/record-architecture.md)
- [Workflow TOML and execution](docs/workflow-toml.md)
- [UI direction](docs/ui-direction.md)
- [macOS and release acceptance](docs/release-qa-checklist.md)
