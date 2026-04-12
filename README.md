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
- `tailscale`
- `codex`
- `claude`

Optional:

- Stitch MCP configured in the provider environment
- a local Ollama-style endpoint if you want `.worker/tools/local-llm`
- Slack incoming webhook if you want notifications

Auth:

- `codex` must already be installed and logged in
- `claude` must already be installed and logged in
- `tailscale` must already be installed, logged in, and allowed to use Funnel on this node

Shell setup:

```zsh
export WORKER_HOME="/path/to/worker"
chmod +x "$WORKER_HOME"/worker-* "$WORKER_HOME"/libexec/*.sh "$WORKER_HOME"/shell/*.zsh
export PATH="$WORKER_HOME:$PATH"
source "$WORKER_HOME"/shell/worker-shortcuts.zsh
```

Shortcuts:

- `wn` -> `worker-new .`
- `wcont` -> `worker-continue .`
- `wr` -> `worker-redirect .`
- `ws` -> `worker-status .`
- `wp` -> `worker-pause .`
- `wk` -> `worker-kill .`
- `wsb` -> `worker-stitch-bind .`
- `wprd` -> `worker-prd . ...`
- `wt` -> `worker-test . ...`
- `wts` -> `worker-test-status .`

### Provider setup

#### Codex

- Install and authenticate `codex`.
- Add the Stitch MCP server to Codex using your Stitch MCP registration details.
- Verify MCP servers with:

```zsh
codex mcp list
```

#### Claude

- Install and authenticate `claude`.
- Add Stitch MCP in Claude Code using the Stitch MCP setup flow for Claude Code.
- Verify the Stitch server is available in your Claude Code MCP configuration before using `worker`.

#### Slack

- Set a Slack incoming webhook URL if you want run notifications:

```zsh
export WORKER_SLACK_WEBHOOK_URL="https://hooks.slack.com/services/..."
```

- Notifications are sent when:
  - a task is completed
  - a provider blocks the run
  - a task reaches 5 iterations
  - a task runs longer than 15 minutes
  - the project is completed
  - `worker-test` produces preview URLs

#### Tailscale Preview Auth

- Set a reusable Tailscale auth key for preview sidecars:

```zsh
export WORKER_TAILSCALE_AUTHKEY="tskey-..."
```

- Recommended key properties:
  - reusable
  - pre-approved if your tailnet uses device approval
  - ephemeral enabled if you want preview nodes to disappear when logged out
  - tagged if your tailnet policy restricts Funnel to specific tags or node identities

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

`worker-prd`

```text
worker-prd <project-name|.|path> <codex|claude>
```

Asks a short set of optional PRD questions, combines your answers with the repo's minimal PRD template, and writes `PRD.md`.
It also writes `STITCH_PROMPT.md` as a starter document for generating first-pass Stitch screens from the same answers.

`worker-test`

```text
worker-test <project-name|.|path> <codex|claude> [notes...]
```

Generates `.worker/test-stack.json` using the selected provider, starts the Docker stack, and exposes the detected services through Tailscale Funnel paths.

`worker-test-status`

```text
worker-test-status <project-name|.|path>
```

Shows the configured test preview URLs and checks whether the Funnel paths appear active.

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
- `STITCH_PROMPT.md`
- `WORKER.md`
- `PLAN.md`
- `TASK.md`
- `REVIEW.md`

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
- `.worker/test-stack.json`
- `.worker/test-runtime.json`
- `.worker/test.env`
- `.worker/tailscale-previews.compose.yml`
- `.worker/tailscale/`
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

## Test Previews

`worker-test` uses the selected provider to inspect the Dockerized project and write `.worker/test-stack.json`.

Then it:

- derives the tailnet domain from the host Tailscale client
- computes one Tailscale hostname per exposed service
- writes `.worker/tailscale-previews.compose.yml`
- injects any preview env vars needed by the app into the compose override
- runs `docker compose up -d`
- starts one Tailscale sidecar per exposed service
- enables Funnel inside each sidecar so every service gets its own public hostname
- sends the preview URL summary to Slack if `WORKER_SLACK_WEBHOOK_URL` is set

`worker-test-status` reads the saved runtime and shows the preview URLs.

Project completion automatically:

- runs `worker-test` with the controller provider
- sends the preview summary to Slack
- then pauses the worker session automatically

Setup expectation:

- Stitch MCP must be installed in the same provider runtime that `worker` uses
- Codex roles use the Codex MCP configuration
- Claude roles use the Claude Code MCP configuration
- bind the project locally with `worker-stitch-bind` after provider-side Stitch setup is working

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
├── worker-prd
├── worker-test
├── worker-test-status
├── worker-redirect
├── worker-pause
├── worker-status
└── worker-kill
```
