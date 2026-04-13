#!/usr/bin/env bash

worker_test_usage() {
  echo "usage: worker-test <project-name|.|path> <codex|claude> [notes...]" >&2
  exit 2
}

worker_test_status_usage() {
  echo "usage: worker-test-status <project-name|.|path>" >&2
  exit 2
}

worker_test_require_provider() {
  case "${1:-}" in
    codex|claude) ;;
    *) echo "Unknown provider: ${1:-}" >&2; worker_test_usage ;;
  esac
}

worker_test_require_authkey() {
  if [ -z "${WORKER_TAILSCALE_AUTHKEY:-}" ]; then
    echo "Set WORKER_TAILSCALE_AUTHKEY before running worker-test." >&2
    exit 1
  fi
}

worker_test_compose_files_json() {
  python3 - "$BASE" <<'PY'
import json, pathlib, sys

base = pathlib.Path(sys.argv[1])
candidates = [
    "docker-compose.yml",
    "docker-compose.yaml",
    "compose.yml",
    "compose.yaml",
]
found = [name for name in candidates if (base / name).exists()]
print(json.dumps(found))
PY
}

worker_test_project_file_list() {
  find "$BASE" -maxdepth 4 \
    \( -path "$BASE/.git" -o -path "$BASE/node_modules" -o -path "$BASE/.next" -o -path "$BASE/dist" -o -path "$BASE/build" -o -path "$BASE/coverage" \) -prune \
    -o -type f -print | sed "s#^$BASE/##" | sort | head -n 200
}

worker_test_write_prompt() {
  local output_file="$1"
  local provider_notes="$2"
  local compose_json
  compose_json="$(worker_test_compose_files_json)"

  {
    read_prompt_file test-stack-planner.txt
    printf '\n\nPROJECT DIRECTORY: %s\n' "$BASE"
    printf 'PROJECT SLUG: %s\n' "$(worker_project_slug)"
    printf 'COMPOSE FILES JSON: %s\n' "$compose_json"
    printf 'WORKER TEST STACK TARGET FILE: %s\n' "$TEST_STACK_FILE"
    printf 'EXTRA NOTES:\n%s\n' "$provider_notes"
    printf '\nPROJECT FILES:\n'
    worker_test_project_file_list
  } > "$output_file"
}

worker_test_generate_stack_with_codex() {
  local prompt_file="$1"
  local output_file="$2"
  codex exec \
    -C "$BASE" \
    --skip-git-repo-check \
    --ephemeral \
    --output-last-message "$output_file" \
    - < "$prompt_file"
}

worker_test_generate_stack_with_claude() {
  local prompt_file="$1"
  local output_file="$2"
  local prompt_text
  prompt_text="$(cat "$prompt_file")"
  (
    cd "$BASE"
    claude -p \
      --model sonnet \
      --permission-mode bypassPermissions \
      --max-turns 10 \
      "$prompt_text" > "$output_file" 2>&1
  )
}

worker_test_resolve_stack_source() {
  local raw_output_file="$1"
  python3 - "$raw_output_file" "$TEST_STACK_FILE" <<'PY'
import json, pathlib, sys

raw_path = pathlib.Path(sys.argv[1])
stack_path = pathlib.Path(sys.argv[2])

def is_valid_json_object(path: pathlib.Path) -> bool:
    if not path.exists():
        return False
    text = path.read_text().strip()
    if not text:
        return False
    try:
        value = json.loads(text)
    except Exception:
        return False
    return isinstance(value, dict)

if is_valid_json_object(stack_path):
    print(stack_path)
else:
    print(raw_path)
PY
}

worker_test_normalize_and_validate_stack() {
  local input_file="$1"
  python3 - "$input_file" "$TEST_STACK_FILE" <<'PY'
import json, pathlib, re, sys

input_path = pathlib.Path(sys.argv[1])
output_path = pathlib.Path(sys.argv[2])
text = input_path.read_text() if input_path.exists() else ""
text = text.strip()

fenced = re.match(r"^```(?:json)?\n(.*)\n```$", text, flags=re.S)
if fenced:
    text = fenced.group(1).strip()

if not text:
    raise SystemExit("Generated test stack output was empty.")

def extract_json_candidate(raw: str):
    try:
        return json.loads(raw)
    except Exception:
        pass

    decoder = json.JSONDecoder()
    for i, ch in enumerate(raw):
        if ch not in "[{":
            continue
        try:
            value, end = decoder.raw_decode(raw[i:])
        except Exception:
            continue
        trailing = raw[i + end :].strip()
        if trailing and not trailing.startswith("```"):
            # We found valid JSON with trailing noise; keep it anyway.
            return value
        return value
    raise SystemExit("Could not extract a JSON test stack from provider output.")

data = extract_json_candidate(text)
if not isinstance(data, dict):
    raise SystemExit("Test stack must be a JSON object.")

compose_files = data.get("compose_files", [])
compose_up_flags = data.get("compose_up_flags", [])
services = data.get("services", [])
preview_env = data.get("preview_env", [])
blocked_reason = (data.get("blocked_reason") or "").strip()
notes = data.get("notes", [])

if not isinstance(compose_files, list) or not all(isinstance(x, str) for x in compose_files):
    raise SystemExit("compose_files must be an array of strings.")
if not isinstance(compose_up_flags, list) or not all(isinstance(x, str) for x in compose_up_flags):
    raise SystemExit("compose_up_flags must be an array of strings.")
if not isinstance(notes, list) or not all(isinstance(x, str) for x in notes):
    raise SystemExit("notes must be an array of strings.")
if not isinstance(services, list):
    raise SystemExit("services must be an array.")

service_keys = set()
compose_services = set()
normalized_services = []
for item in services:
    if not isinstance(item, dict):
        raise SystemExit("Each item in services must be an object.")
    key = item.get("key", "")
    compose_service = item.get("compose_service", "")
    port = item.get("port", 0)
    scheme = item.get("scheme", "http")

    if not isinstance(key, str) or not re.fullmatch(r"[a-z0-9-]+", key):
        raise SystemExit("services key must match [a-z0-9-]+.")
    if key in service_keys:
        raise SystemExit("services keys must be unique.")
    service_keys.add(key)

    if not isinstance(compose_service, str) or not re.fullmatch(r"[A-Za-z0-9_.-]+", compose_service):
        raise SystemExit("services compose_service must be a valid compose service name.")
    compose_services.add(compose_service)

    if isinstance(port, bool) or not isinstance(port, int) or not (1 <= port <= 65535):
        raise SystemExit("services port must be an integer between 1 and 65535.")
    if scheme not in {"http", "https", "https+insecure", "tcp"}:
        raise SystemExit("services scheme must be one of http, https, https+insecure, tcp.")

    normalized_services.append({
        "key": key,
        "compose_service": compose_service,
        "port": port,
        "scheme": scheme,
    })

if not isinstance(preview_env, list):
    raise SystemExit("preview_env must be an array.")

normalized_preview_env = []
for item in preview_env:
    if not isinstance(item, dict):
        raise SystemExit("Each preview_env item must be an object.")
    name = item.get("name", "")
    compose_service = item.get("compose_service", "")
    from_service = item.get("from_service", "")
    injection = item.get("injection", "environment")

    if not isinstance(name, str) or not re.fullmatch(r"[A-Z_][A-Z0-9_]*", name):
        raise SystemExit("preview_env names must be valid uppercase env vars.")
    if not isinstance(compose_service, str) or compose_service not in compose_services:
        raise SystemExit("preview_env compose_service must reference a known compose service.")
    if not isinstance(from_service, str) or from_service not in service_keys:
        raise SystemExit("preview_env from_service must reference a known service key.")
    if injection not in {"environment", "build_arg"}:
        raise SystemExit("preview_env injection must be either environment or build_arg.")

    normalized_preview_env.append({
        "name": name,
        "compose_service": compose_service,
        "from_service": from_service,
        "injection": injection,
    })

if blocked_reason and normalized_services:
    raise SystemExit("blocked_reason cannot be set when services are present.")
if not blocked_reason and not normalized_services:
    raise SystemExit("At least one service is required when blocked_reason is empty.")

normalized = {
    "compose_files": compose_files,
    "compose_up_flags": compose_up_flags,
    "services": normalized_services,
    "preview_env": normalized_preview_env,
    "blocked_reason": blocked_reason,
    "notes": notes,
}
output_path.write_text(json.dumps(normalized, indent=2) + "\n")
PY
}

worker_test_generate_stack() {
  local provider="$1"
  local notes="$2"
  local prompt_file raw_output

  prompt_file="$(mktemp)"
  raw_output="$(mktemp)"
  trap 'rm -f "$prompt_file" "$raw_output"' RETURN

  worker_test_write_prompt "$prompt_file" "$notes"

  if [ "$provider" = "codex" ]; then
    worker_test_generate_stack_with_codex "$prompt_file" "$raw_output"
  else
    worker_test_generate_stack_with_claude "$prompt_file" "$raw_output"
  fi

  worker_test_normalize_and_validate_stack "$(worker_test_resolve_stack_source "$raw_output")"
}

worker_test_tailnet_domain() {
  python3 - <<'PY'
import json, subprocess

raw = subprocess.check_output(["tailscale", "status", "--json"], text=True)
data = json.loads(raw)
dns_name = ((data.get("Self") or {}).get("DNSName") or "").rstrip(".")
if not dns_name or "." not in dns_name:
    raise SystemExit("Could not determine this node's Tailscale DNS domain.")
print(dns_name.split(".", 1)[1])
PY
}

worker_test_node_hostname() {
  local service_key="$1"
  python3 - "$(worker_project_slug)" "$service_key" <<'PY'
import re, sys

slug = sys.argv[1]
service = sys.argv[2]
name = f"{slug}-{service}".lower()
name = re.sub(r"[^a-z0-9-]+", "-", name).strip("-")
print(name[:63].rstrip("-") or "preview")
PY
}

worker_test_runtime_write() {
  local tailnet_domain="$1"
  python3 - "$TEST_STACK_FILE" "$TEST_RUNTIME_FILE" "$TEST_ENV_FILE" "$tailnet_domain" "$(worker_project_slug)" <<'PY'
import json, pathlib, sys

stack_path = pathlib.Path(sys.argv[1])
runtime_path = pathlib.Path(sys.argv[2])
env_path = pathlib.Path(sys.argv[3])
tailnet_domain = sys.argv[4]
slug = sys.argv[5]

data = json.loads(stack_path.read_text())
runtime = {
    "tailnet_domain": tailnet_domain,
    "slug": slug,
    "services": [],
    "preview_env": [],
    "notes": data.get("notes", []),
}

service_urls = {}
for item in data.get("services", []):
    key = item["key"]
    node_hostname = f"{slug}-{key}".lower()
    node_hostname = node_hostname[:63].rstrip("-") or "worker-preview"
    url = f"https://{node_hostname}.{tailnet_domain}"
    sidecar_service = f"ts-preview-{key}"
    target = f"{item['scheme']}://127.0.0.1:{item['port']}"
    runtime["services"].append({
        "key": key,
        "compose_service": item["compose_service"],
        "sidecar_service": sidecar_service,
        "node_hostname": node_hostname,
        "port": item["port"],
        "scheme": item["scheme"],
        "target": target,
        "url": url,
    })
    service_urls[key] = url

env_lines = []
for item in data.get("preview_env", []):
    value = service_urls[item["from_service"]]
    runtime["preview_env"].append({
        "name": item["name"],
        "compose_service": item["compose_service"],
        "from_service": item["from_service"],
        "injection": item.get("injection", "environment"),
        "value": value,
    })
    env_lines.append(f"{item['name']}={value}")

runtime_path.write_text(json.dumps(runtime, indent=2) + "\n")
env_path.write_text("\n".join(env_lines) + ("\n" if env_lines else ""))
PY
}

worker_test_write_preview_compose() {
  mkdir -p "$TEST_TAILSCALE_DIR"
  python3 - "$TEST_RUNTIME_FILE" "$TEST_TAILSCALE_DIR" <<'PY'
import json, pathlib, sys

runtime = json.loads(pathlib.Path(sys.argv[1]).read_text())
base = pathlib.Path(sys.argv[2])
for item in runtime.get("services", []):
    (base / item["key"] / "state").mkdir(parents=True, exist_ok=True)
PY

  python3 - "$TEST_RUNTIME_FILE" "$TEST_PREVIEW_COMPOSE_FILE" <<'PY'
import json, pathlib, sys

runtime = json.loads(pathlib.Path(sys.argv[1]).read_text())
output = pathlib.Path(sys.argv[2])

env_by_service = {}
build_args_by_service = {}
for item in runtime.get("preview_env", []):
    if item.get("injection") == "build_arg":
        build_args_by_service.setdefault(item["compose_service"], []).append(item)
    else:
        env_by_service.setdefault(item["compose_service"], []).append(item)

lines = ["services:"]

for compose_service in sorted(set(env_by_service) | set(build_args_by_service)):
    lines.append(f"  {compose_service}:")
    if compose_service in env_by_service:
        lines.append("    environment:")
        for item in env_by_service[compose_service]:
            value = item["value"].replace('"', '\\"')
            lines.append(f'      {item["name"]}: "{value}"')
    if compose_service in build_args_by_service:
        lines.append("    build:")
        lines.append("      args:")
        for item in build_args_by_service[compose_service]:
            value = item["value"].replace('"', '\\"')
            lines.append(f'        {item["name"]}: "{value}"')

for item in runtime.get("services", []):
    key = item["key"]
    sidecar = item["sidecar_service"]
    node_hostname = item["node_hostname"]
    compose_service = item["compose_service"]
    state_dir = f".worker/tailscale/{key}/state"

    lines.extend([
        f"  {sidecar}:",
        "    image: tailscale/tailscale:latest",
        '    environment:',
        '      TS_AUTHKEY: "${WORKER_TAILSCALE_AUTHKEY:?Set WORKER_TAILSCALE_AUTHKEY}"',
        '      TS_AUTH_ONCE: "true"',
        '      TS_ACCEPT_DNS: "true"',
        '      TS_USERSPACE: "true"',
        '      TS_STATE_DIR: "/var/lib/tailscale"',
        f'      TS_HOSTNAME: "{node_hostname}"',
        '    volumes:',
        f'      - "{state_dir}:/var/lib/tailscale"',
        f'    network_mode: "service:{compose_service}"',
        '    depends_on:',
        f'      - "{compose_service}"',
        '    restart: unless-stopped',
    ])

output.write_text("\n".join(lines) + "\n")
PY
}

worker_test_blocked_reason() {
  python3 - "$TEST_STACK_FILE" <<'PY'
import json, pathlib, sys

path = pathlib.Path(sys.argv[1])
if not path.exists():
    print("")
    raise SystemExit(0)

data = json.loads(path.read_text())
print((data.get("blocked_reason") or "").strip())
PY
}

worker_test_slack_status_message() {
  python3 - "$TEST_RUNTIME_FILE" "$BASE" <<'PY'
import json, pathlib, sys

runtime = json.loads(pathlib.Path(sys.argv[1]).read_text())
project_name = pathlib.Path(sys.argv[2]).name

lines = [f"worker-test: previews ready for {project_name}"]
for item in runtime.get("services", []):
    lines.append(f"- {item['key']}: {item['url']}")

preview_env = runtime.get("preview_env") or []
if preview_env:
    lines.append("env:")
    for item in preview_env:
        lines.append(f"- {item['compose_service']}: {item['name']}={item['value']}")

print("\n".join(lines))
PY
}

worker_test_notify_slack_status() {
  [ -f "$TEST_RUNTIME_FILE" ] || return 0
  worker_notify_slack "$(worker_test_slack_status_message)"
}

worker_test_notify_slack_blocked() {
  local reason="$1"
  worker_notify_slack "worker-test blocked for $(worker_project_name): $reason"
}

worker_test_notify_slack_failure() {
  local message="$1"
  worker_notify_slack "worker-test failed for $(worker_project_name): $message"
}

worker_test_compose_args_file() {
  local output_file="$1"
  local preview_file="${2:-$TEST_PREVIEW_COMPOSE_FILE}"
  python3 - "$TEST_STACK_FILE" "$preview_file" "$BASE" <<'PY' > "$output_file"
import json, pathlib, sys

stack_path = pathlib.Path(sys.argv[1])
preview_path = pathlib.Path(sys.argv[2])
base = pathlib.Path(sys.argv[3])
stack = json.loads(stack_path.read_text()) if stack_path.exists() else {}
parts = []
for filename in stack.get("compose_files", []):
    parts.extend(["-f", str(base / filename)])
if preview_path.exists():
    parts.extend(["-f", str(preview_path)])
if parts:
    sys.stdout.buffer.write(b"\0".join(part.encode() for part in parts) + b"\0")
PY
}

worker_test_compose_args_array() {
  local args_file
  args_file="$(mktemp)"
  worker_test_compose_args_file "$args_file" "${1:-$TEST_PREVIEW_COMPOSE_FILE}"
  local -a args=()
  while IFS= read -r -d '' part; do
    args+=("$part")
  done < "$args_file"
  rm -f "$args_file"
  printf '%s\0' "${args[@]}"
}

worker_test_compose_up_flags_file() {
  local output_file="$1"
  python3 - "$TEST_STACK_FILE" <<'PY' > "$output_file"
import json, pathlib, sys

stack_path = pathlib.Path(sys.argv[1])
stack = json.loads(stack_path.read_text()) if stack_path.exists() else {}
parts = []
for flag in stack.get("compose_up_flags", []):
    parts.append(str(flag))
if parts:
    sys.stdout.buffer.write(b"\0".join(part.encode() for part in parts) + b"\0")
PY
}

worker_test_compose_up() {
  local args_file flags_file
  args_file="$(mktemp)"
  flags_file="$(mktemp)"
  worker_test_compose_args_file "$args_file"
  worker_test_compose_up_flags_file "$flags_file"

  local -a args=() up_flags=()
  while IFS= read -r -d '' part; do
    args+=("$part")
  done < "$args_file"
  rm -f "$args_file"

  while IFS= read -r -d '' part; do
    up_flags+=("$part")
  done < "$flags_file"
  rm -f "$flags_file"

  docker compose "${args[@]}" up "${up_flags[@]}" -d
}

worker_test_current_sidecar_services() {
  local runtime_file="${1:-$TEST_RUNTIME_FILE}"
  [ -f "$runtime_file" ] || return 0
  python3 - "$runtime_file" <<'PY'
import json, pathlib, sys

runtime = json.loads(pathlib.Path(sys.argv[1]).read_text())
for item in runtime.get("services", []):
    print(item["sidecar_service"])
PY
}

worker_test_remove_previous_sidecars() {
  [ -f "$TEST_RUNTIME_FILE" ] || return 0
  [ -f "$TEST_PREVIEW_COMPOSE_FILE" ] || return 0

  local args_file
  args_file="$(mktemp)"
  worker_test_compose_args_file "$args_file" "$TEST_PREVIEW_COMPOSE_FILE"

  local -a args=()
  while IFS= read -r -d '' part; do
    args+=("$part")
  done < "$args_file"
  rm -f "$args_file"

  local -a services=()
  while IFS= read -r service; do
    [ -n "$service" ] && services+=("$service")
  done < <(worker_test_current_sidecar_services)

  [ "${#services[@]}" -gt 0 ] || return 0

  for service in "${services[@]}"; do
    local cid
    cid="$(docker compose "${args[@]}" ps -q "$service" 2>/dev/null || true)"
    if [ -n "$cid" ]; then
      docker exec "$cid" tailscale logout >/dev/null 2>&1 || true
    fi
  done

  docker compose "${args[@]}" stop "${services[@]}" >/dev/null 2>&1 || true
  docker compose "${args[@]}" rm -f "${services[@]}" >/dev/null 2>&1 || true
}

worker_test_wait_for_sidecars() {
  local args_file
  args_file="$(mktemp)"
  worker_test_compose_args_file "$args_file"

  local -a args=()
  while IFS= read -r -d '' part; do
    args+=("$part")
  done < "$args_file"
  rm -f "$args_file"

  python3 - "$TEST_RUNTIME_FILE" <<'PY' | while IFS=$'\t' read -r sidecar_service expected_hostname; do
import json, pathlib, sys

runtime = json.loads(pathlib.Path(sys.argv[1]).read_text())
for item in runtime.get("services", []):
    print(f"{item['sidecar_service']}\t{item['node_hostname']}")
PY
    local ok=0
    local attempt
    for attempt in $(seq 1 30); do
      local cid status_json dns_name
      cid="$(docker compose "${args[@]}" ps -q "$sidecar_service" 2>/dev/null || true)"
      if [ -z "$cid" ]; then
        sleep 2
        continue
      fi
      status_json="$(docker exec "$cid" tailscale status --json 2>/dev/null || true)"
      dns_name="$(python3 - "$status_json" <<'PY'
import json, sys

raw = sys.argv[1]
if not raw.strip():
    print("")
    raise SystemExit(0)
try:
    data = json.loads(raw)
except Exception:
    print("")
    raise SystemExit(0)
print(((data.get("Self") or {}).get("HostName") or "").strip())
PY
)"
      if [ "$dns_name" = "$expected_hostname" ]; then
        ok=1
        break
      fi
      sleep 2
    done
    if [ "$ok" -ne 1 ]; then
      echo "Timed out waiting for Tailscale sidecar: $sidecar_service" >&2
      exit 1
    fi
  done
}

worker_test_refresh_runtime_urls_from_sidecars() {
  local args_file
  args_file="$(mktemp)"
  worker_test_compose_args_file "$args_file"

  local -a args=()
  while IFS= read -r -d '' part; do
    args+=("$part")
  done < "$args_file"
  rm -f "$args_file"

  local tmp_dns
  tmp_dns="$(mktemp)"

  python3 - "$TEST_RUNTIME_FILE" <<'PY' | while IFS=$'\t' read -r sidecar_service; do
import json, pathlib, sys

runtime = json.loads(pathlib.Path(sys.argv[1]).read_text())
for item in runtime.get("services", []):
    print(item["sidecar_service"])
PY
    local cid status_json dns_name
    cid="$(docker compose "${args[@]}" ps -q "$sidecar_service" 2>/dev/null || true)"
    [ -n "$cid" ] || continue
    status_json="$(docker exec "$cid" tailscale status --json 2>/dev/null || true)"
    dns_name="$(python3 - "$status_json" <<'PY'
import json, sys

raw = sys.argv[1]
if not raw.strip():
    print("")
    raise SystemExit(0)
try:
    data = json.loads(raw)
except Exception:
    print("")
    raise SystemExit(0)
print((((data.get("Self") or {}).get("DNSName")) or "").rstrip("."))
PY
)"
    [ -n "$dns_name" ] || continue
    printf '%s\t%s\n' "$sidecar_service" "$dns_name" >> "$tmp_dns"
  done

  local refresh_result
  refresh_result="$(python3 - "$TEST_RUNTIME_FILE" "$TEST_ENV_FILE" "$tmp_dns" <<'PY'
import json, pathlib, sys

runtime_path = pathlib.Path(sys.argv[1])
env_path = pathlib.Path(sys.argv[2])
dns_path = pathlib.Path(sys.argv[3])

runtime = json.loads(runtime_path.read_text())
dns_by_sidecar = {}
if dns_path.exists():
    for line in dns_path.read_text().splitlines():
        if "\t" not in line:
            continue
        sidecar, dns_name = line.split("\t", 1)
        dns_by_sidecar[sidecar] = dns_name.strip()

changed = False
service_urls = {}
for item in runtime.get("services", []):
    dns_name = dns_by_sidecar.get(item["sidecar_service"], "").strip()
    actual_url = f"https://{dns_name}" if dns_name else item.get("url", "")
    if item.get("url") != actual_url:
        item["url"] = actual_url
        changed = True
    service_urls[item["key"]] = item.get("url", "")

env_lines = []
for item in runtime.get("preview_env", []):
    value = service_urls.get(item["from_service"], item.get("value", ""))
    if item.get("value") != value:
        item["value"] = value
        changed = True
    env_lines.append(f"{item['name']}={value}")

runtime_path.write_text(json.dumps(runtime, indent=2) + "\n")
env_path.write_text("\n".join(env_lines) + ("\n" if env_lines else ""))
print("changed" if changed else "unchanged")
PY
)"
  rm -f "$tmp_dns"
  printf '%s\n' "$refresh_result"
}

worker_test_apply_routes() {
  local args_file
  args_file="$(mktemp)"
  worker_test_compose_args_file "$args_file"

  local -a args=()
  while IFS= read -r -d '' part; do
    args+=("$part")
  done < "$args_file"
  rm -f "$args_file"

  python3 - "$TEST_RUNTIME_FILE" <<'PY' | while IFS=$'\t' read -r sidecar_service target; do
import json, pathlib, sys

runtime = json.loads(pathlib.Path(sys.argv[1]).read_text())
for item in runtime.get("services", []):
    print(f"{item['sidecar_service']}\t{item['target']}")
PY
    local cid
    cid="$(docker compose "${args[@]}" ps -q "$sidecar_service" 2>/dev/null || true)"
    [ -n "$cid" ] || {
      echo "Missing sidecar container for $sidecar_service" >&2
      exit 1
    }
    docker exec "$cid" tailscale funnel reset >/dev/null 2>&1 || true
    docker exec "$cid" tailscale funnel --bg "$target"
  done
}

worker_test_print_summary() {
  python3 - "$TEST_RUNTIME_FILE" <<'PY'
import json, pathlib, sys

runtime = json.loads(pathlib.Path(sys.argv[1]).read_text())

print("configured preview urls:")
for item in runtime.get("services", []):
    print(f"- {item['key']}: {item['url']} -> {item['compose_service']} ({item['scheme']}:{item['port']})")

if runtime.get("preview_env"):
    print("\npreview env:")
    for item in runtime["preview_env"]:
        print(f"- {item['compose_service']}: {item['name']}={item['value']}")
PY
}

worker_test_status_verify() {
  local args_file
  args_file="$(mktemp)"
  worker_test_compose_args_file "$args_file"

  local -a args=()
  while IFS= read -r -d '' part; do
    args+=("$part")
  done < "$args_file"
  rm -f "$args_file"

  python3 - "$TEST_RUNTIME_FILE" <<'PY' | while IFS=$'\t' read -r key sidecar_service expected_hostname url; do
import json, pathlib, sys

runtime = json.loads(pathlib.Path(sys.argv[1]).read_text())
for item in runtime.get("services", []):
    print(f"{item['key']}\t{item['sidecar_service']}\t{item['node_hostname']}\t{item['url']}")
PY
    local cid state
    cid="$(docker compose "${args[@]}" ps -q "$sidecar_service" 2>/dev/null || true)"
    if [ -z "$cid" ]; then
      state="stopped"
    else
      local status_json hostname
      status_json="$(docker exec "$cid" tailscale status --json 2>/dev/null || true)"
      hostname="$(python3 - "$status_json" <<'PY'
import json, sys

raw = sys.argv[1]
if not raw.strip():
    print("")
    raise SystemExit(0)
try:
    data = json.loads(raw)
except Exception:
    print("")
    raise SystemExit(0)
print(((data.get("Self") or {}).get("HostName") or "").strip())
PY
)"
      if [ "$hostname" = "$expected_hostname" ]; then
        state="active"
      else
        state="starting"
      fi
    fi
    printf -- "- %s: %s %s\n" "$key" "$state" "$url"
  done
}
