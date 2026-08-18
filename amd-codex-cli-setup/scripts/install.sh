#!/usr/bin/env bash
set -euo pipefail

model="${1:-gpt-5.6-sol}"
deployment="${2:-$model}"
codex_prefix="${HOME}/.local"
codex_bin="${codex_prefix}/bin/codex"
config_dir="${HOME}/.codex"
config_file="${config_dir}/config.toml"

if ! command -v node >/dev/null 2>&1 || ! command -v npm >/dev/null 2>&1; then
  echo "Node.js and npm are required." >&2
  exit 1
fi

printf 'AMD LLM Gateway API key: ' >&2
IFS= read -r -s amd_key
printf '\n' >&2
if [[ -z "$amd_key" ]]; then
  echo "API key cannot be empty." >&2
  exit 1
fi

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

export PATH="${codex_prefix}/bin:${PATH}"
if [[ ":${PATH}:" != *":${HOME}/.local/bin:"* ]]; then
  echo "Failed to add ~/.local/bin to PATH." >&2
  exit 1
fi

shell_rc="${HOME}/.bashrc"
path_line='export PATH="$HOME/.local/bin:$PATH"'
if [[ ! -f "$shell_rc" ]] || ! grep -Fqx "$path_line" "$shell_rc"; then
  printf '\n%s\n' "$path_line" >>"$shell_rc"
fi

"$codex_bin" --version
"$codex_bin" --ask-for-approval never exec \
  --skip-git-repo-check \
  --sandbox read-only \
  "Reply with exactly: AMD_CODEX_OK"

echo "AMD Codex setup completed for model ${model}."
echo "Restart existing Codex sessions before use."
