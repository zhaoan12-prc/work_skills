---
name: claude-amd-direct-setup
description: Installs, configures, repairs, and verifies Claude Code against the direct AMD LLM Gateway. Use for AMD Gateway authentication, missing subscription-key errors, apiKeyHelper failures, wrong Claude entrypoints, upgrades that bypass wrappers, stale Claude binaries, broken bashrc login shells, missing user header errors, or claude -p diagnostics.
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

This layout is intentional. The official updater owns
`~/.local/bin/claude`; putting the wrapper there causes the next update to
silently replace it. A separate `~/bin/claude` wrapper survives updates while
always invoking the newest official binary.

## Supported direct models

Use only:

- `claude-sonnet-4.6` (default)
- `claude-opus-4.6`

Normalize `opus[1m]`, `claude-opus-4.5[1m]`, retired models, and unknown values
to `claude-sonnet-4.6`, unless the user explicitly requests the supported Opus
model.

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
- [ ] Existing Claude sessions were restarted.
