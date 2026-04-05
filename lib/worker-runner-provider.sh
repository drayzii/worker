#!/usr/bin/env bash

run_codex() {
  local prompt="$1"
  : > "$TEMP_FILE"
  codex exec --json "$prompt" 2>&1 | tee -a "$LOG_FILE" | tee "$TEMP_FILE"
  return ${PIPESTATUS[0]}
}

run_claude() {
  local prompt="$1"
  local max_turns="${2:-6}"
  : > "$TEMP_FILE"
  claude -p \
    --model sonnet \
    --permission-mode bypassPermissions \
    --max-turns "$max_turns" \
    --output-format stream-json \
    --verbose \
    --include-partial-messages \
    --append-system-prompt "$(cat "$SYSTEM_PROMPT_FILE")" \
    "$prompt" 2>&1 | tee -a "$LOG_FILE" | tee "$TEMP_FILE"
  return ${PIPESTATUS[0]}
}

run_provider() {
  local provider="$1"
  local prompt="$2"
  local max_turns="${3:-6}"
  if [ "$provider" = "codex" ]; then
    run_codex "$prompt"
  else
    run_claude "$prompt" "$max_turns"
  fi
}

last_provider_error() {
  python3 - "$TEMP_FILE" <<'PY'
import pathlib, sys

p = pathlib.Path(sys.argv[1])
text = p.read_text() if p.exists() else ""
lines = [line.strip() for line in text.splitlines() if line.strip()]
print(lines[-1] if lines else "provider exited non-zero without a captured error")
PY
}
