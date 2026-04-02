#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-summary}"
shift || true
PROMPT="${*:-}"

if [ -z "$PROMPT" ]; then
  echo "usage: local-llm <summary|boilerplate|small-code> <prompt>" >&2
  exit 2
fi

case "$MODE" in
  summary)
    MODEL="gemma3:4b"
    SYS="You are a terse local software-engineering helper. Only summarize. Do not own project planning, architecture, debugging strategy, or milestone decisions."
    ;;
  boilerplate|small-code)
    MODEL="qwen2.5-coder:7b"
    SYS="You are a local coding helper. Produce only tiny safe snippets or repetitive boilerplate. Do not own planning, architecture, migrations, debugging strategy, or test loops."
    ;;
  *)
    echo "usage: local-llm <summary|boilerplate|small-code> <prompt>" >&2
    exit 2
    ;;
esac

jq -n \
  --arg model "$MODEL" \
  --arg prompt "$SYS\n\n$PROMPT" \
  '{
    model: $model,
    prompt: $prompt,
    stream: false,
    options: {
      num_ctx: 6144,
      temperature: 0.1
    }
  }' \
| curl -sS http://127.0.0.1:11434/api/generate -d @- \
| jq -r '.response'
