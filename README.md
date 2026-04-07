# /dispatch — Parallel Task Dispatcher for Claude Code

Plugin for Claude Code that dispatches tasks in parallel across multiple Claude sessions running in tmux. A coordinator distributes work, monitors completion via file existence checks, detects stuck workers with a watchdog, and auto-reassigns. Turns 13 hours of sequential work into 3 hours with 4 workers.

## What it does

- Distributes tasks across multiple Claude Code sessions in tmux windows
- Monitors completion by checking if expected output files exist (more reliable than screen scraping)
- Detects stuck workers with a watchdog (compares screen captures every cycle)
- Auto-injects "no subagents for web search" restriction (subagents don't inherit bypass permissions)
- Sends automatic Enter after paste to resolve the "Pasted text" buffer issue
- Supports task dependencies (DAG) — e.g., task 13 waits for tasks 1-6
- Persists state across restarts — never loses progress

## Real-world usage

**13 research tasks dispatched in parallel:**
- 6 market viability analyses by Mexican state
- 6 country expansion analyses (Peru, Ecuador, Argentina, Spain, Brazil, Dominican Republic)
- 1 consolidated report (depended on the 6 state analyses)
- 4 simultaneous workers in tmux
- Result: 13 professional .docx documents generated in ~3 hours

## Installation

1. Clone this repo into your plugins directory:
```bash
git clone https://github.com/felmarv/-claude-dispatch.git ~/plugins/dispatch
```

2. Copy the slash command to your Claude Code commands:
```bash
cp ~/plugins/dispatch/commands/dispatch.md ~/.claude/commands/dispatch.md
```

3. `/dispatch` is now available in Claude Code — no restart needed.

## Usage

```bash
# Dispatch tasks from a file
/dispatch run tasks.txt

# Dispatch with options
/dispatch run tasks.txt --workers 6 --interval 30

# Check progress
/dispatch status

# Stop the dispatcher (workers finish current task)
/dispatch stop

# Retry a failed task
/dispatch retry 5

# Retry all failed tasks
/dispatch retry --failed
```

## Task file format

```
# Lines starting with # are comments
# Format: ID|TYPE|NAME|OUTPUT_PATH|INSTRUCTION

1|research|California|/path/to/output.docx|Research California as a market...
2|research|Texas|/path/to/output.docx|Research Texas as a market...
3|consolidated|Summary|/path/to/summary.docx|Read documents 1-2 and consolidate... depends_on:1,2
```

| Field | Description |
|-------|-------------|
| ID | Sequential integer, unique |
| TYPE | Category for grouping (your choice) |
| NAME | Short name for logs |
| OUTPUT_PATH | Full path to expected output file — used for completion detection |
| INSTRUCTION | Complete prompt for Claude. Must be self-contained. |

## Architecture

```
┌──────────────┐     ┌──────────────┐     ┌─────────────────────┐
│ Task file    │────▶│  Dispatcher   │────▶│   tmux workers      │
│ (tasks.txt)  │     │  (v3, bash)   │     │   (Claude sessions) │
└──────────────┘     └──────┬───────┘     └─────────┬───────────┘
                            │                        │
                    ┌───────▼───────┐        ┌───────▼───────┐
                    │  state.txt    │        │  output files │
                    │  dispatch.log │        │  (.docx, etc) │
                    └───────────────┘        └───────────────┘
```

**Hybrid approach:** Claude parses tasks and launches the bash dispatcher in the background. The bash script handles the monitoring loop (every 60s). Claude remains available for `/dispatch status` and `/dispatch retry`.

## Known bugs (11 documented)

All discovered during real-world usage. See [BUGS.md](BUGS.md) for full details with root causes and solutions.

| # | Bug | Severity | Status |
|---|-----|----------|--------|
| 1 | Premature idle detection | High | Fixed (cooldown) |
| 2 | /clear + instruction as separate steps | Medium | Fixed (no /clear) |
| 3 | init_state overwrites progress | High | Fixed (check exists) |
| 4 | Pasted text not executed | High | Fixed (extra Enter) |
| 5 | Subagents don't inherit web search permissions | Medium | Fixed (inject restriction) |
| 6 | Residual text from dead session | Low | Manual (recreate window) |
| 7 | "Pasted text" needs extra Enter | High | Fixed (sleep 3 + Enter) |
| 8 | Doesn't track externally assigned tasks | Medium | Fixed (independent idle check) |
| 9 | Idle detection fails with long output | High | Fixed (last line only) |
| 10 | **Doesn't detect stuck workers** | **Critical** | **Fixed in V3 (watchdog)** |
| 11 | Task sent to window with existing conversation | Low | Accepted trade-off |

## Project structure

```
plugins/dispatch/
├── README.md                              # This file
├── BUGS.md                                # 11 bugs with root causes and fixes
├── ARCHITECTURE.md                        # System diagrams and flow
├── dispatcher_v3.sh                       # Bash dispatcher with watchdog
├── commands/
│   └── dispatch.md                        # Slash command for Claude Code
├── skills/dispatch/
│   ├── SKILL.md                           # Full skill prompt (the brain)
│   └── references/
│       ├── detection-rules.md             # Idle/done/stuck detection rules
│       └── tmux-patterns.md               # tmux command reference
├── knowledge/
│   ├── dispatcher_v2.sh                   # Original script (reference)
│   ├── tasks-example.txt                  # Real task file (13 tasks)
│   ├── task-format.md                     # Task format documentation
│   ├── idle-detection.md                  # How idle detection works
│   ├── tmux-integration.md                # tmux send-keys patterns
│   └── watchdog-design.md                 # Watchdog design document
├── session-log/
│   └── timeline.md                        # Build session timeline
└── future/
    └── skill-design.md                    # Future improvements roadmap
```

## Requirements

- macOS with tmux installed
- Claude Code CLI
- Multiple Claude Code sessions (each uses ~200-300 MB RAM)
- Practical limit: ~4-5 workers on 8 GB RAM

## License

MIT
