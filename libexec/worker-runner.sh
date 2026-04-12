#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../lib/worker-common.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../lib/worker-runner-state.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../lib/worker-runner-briefs.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../lib/worker-runner-provider.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../lib/worker-runner-prompts.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../lib/worker-test.sh"

BASE="${1:?usage: worker-runner <project-dir> [new|continue]}"
MODE="${2:-continue}"

worker_set_project_paths_from_base "$BASE"

cd "$BASE"
worker_init_project_dirs
touch "$LOG_FILE" "$STATUS_FILE" "$PLAN_FILE" "$TASK_FILE" "$REVIEW_FILE"

echo $$ > "$ACTIVE_FILE"
trap 'rm -f "$ACTIVE_FILE"' EXIT

worker_load_roles

if [ -f "$STATE_FILE" ]; then
  # shellcheck disable=SC1090
  source "$STATE_FILE"
fi

: "${ITERATION:=0}"
: "${STAGE:=controller_plan}"
: "${EXECUTOR_FAILURES:=0}"
: "${ESCALATION_FAILURES:=0}"
: "${CONTROLLER_FAILURES:=0}"
: "${TASK_NOTIFICATION_FINGERPRINT:=}"
: "${TASK_ITERATION5_NOTIFIED:=0}"
: "${TASK_HUNG_NOTIFIED:=0}"
: "${PROJECT_COMPLETE_NOTIFIED:=0}"
: "${BLOCKER_NOTIFICATION_KEY:=}"

MAX_ITERS=100
ensure_status_skeleton
sanitize_controller_decision
worker_stamp_artifacts
save_state

while [ "$ITERATION" -lt "$MAX_ITERS" ]; do
  ITERATION=$((ITERATION + 1))
  save_state

  case "$STAGE" in
    controller_plan)
      normalize_status_for_stage controller_plan
      sanitize_controller_decision
      sync_task_tracking
      worker_stamp_artifacts
      write_controller_brief
      BEFORE_FP="$(state_fingerprint)"
      banner "controller_plan provider=$CONTROLLER iteration=$ITERATION"
      if ! run_provider "$CONTROLLER" "$(make_controller_plan_prompt)" 15; then
        if worker_provider_auth_failed; then
          set_controller_blocker "Controller provider '$CONTROLLER' is not authenticated."
          banner "controller auth failed; stopping"
          break
        fi
        if worker_provider_hit_max_turns; then
          set_controller_blocker "Controller provider '$CONTROLLER' hit max turns during planning."
          banner "controller max turns; stopping"
          break
        fi
      fi
      post_turn_guard
      sanitize_controller_decision
      sync_task_tracking
      worker_stamp_artifacts
      AFTER_FP="$(state_fingerprint)"
      if ! plan_artifacts_ready; then
        set_controller_blocker "Controller failed to produce PLAN.md, TASK.md, and REVIEW.md."
        banner "controller planning incomplete; stopping"
        break
      fi
      if worker_provider_noop || [ "$BEFORE_FP" = "$AFTER_FP" ]; then
        set_controller_blocker "Controller planning made no meaningful progress."
        banner "controller planning no progress; stopping"
        break
      fi
      CONTROLLER_FAILURES=0
      clear_blocker_notification_if_unblocked
      STAGE="executor"
      ;;
    executor)
      normalize_status_for_stage executor
      sanitize_controller_decision
      increment_task_iterations
      notify_task_iteration_milestone_if_needed
      worker_stamp_artifacts
      write_executor_brief
      BEFORE_FP="$(state_fingerprint)"
      banner "executor provider=$EXECUTOR iteration=$ITERATION"
      if ! run_provider "$EXECUTOR" "$(make_executor_prompt)" 6; then
        if worker_provider_auth_failed; then
          set_escalation_blocker "Executor provider '$EXECUTOR' is not authenticated."
          banner "executor auth failed; stopping"
          break
        fi
        if worker_provider_hit_max_turns; then
          set_status_field ROUTE_TO_ESCALATION YES
          set_status_field BLOCKER "Executor provider '$EXECUTOR' hit max turns."
          notify_blocker_once "executor" "Executor provider '$EXECUTOR' hit max turns."
        else
          set_status_field ROUTE_TO_ESCALATION YES
          set_status_field BLOCKER "Executor provider '$EXECUTOR' failed: $(last_provider_error)"
          notify_blocker_once "executor" "Executor provider '$EXECUTOR' failed: $(last_provider_error)"
        fi
      fi
      post_turn_guard
      sanitize_controller_decision
      sync_task_tracking
      worker_stamp_artifacts
      AFTER_FP="$(state_fingerprint)"
      if worker_provider_noop || { [ "$BEFORE_FP" = "$AFTER_FP" ] && ! escalation_requested; }; then
        EXECUTOR_FAILURES=$((EXECUTOR_FAILURES + 1))
      else
        EXECUTOR_FAILURES=0
      fi

      if escalation_requested || [ "$EXECUTOR_FAILURES" -ge 2 ]; then
        STAGE="escalation"
      else
        STAGE="controller_review"
      fi
      clear_blocker_notification_if_unblocked
      ;;
    controller_review)
      normalize_status_for_stage controller_review
      sanitize_controller_decision
      increment_task_iterations
      notify_task_iteration_milestone_if_needed
      worker_stamp_artifacts
      write_review_brief
      BEFORE_DECISION="$(controller_decision)"
      BEFORE_TASK_FP="$(status_field TASK_FINGERPRINT)"
      BEFORE_TASK_MILESTONE="$(task_field MILESTONE)"
      BEFORE_TASK_TITLE="$(task_title)"
      BEFORE_FP="$(state_fingerprint)"
      banner "controller_review provider=$CONTROLLER iteration=$ITERATION"
      if ! run_provider "$CONTROLLER" "$(make_controller_review_prompt)" 15; then
        if worker_provider_auth_failed; then
          set_controller_blocker "Controller provider '$CONTROLLER' is not authenticated during review."
          banner "controller review auth failed; stopping"
          break
        fi
        if worker_provider_hit_max_turns; then
          set_controller_blocker "Controller review hit max turns."
          banner "controller review max turns; stopping"
          break
        fi
      fi
      post_turn_guard
      sanitize_controller_decision
      sync_task_tracking
      worker_stamp_artifacts
      AFTER_FP="$(state_fingerprint)"
      DECISION="$(controller_decision)"
      AFTER_TASK_FP="$(task_fingerprint)"

      if worker_provider_noop || { [ "$BEFORE_FP" = "$AFTER_FP" ] && [ "$BEFORE_DECISION" = "$DECISION" ]; }; then
        set_controller_blocker "Controller review made no meaningful progress."
        banner "controller review no progress; stopping"
        break
      fi

      if [ "$DECISION" = "ACCEPT" ] && [ -n "$BEFORE_TASK_FP" ] && [ "$BEFORE_TASK_FP" != "$AFTER_TASK_FP" ]; then
        notify_task_completed "$BEFORE_TASK_MILESTONE" "$BEFORE_TASK_TITLE"
      fi
      if [ "$DECISION" = "COMPLETE" ] && [ -n "$BEFORE_TASK_FP" ]; then
        notify_task_completed "$BEFORE_TASK_MILESTONE" "$BEFORE_TASK_TITLE"
      fi

      case "$DECISION" in
        COMPLETE)
          ;;
        ESCALATE)
          STAGE="escalation"
          ;;
        REVISE|EXECUTE|ACCEPT)
          if ! status_complete; then
            STAGE="executor"
          fi
          ;;
        *)
          set_controller_blocker "Controller review did not set a valid decision."
          banner "invalid controller decision; stopping"
          break
          ;;
      esac
      clear_blocker_notification_if_unblocked
      ;;
    escalation)
      normalize_status_for_stage escalation
      sanitize_controller_decision
      increment_task_iterations
      notify_task_iteration_milestone_if_needed
      worker_stamp_artifacts
      write_escalation_brief
      BEFORE_FP="$(state_fingerprint)"
      banner "escalation provider=$ESCALATION iteration=$ITERATION"
      if ! run_provider "$ESCALATION" "$(make_escalation_prompt)" 20; then
        if worker_provider_hit_max_turns; then
          set_escalation_blocker "Escalation provider '$ESCALATION' hit max turns while resolving blocker."
          banner "escalation max turns; stopping"
          break
        fi
        if worker_provider_auth_failed; then
          set_escalation_blocker "Escalation provider '$ESCALATION' is not authenticated."
          banner "escalation auth failed; stopping"
          break
        fi
      fi
      post_turn_guard
      sanitize_controller_decision
      sync_task_tracking
      worker_stamp_artifacts
      AFTER_FP="$(state_fingerprint)"

      if worker_provider_noop || [ "$BEFORE_FP" = "$AFTER_FP" ]; then
        set_escalation_blocker "Escalation provider '$ESCALATION' made no meaningful progress."
        banner "escalation no progress; stopping"
        break
      fi

      if escalation_requested; then
        set_escalation_blocker "Escalation provider '$ESCALATION' did not clear the blocker."
        banner "escalation unresolved; stopping"
        break
      fi

      ESCALATION_FAILURES=$((ESCALATION_FAILURES + 1))
      STAGE="controller_review"
      clear_blocker_notification_if_unblocked
      ;;
    *)
      STAGE="controller_plan"
      ;;
  esac

  save_state
  notify_task_hung_if_needed

  if status_complete; then
    banner "worker-test on completion provider=$CONTROLLER"
    if ! "$REPO_DIR/worker-test" "$BASE" "$CONTROLLER" "Automatic completion preview run."; then
      banner "worker-test on completion failed"
      worker_test_notify_slack_failure "automatic completion run failed"
    fi
    notify_project_complete_if_needed
    save_state
    banner "project marked complete"
    worker_pause_async
    break
  fi

  sleep 2
done

echo "[worker finished]" | tee -a "$LOG_FILE"
