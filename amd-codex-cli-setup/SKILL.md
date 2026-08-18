---
name: amd-codex-cli-setup
description: Installs, configures, repairs, and verifies OpenAI Codex CLI against the AMD LLM API Gateway Responses endpoint. Use for AMD Codex installation, gpt-5.6-sol setup, subscription-key authentication, wrong endpoint or model errors, Chat Completions incompatibility, persistent credentials, and Codex upgrades.
---

# AMD Codex CLI Setup

Install the latest Codex CLI and connect it to AMD's Codex-specific Responses
API. Prove success with a real request.

## Required end state

- Official Codex is installed at `~/.local/bin/codex`.
- Codex uses the latest available CLI, not the legacy Chat Completions release.
- `~/.codex/config.toml` has mode `600`.
- Default model and deployment are `gpt-5.6-sol`.
- Base URL is `https://llm-api.amd.com/openai/gpt-5.6-sol`.
- Requests use Responses API version `2025-04-01-preview`.
- The AMD key is sent as `Ocp-Apim-Subscription-Key`.
- A real `codex exec` request succeeds without manually exporting variables.

## Critical distinctions

Do not use `https://llm-api.amd.com/OnPrem` for AMD Codex models. That endpoint
uses Chat Completions and lists models such as `GPT-oss-20B`; it does not expose
`gpt-5.6-sol`.

AMD Codex deployments use this pattern:

```text
https://llm-api.amd.com/openai/<deployment>
```

They require `wire_api = "responses"`. Current Codex releases support Responses
API; do not downgrade to an old Chat Completions release.

## Safety rules

1. Never put a real API key in this skill, a repository, chat, command argument,
   shell history, logs, or test output.
2. Ask the user to run the interactive installer themselves when a new key is
   needed. It reads the key with terminal echo disabled.
3. The requested zero-manual-environment setup stores the key in
   `~/.codex/config.toml`; keep the file at mode `600`.
4. Back up an existing config before replacing it.
5. Never claim success from config inspection alone; run a real request.
6. Restart existing Codex sessions after changing the binary or config.

## Preferred workflow

### 1. Inspect without leaking credentials

Run:

```bash
node --version
npm --version
command -v codex || true
codex --version || true
test -f "$HOME/.codex/config.toml" && stat -c '%a %n' "$HOME/.codex/config.toml"
```

Do not print or read the full config when it may contain a key. Inspect only
specific non-secret lines when necessary.

### 2. Run the interactive installer

From the repository root, ask the user to run:

```bash
bash work_skills/amd-codex-cli-setup/scripts/install.sh
```

Optional model and deployment:

```bash
bash work_skills/amd-codex-cli-setup/scripts/install.sh <model> <deployment>
```

The script installs Codex user-locally, prompts securely for the AMD key,
backs up the existing config, writes the Responses provider, and performs a
real request.

### 3. Verify independently

After the installer succeeds, run:

```bash
codex --version
codex --ask-for-approval never exec --skip-git-repo-check --sandbox read-only \
  "Reply with exactly: AMD_CODEX_OK"
```

Confirm the startup summary reports:

```text
model: gpt-5.6-sol
provider: amd
```

and the answer is exactly `AMD_CODEX_OK`.

### 4. Restart sessions

Configuration is not hot-reloaded. Exit any running Codex UI with `Ctrl+C`,
then start a new one:

```bash
codex
```

## Manual config reference

Use this shape, replacing placeholders securely:

```toml
model = "<model>"
model_provider = "amd"

[model_providers.amd]
name = "AMD Codex Gateway"
base_url = "https://llm-api.amd.com/openai/<deployment>"
wire_api = "responses"
experimental_bearer_token = "DUMMY_KEY"
query_params = { api-version = "2025-04-01-preview" }
http_headers = { "Ocp-Apim-Subscription-Key" = "<secret>", "user" = "<os-user>" }
```

`experimental_bearer_token` is intentionally a dummy bearer value. AMD
authentication comes from the subscription-key header.

## Failure diagnosis

- `Deployment ... for ChatCompletions is not found`: wrong `/OnPrem` endpoint
  or legacy `wire_api = "chat"` configuration.
- `Deployment ... is not found`: the deployment segment or model ID is wrong.
- `401` or missing subscription key: the AMD key header is absent or invalid.
- `/model` causes failures: the picker shows Codex's built-in model catalog,
  not AMD deployment availability. Restore `model` in the config and restart.
- New config appears ignored: exit all existing Codex sessions and relaunch.
- Global npm install gets `EACCES`: use `--prefix "$HOME/.local"` and a
  user-owned npm cache as the installer does.

## Completion checklist

- [ ] No key was exposed in repository files, logs, or output.
- [ ] Codex is the current version and resolves from `~/.local/bin`.
- [ ] Config mode is `600`.
- [ ] Provider uses the AMD `/openai/<deployment>` Responses endpoint.
- [ ] Default model is the requested AMD deployment.
- [ ] Real request succeeds.
- [ ] Existing Codex sessions were restarted.
