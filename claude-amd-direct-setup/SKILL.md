---
name: claude-amd-direct-setup
description: Installs, repairs, and verifies Claude Code against the direct AMD LLM Gateway. Use for AMD Gateway authentication, missing subscription-key errors, apiKeyHelper failures, wrong Claude entrypoints, upgrades that bypass wrappers, stale Claude binaries, or claude-route and claude -p diagnostics.
---

# Claude AMD Direct Setup

Configure Claude Code so `claude` always reaches the AMD Anthropic-compatible
gateway with the subscription-key header. Keep secrets outside repositories and
prove success with a real request.

## Required end state

- Official Claude Code remains at `~/.local/bin/claude`.
- The stable wrapper is `~/bin/claude`.
- `~/bin` precedes `~/.local/bin` in `PATH`.
- The wrapper loads `~/.claude/amd-gateway.env`.
- The wrapper exports:

```bash
export ANTHROPIC_BASE_URL="https://llm-api.amd.com/Anthropic"
export ANTHROPIC_CUSTOM_HEADERS="Ocp-Apim-Subscription-Key: ${AMD_LLM_GATEWAY_KEY}"
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

1. Ask for `AMD_LLM_GATEWAY_KEY` before writing secret-bearing files.
2. Never print the key or put it in commands that may enter shell history.
3. Store it only in `~/.claude/amd-gateway.env`, mode `600`.
4. Never put a real key in a repository, `SKILL.md`, logs, or test output.
5. Do not use `apiKeyHelper` as the gateway authentication mechanism. AMD
   requires `Ocp-Apim-Subscription-Key` through `ANTHROPIC_CUSTOM_HEADERS`.
6. Do not claim success from configuration inspection or `claude-route`; run
   a real `claude -p` request.
7. Do not overwrite an official binary until its version and replacement have
   been identified.

## Workflow

### 1. Inspect without leaking credentials

Run:

```bash
command -v claude
readlink -f "$(command -v claude)"
claude --version
test -x "$HOME/.local/bin/claude" && "$HOME/.local/bin/claude" --version
test -f "$HOME/.claude/amd-gateway.env" && echo env_file_exists
bash work_skills/claude-amd-direct-setup/scripts/healthcheck.sh
```

Interpret entrypoints carefully:

- Healthy: `command -v claude` is `~/bin/claude`.
- Bypassed wrapper: it resolves to `~/.local/bin/claude`.
- Legacy layout: it resolves to `/usr/local/bin/claude`, often forwarding to a
  stale `/usr/local/bin/claude.real`.

Check running sessions separately. Configuration is not hot-reloaded; old
Claude processes must be restarted.

### 2. Install or update the official binary first

```bash
curl -fsSL https://claude.ai/install.sh | bash
```

After installation, verify the official binary directly:

```bash
"$HOME/.local/bin/claude" --version
```

If installation downloads a binary and hangs, preserve the executable before
stopping the installer. Do not replace a known-working binary with an
unverified download.

### 3. Write the secret file

Avoid passing the key as a command-line argument. Write it from a protected
interactive input or an already populated environment variable:

```bash
mkdir -p "$HOME/.claude"
umask 077
printf 'export AMD_LLM_GATEWAY_KEY="%s"\n' "$AMD_LLM_GATEWAY_KEY" \
  > "$HOME/.claude/amd-gateway.env"
chmod 600 "$HOME/.claude/amd-gateway.env"
```

The file must contain one export and no extra output.

### 4. Write minimal settings

```json
{
  "apiKeyHelper": "bash -lc 'printf %s \"$AMD_LLM_GATEWAY_KEY\"'",
  "model": "claude-sonnet-4.6"
}
```

`apiKeyHelper` satisfies Claude Code's external-key mode. The actual AMD
gateway authentication still comes from `ANTHROPIC_CUSTOM_HEADERS`.

Do not add `/Unified` settings from the legacy guide. This direct-mode skill
uses `https://llm-api.amd.com/Anthropic`.

### 5. Create the stable wrapper

Create `~/bin/claude` with this behavior:

```bash
#!/usr/bin/env bash
set -euo pipefail

env_file="${HOME}/.claude/amd-gateway.env"
real_claude="${HOME}/.local/bin/claude"

if [[ -z "${AMD_LLM_GATEWAY_KEY:-}" && -f "$env_file" ]]; then
  set +u
  source "$env_file"
  set -u
fi

if [[ -z "${AMD_LLM_GATEWAY_KEY:-}" ]]; then
  echo "AMD gateway key is missing: $env_file" >&2
  exit 1
fi
if [[ ! -x "$real_claude" ]]; then
  echo "Official Claude binary is missing: $real_claude" >&2
  exit 1
fi

export CLAUDE_AMD_WRAPPER=1
export ANTHROPIC_BASE_URL="https://llm-api.amd.com/Anthropic"
export ANTHROPIC_CUSTOM_HEADERS="Ocp-Apim-Subscription-Key: ${AMD_LLM_GATEWAY_KEY}"
export CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1

exec "$real_claude" "$@"
```

Make it executable:

```bash
chmod 700 "$HOME/bin/claude"
```

Never make `~/.local/bin/claude` point back to this wrapper; that creates an
updater conflict and can create recursion.

### 6. Fix PATH ordering

Ensure `~/bin` comes before `~/.local/bin`:

```bash
export PATH="$HOME/bin:$HOME/.local/bin:$PATH"
```

Persist the equivalent once in the appropriate shell startup file. Remove
duplicate or reversed PATH fragments. Then clear command lookup caching:

```bash
hash -r
command -v claude
```

### 7. Verify in order

First run the non-secret healthcheck:

```bash
bash work_skills/claude-amd-direct-setup/scripts/healthcheck.sh
```

Then run a real request:

```bash
claude -p --output-format json 'Reply with exactly: API OK'
```

Verify the response model:

```bash
claude -p --output-format json 'Reply with exactly: API OK' |
  python3 work_skills/claude-amd-direct-setup/scripts/verify_output_model.py
```

Finally verify tool use when required:

```bash
claude -p --output-format json --allowedTools Bash -- \
  'Use Bash to run pwd, then answer with only the absolute path.'
```

Restart any Claude process that was already running before the repair.

## Failure diagnosis

- `apiKeyHelper script is failing`: the wrapper was bypassed, the env file is
  missing, or the process predates the repair.
- `Invalid API key`: the AMD key was sent to the official Anthropic endpoint;
  check `command -v claude`, wrapper execution, and `ANTHROPIC_BASE_URL`.
- `401 missing subscription key`: `ANTHROPIC_CUSTOM_HEADERS` is absent or not
  the single string `Ocp-Apim-Subscription-Key: ...`.
- Route inspection looks healthy but requests fail: route inspection is not
  proof; inspect the real `claude -p` error.
- Claude version becomes older after repair: a legacy wrapper is invoking
  `/usr/local/bin/claude.real`; migrate to the user-local layout above.
- A Claude update breaks routing: confirm the updater changed
  `~/.local/bin/claude`, keep that binary intact, and restore PATH precedence
  for `~/bin`.
- Retired-model warning: normalize `~/.claude/settings.json`, then restart.
- Experimental beta-header error: ensure
  `CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1` is exported by the wrapper.

## Completion checklist

- [ ] No secret entered repository files or output.
- [ ] `~/.claude/amd-gateway.env` exists with mode `600`.
- [ ] `~/.local/bin/claude` is the current official binary.
- [ ] `~/bin/claude` is the wrapper and is mode `700`.
- [ ] `~/bin` precedes `~/.local/bin`.
- [ ] The wrapper exports the AMD base URL and subscription header.
- [ ] Settings contain only `apiKeyHelper` and a supported model.
- [ ] Healthcheck passes.
- [ ] A real text request succeeds.
- [ ] Response model verification succeeds.
- [ ] Existing Claude sessions were restarted.
