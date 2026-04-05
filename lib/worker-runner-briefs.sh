#!/usr/bin/env bash

write_controller_brief() {
  local project_prompt extra current_status important_files file_tree
  project_prompt="$(latest_project_prompt)"
  extra="$(latest_extra)"
  current_status="$(tail -n 30 "$STATUS_FILE" 2>/dev/null || true)"
  important_files="$(find . -maxdepth 5 \
    \( -path './.git' -o -path './node_modules' -o -path './.next' -o -path './dist' -o -path './build' -o -path './coverage' \) -prune \
    -o -type f \
    \( -name 'package.json' -o -name 'README*' -o -name 'tsconfig*.json' -o -name 'jsconfig*.json' -o -name 'vite.config.*' -o -name 'vitest.config.*' -o -name 'jest.config.*' -o -name 'playwright.config.*' -o -name 'next.config.*' -o -name 'docker-compose*.yml' -o -name 'docker-compose*.yaml' -o -name 'compose.yml' -o -name 'compose.yaml' -o -path './src/*' -o -path './app/*' -o -path './pages/*' -o -path './components/*' -o -path './lib/*' -o -path './tests/*' -o -path './test/*' \) \
    -print | sed 's#^\./##' | sort | head -n 120)"
  file_tree="$(find . -maxdepth 5 \
    \( -path './.git' -o -path './node_modules' -o -path './.next' -o -path './dist' -o -path './build' -o -path './coverage' \) -prune \
    -o -type f -print | sed 's#^\./##' | sort | head -n 200)"

  cat > "$CONTROLLER_BRIEF_FILE" <<EOF
PROJECT PROMPT:
$project_prompt

ADDITIONAL INSTRUCTIONS:
$extra

CURRENT STATUS:
$current_status

IMPORTANT FILES:
$important_files

TOP-LEVEL FILES:
$file_tree

REQUIRED TASK.md FORMAT:
MILESTONE: <id>
TITLE: <short title>
OBJECTIVE: <one paragraph>
SCOPE:
- ...
ACCEPTANCE:
- ...
VALIDATION:
- ...
EOF
}

write_executor_brief() {
  local task review status errors changed
  task="$(tail -n 80 "$TASK_FILE" 2>/dev/null || true)"
  review="$(tail -n 60 "$REVIEW_FILE" 2>/dev/null || true)"
  status="$(tail -n 40 "$STATUS_FILE" 2>/dev/null || true)"
  errors="$(grep -E 'failed|error|timeout|Error|FAIL|Test timeout|ECONN|ENOENT|EADDRINUSE|lightningcss' "$LOG_FILE" 2>/dev/null | tail -n 60 || true)"
  changed="$(git status --short 2>/dev/null | tail -n 60 || true)"

  cat > "$EXECUTOR_BRIEF_FILE" <<EOF
CURRENT TASK:
$task

CURRENT REVIEW:
$review

CURRENT STATUS:
$status

RECENT ERRORS:
$errors

CURRENT CHANGES:
$changed
EOF
}

write_review_brief() {
  local task review status changed errors
  task="$(tail -n 80 "$TASK_FILE" 2>/dev/null || true)"
  review="$(tail -n 60 "$REVIEW_FILE" 2>/dev/null || true)"
  status="$(tail -n 40 "$STATUS_FILE" 2>/dev/null || true)"
  changed="$(git status --short 2>/dev/null | tail -n 60 || true)"
  errors="$(grep -E 'failed|error|timeout|Error|FAIL|Test timeout|ECONN|ENOENT|EADDRINUSE|lightningcss' "$LOG_FILE" 2>/dev/null | tail -n 60 || true)"

  cat > "$REVIEW_BRIEF_FILE" <<EOF
CURRENT TASK:
$task

CURRENT REVIEW:
$review

CURRENT STATUS:
$status

CURRENT CHANGES:
$changed

RECENT ERRORS:
$errors
EOF
}

write_escalation_brief() {
  local task status blocker errors extra
  task="$(tail -n 80 "$TASK_FILE" 2>/dev/null || true)"
  status="$(tail -n 40 "$STATUS_FILE" 2>/dev/null || true)"
  blocker="$(grep -E '^BLOCKER:' "$STATUS_FILE" 2>/dev/null | tail -n 1 || true)"
  errors="$(grep -E 'failed|error|timeout|Error|FAIL|Test timeout|ECONN|ENOENT|EADDRINUSE|lightningcss' "$LOG_FILE" 2>/dev/null | tail -n 80 || true)"
  extra="$(latest_extra)"

  cat > "$ESCALATION_BRIEF_FILE" <<EOF
CURRENT BLOCKER:
$blocker

CURRENT TASK:
$task

CURRENT STATUS:
$status

RECENT ERRORS:
$errors

ADDITIONAL INSTRUCTIONS:
$extra
EOF
}
