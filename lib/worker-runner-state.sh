#!/usr/bin/env bash

save_state() {
  cat > "$STATE_FILE" <<EOF
ITERATION=$ITERATION
STAGE=$STAGE
EXECUTOR_FAILURES=$EXECUTOR_FAILURES
ESCALATION_FAILURES=$ESCALATION_FAILURES
CONTROLLER_FAILURES=$CONTROLLER_FAILURES
EOF
}

banner() {
  echo "=== $1 | $(worker_ts) ===" | tee -a "$LOG_FILE"
}

ensure_status_skeleton() {
  if ! grep -q '^STATUS:' "$STATUS_FILE" 2>/dev/null; then
    read_template_file status.md > "$STATUS_FILE"
  fi
  ensure_task_tracking_fields
}

status_complete() {
  grep -Eq '^STATUS:[[:space:]]*COMPLETE$' "$STATUS_FILE" 2>/dev/null
}

controller_decision() {
  grep -E '^CONTROLLER_DECISION:' "$STATUS_FILE" 2>/dev/null | tail -n 1 | sed 's/^CONTROLLER_DECISION:[[:space:]]*//'
}

escalation_requested() {
  grep -Eq '^ROUTE_TO_ESCALATION:[[:space:]]*(YES|TRUE|1)$' "$STATUS_FILE" 2>/dev/null
}

latest_project_prompt() {
  [ -f "$INITIAL_PROMPT_FILE" ] && cat "$INITIAL_PROMPT_FILE" || true
}

latest_extra() {
  [ -f "$EXTRA_FILE" ] && cat "$EXTRA_FILE" || true
}

task_field() {
  local key="$1"
  python3 - "$TASK_FILE" "$key" <<'PY'
import pathlib, re, sys
p = pathlib.Path(sys.argv[1]); key = sys.argv[2]
text = p.read_text() if p.exists() else ""
m = re.search(rf'^{re.escape(key)}:\s*(.+)$', text, flags=re.M)
print(m.group(1).strip() if m else "")
PY
}

status_field() {
  local key="$1"
  python3 - "$STATUS_FILE" "$key" <<'PY'
import pathlib, re, sys
p = pathlib.Path(sys.argv[1]); key = sys.argv[2]
text = p.read_text() if p.exists() else ""
m = re.search(rf'^{re.escape(key)}:\s*(.*)$', text, flags=re.M)
print(m.group(1).strip() if m else "")
PY
}

set_status_field() {
  local key="$1"
  local value="$2"
  python3 - "$STATUS_FILE" "$key" "$value" <<'PY'
import pathlib, re, sys
p = pathlib.Path(sys.argv[1]); key = sys.argv[2]; value = sys.argv[3]
text = p.read_text() if p.exists() else ""
pat = rf'^{re.escape(key)}:.*$'
rep = f'{key}: {value}'
if re.search(pat, text, flags=re.M):
    text = re.sub(pat, rep, text, flags=re.M)
else:
    text = text.rstrip() + ('\n' if text and not text.endswith('\n') else '') + rep + '\n'
p.write_text(text)
PY
}

ensure_task_tracking_fields() {
  if ! grep -q '^TASK_FINGERPRINT:' "$STATUS_FILE" 2>/dev/null; then
    set_status_field TASK_FINGERPRINT ""
  fi
  if ! grep -q '^TASK_ITERATIONS:' "$STATUS_FILE" 2>/dev/null; then
    set_status_field TASK_ITERATIONS "0"
  fi
  if ! grep -q '^TASK_STARTED_AT:' "$STATUS_FILE" 2>/dev/null; then
    set_status_field TASK_STARTED_AT ""
  fi
}

task_fingerprint() {
  if [ ! -s "$TASK_FILE" ]; then
    printf '\n'
    return 0
  fi
  worker_fingerprint_files "$TASK_FILE"
}

sync_task_tracking() {
  local current_fp stored_fp
  current_fp="$(task_fingerprint)"
  stored_fp="$(status_field TASK_FINGERPRINT)"

  if [ -z "$current_fp" ]; then
    set_status_field TASK_FINGERPRINT ""
    set_status_field TASK_ITERATIONS "0"
    set_status_field TASK_STARTED_AT ""
    return 0
  fi

  if [ "$stored_fp" != "$current_fp" ]; then
    set_status_field TASK_FINGERPRINT "$current_fp"
    set_status_field TASK_ITERATIONS "0"
    set_status_field TASK_STARTED_AT "$(worker_utc_now)"
  fi
}

increment_task_iterations() {
  local current_fp current_iterations
  ensure_task_tracking_fields
  sync_task_tracking
  current_fp="$(status_field TASK_FINGERPRINT)"

  if [ -z "$current_fp" ]; then
    return 0
  fi

  current_iterations="$(status_field TASK_ITERATIONS)"
  case "$current_iterations" in
    ''|*[!0-9]*) current_iterations=0 ;;
  esac
  current_iterations=$((current_iterations + 1))
  set_status_field TASK_ITERATIONS "$current_iterations"
}

normalize_status_for_stage() {
  local stage="$1"
  local milestone
  milestone="$(task_field MILESTONE)"

  case "$stage" in
    controller_plan)   set_status_field PHASE "Planning" ;;
    executor)          set_status_field PHASE "Execution" ;;
    controller_review) set_status_field PHASE "Review" ;;
    escalation)        set_status_field PHASE "Escalation" ;;
    *)                 set_status_field PHASE "Working" ;;
  esac

  if [ -n "$milestone" ]; then
    set_status_field CURRENT_MILESTONE "$milestone"
  fi
}

state_fingerprint() {
  worker_fingerprint_files "$PLAN_FILE" "$TASK_FILE" "$REVIEW_FILE" "$STATUS_FILE"
}

sanitize_controller_decision() {
  python3 - "$STATUS_FILE" "$PLAN_FILE" "$TASK_FILE" "$REVIEW_FILE" <<'PY'
import pathlib, re, sys

status_file = pathlib.Path(sys.argv[1])
plan_file = pathlib.Path(sys.argv[2])
task_file = pathlib.Path(sys.argv[3])
review_file = pathlib.Path(sys.argv[4])

def nonempty(p: pathlib.Path) -> bool:
    return p.exists() and p.stat().st_size > 0

text = status_file.read_text() if status_file.exists() else ""
have_any_artifacts = nonempty(plan_file) or nonempty(task_file) or nonempty(review_file)

m = re.search(r'^CONTROLLER_DECISION:\s*(.*)$', text, flags=re.M)
decision = m.group(1).strip().upper() if m else ""

if have_any_artifacts and decision in {"PLAN", "REPLAN"}:
    if re.search(r'^CONTROLLER_DECISION:.*$', text, flags=re.M):
        text = re.sub(r'^CONTROLLER_DECISION:.*$', 'CONTROLLER_DECISION: REVISE', text, flags=re.M)
    else:
        text = text.rstrip() + '\nCONTROLLER_DECISION: REVISE\n'
    status_file.write_text(text)
PY
}

post_turn_guard() {
  python3 - "$STATUS_FILE" <<'PY'
import pathlib, re, sys
p = pathlib.Path(sys.argv[1])
text = p.read_text() if p.exists() else ""
has_complete = re.search(r'^STATUS:\s*COMPLETE\s*$', text, flags=re.M)
has_next = re.search(r'^NEXT_ACTION:\s*(?!\s*$|none\b|n/?a\b).*', text, flags=re.I | re.M)
if has_complete and has_next:
    text = re.sub(r'^STATUS:\s*COMPLETE\s*$', 'STATUS: INCOMPLETE', text, flags=re.M)
p.write_text(text)
PY
}

plan_artifacts_ready() {
  [ -s "$PLAN_FILE" ] && [ -s "$TASK_FILE" ] && [ -s "$REVIEW_FILE" ]
}

set_controller_blocker() {
  local msg="$1"
  local task_fp task_iterations task_started_at
  task_fp="$(status_field TASK_FINGERPRINT)"
  task_iterations="$(status_field TASK_ITERATIONS)"
  task_started_at="$(status_field TASK_STARTED_AT)"
  [ -n "$task_iterations" ] || task_iterations="0"
  cat > "$STATUS_FILE" <<EOF
PHASE: Controller blocked
CURRENT_MILESTONE: $(task_field MILESTONE)
TASK_FINGERPRINT: $task_fp
TASK_ITERATIONS: $task_iterations
TASK_STARTED_AT: $task_started_at
LAST_ACTION: controller planning/review failed
NEXT_ACTION: fix controller or override provider, then continue
CONTROLLER_DECISION: REVISE
ROUTE_TO_ESCALATION: NO
BLOCKER: $msg
STATUS: INCOMPLETE
EOF
  worker_stamp_file_end "$STATUS_FILE" "$(worker_utc_now)"
}

set_escalation_blocker() {
  local msg="$1"
  local task_fp task_iterations task_started_at
  task_fp="$(status_field TASK_FINGERPRINT)"
  task_iterations="$(status_field TASK_ITERATIONS)"
  task_started_at="$(status_field TASK_STARTED_AT)"
  [ -n "$task_iterations" ] || task_iterations="0"
  cat > "$STATUS_FILE" <<EOF
PHASE: Escalation blocked
CURRENT_MILESTONE: $(task_field MILESTONE)
TASK_FINGERPRINT: $task_fp
TASK_ITERATIONS: $task_iterations
TASK_STARTED_AT: $task_started_at
LAST_ACTION: escalation failed or exceeded limits
NEXT_ACTION: manual intervention or provider override required
CONTROLLER_DECISION: ESCALATE
ROUTE_TO_ESCALATION: YES
BLOCKER: $msg
STATUS: INCOMPLETE
EOF
  worker_stamp_file_end "$STATUS_FILE" "$(worker_utc_now)"
}
