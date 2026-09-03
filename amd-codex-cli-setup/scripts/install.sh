#!/usr/bin/env bash
set -euo pipefail

model="${1:-gpt-5.6-sol}"
deployment="${2:-$model}"
codex_prefix="${HOME}/.local"
codex_bin="${codex_prefix}/bin/codex"
config_dir="${HOME}/.codex"
config_file="${config_dir}/config.toml"
claude_env_file="${HOME}/.claude/amd-gateway.env"
path_line='export PATH="$HOME/bin:$HOME/.local/bin:$PATH"'

resolve_amd_key() {
  if [[ -n "${AMD_LLM_GATEWAY_KEY:-}" ]]; then
    printf '%s' "$AMD_LLM_GATEWAY_KEY"
    return
  fi

  if [[ -f "$claude_env_file" ]]; then
    set +u
    # shellcheck disable=SC1090
    source "$claude_env_file"
    set -u
    if [[ -n "${AMD_LLM_GATEWAY_KEY:-}" ]]; then
      printf '%s' "$AMD_LLM_GATEWAY_KEY"
      return
    fi
  fi

  if [[ ! -t 0 ]]; then
    IFS= read -r amd_key || true
    if [[ -n "${amd_key:-}" ]]; then
      printf '%s' "$amd_key"
      return
    fi
  fi

  printf 'AMD LLM Gateway API key: ' >&2
  IFS= read -r -s amd_key
  printf '\n' >&2
  if [[ -z "$amd_key" ]]; then
    echo "API key cannot be empty." >&2
    exit 1
  fi
  printf '%s' "$amd_key"
}

if ! command -v node >/dev/null 2>&1 || ! command -v npm >/dev/null 2>&1; then
  echo "Node.js and npm are required." >&2
  exit 1
fi

amd_key="$(resolve_amd_key)"

mkdir -p "$codex_prefix" "${HOME}/.cache/npm-codex" "$config_dir"
npm install -g \
  --prefix "$codex_prefix" \
  --cache "${HOME}/.cache/npm-codex" \
  @openai/codex@latest

if [[ -f "$config_file" ]]; then
  backup="${config_file}.backup.$(date +%Y%m%d-%H%M%S)"
  cp -p "$config_file" "$backup"
  echo "Backed up existing config to $backup"
fi

toml_key="${amd_key//\\/\\\\}"
toml_key="${toml_key//\"/\\\"}"
os_user="$(id -un)"
toml_user="${os_user//\\/\\\\}"
toml_user="${toml_user//\"/\\\"}"

umask 077
cat >"$config_file" <<EOF
model = "${model}"
model_provider = "amd"

[model_providers.amd]
name = "AMD Codex Gateway"
base_url = "https://llm-api.amd.com/openai/${deployment}"
wire_api = "responses"
experimental_bearer_token = "DUMMY_KEY"
query_params = { api-version = "2025-04-01-preview" }
http_headers = { "Ocp-Apim-Subscription-Key" = "${toml_key}", "user" = "${toml_user}" }
EOF
chmod 600 "$config_file"
unset amd_key toml_key

shell_rc="${HOME}/.bashrc"
if [[ -f "$shell_rc" ]] && ! bash -n "$shell_rc" 2>/dev/null; then
  echo "Warning: ${shell_rc} has syntax errors; fix before relying on login shells." >&2
fi
if [[ ! -f "$shell_rc" ]] || ! grep -Fqx "$path_line" "$shell_rc"; then
  printf '\n%s\n' "$path_line" >>"$shell_rc"
fi

export PATH="$HOME/bin:$HOME/.local/bin:$PATH"
hash -r

"$codex_bin" --version
"$codex_bin" --ask-for-approval never exec \
  --skip-git-repo-check \
  --sandbox read-only \
  "Reply with exactly: AMD_CODEX_OK"

echo "AMD Codex setup completed for model ${model}."
echo "Restart existing Codex sessions before use."
