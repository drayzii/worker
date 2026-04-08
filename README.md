# worker

`worker` is a local autonomous software-engineering loop designed for a dedicated always-on Mac.

It initializes a project, runs a controller/executor/escalation workflow inside `tmux`, persists project state in plain files, and lets you resume, redirect, inspect, pause, or kill work from the terminal.

This repo is optimized for one stable host machine, not generic multi-machine portability.

## What it does

- Uses a role-based loop:
  - `controller` plans and reviews
  - `executor` implements the current task
  - `escalation` handles blockers
- Stores workflow state in the project itself
- Uses Docker Compose as the default local-resource strategy for fresh projects
- Supports `codex` and `claude` as interchangeable providers for each role
- Refreshes `graphify` context at key points and injects `GRAPH_REPORT.md` into agent briefs

## Host assumptions

This setup assumes:

- it is usually plugged in
- `tmux` sessions can run for long periods
- local auth state for Codex and Claude persists on that machine
- projects can be resumed later without reconstructing context from scratch

## Required tools

Minimum tools expected on the host:

- `bash`
- `zsh`
- `python3`
- `git`
- `tmux`
- `docker` and `docker compose`
- `jq`
- `curl`
- `codex`
- `claude`

Optional but expected for the full workflow:

- `graphify`
- whatever backing environment `graphify` needs for LLM-backed extraction
- a local Ollama-style model endpoint if you want the generated `.worker/tools/local-llm` shim to work

## Auth

Both providers are used as local CLIs.

- `codex` is invoked with `codex exec --json ...`
- `claude` is invoked with `claude -p ...`

For this setup to work reliably on the host machine:

- `codex` must already be installed and authenticated
- `claude` must already be installed and authenticated
- that auth state must survive normal reboots and unattended runs

If either provider is not authenticated, the worker loop writes a blocker into `.worker/status.md` and stops.

## Install

Make the public commands available on `PATH`.

Example:

```zsh
export PATH="/Users/drayzii/apps/worker:$PATH"
source /Users/drayzii/apps/worker/shell/worker-shortcuts.zsh
```

The shortcuts file gives you:

- `wn` → `worker-new .`
- `wc` → `worker-continue .`
- `wr` → `worker-redirect .`
- `ws` → `worker-status .`
- `wp` → `worker-pause .`
- `wk` → `worker-kill .`

Note:

- `wc` overrides the normal shell `wc` command in interactive sessions if you source the shortcuts file.

## Project model

This repo no longer creates project folders for you.

You create the project directory yourself, then initialize inside it.

Typical flow:

1. Create a repo or folder.
2. Add `PRD.md` if you have one.
3. `cd` into the project.
4. Run `worker-new .`
5. Resume with `worker-continue .`

Project selection rules:

- `.` means the current directory
- an explicit path works
- a bare name still resolves to `~/Projects/<name>` for backward compatibility

## Required project inputs

`worker-new` requires one of:

- a trailing prompt
- `PRD.md` in the project root

If both exist, both are written into `.worker/initial-prompt.txt`.

Examples:

```zsh
cd /path/to/project
worker-new .
```

```zsh
cd /path/to/project
worker-new . "Build a multi-tenant admin dashboard"
```

```zsh
worker-new my-project "Build a notes app"
```

## Public commands

### `worker-new`

Initializes an existing project directory and starts the worker runner in `tmux`.

Usage:

```text
worker-new <project-name|.|path> [--controller codex|claude] [--executor codex|claude] [--escalation codex|claude] [project prompt...]
```

Defaults:

- controller: `codex`
- executor: `codex`
- escalation: `claude`

### `worker-continue`

Resumes a project from the current repo state and the persisted worker artifacts.

Usage:

```text
worker-continue <project-name|.|path> [--controller codex|claude] [--executor codex|claude] [--escalation codex|claude] [extra instructions...]
```

### `worker-redirect`

Stops the active session, asks the controller to rewrite workflow artifacts only, and leaves the project ready to resume.

Usage:

```text
worker-redirect <project-name|.|path> <redirect instructions...>
```

### `worker-status`

Prints:

- `TASK.md`
- `REVIEW.md`
- `.worker/status.md`

Usage:

```text
worker-status <project-name|.|path>
```

### `worker-pause`

Stops the active runner process and `tmux` session without removing project artifacts.

Usage:

```text
worker-pause <project-name|.|path>
```

### `worker-kill`

Kills the `tmux` session and, if compose files are present, also stops Docker Compose services.

Usage:

```text
worker-kill <project-name|.|path> [--purge-volumes]
```

## Workflow artifacts written into the project

Project root:

- `PRD.md` optional input
- `WORKER.md`
- `PLAN.md`
- `TASK.md`
- `REVIEW.md`
- `graphify-out/` if `graphify` runs successfully

`.worker/`:

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
- `.worker/tools/local-llm`
- `.worker/logs/run.log`
- `.worker/logs/current-run.ndjson`

## Current workflow model

The workflow is milestone-centric.

- `PLAN.md` defines milestones
- `TASK.md` contains the single current task
- subtasks live inside `SCOPE`, `ACCEPTANCE`, and `VALIDATION`
- the controller owns task transitions

High-level loop:

1. `controller_plan`
2. `executor`
3. `controller_review`
4. repeat execution/review until complete
5. `escalation` only when routed explicitly or after repeated executor failure

The controller writes the initial `TASK.md` during planning.
After that, `controller_review` normally writes the next or revised `TASK.md`.

## Git lifecycle rules

The intended model is:

- one branch per current `TASK.md`
- commits as subtasks are completed
- local merge before moving to the next task
- no PRs, no remotes, no deploy steps unless explicitly requested

This policy is encoded in:

- `prompts/system-prompt.txt`
- `templates/WORKER.md`
- `prompts/controller-review.txt`

## Docker Compose rules

For fresh projects, the workflow is container-first.

That means:

- required local resources should be defined through Docker Compose
- if compose files do not exist yet, the workflow should create them
- `worker-kill` will stop Compose services if it finds:
  - `docker-compose.yml`
  - `docker-compose.yaml`
  - `compose.yml`
  - `compose.yaml`

## Prompts and templates

Repo-owned prompts live in:

- `prompts/system-prompt.txt`
- `prompts/controller-plan.txt`
- `prompts/executor.txt`
- `prompts/controller-review.txt`
- `prompts/escalation.txt`
- `prompts/redirect.txt`

Repo-owned templates live in:

- `templates/WORKER.md`
- `templates/status.md`
- `templates/continue-extra.txt`

These are the source of truth for workflow behavior. The scripts load them at runtime.

## Graphify integration

Current integration style:

- file-based
- provider-agnostic
- no MCP integration in this repo yet

What happens:

- `worker-new` refreshes graph context
- `worker-continue` refreshes graph context
- `worker-redirect` refreshes graph context
- `worker-runner` refreshes graph context after executor turns
- `worker-runner` refreshes graph context after escalation turns

The worker expects graphify output in:

- `graphify-out/GRAPH_REPORT.md`
- `graphify-out/graph.json`
- `graphify-out/graph.html`
- `graphify-out/cache/`

The briefs inject `GRAPH_REPORT.md` into:

- controller brief
- executor brief
- review brief
- escalation brief

So agents use graphify indirectly through the generated brief files.

### Graphify command

By default the worker runs:

```text
graphify
```

from the project root.

You can override that with:

```zsh
export WORKER_GRAPHIFY_CMD='graphify . --update'
```

If `graphify` is not installed or not on `PATH`, the worker logs a skip and continues.

### Important note about graphify provider access

This repo does not talk to graphify through MCP or a provider-specific hook.

It simply shells out to the `graphify` CLI and consumes the generated files afterward.

That means:

- Codex and Claude both benefit from graphify in this project
- because both of them read the same brief files
- not because this repo installs graphify-specific assistant hooks

## Local model shim

`worker-new` creates `.worker/tools/local-llm`, which points to this repo’s internal:

- `libexec/local-llm.sh`

That script expects a local HTTP model endpoint at:

```text
http://127.0.0.1:11434/api/generate
```

The prompts explicitly forbid local models from owning planning, review, debugging strategy, or test-loop control. They are only intended for tiny safe helper tasks.

## Logs and state

Durable per-project runtime state lives in the project itself.

Most important files:

- `.worker/logs/run.log`
- `.worker/logs/current-run.ndjson`
- `.worker/status.md`
- `.worker/runtime.env`
- `.worker/roles.env`

For a remote inspection workflow, these are the first files to check.

## Example daily usage

Fresh project:

```zsh
mkdir my-app
cd my-app
git init
echo "# Product Requirements" > PRD.md
worker-new .
```

Resume:

```zsh
cd my-app
worker-continue .
```

Redirect:

```zsh
cd my-app
worker-redirect . "Stop polishing UI and finish auth first"
```

Inspect:

```zsh
cd my-app
worker-status .
```

Pause:

```zsh
cd my-app
worker-pause .
```

Kill:

```zsh
cd my-app
worker-kill . --purge-volumes
```

## Known current behaviors

- The worker loop is built around `tmux`.
- Provider failures become blockers in `.worker/status.md`.
- A project can be resumed with different role-provider assignments.
- The repo currently exposes only the public commands listed above.
- Internal implementation scripts live under `lib/` and `libexec/`.

## Repo layout

```text
worker/
├── lib/                  shared shell helpers
├── libexec/              internal executables
├── prompts/              workflow prompts
├── templates/            generated file templates
├── shell/                convenience shell wrappers
├── worker-new
├── worker-continue
├── worker-redirect
├── worker-pause
├── worker-status
└── worker-kill
```
