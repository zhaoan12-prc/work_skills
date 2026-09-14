#!/usr/bin/env bash
# Read-only structural audit for a four-layer Hyperloom launcher workspace.
set -uo pipefail

WS="${1:-.}"
errors=0
warnings=0

ok()   { printf 'OK   %s\n' "$*"; }
warn() { printf 'WARN %s\n' "$*"; warnings=$((warnings + 1)); }
bad()  { printf 'FAIL %s\n' "$*"; errors=$((errors + 1)); }

if [ ! -d "$WS" ]; then
  echo "FAIL workspace is not a directory: $WS" >&2
  exit 2
fi
WS="$(cd "$WS" && pwd)"
printf 'workspace=%s\n' "$WS"

required=(
  README.md models.tsv env_common.sh setup_claude.sh
  hl_matrix.sh hl_launch.sh hl_node_docker.sh hl_incontainer.sh
)
for file in "${required[@]}"; do
  if [ -f "$WS/$file" ]; then ok "$file present"; else bad "$file missing"; fi
done

for file in "$WS"/*.sh; do
  [ -f "$file" ] || continue
  if bash -n "$file"; then
    ok "$(basename "$file") syntax"
  else
    bad "$(basename "$file") has shell syntax errors"
  fi
done

check_pattern() {
  local file="$1" pattern="$2" label="$3"
  if [ ! -f "$WS/$file" ]; then return; fi
  if grep -Eq "$pattern" "$WS/$file"; then ok "$label"; else warn "$label not found"; fi
}

check_pattern hl_launch.sh 'spur[[:space:]]+exec' 'row launcher uses spur exec'
check_pattern hl_launch.sh 'squeue' 'row launcher checks Slurm allocation'
check_pattern hl_node_docker.sh 'docker[[:space:]]+run' 'node layer starts Docker'
check_pattern hl_node_docker.sh 'ROCR_VISIBLE_DEVICES' 'node layer passes GPU mask'
check_pattern hl_node_docker.sh 'hl_incontainer\.sh' 'node layer calls container driver'
check_pattern hl_incontainer.sh 'setup_claude\.sh' 'container driver installs/configures Claude'
check_pattern hl_incontainer.sh 'claude_agent_sdk' 'container driver verifies Claude SDK'
check_pattern hl_incontainer.sh 'inference_optimizer\.cli.*optimize|optimize.*inference_optimizer\.cli' 'container driver starts Hyperloom optimize'
check_pattern setup_claude.sh 'claude\.ai/install\.sh|@anthropic-ai/claude-code' 'Claude setup has an installer'

if [ -e "$WS/secrets.env" ]; then
  mode="$(stat -c '%a' "$WS/secrets.env" 2>/dev/null || true)"
  owner="$(stat -c '%U:%G' "$WS/secrets.env" 2>/dev/null || true)"
  if [ "$mode" = 600 ]; then
    ok "secrets.env mode=600 owner=${owner:-unknown}"
  else
    bad "secrets.env mode=${mode:-unknown}; expected 600"
  fi
  if [ -r "$WS/secrets.env" ]; then
    printf 'INFO secrets.env keys:'
    awk -F= '/^[A-Za-z_][A-Za-z0-9_]*=/{printf " %s", $1} END{print ""}' "$WS/secrets.env"
  else
    warn "secrets.env is not readable by current user; values were not inspected"
  fi
else
  warn "secrets.env missing"
fi

if [ -f "$WS/models.tsv" ]; then
  awk_result="$({
    awk -F '\t' '
      BEGIN { bad=0; rows=0 }
      /^[[:space:]]*#/ || NF==0 { next }
      {
        rows++
        if (NF < 12) {
          printf "FAIL models.tsv line %d has %d fields; expected at least 12\n", NR, NF
          bad=1
          next
        }
        en=$1; key=$2; tp=$4; node=$5; gpus=$6; model=$7
        if (key == "") { printf "FAIL models.tsv line %d has empty key\n", NR; bad=1 }
        if (seen_key[key]++) { printf "FAIL duplicate key %s\n", key; bad=1 }
        if (en == "1" && node == "TBD") { printf "FAIL enabled key %s has node=TBD\n", key; bad=1 }
        if (en == "1") {
          n=split(gpus, a, ",")
          if (tp !~ /^[0-9]+$/ || n != tp) {
            printf "FAIL key %s has tp=%s but %d GPUs in mask %s\n", key, tp, n, gpus
            bad=1
          }
          for (i=1; i<=n; i++) {
            slot=node ":" a[i]
            if (claim[slot] != "") {
              printf "FAIL GPU %s claimed by %s and %s\n", slot, claim[slot], key
              bad=1
            }
            claim[slot]=key
          }
        }
        printf "INFO row key=%s enabled=%s node=%s gpus=%s model=%s\n", key, en, node, gpus, model
      }
      END {
        if (rows == 0) { print "FAIL models.tsv has no data rows"; bad=1 }
        exit bad
      }
    ' "$WS/models.tsv"
  } 2>&1)"
  awk_rc=$?
  printf '%s\n' "$awk_result"
  if [ "$awk_rc" -eq 0 ]; then ok 'models.tsv structure and enabled GPU claims'; else errors=$((errors + 1)); fi

  while IFS=$'\t' read -r enabled key _fw _tp _node _gpus model _rest; do
    case "$enabled" in ''|'#'*) continue ;; esac
    if [[ "$model" = /* ]] && [ ! -e "$model" ]; then
      warn "model path for $key is not visible on the login node: $model"
    fi
  done < "$WS/models.tsv"
fi

if [ -d "$WS/deps_master/GEAK/.git" ]; then
  ok 'dependency master contains GEAK checkout'
else
  warn 'deps_master/GEAK is not populated; run the workspace preclone step before launch'
fi

if [ -d "$WS/logs" ]; then ok 'logs directory present'; else warn 'logs directory missing'; fi
if [ -d "$WS/exp" ]; then ok 'artifact directory present'; else warn 'exp directory missing'; fi

printf 'summary errors=%d warnings=%d\n' "$errors" "$warnings"
[ "$errors" -eq 0 ]
