#!/usr/bin/env bash

make_controller_plan_prompt() {
  read_prompt_file controller-plan.txt
}

make_executor_prompt() {
  read_prompt_file executor.txt
}

make_controller_review_prompt() {
  read_prompt_file controller-review.txt
}

make_escalation_prompt() {
  read_prompt_file escalation.txt
}

make_redirect_prompt() {
  read_prompt_file redirect.txt
}
