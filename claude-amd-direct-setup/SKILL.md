---
name: claude-amd-direct-setup
description: Install, configure, repair, and verify Claude Code against AMD LLM Gateway in direct mode. Use when the user mentions Claude Code, AMD LLM Gateway, ANTHROPIC_BASE_URL, ANTHROPIC_CUSTOM_HEADERS, 401 missing subscription key, which claude, claude-route, or claude -p, or when Claude must be forced through a wrapper entrypoint.
---

# Claude AMD Direct Setup

## Purpose

Provide a reusable, local-first workflow for connecting Claude Code directly to AMD LLM Gateway. The intended end state is:

- `claude` always goes through a wrapper before invoking the real Claude Code binary
- `~/.claude/amd-gateway.env` stores the gateway key for non-interactive wrapper use
- `~/.claude/settings.json` keeps only `apiKeyHelper` and `model`
- only the direct AMD Anthropic endpoint is used, with no local proxy fallback
- only `claude-sonnet-4.6` and `claude-opus-4.6` are treated as supported direct models
- validation always includes a real `claude -p` request, not just route inspection or a healthcheck
- if the official installer downloads the binary but hangs during the final install step, setup can still be completed by wiring the downloaded binary into the wrapper flow

## When to Use

- first-time Claude Code installation or reinstallation is needed
- Claude must be locked to AMD Gateway direct mode
- `401 missing subscription key` appears
- `which claude` resolves to the wrong entrypoint and bypasses the wrapper
- `claude-route` looks correct but real `claude -p` requests still fail
- `/model` persisted an AMD-incompatible alias such as `opus[1m]`

## Prerequisites

The wrapper does not need to be prepared in advance. This skill should create or repair the wrapper after Claude Code itself is installed.

Required conditions:

- `bash`, `curl`, and `python3` are available
- the machine can reach the Claude installer and AMD Gateway endpoints
- the user provides `AMD_LLM_GATEWAY_KEY` if automatic local setup is expected
- there is a writable location for the wrapper, usually `/usr/local/bin`
- if `/usr/local/bin` is not usable, pick another stable directory already on `PATH` and ensure `which claude` resolves there

## Non-Negotiable Rules

1. Never write a real gateway key into repository files or print it in output.
2. Always ask for `AMD_LLM_GATEWAY_KEY` before editing any local secret-bearing config.
3. If the user does not provide the key, stop automatic setup and switch to placeholder-only manual guidance.
4. Keep secrets in user-local files, preferably `~/.claude/amd-gateway.env`, not in the repository.
5. Install Claude Code first, then create or repair the wrapper:

```bash
curl -fsSL https://claude.ai/install.sh | bash
```

6. The wrapper must export both of these variables:

```bash
export ANTHROPIC_BASE_URL="https://llm-api.amd.com/Anthropic"
export ANTHROPIC_CUSTOM_HEADERS="Ocp-Apim-Subscription-Key: ${AMD_LLM_GATEWAY_KEY}"
```

7. The second line is critical. `ANTHROPIC_CUSTOM_HEADERS` must be a single string, not JSON.
8. Do not rely only on the default `Authorization` or `X-Api-Key` behavior from `apiKeyHelper`.
9. Keep `~/.claude/settings.json` limited to `apiKeyHelper` and `model`.
10. Default to `claude-sonnet-4.6`. Use `claude-opus-4.6` as the high-tier direct model.
11. If `~/.local/bin` appears earlier in `PATH`, make the `claude` binary there point to the wrapper as well.
12. Never claim success from `claude-route` or healthcheck alone. Run real `claude -p` validation.
13. Do not rely on `~/.bashrc` as the primary secret store. Many `.bashrc` files return early for non-interactive shells.
14. If `.bashrc` must be used, place the key export before any `[ -z "$PS1" ] && return` line.
15. When sourcing user shell files from a wrapper that uses `set -u`, temporarily disable nounset around the `source`.

## Preferred Local Layout

- `~/.claude/amd-gateway.env`
  - stores only `export AMD_LLM_GATEWAY_KEY="PASTE_YOUR_KEY_HERE"` and is chmod `600`
- `~/.bashrc`
  - optional fallback only; if used, the key export must appear before non-interactive early returns
- `~/.claude/settings.json`
  - stores only `apiKeyHelper` and the selected direct model
- `/usr/local/bin/claude`
  - wrapper that loads `~/.claude/amd-gateway.env`, normalizes bad aliases, and forwards to the real Claude binary
- `/usr/local/bin/claude-route`
  - route inspector that reports direct mode, normalized model, and entrypoint information
- `/usr/local/bin/claude.real`
  - the real Claude Code binary, or a symlink to the official downloaded binary
- `~/.local/bin/claude`
  - if this location can win in `PATH`, link it to the wrapper too

## Setup And Repair Workflow

### Step 1: Inspect current state

Check the machine without leaking the key:

- `claude --version`
- `which claude`
- `which claude-route`
- `claude-route`
- `echo "${AMD_LLM_GATEWAY_KEY:+set}"`
- `test -f ~/.claude/amd-gateway.env && echo env_file_exists`
- `bash ".cursor/skills/claude-amd-direct-setup/scripts/healthcheck.sh"`

Never print the real key. Only confirm whether it is set.

### Step 2: Ask for the key if needed

If `AMD_LLM_GATEWAY_KEY` is missing:

- say that the key is still needed
- explain that the real key will be written only to local user files
- if the user does not want to share it, switch to `PASTE_YOUR_KEY_HERE` manual steps

### Step 3: Install Claude Code first

Run the official installer first:

```bash
curl -fsSL https://claude.ai/install.sh | bash
```

Operational notes based on real setup experience:

- the installer may download the binary into `~/.claude/downloads/` and then hang during the final `install` subprocess
- if that happens, do not blindly rerun the installer over and over
- first check whether `~/.claude/downloads/claude-*-linux-x64` exists and is executable
- run `~/.claude/downloads/claude-*-linux-x64 --version`
- if the binary works, copy it to a stable temporary path such as `/usr/local/bin/claude.real.tmp` before killing the stuck installer
- the installer may clean `~/.claude/downloads/` when interrupted, so preserve the binary first
- if the binary works, wire it into `claude.real` and continue with wrapper setup
- if the downloaded binary is gone, directly download the same release URL shown in the installer process into `/usr/local/bin/claude.real`

### Step 4: Write local config

Preferred secret file:

```bash
mkdir -p ~/.claude
cat > ~/.claude/amd-gateway.env <<'EOF'
export AMD_LLM_GATEWAY_KEY="PASTE_YOUR_KEY_HERE"
EOF
chmod 600 ~/.claude/amd-gateway.env
```

Use `~/.bashrc` only as a fallback. If used, insert the export before any line like `[ -z "$PS1" ] && return`; appending to the end of `.bashrc` is often wrong for non-interactive wrappers.

`~/.claude/settings.json` should keep only:

```json
{
  "apiKeyHelper": "bash -lc 'printf %s \"$AMD_LLM_GATEWAY_KEY\"'",
  "model": "claude-sonnet-4.6"
}
```

Do not add extra auth fields. Model switching should happen here and nowhere else.

### Step 5: Wrapper requirements

The wrapper should do all of the following:

- if the current shell does not already have `AMD_LLM_GATEWAY_KEY`, first try loading `~/.claude/amd-gateway.env`
- use `~/.bashrc` only as a fallback, and only after checking that the key is still missing
- when sourcing user files under `set -u`, wrap the `source` with `set +u` and then restore `set -u`
- export `ANTHROPIC_BASE_URL`
- export `ANTHROPIC_CUSTOM_HEADERS`
- normalize bad persisted model aliases into supported direct models
- `exec` into the real Claude Code binary

Minimum safe source pattern:

```bash
if [[ -z "${AMD_LLM_GATEWAY_KEY:-}" && -f "${HOME}/.claude/amd-gateway.env" ]]; then
  set +u
  source "${HOME}/.claude/amd-gateway.env"
  set -u
fi

if [[ -z "${AMD_LLM_GATEWAY_KEY:-}" && -f "${HOME}/.bashrc" ]]; then
  set +u
  source "${HOME}/.bashrc"
  set -u
fi
```

Minimum alias normalization rules:

- `opus[1m]` -> `claude-opus-4.6`
- `claude-opus-4.5[1m]` -> `claude-opus-4.6`
- any other unknown value -> `claude-sonnet-4.6`

### Step 6: Ensure the real entrypoint is the wrapper

Always check:

```bash
which claude
```

If the result is not the expected wrapper:

- fix `PATH` ordering, or
- point `~/.local/bin/claude` to the wrapper, or
- replace whichever `claude` binary wins first on `PATH` with the wrapper

Do not assume `/usr/local/bin/claude` will always be chosen.

### Step 7: Verify in the correct order

Use this validation order exactly:

1. Route inspection first:

```bash
claude-route
```

Expected direct-mode indicators:

- `"mode": "direct"`
- `"backend": "claude-amd-anthropic"`
- `"custom_headers": "set"`
- `"normalized_model": "claude-sonnet-4.6"` or `"claude-opus-4.6"`
- `"which_claude"` points to the wrapper entrypoint
- `"real_version"` reports a working Claude Code binary

2. Then run a real text request:

```bash
claude -p --output-format json 'Reply with exactly OK'
```

3. Then verify the reported model:

```bash
claude -p --output-format json 'Reply with exactly OK' | \
  python3 ".cursor/skills/claude-amd-direct-setup/scripts/verify_output_model.py"
```

4. Finally verify tool use:

```bash
claude -p --output-format json --allowedTools Bash -- \
  'Use the Bash tool to run pwd, then answer with only the absolute path.'
```

Do not stop at healthcheck. The setup is only truly complete when:

- the text request succeeds
- `modelUsage` reports a supported 4.6 model
- the Bash tool call succeeds

### Step 8: Fallback when the user does not provide the key

Do not invent a fake key. Provide placeholder-only guidance and explicitly mention the local files that must be updated:

- `~/.claude/amd-gateway.env`
- `~/.claude/settings.json`
- the wrapper file

If the user chooses the fallback `.bashrc` route, explicitly warn them that the export must appear before non-interactive early returns such as `[ -z "$PS1" ] && return`.

## Supported Direct Models

Use only these exact model names:

- `claude-sonnet-4.6`
- `claude-opus-4.6`

Do not treat interactive `/model` as the final source of truth. For this direct setup, `~/.claude/settings.json` is the only reliable model switch location.

## Common Failure Modes

1. `401 missing subscription key`
   - the first check is not whether the key itself is correct
   - first confirm that `ANTHROPIC_CUSTOM_HEADERS` is set
   - then confirm that it is the single string `Ocp-Apim-Subscription-Key: ...`
   - do not store it as JSON

2. `claude-route` looks healthy but the real request fails
   - continue with `claude -p --output-format json ...`
   - inspect the real API error instead of stopping at route output

3. `which claude` points to the wrong binary
   - inspect `PATH`
   - inspect `~/.local/bin/claude`
   - make sure the wrapper is the actual runtime entrypoint

4. the official installer downloads the binary but hangs at the end
   - inspect `~/.claude/downloads/claude-*-linux-x64`
   - run `--version`
   - if the binary works, copy it to a stable path before killing the stuck installer
   - connect the preserved binary to `claude.real` and continue
   - if the download was cleaned up, download the same release directly to `claude.real`

5. `~/.claude/settings.json` was polluted by an old `/model` selection
   - change it back to `claude-sonnet-4.6` or `claude-opus-4.6`
   - or let the wrapper normalize it automatically at startup

6. `claude-route` shows `settings_parse_error`
   - launch `claude` once
   - let the wrapper back up the invalid file and rewrite a minimal config

7. the current shell still has stale environment
   - reload `~/.claude/amd-gateway.env`
   - reload `~/.bashrc` only if it is being used as the fallback store
   - or open a new terminal before retesting

8. healthcheck passes but Claude tool use still fails
   - keep going with real `claude -p` and Bash tool validation
   - without that, setup is not complete

9. `claude-route` reports `custom_headers: missing_key`
   - first check whether `~/.claude/amd-gateway.env` exists and is chmod `600`
   - if the key was stored in `.bashrc`, check whether it appears after `[ -z "$PS1" ] && return`
   - move the export above that early return, or migrate the key to `~/.claude/amd-gateway.env`

10. wrapper fails with `PS1: unbound variable`
   - the wrapper is sourcing shell startup files while `set -u` is active
   - wrap each `source` call with `set +u` and then restore `set -u`

## Manual Fallback Snippet

If the user does not want to share the real key, use only a placeholder:

```bash
mkdir -p ~/.claude
cat > ~/.claude/amd-gateway.env <<'EOF'
export AMD_LLM_GATEWAY_KEY="PASTE_YOUR_KEY_HERE"
EOF
chmod 600 ~/.claude/amd-gateway.env
```

Never write the real key into project files.

## Additional Resources

- Usage examples: [examples.md](examples.md)
- Environment and route validation: `scripts/healthcheck.sh`
- Model output validation: `scripts/verify_output_model.py`

## Validation Checklist

- [ ] no real secret was added to repository files
- [ ] the user was asked for the key before secret-bearing local edits
- [ ] Claude Code was installed before wrapper configuration
- [ ] `~/.claude/amd-gateway.env` stores the key and is chmod `600`, or `.bashrc` fallback is intentionally used before early returns
- [ ] `~/.claude/settings.json` keeps only `apiKeyHelper` and `model`
- [ ] the wrapper exports both `ANTHROPIC_BASE_URL` and `ANTHROPIC_CUSTOM_HEADERS`
- [ ] `ANTHROPIC_CUSTOM_HEADERS` is a string, not JSON
- [ ] `which claude` resolves to the wrapper
- [ ] if `~/.local/bin` is earlier in `PATH`, it also points to the wrapper
- [ ] `claude-route` reports direct mode, `custom_headers: set`, and a supported 4.6 model
- [ ] the real `claude -p` text request succeeds
- [ ] `modelUsage` reports `claude-sonnet-4.6` or `claude-opus-4.6`
- [ ] the Bash tool call succeeds, or any remaining limitation is stated clearly
