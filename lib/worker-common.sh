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
  PROMPTS_DIR="$REPO_DIR/prompts"
  TEMPLATES_DIR="$REPO_DIR/templates"
  SYSTEM_PROMPT_FILE="$REPO_DIR/prompts/system-prompt.txt"
  RUNNER_BIN="$REPO_DIR/libexec/worker-runner.sh"
  LOCAL_LLM_BIN="$REPO_DIR/libexec/local-llm.sh"
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
