#!/usr/bin/env bash
set -euo pipefail

model="${1:-claude-sonnet-4.6}"
case "$model" in
  claude-sonnet-4.6|claude-opus-4.6) ;;
  *)
    echo "Unsupported model: ${model}. Use claude-sonnet-4.6 or claude-opus-4.6." >&2
    exit 1
    ;;
esac

env_dir="${HOME}/.claude"
env_file="${env_dir}/amd-gateway.env"
settings_file="${env_dir}/settings.json"
wrapper="${HOME}/bin/claude"
official="${HOME}/.local/bin/claude"
path_line='export PATH="$HOME/bin:$HOME/.local/bin:$PATH"'

resolve_amd_key() {
  if [[ -n "${AMD_LLM_GATEWAY_KEY:-}" ]]; then
    printf '%s' "$AMD_LLM_GATEWAY_KEY"
    return
  fi

  if [[ -f "$env_file" ]]; then
    set +u
    # shellcheck disable=SC1090
    source "$env_file"
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

write_env_file() {
  local key="$1"
  mkdir -p "$env_dir"
  umask 077
  printf 'export AMD_LLM_GATEWAY_KEY="%s"\n' "$key" >"$env_file"
  chmod 600 "$env_file"
}

write_settings() {
  if [[ -f "$settings_file" ]]; then
    cp -p "$settings_file" "${settings_file}.backup.$(date +%Y%m%d-%H%M%S)"
  fi
  umask 077
  cat >"$settings_file" <<JSON
{
  "apiKeyHelper": "bash -c 'set -a; [ -f \\"\\$HOME/.claude/amd-gateway.env\\" ] && . \\"\\$HOME/.claude/amd-gateway.env\\"; set +a; printf %s \\"\\$AMD_LLM_GATEWAY_KEY\\"'",
  "model": "${model}"
}
JSON
  chmod 600 "$settings_file"
}

write_wrapper() {
  mkdir -p "${HOME}/bin"
  cat >"$wrapper" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail

env_file="${HOME}/.claude/amd-gateway.env"
real_claude="${HOME}/.local/bin/claude"

if [[ -z "${AMD_LLM_GATEWAY_KEY:-}" && -f "$env_file" ]]; then
  set +u
  # shellcheck disable=SC1090
  source "$env_file"
  set -u
fi
export AMD_LLM_GATEWAY_KEY

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
export ANTHROPIC_CUSTOM_HEADERS=$'Ocp-Apim-Subscription-Key: '"${AMD_LLM_GATEWAY_KEY}"$'\nuser: '"$(id -un)"
export CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1

exec "$real_claude" "$@"
BASH
  chmod 700 "$wrapper"
}

ensure_path() {
  local shell_rc="${HOME}/.bashrc"
  if [[ -f "$shell_rc" ]] && ! bash -n "$shell_rc" 2>/dev/null; then
    echo "Warning: ${shell_rc} has syntax errors; fix before relying on login shells." >&2
  fi
  if [[ ! -f "$shell_rc" ]] || ! grep -Fqx "$path_line" "$shell_rc"; then
    printf '\n%s\n' "$path_line" >>"$shell_rc"
  fi
  if [[ -f "$shell_rc" ]] && ! bash -n "$shell_rc"; then
    echo "Error: ${shell_rc} is invalid after PATH update." >&2
    exit 1
  fi
  export PATH="$HOME/bin:$HOME/.local/bin:$PATH"
  hash -r
}

install_official_binary() {
  if [[ ! -x "$official" ]]; then
    curl -fsSL https://claude.ai/install.sh | bash
  fi
  if [[ ! -x "$official" ]]; then
    echo "Official Claude binary is missing after install: $official" >&2
    exit 1
  fi
  "$official" --version
}

amd_key="$(resolve_amd_key)"
write_env_file "$amd_key"
unset amd_key
write_settings
write_wrapper
ensure_path
install_official_binary

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bash "${script_dir}/healthcheck.sh"

"$wrapper" -p --output-format json 'Reply with exactly: API OK' |
  python3 "${script_dir}/verify_output_model.py"

echo "Claude AMD direct setup completed for model ${model}."
echo "Restart existing Claude sessions before use."
