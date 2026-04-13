#!/usr/bin/env bash

write_controller_brief() {
  local project_prompt extra current_status important_files file_tree stitch_binding stitch_live_note prd_present stitch_summary_present
  project_prompt="$(latest_project_prompt)"
  extra="$(latest_extra)"
  current_status="$(tail -n 30 "$STATUS_FILE" 2>/dev/null || true)"
  stitch_binding="$(worker_stitch_binding_summary)"
  prd_present="$([ -f "$PRD_FILE" ] && echo yes || echo no)"
  stitch_summary_present="$([ -f "$STITCH_SUMMARY_FILE" ] && echo yes || echo no)"
  if worker_stitch_is_bound; then
    stitch_live_note="Use Stitch MCP directly for current project context before planning. .worker/stitch.json identifies the linked Stitch project, and the linked Stitch screens are the source of truth for current UI state."
  else
    stitch_live_note="No Stitch binding file is present for this project."
  fi
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

PRD.md PRESENT:
$prd_present

STITCH BINDING:
$stitch_binding

STITCH MCP MODE:
$stitch_live_note

STITCH_SUMMARY.md PRESENT:
$stitch_summary_present

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
  local task review status errors changed stitch_binding stitch_live_note
  task="$(tail -n 80 "$TASK_FILE" 2>/dev/null || true)"
  review="$(tail -n 60 "$REVIEW_FILE" 2>/dev/null || true)"
  status="$(tail -n 40 "$STATUS_FILE" 2>/dev/null || true)"
  errors="$(grep -E 'failed|error|timeout|Error|FAIL|Test timeout|ECONN|ENOENT|EADDRINUSE|lightningcss' "$LOG_FILE" 2>/dev/null | tail -n 60 || true)"
  changed="$(git status --short 2>/dev/null | tail -n 60 || true)"
  stitch_binding="$(worker_stitch_binding_summary)"
  if worker_stitch_is_bound; then
    stitch_live_note="For UI work, fetch exact linked screens, assets, and specs on demand via Stitch MCP using .worker/stitch.json and the bound project identity."
  else
    stitch_live_note="No Stitch binding file is present for this project."
  fi

  cat > "$EXECUTOR_BRIEF_FILE" <<EOF
CURRENT TASK:
$task

CURRENT REVIEW:
$review

CURRENT STATUS:
$status

STITCH BINDING:
$stitch_binding

STITCH MCP MODE:
$stitch_live_note

RECENT ERRORS:
$errors

CURRENT CHANGES:
$changed
EOF
}

write_review_brief() {
  local task review status changed errors stitch_binding stitch_live_note
  task="$(tail -n 80 "$TASK_FILE" 2>/dev/null || true)"
  review="$(tail -n 60 "$REVIEW_FILE" 2>/dev/null || true)"
  status="$(tail -n 40 "$STATUS_FILE" 2>/dev/null || true)"
  changed="$(git status --short 2>/dev/null | tail -n 60 || true)"
  errors="$(grep -E 'failed|error|timeout|Error|FAIL|Test timeout|ECONN|ENOENT|EADDRINUSE|lightningcss' "$LOG_FILE" 2>/dev/null | tail -n 60 || true)"
  stitch_binding="$(worker_stitch_binding_summary)"
  if worker_stitch_is_bound; then
    stitch_live_note="Use Stitch MCP directly for current project context before reviewing UI-related work. .worker/stitch.json identifies the linked Stitch project, and the linked Stitch screens are the source of truth for current UI state."
  else
    stitch_live_note="No Stitch binding file is present for this project."
  fi

  cat > "$REVIEW_BRIEF_FILE" <<EOF
CURRENT TASK:
$task

CURRENT REVIEW:
$review

CURRENT STATUS:
$status

STITCH BINDING:
$stitch_binding

STITCH MCP MODE:
$stitch_live_note

CURRENT CHANGES:
$changed

RECENT ERRORS:
$errors
EOF
}

write_escalation_brief() {
  local task status blocker errors extra stitch_binding stitch_live_note
  task="$(tail -n 80 "$TASK_FILE" 2>/dev/null || true)"
  status="$(tail -n 40 "$STATUS_FILE" 2>/dev/null || true)"
  blocker="$(grep -E '^BLOCKER:' "$STATUS_FILE" 2>/dev/null | tail -n 1 || true)"
  errors="$(grep -E 'failed|error|timeout|Error|FAIL|Test timeout|ECONN|ENOENT|EADDRINUSE|lightningcss' "$LOG_FILE" 2>/dev/null | tail -n 80 || true)"
  extra="$(latest_extra)"
  stitch_binding="$(worker_stitch_binding_summary)"
  if worker_stitch_is_bound; then
    stitch_live_note="Stitch is bound. Use live Stitch MCP only if the blocker depends on current design context from the linked Stitch project or screens in .worker/stitch.json."
  else
    stitch_live_note="No Stitch binding file is present for this project."
  fi

  cat > "$ESCALATION_BRIEF_FILE" <<EOF
CURRENT BLOCKER:
$blocker

CURRENT TASK:
$task

CURRENT STATUS:
$status

STITCH BINDING:
$stitch_binding

STITCH MCP MODE:
$stitch_live_note

RECENT ERRORS:
$errors

ADDITIONAL INSTRUCTIONS:
$extra
EOF
}
