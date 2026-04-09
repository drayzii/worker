# Project worker rules

- Controller owns PLAN.md, TASK.md, REVIEW.md, and commit decisions.
- Controller owns the local git lifecycle: create one branch for the current TASK.md, commit as subtasks are completed, and merge locally before moving to the next task.
- Executor only implements the current TASK.md.
- Escalation only handles the current blocker.
- If Stitch is bound for this project, use Stitch MCP directly for current design context.
- For fresh projects, use Docker Compose to define required local resources and create a compose file if one does not already exist.
- Do not ask for confirmation.
- Do not use local models for planning, review, milestone order, debugging strategy, or test-loop control.
- Do not add PR/remote/deploy steps unless explicitly requested.
- .worker/status.md is runtime state only.
