#!/usr/bin/env bash
# Install the Claude Agent SDK (Python package `claude-agent-sdk`) and prove it
# reaches the AMD gateway through the ~/bin/claude wrapper.
#
# Usage:
#   install_sdk.sh [--python PY] [--target DIR] [--model MODEL] [--no-request]
#
#   --python PY   interpreter that will import the SDK (default: python3).
#                 The SDK needs Python >= 3.10.
#   --target DIR  install into DIR with `pip --target` instead of into PY's
#                 environment. Use this when PY's environment must not change
#                 (e.g. /opt/venv in an sglang/vLLM serving image). Programs
#                 must then append DIR to sys.path.
#   --model M     model for the verification request (default: from settings.json).
#   --no-request  install and import only; skip the real request.
set -euo pipefail

py=python3
target=""
model=""
do_request=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --python) py="$2"; shift 2 ;;
    --target) target="$2"; shift 2 ;;
    --model) model="$2"; shift 2 ;;
    --no-request) do_request=0; shift ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

wrapper="${HOME}/bin/claude"
if [[ ! -x "$wrapper" ]]; then
  echo "Missing wrapper ${wrapper}; run install.sh first." >&2
  exit 1
fi

"$py" - <<'PY' || { echo "claude-agent-sdk needs Python >= 3.10 (got $("$py" -V 2>&1))." >&2; exit 1; }
import sys
sys.exit(0 if sys.version_info >= (3, 10) else 1)
PY

if [[ -n "$target" ]]; then
  mkdir -p "$target"
  target="$(cd "$target" && pwd)"
  "$py" -m pip install --quiet --upgrade --target "$target" claude-agent-sdk
else
  "$py" -m pip install --quiet --upgrade claude-agent-sdk
fi

if [[ -z "$model" && -f "${HOME}/.claude/settings.json" ]]; then
  model="$("$py" -c 'import json,sys; print(json.load(open(sys.argv[1])).get("model",""))' \
    "${HOME}/.claude/settings.json")"
fi

SDK_TARGET="$target" SDK_MODEL="$model" SDK_REQUEST="$do_request" CLAUDE_WRAPPER="$wrapper" \
  "$py" - <<'PY'
import asyncio
import os
import sys

if os.environ["SDK_TARGET"]:
    # Append, never insert: the host environment's packages keep precedence.
    sys.path.append(os.environ["SDK_TARGET"])

import claude_agent_sdk
from claude_agent_sdk import ClaudeAgentOptions, ResultMessage, query

version = getattr(claude_agent_sdk, "__version__", "unknown")
print("OK: import claude_agent_sdk {} from {}".format(version, claude_agent_sdk.__file__))
if os.environ["SDK_REQUEST"] != "1":
    sys.exit(0)


async def main():
    # cli_path pins the AMD wrapper. Without it the SDK spawns whatever
    # `claude` is first on PATH, which may be the raw binary without AMD headers.
    opts = ClaudeAgentOptions(cli_path=os.environ["CLAUDE_WRAPPER"], max_turns=1,
                              model=os.environ["SDK_MODEL"] or None)
    models, result = set(), None
    async for msg in query(prompt="Reply with exactly: SDK OK", options=opts):
        if getattr(msg, "model", None):
            models.add(msg.model)
        if isinstance(msg, ResultMessage):
            result = msg
            models.update((getattr(msg, "model_usage", None) or {}).keys())
    if result is None or result.is_error or "SDK OK" not in (result.result or ""):
        print("ERROR: SDK request failed: {!r}".format(getattr(result, "result", None)),
              file=sys.stderr)
        sys.exit(1)
    print("OK: SDK request answered via {} (model: {})".format(
        os.environ["CLAUDE_WRAPPER"], ", ".join(sorted(models)) or "unreported"))


asyncio.run(main())
PY
