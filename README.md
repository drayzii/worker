# worker

`worker` is a local autonomous engineering loop for a dedicated always-on Mac.

It runs a `controller -> executor -> review -> escalation` workflow in `tmux`, keeps state in project files, and is designed for existing project folders rather than creating repos for you.

## Setup

Requirements:

- `bash`
- `zsh`
- `python3`
- `git`
- `tmux`
- `docker` and `docker compose`
- `codex`
- `claude`

Optional:

- `graphify`
- Stitch MCP configured in the provider environment
- a local Ollama-style endpoint if you want `.worker/tools/local-llm`

Auth:

- `codex` must already be installed and logged in
- `claude` must already be installed and logged in

Shell setup:

```zsh
export WORKER_HOME="/path/to/worker"
chmod +x "$WORKER_HOME"/worker-* "$WORKER_HOME"/libexec/*.sh "$WORKER_HOME"/shell/*.zsh
export PATH="$WORKER_HOME:$PATH"
source "$WORKER_HOME"/shell/worker-shortcuts.zsh
```

Shortcuts:

- `wn` -> `worker-new .`
- `wc` -> `worker-continue .`
- `wr` -> `worker-redirect .`
- `ws` -> `worker-status .`
- `wp` -> `worker-pause .`
- `wk` -> `worker-kill .`
- `wsb` -> `worker-stitch-bind .`

Note: `wc` overrides the normal shell `wc` command in interactive sessions.

### Provider setup

#### Codex

- Install and authenticate `codex`.
- Add the Stitch MCP server to Codex using your Stitch MCP registration details.
- Verify MCP servers with:

```zsh
codex mcp list
```

- If you use graphify with Codex:

```zsh
pip install graphifyy
graphify install --platform codex
graphify codex install
```

- Enable Codex multi-agent support for graphify in `~/.codex/config.toml`:

```toml
[features]
multi_agent = true
```

- In Codex, graphify is typically invoked as:

```text
$graphify .
```

#### Claude

- Install and authenticate `claude`.
- Add Stitch MCP in Claude Code using the Stitch MCP setup flow for Claude Code.
- Verify the Stitch server is available in your Claude Code MCP configuration before using `worker`.
- If you use graphify with Claude Code:

```zsh
pip install graphifyy
graphify install
graphify claude install
```

- In Claude Code, graphify is typically invoked as:

```text
/graphify .
```

## Quick Start

```zsh
mkdir my-app
cd my-app
git init
echo "# Product Requirements" > PRD.md
worker-new .
```

Resume later:

```zsh
worker-continue .
```

## Project Model

- You create the project directory yourself.
- `worker-new` initializes inside an existing folder.
- It requires either a prompt or `PRD.md`.
- `.` means current directory.
- A full or relative path also works.
- A bare name still resolves to `~/Projects/<name>` for backward compatibility.

## Commands

`worker-new`

```text
worker-new <project-name|.|path> [--controller codex|claude] [--executor codex|claude] [--escalation codex|claude] [project prompt...]
```

Defaults:

- controller: `codex`
- executor: `codex`
- escalation: `claude`

`worker-continue`

```text
worker-continue <project-name|.|path> [--controller codex|claude] [--executor codex|claude] [--escalation codex|claude] [extra instructions...]
```

`worker-redirect`

```text
worker-redirect <project-name|.|path> <redirect instructions...>
```

`worker-status`

```text
worker-status <project-name|.|path>
```

`worker-pause`

```text
worker-pause <project-name|.|path>
```

`worker-kill`

```text
worker-kill <project-name|.|path> [--purge-volumes]
```

`worker-stitch-bind`

```text
worker-stitch-bind <project-name|.|path> <stitch-project-id> [--workspace <id>] [--name <name>] [--url <url>]
```

## Workflow

- `PLAN.md` defines milestones.
- `TASK.md` holds one current task.
- Subtasks live inside `SCOPE`, `ACCEPTANCE`, and `VALIDATION`.
- The controller owns planning, review, task transitions, and the local git lifecycle.
- The executor implements the current task.
- Escalation handles blockers only.

Git policy:

- one local branch per `TASK.md`
- commit as subtasks complete
- merge locally before the next task
- no remotes, PRs, or deploy steps unless explicitly requested

Infra policy:

- fresh projects are container-first
- required local resources should be defined with Docker Compose

## Files

Project root:

- `PRD.md`
- `WORKER.md`
- `PLAN.md`
- `TASK.md`
- `REVIEW.md`
- `graphify-out/` if `graphify` runs

Runtime state:

- `.worker/status.md`
- `.worker/roles.env`
- `.worker/runtime.env`
- `.worker/ACTIVE.pid`
- `.worker/initial-prompt.txt`
- `.worker/continue-extra.txt`
- `.worker/controller-brief.md`
- `.worker/executor-brief.md`
- `.worker/review-brief.md`
- `.worker/escalation-brief.md`
- `.worker/redirect-brief.md`
- `.worker/stitch.json`
- `.worker/logs/run.log`
- `.worker/logs/current-run.ndjson`

## Stitch

Binding file:

- `.worker/stitch.json`

Usage:

```zsh
worker-stitch-bind . stitch-project-123 --name "My App"
```

Behavior:

- the binding file stores project identity
- the providers are instructed to use Stitch MCP directly
- controller uses it during planning and review when bound
- executor uses it on demand for exact screens, assets, and specs

This repo does not shell out to Stitch directly. Stitch is used through the provider environment.

Setup expectation:

- Stitch MCP must be installed in the same provider runtime that `worker` uses
- Codex roles use the Codex MCP configuration
- Claude roles use the Claude Code MCP configuration
- bind the project locally with `worker-stitch-bind` after provider-side Stitch setup is working

## Graphify

If `graphify` is installed, the worker refreshes graph context at key points and injects `graphify-out/GRAPH_REPORT.md` into the role briefs.

Provider notes:

- Codex: `graphify install --platform codex` and `graphify codex install`
- Claude Code: `graphify install` and `graphify claude install`
- Codex uses `$graphify ...`
- Claude Code uses `/graphify ...`

Default command:

```text
graphify
```

Override if needed:

```zsh
export WORKER_GRAPHIFY_CMD='graphify . --update'
```

## Repo Layout

```text
worker/
├── lib/
├── libexec/
├── prompts/
├── templates/
├── shell/
├── worker-new
├── worker-continue
├── worker-stitch-bind
├── worker-redirect
├── worker-pause
├── worker-status
└── worker-kill
```
