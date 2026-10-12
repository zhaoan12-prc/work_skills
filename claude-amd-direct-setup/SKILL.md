---
name: claude-amd-direct-setup
description: Installs, configures, repairs, and verifies Claude Code against the direct AMD LLM Gateway. Use for AMD Gateway authentication, missing subscription-key errors, apiKeyHelper failures, wrong Claude entrypoints, upgrades that bypass wrappers, stale Claude binaries, broken bashrc login shells, missing user header errors, claude -p diagnostics, installing the Claude Agent SDK (claude_agent_sdk) for programs that drive Claude from Python, or setting Claude up inside a container.
---

# Claude AMD Direct Setup

Configure Claude Code so `claude` always reaches the AMD Anthropic-compatible
gateway with the subscription-key and user headers. Keep secrets outside
repositories and prove success with a real request.

## Required end state

- Official Claude Code remains at `~/.local/bin/claude`.
- The stable wrapper is `~/bin/claude`.
- `~/bin` precedes `~/.local/bin` in `PATH`.
- The wrapper loads `~/.claude/amd-gateway.env`.
- The wrapper exports:

```bash
export ANTHROPIC_BASE_URL="https://llm-api.amd.com/Anthropic"
export ANTHROPIC_CUSTOM_HEADERS=$'Ocp-Apim-Subscription-Key: '"${AMD_LLM_GATEWAY_KEY}"$'\nuser: '"$(id -un)"
export AMD_LLM_GATEWAY_KEY
```

- `~/.claude/settings.json` contains only `apiKeyHelper` and a supported model.
- A real `claude -p` request succeeds.
- When a Python program drives Claude (for example GEAK `run_e2e.py`),
  `claude_agent_sdk` is importable by that program's interpreter and a real SDK
  request through `~/bin/claude` succeeds.

This layout is intentional. The official updater owns
`~/.local/bin/claude`; putting the wrapper there causes the next update to
silently replace it. A separate `~/bin/claude` wrapper survives updates while
always invoking the newest official binary.

## Supported direct models

Use only:

- `claude-sonnet-4.6` (default)
- `claude-opus-4.6`
- `claude-opus-5.5`

Normalize `opus[1m]`, `claude-opus-4.5[1m]`, retired models, and unknown values
to `claude-sonnet-4.6`, unless the user explicitly requests a supported Opus
model.

The interactive banner may abbreviate `claude-opus-5.5` as "Opus 5". Copy model
IDs from `settings.json` or from `modelUsage` in JSON output, never from the
banner: `claude-opus-5` is a different ID.

## Safety rules

1. Never put a real API key in this skill, a repository, chat logs, or test
   output.
2. When the user explicitly authorizes automated setup, prefer
   `AMD_LLM_GATEWAY_KEY` or stdin over interactive prompts. Do not echo the key.
3. Store the key only in `~/.claude/amd-gateway.env`, mode `600`.
4. Do not use `apiKeyHelper` as the gateway authentication mechanism. AMD
   requires `Ocp-Apim-Subscription-Key` and `user` through
   `ANTHROPIC_CUSTOM_HEADERS`.
5. Do not claim success from configuration inspection alone; run a real
   `claude -p` request.
6. Do not overwrite an official binary until its version and replacement have
   been identified.
7. Restart existing Claude sessions after changing the wrapper or config.

## Preferred workflow

### 1. Run the installer

From the repository root:

```bash
bash work_skills/claude-amd-direct-setup/scripts/install.sh
```

Optional model:

```bash
bash work_skills/claude-amd-direct-setup/scripts/install.sh claude-opus-4.6
```

The installer resolves the AMD key in this order:

1. `AMD_LLM_GATEWAY_KEY` environment variable
2. Existing `~/.claude/amd-gateway.env`
3. Stdin when the script is not attached to a TTY
4. Secure interactive prompt

Automated examples when the user explicitly provides the key:

```bash
AMD_LLM_GATEWAY_KEY='<secret>' bash work_skills/claude-amd-direct-setup/scripts/install.sh
printf '%s\n' '<secret>' | bash work_skills/claude-amd-direct-setup/scripts/install.sh
```

The script writes the env file, settings, wrapper, PATH, installs the official
binary if missing, runs healthcheck, and performs a real request.

### 2. Inspect without leaking credentials

```bash
command -v claude
readlink -f "$(command -v claude)"
claude --version
test -f "$HOME/.claude/amd-gateway.env" && stat -c '%a %n' "$HOME/.claude/amd-gateway.env"
bash work_skills/claude-amd-direct-setup/scripts/healthcheck.sh
```

Interpret entrypoints carefully:

- Healthy: `command -v claude` is `~/bin/claude`.
- Bypassed wrapper: it resolves to `~/.local/bin/claude`.
- Legacy layout: it resolves to `/usr/local/bin/claude`.

Configuration is not hot-reloaded; old Claude processes must be restarted.

### 3. Verify independently

```bash
claude -p --output-format json 'Reply with exactly: API OK'
claude -p --output-format json 'Reply with exactly: API OK' |
  python3 work_skills/claude-amd-direct-setup/scripts/verify_output_model.py
```

### 4. Install the Claude Agent SDK (when a program drives Claude from Python)

`claude-agent-sdk` (import name `claude_agent_sdk`) is the official Python
package for driving Claude Code from code. It does not talk to the API itself:
it spawns the `claude` CLI and streams its messages, and it keeps the session
alive until the agent's work is finished.

Install it whenever a tool launches Claude from Python. GEAK `run_e2e.py` is
the main case: it imports `claude_agent_sdk` and silently falls back to
`claude -p` when the import fails. `claude -p` ends when the first answer ends,
so a long background Workflow is torn down minutes after it starts. The result
reports `workflow_parse_error`, and orphan serving processes may be left
behind. A working `claude -p` therefore does not prove that the SDK path works.

The SDK needs Python >= 3.10. Install it into the interpreter that will import
it, and prove it with a real request:

```bash
# Normal environment
bash work_skills/claude-amd-direct-setup/scripts/install_sdk.sh --python python3

# Environment that must not change (e.g. /opt/venv in an sglang/vLLM image):
# install beside it and append the directory to sys.path in the launcher.
bash work_skills/claude-amd-direct-setup/scripts/install_sdk.sh \
  --python /opt/venv/bin/python --target <run_dir>/_tooling/sdk_site
```

The script installs the package, imports it, then sends a real SDK request with
`cli_path=~/bin/claude` and prints the models that answered. Success looks like:

```text
OK: import claude_agent_sdk 0.2.165 from <target>/claude_agent_sdk/__init__.py
OK: SDK request answered via /root/bin/claude (model: claude-opus-5-5, claude-opus-5.5)
```

Rules for programs that use the SDK:

- Point the SDK at the wrapper: `ClaudeAgentOptions(cli_path="~/bin/claude")`
  (expanded), or for GEAK `GEAK_CLAUDE_BIN=$HOME/bin/claude`. Otherwise it
  spawns whatever `claude` comes first on `PATH`, and the raw binary has no AMD
  headers.
- With `--target`, append the directory to `sys.path`; never put it in front,
  or it can shadow the environment's own packages (pydantic, anyio, ...).
  Do not export it through `PYTHONPATH`, because child processes such as
  serving engines would inherit it.
- After launch, check that the SDK path is really in use: the process tree
  shows `claude --output-format stream-json ... --model <id>` under the Python
  program, and the program's log grows. If you only see `claude -p`, the import
  failed.

### 5. Inside a container

Containers start with a bare root home. Set up the same layout under `/root`:

1. Copy the official binary to `/root/.local/share/claude/versions/<ver>` and
   link it as `/root/.local/bin/claude`. A read-only mount of the host's
   `~/.local/share/claude` is a convenient source.
2. Copy the wrapper to `/root/bin/claude` (mode `700`), write
   `/root/.claude/amd-gateway.env` (mode `600`) from the current key, and write
   `/root/.claude/settings.json` as in this skill.
3. Add `export PATH="$HOME/bin:$HOME/.local/bin:$PATH"` to `/root/.bashrc` and
   `source` it. Without this the shell reports `claude: command not found`, or
   runs the raw binary.
4. Run `claude -p --output-format json 'Reply with exactly: API OK'` and check
   `modelUsage`.
5. Run `install_sdk.sh` (step 4) with the container's interpreter, using
   `--target` when the image's environment must not change.
6. For unattended work as root, start Claude with
   `IS_SANDBOX=1 claude --dangerously-skip-permissions`. On first start, accept
   the theme and security notes, and choose "Yes, I trust this folder" (the
   default selection is "No, exit").

Mount only what the work needs (working directory read-write, models and
reference repositories read-only) instead of a whole data root.

## Manual config reference

### Secret file

```bash
mkdir -p "$HOME/.claude"
umask 077
printf 'export AMD_LLM_GATEWAY_KEY="%s"\n' "$AMD_LLM_GATEWAY_KEY" \
  > "$HOME/.claude/amd-gateway.env"
chmod 600 "$HOME/.claude/amd-gateway.env"
```

### Settings

Use `bash -c`, not `bash -lc`. Login shells source `~/.bashrc`; a broken
`.bashrc` makes `apiKeyHelper` return empty and breaks interactive Claude.

```json
{
  "apiKeyHelper": "bash -c 'set -a; [ -f \"$HOME/.claude/amd-gateway.env\" ] && . \"$HOME/.claude/amd-gateway.env\"; set +a; printf %s \"$AMD_LLM_GATEWAY_KEY\"'",
  "model": "claude-sonnet-4.6"
}
```

### Wrapper

The AMD Anthropic gateway requires both headers:

- `Ocp-Apim-Subscription-Key`
- `user: <os-username>`

Use newline-separated `ANTHROPIC_CUSTOM_HEADERS` and export
`AMD_LLM_GATEWAY_KEY` before launching the official binary. See
`scripts/install.sh` for the canonical wrapper.

### PATH

```bash
export PATH="$HOME/bin:$HOME/.local/bin:$PATH"
```

Validate shell startup files with `bash -n ~/.bashrc` after edits.

## Failure diagnosis

- `apiKeyHelper failed: did not return a value`: env file missing, wrapper not
  used, old session still running, or `apiKeyHelper` uses fragile `bash -lc`
  against a broken `~/.bashrc`.
- `400 The 'user' header with a valid User`: wrapper missing the `user` header.
- `Invalid API key`: request went to official Anthropic instead of AMD; check
  wrapper, `ANTHROPIC_BASE_URL`, and PATH order.
- `401 missing subscription key`: `ANTHROPIC_CUSTOM_HEADERS` missing or wrong.
- `/model` removed `model` from settings or added extra fields: rerun installer
  or restore supported model in `settings.json`, then restart.
- Retired-model warning: normalize settings to a supported model, then restart.
- Healthcheck shows `fragile_helper`: replace `bash -lc` apiKeyHelper with the
  env-file reader from this skill.
- `ModuleNotFoundError: No module named 'claude_agent_sdk'`, or a launcher that
  "falls back to claude -p": install the SDK for that interpreter (step 4).
- A background Workflow dies minutes after launch and the result says
  `workflow_parse_error`: the launcher used `claude -p` instead of the SDK.
  Install the SDK, stop leftover child processes, and relaunch from scratch.
- `claude-agent-sdk` fails to install or import on an old interpreter: it
  needs Python >= 3.10. Use the program's own interpreter, not the system
  `python3`.
- SDK requests fail with `Invalid API key` or missing-header errors while
  `claude -p` works: the SDK spawned the raw binary. Pass
  `cli_path=~/bin/claude` (expanded) or fix `PATH` order.
- `claude: command not found` in a fresh container: `/root/.bashrc` lacks the
  `PATH` line from step 5.

## Completion checklist

- [ ] No secret entered repository files or output.
- [ ] `~/.claude/amd-gateway.env` exists with mode `600`.
- [ ] `~/.local/bin/claude` is the current official binary.
- [ ] `~/bin/claude` is the wrapper and is mode `700`.
- [ ] Wrapper exports AMD base URL, subscription key, and user header.
- [ ] `~/bin` precedes `~/.local/bin`.
- [ ] Settings contain only `apiKeyHelper` and a supported model.
- [ ] `bash -n ~/.bashrc` passes.
- [ ] Healthcheck passes.
- [ ] A real text request succeeds.
- [ ] Response model verification succeeds.
- [ ] If a Python program drives Claude: `install_sdk.sh` passed for that
      program's interpreter, including the real SDK request.
- [ ] After launching such a program, the process tree shows the SDK-spawned
      `claude --output-format stream-json`, not `claude -p`.
- [ ] Existing Claude sessions were restarted.
