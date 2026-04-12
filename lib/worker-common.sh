#!/usr/bin/env bash

worker_repo_dir() {
  local source_file="${BASH_SOURCE[0]}"
  while [ -h "$source_file" ]; do
    source_file="$(readlink "$source_file")"
  done
  cd "$(dirname "$source_file")/.." && pwd
}

worker_set_project_paths_from_name() {
  local name="$1"
  BASE="$HOME/Projects/$name"
  SESSION="worker-$name"
  worker_set_project_paths_from_base "$BASE"
}

worker_abs_path() {
  local target="$1"
  if [ "${target#~/}" != "$target" ]; then
    target="$HOME/${target#~/}"
  fi
  (
    cd "$target" 2>/dev/null && pwd
  )
}

worker_resolve_project_dir() {
  local selector="${1:?missing project selector}"

  if [ "$selector" = "." ]; then
    pwd
  elif [ "$selector" = ".." ] || [ "${selector#./}" != "$selector" ] || [ "${selector#../}" != "$selector" ] || [ "${selector#/}" != "$selector" ] || [ "${selector#~}" != "$selector" ] || [ "${selector#*/}" != "$selector" ]; then
    worker_abs_path "$selector"
  else
    printf '%s\n' "$HOME/Projects/$selector"
  fi
}

worker_session_name_for_base() {
  local base="$1"
  printf 'worker-%s\n' "$(basename "$base")"
}

worker_set_project_paths_from_selector() {
  BASE="$(worker_resolve_project_dir "$1")"
  SESSION="$(worker_session_name_for_base "$BASE")"
  worker_set_project_paths_from_base "$BASE"
}

worker_set_project_paths_from_base() {
  REPO_DIR="$(worker_repo_dir)"
  BASE="$1"
  LOG_DIR="$BASE/.worker/logs"
  LOG_FILE="$LOG_DIR/run.log"
  TEMP_FILE="$LOG_DIR/current-run.ndjson"
  STATE_FILE="$BASE/.worker/runtime.env"
  ACTIVE_FILE="$BASE/.worker/ACTIVE.pid"
  ROLES_FILE="$BASE/.worker/roles.env"
  STATUS_FILE="$BASE/.worker/status.md"
  PLAN_FILE="$BASE/PLAN.md"
  TASK_FILE="$BASE/TASK.md"
  REVIEW_FILE="$BASE/REVIEW.md"
  INITIAL_PROMPT_FILE="$BASE/.worker/initial-prompt.txt"
  EXTRA_FILE="$BASE/.worker/continue-extra.txt"
  CONTROLLER_BRIEF_FILE="$BASE/.worker/controller-brief.md"
  EXECUTOR_BRIEF_FILE="$BASE/.worker/executor-brief.md"
  REVIEW_BRIEF_FILE="$BASE/.worker/review-brief.md"
  ESCALATION_BRIEF_FILE="$BASE/.worker/escalation-brief.md"
  REDIRECT_BRIEF_FILE="$BASE/.worker/redirect-brief.md"
  WORKER_RULES_FILE="$BASE/WORKER.md"
  STITCH_BINDING_FILE="$BASE/.worker/stitch.json"
  TEST_STACK_FILE="$BASE/.worker/test-stack.json"
  TEST_RUNTIME_FILE="$BASE/.worker/test-runtime.json"
  TEST_ENV_FILE="$BASE/.worker/test.env"
  TEST_PREVIEW_COMPOSE_FILE="$BASE/.worker/tailscale-previews.compose.yml"
  TEST_TAILSCALE_DIR="$BASE/.worker/tailscale"
  PROMPTS_DIR="$REPO_DIR/prompts"
  TEMPLATES_DIR="$REPO_DIR/templates"
  SYSTEM_PROMPT_FILE="$REPO_DIR/prompts/system-prompt.txt"
  RUNNER_BIN="$REPO_DIR/libexec/worker-runner.sh"
  LOCAL_LLM_BIN="$REPO_DIR/libexec/local-llm.sh"
}

read_prompt_file() {
  local prompt_name="$1"
  cat "$PROMPTS_DIR/$prompt_name"
}

read_template_file() {
  local template_name="$1"
  cat "$TEMPLATES_DIR/$template_name"
}

worker_require_project_dir() {
  if [ ! -d "$BASE" ]; then
    echo "Project not found: $BASE" >&2
    exit 1
  fi
}

worker_init_project_dirs() {
  mkdir -p "$BASE/.worker/tools" "$LOG_DIR"
}

worker_default_roles() {
  CONTROLLER="codex"
  EXECUTOR="codex"
  ESCALATION="claude"
}

worker_load_roles() {
  if [ -f "$ROLES_FILE" ]; then
    # shellcheck disable=SC1090
    source "$ROLES_FILE"
  else
    worker_default_roles
  fi
}

worker_write_roles() {
  cat > "$ROLES_FILE" <<EOF
CONTROLLER=$CONTROLLER
EXECUTOR=$EXECUTOR
ESCALATION=$ESCALATION
EOF
}

worker_ts() {
  date '+%a %b %d %H:%M:%S %Z %Y'
}

worker_utc_now() {
  date -u '+%Y-%m-%dT%H:%M:%SZ'
}

worker_project_name() {
  basename "$BASE"
}

worker_project_slug() {
  python3 - "$BASE" <<'PY'
import pathlib, re, sys

name = pathlib.Path(sys.argv[1]).name.lower()
slug = re.sub(r'[^a-z0-9]+', '-', name).strip('-')
print(slug or "project")
PY
}

worker_notify_slack() {
  local text="$1"
  local webhook="${WORKER_SLACK_WEBHOOK_URL:-}"

  if [ -z "$webhook" ]; then
    return 0
  fi

  python3 - "$text" <<'PY' | curl -sS -X POST \
    -H 'Content-type: application/json' \
    --data @- \
    "$webhook" >/dev/null 2>&1 || {
import json, sys
print(json.dumps({"text": sys.argv[1]}))
PY
    if [ -n "${LOG_FILE:-}" ]; then
      echo "[worker] slack notification failed" >> "$LOG_FILE"
    fi
  }
}

worker_stamp_file_end() {
  local file="$1"
  local stamp="$2"
  python3 - "$file" "$stamp" <<'PY'
import pathlib, re, sys
p = pathlib.Path(sys.argv[1])
stamp = sys.argv[2]
text = p.read_text() if p.exists() else ""
text = re.sub(r'\n*UPDATED_AT:\s*[^\n]*\s*\Z', '', text, flags=re.S)
text = text.rstrip('\n')
if text:
    text += '\n\n'
text += f'UPDATED_AT: {stamp}\n'
p.write_text(text)
PY
}

worker_stamp_artifacts() {
  local stamp
  stamp="$(worker_utc_now)"
  worker_stamp_file_end "$PLAN_FILE" "$stamp"
  worker_stamp_file_end "$TASK_FILE" "$stamp"
  worker_stamp_file_end "$REVIEW_FILE" "$stamp"
  worker_stamp_file_end "$STATUS_FILE" "$stamp"
}

worker_fingerprint_files() {
  python3 - "$@" <<'PY'
import hashlib, pathlib, re, sys
parts = []
for path in sys.argv[1:]:
    p = pathlib.Path(path)
    text = p.read_text() if p.exists() else ""
    text = re.sub(r'\n*UPDATED_AT:\s*[^\n]*\s*\Z', '', text, flags=re.S)
    parts.append(text)
print(hashlib.sha256("\n---\n".join(parts).encode()).hexdigest())
PY
}

worker_provider_auth_failed() {
  grep -Eiq 'authentication_failed|Not logged in|Please run /login' "$TEMP_FILE" 2>/dev/null
}

worker_provider_hit_max_turns() {
  grep -Eiq 'error_max_turns|max turns|max_turns' "$TEMP_FILE" 2>/dev/null
}

worker_provider_noop() {
  grep -Eiq 'shall i proceed|want me to proceed|ready to proceed|acknowledged|confirmed\.|i.ve read all five files|do you want me to' "$TEMP_FILE" 2>/dev/null
}

worker_stop_active_pid() {
  if [ -f "$ACTIVE_FILE" ]; then
    local pid
    pid="$(cat "$ACTIVE_FILE" 2>/dev/null || true)"
    if [ -n "${pid:-}" ] && kill -0 "$pid" 2>/dev/null; then
      kill -TERM "$pid" 2>/dev/null || true
      sleep 1
      if kill -0 "$pid" 2>/dev/null; then
        kill -KILL "$pid" 2>/dev/null || true
      fi
      echo "Stopped runner pid: $pid"
    fi
    rm -f "$ACTIVE_FILE"
  fi
}

worker_stitch_is_bound() {
  [ -f "$STITCH_BINDING_FILE" ]
}

worker_stitch_binding_field() {
  local key="$1"
  python3 - "$STITCH_BINDING_FILE" "$key" <<'PY'
import json, pathlib, sys

path = pathlib.Path(sys.argv[1])
key = sys.argv[2]

if not path.exists():
    print("")
    raise SystemExit(0)

try:
    data = json.loads(path.read_text())
except Exception:
    print("")
    raise SystemExit(0)

value = data.get(key, "")
print("" if value is None else value)
PY
}

worker_write_stitch_binding() {
  local project_id="$1"
  local workspace_id="$2"
  local project_name="$3"
  local project_url="$4"
  local bound_at
  bound_at="$(worker_utc_now)"

  mkdir -p "$BASE/.worker"

  python3 - "$STITCH_BINDING_FILE" "$project_id" "$workspace_id" "$project_name" "$project_url" "$bound_at" <<'PY'
import json, pathlib, sys

path = pathlib.Path(sys.argv[1])
project_id, workspace_id, project_name, project_url, bound_at = sys.argv[2:7]

payload = {
    "version": 1,
    "stitch_project_id": project_id,
    "stitch_workspace_id": workspace_id or "",
    "stitch_project_name": project_name or "",
    "stitch_project_url": project_url or "",
    "bound_at": bound_at,
}

path.write_text(json.dumps(payload, indent=2) + "\n")
PY
}

worker_stitch_binding_summary() {
  python3 - "$STITCH_BINDING_FILE" <<'PY'
import json, pathlib, sys

path = pathlib.Path(sys.argv[1])
if not path.exists():
    print("")
    raise SystemExit(0)

try:
    data = json.loads(path.read_text())
except Exception:
    print("invalid stitch binding file")
    raise SystemExit(0)

fields = [
    ("project_id", data.get("stitch_project_id", "")),
    ("workspace_id", data.get("stitch_workspace_id", "")),
    ("project_name", data.get("stitch_project_name", "")),
    ("project_url", data.get("stitch_project_url", "")),
    ("bound_at", data.get("bound_at", "")),
]

for key, value in fields:
    if value:
        print(f"{key}: {value}")
PY
}
