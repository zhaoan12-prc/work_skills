#!/usr/bin/env bash
set -uo pipefail

wrapper="${HOME}/bin/claude"
official="${HOME}/.local/bin/claude"
env_file="${HOME}/.claude/amd-gateway.env"
settings="${HOME}/.claude/settings.json"
resolved="$(command -v claude 2>/dev/null || true)"

path_order="missing"
wrapper_index=-1
official_index=-1
index=0
IFS=: read -r -a path_parts <<< "${PATH:-}"
for part in "${path_parts[@]}"; do
  [[ "$part" == "${HOME}/bin" && "$wrapper_index" -lt 0 ]] && wrapper_index=$index
  [[ "$part" == "${HOME}/.local/bin" && "$official_index" -lt 0 ]] && official_index=$index
  index=$((index + 1))
done
if [[ "$wrapper_index" -ge 0 && "$official_index" -ge 0 ]]; then
  if [[ "$wrapper_index" -lt "$official_index" ]]; then
    path_order="ok"
  else
    path_order="reversed"
  fi
fi

env_mode="missing"
if [[ -f "$env_file" ]]; then
  env_mode="$(stat -c '%a' "$env_file" 2>/dev/null || echo unknown)"
fi

settings_state="$(
  python3 - "$settings" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
try:
    data = json.loads(path.read_text())
except FileNotFoundError:
    print("missing")
except (OSError, ValueError):
    print("invalid")
else:
    allowed = {"apiKeyHelper", "model"}
    model = data.get("model")
    helper = data.get("apiKeyHelper")
    if set(data) - allowed:
        print("extra_fields")
    elif model not in {"claude-sonnet-4.6", "claude-opus-4.6"}:
        print("unsupported_model")
    elif not isinstance(helper, str) or "AMD_LLM_GATEWAY_KEY" not in helper:
        print("bad_helper")
    else:
        print("ok")
PY
)"

wrapper_exists=false
official_exists=false
[[ -x "$wrapper" ]] && wrapper_exists=true
[[ -x "$official" ]] && official_exists=true

official_target="missing"
official_layout="missing"
if [[ "$official_exists" == true ]]; then
  official_target="$(readlink -f "$official" 2>/dev/null || printf '%s' "$official")"
  case "$official_target" in
    "${HOME}/.local/share/claude/versions/"*)
      official_layout="managed"
      ;;
    *)
      official_layout="unexpected_target"
      ;;
  esac
fi

status=ok
if [[ "$resolved" != "$wrapper" ||
      "$wrapper_exists" != true ||
      "$official_exists" != true ||
      "$official_layout" != managed ||
      "$path_order" != ok ||
      "$env_mode" != 600 ||
      "$settings_state" != ok ]]; then
  status=repair_required
fi

python3 - "$status" "$resolved" "$wrapper" "$wrapper_exists" \
  "$official" "$official_exists" "$official_target" "$official_layout" \
  "$path_order" "$env_mode" "$settings_state" <<'PY'
import json
import sys

print(json.dumps({
    "status": sys.argv[1],
    "command": sys.argv[2] or None,
    "expected_wrapper": sys.argv[3],
    "wrapper_executable": sys.argv[4] == "true",
    "official_binary": sys.argv[5],
    "official_binary_executable": sys.argv[6] == "true",
    "official_binary_target": sys.argv[7],
    "official_binary_layout": sys.argv[8],
    "path_order": sys.argv[9],
    "secret_file_mode": sys.argv[10],
    "settings": sys.argv[11],
}, indent=2))
PY

[[ "$status" == ok ]]
