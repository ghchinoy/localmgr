# AGENTS.md

## Progressive Agent Onboarding & Context

To gain a progressive, comprehensive understanding of **LocalMgr**, agents should follow this reading hierarchy:
1. **[GEMINI.md](GEMINI.md)**: Start here for the core project overview, architecture stack, build commands (`make app`), and key service roles.
2. **[docs/](docs/) Directory**: Review the deep-dive architectural blueprints and Core User Journeys:
   - [docs/ARCHITECTURE_PLAN.md](docs/ARCHITECTURE_PLAN.md): Detailed multi-backend architecture, system diagrams, and engine routing.
   - [docs/USER_JOURNEYS.md](docs/USER_JOURNEYS.md): Mapped CUJs (`CUJ-1`, `CUJ-2`, `CUJ-3`), issue tracking IDs, and Diátaxis documentation alignment.

---

## Issue Tracking

This project uses **bd (beads)** for issue tracking.
Run `bd prime` for workflow context, or install hooks (`bd hooks install`) for auto-injection.

**Quick reference:**
- `bd ready` - Find unblocked work
- `bd create "Title" --type task --priority 2` - Create issue
- `bd close <id>` - Complete work
- `bd dolt push` - Push beads to remote

For full workflow details: `bd prime`
