# work_skills

Shared setup skills for AMD LLM Gateway tooling.

## Quick install

```bash
# Claude Code (Anthropic-compatible gateway)
AMD_LLM_GATEWAY_KEY='<secret>' bash work_skills/claude-amd-direct-setup/scripts/install.sh

# Codex CLI (Responses API gateway)
AMD_LLM_GATEWAY_KEY='<secret>' bash work_skills/amd-codex-cli-setup/scripts/install.sh
```

Codex can also reuse `~/.claude/amd-gateway.env` if Claude was installed first.

Restart existing Claude/Codex sessions after setup.
