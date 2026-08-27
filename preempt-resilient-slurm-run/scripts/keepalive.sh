#!/bin/bash
# keepalive.sh —— 在【登录节点】周期运行。三件事：
#   1) 补位：每个 lane 不在队列里就补一个，带指数退避
#   2) claim 的判活权威：持有者还活着就代其刷心跳；已经死了就回收 claim
#   3) 报警：僵尸 PENDING、连续到手即死
#
# 为什么必须在作业之外：
#   reaper / 抢占用 SIGKILL 级手段清作业，被杀进程自己的 EXIT trap 不保证执行。
#   让作业「自己在退出时重新排队」在真实集群上一定失败。补位逻辑必须是外部的。
#
# 触发（任选其一，都不依赖交互会话）：
#   scrontab -e  ->  */3 * * * * /path/to/keepalive.sh
#   nohup keepalive_daemon.sh &
#
# 幂等、有硬上限、可审计。手动跑一次也安全。

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNCONF="${RUNCONF:-$HERE/runconf.sh}"
[ -f "$RUNCONF" ] || { echo "找不到 $RUNCONF（从 runconf.example.sh 复制一份）" >&2; exit 1; }
# shellcheck disable=SC1090
. "$RUNCONF"

CLAIM_DIR="$RUN_DIR/.claim"
STATE_DIR="$RUN_DIR/.keepalive_state"
LOG="$RUN_DIR/keepalive.log"
LOCK="$RUN_DIR/.keepalive.lock"
mkdir -p "$STATE_DIR" "$LOG_DIR"

export PATH="${HOME}/bin:${HOME}/.local/bin:/usr/local/bin:${PATH}"

# whoami 会 fork 并可能触盘；共享盘写回停滞时它会卡死在 D 态拖垮整个 keepalive。
# 用 shell 内建变量，不 fork、不触盘。
USER_NAME="${USER:-${LOGNAME:-$(id -un)}}"

log() { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*" >> "$LOG"; }
now() { date +%s; }

# ---- 防重入 ------------------------------------------------------------------
if ! mkdir "$LOCK" 2>/dev/null; then
  if [ -n "$(find "$LOCK" -maxdepth 0 -mmin +10 2>/dev/null)" ]; then
    log "发现陈旧锁（>10min），接管"
  else
    exit 0
  fi
fi
trap 'rmdir "$LOCK" 2>/dev/null' EXIT

# ---- 收工判据：只认哨兵文件 ---------------------------------------------------
if [ -f "$STOP_SENTINEL" ]; then
  log "发现哨兵 $(basename "$STOP_SENTINEL")，停止补位"
  exit 0
fi

command -v sbatch >/dev/null || { log "错误：找不到 sbatch，PATH=$PATH"; exit 1; }
command -v squeue >/dev/null || { log "错误：找不到 squeue（本脚本必须在登录节点跑）"; exit 1; }
SUBMIT="$HERE/submit.sbatch"
[ -f "$SUBMIT" ] || { log "错误：找不到 $SUBMIT"; exit 1; }

# ---- 当前队列 ----------------------------------------------------------------
QUEUE="$(squeue -h -u "$USER_NAME" -o '%i|%j|%T|%r|%V' 2>/dev/null)"
lane_names=()
for spec in "${LANES[@]}"; do lane_names+=("${spec%%|*}"); done
in_queue() { printf '%s\n' "$QUEUE" | grep -q "^[0-9]*|$1|"; }
lane_job()  { printf '%s\n' "$QUEUE" | awk -F'|' -v n="$1" '$2==n {print $1; exit}'; }
lane_state(){ printf '%s\n' "$QUEUE" | awk -F'|' -v n="$1" '$2==n {print $3; exit}'; }

N_QUEUED=0
for n in "${lane_names[@]}"; do in_queue "$n" && N_QUEUED=$((N_QUEUED+1)); done

# ---- claim：判活权威 + 垃圾回收 ----------------------------------------------
#
# 计算节点上通常【没有】squeue/sbatch/scontrol —— 见 SKILL.md 第 2 条。
# 因此作业自己无法判断 claim 持有者死没死，submit.sbatch 只能 fail-closed
# （判不出就退出，绝不并发写同一个 RUN_DIR）。代价是持有者被 SIGKILL 后
# claim 目录留在原地、心跳不再更新，若没人清理，之后每一路都退出 —— 整条 run 永久空转。
#
# 清理只能由能跑 squeue 的登录节点做，也就是这里。这是整套设计的关键分工：
#   计算节点 = fail-closed（宁可空等，绝不并发）
#   登录节点 = 判活权威 + GC（负责解锁）
WORKING=""
if [ -f "$CLAIM_DIR/jobid" ]; then
  OWNER="$(cat "$CLAIM_DIR/jobid" 2>/dev/null || true)"
  OWNER_STATE="$(squeue -h -j "${OWNER:-0}" -o '%T' 2>/dev/null || true)"
  case "$OWNER_STATE" in
    RUNNING*|COMPLETING*)
      WORKING="$OWNER"
      # 代其刷心跳：这样即使持有者跑的是不写心跳的旧版作业脚本，也会被正确尊重。
      date +%s > "$CLAIM_DIR/heartbeat" 2>/dev/null || true
      ;;
    *)
      log "⚠ claim 持有者 ${OWNER:-未知} 状态 '${OWNER_STATE:-已不在队列}' —— 回收陈旧 claim"
      rm -rf "$CLAIM_DIR"
      ;;
  esac
fi

# claim 自愈：claim 丢了但确实有本 run 的作业在 RUNNING（例如别的作业的 EXIT trap
# 误删了它），把 claim 补回去指向那个作业，防止下一路进来并发写。
if [ -z "$WORKING" ]; then
  for n in "${lane_names[@]}"; do
    st="$(lane_state "$n")"
    case "$st" in RUNNING*|COMPLETING*)
      j="$(lane_job "$n")"
      mkdir -p "$CLAIM_DIR"
      echo "$j"  > "$CLAIM_DIR/jobid"
      echo "$n"  > "$CLAIM_DIR/lane"
      date -u    > "$CLAIM_DIR/since"
      date +%s   > "$CLAIM_DIR/heartbeat"
      echo "restored by keepalive: claim missing while $j RUNNING" > "$CLAIM_DIR/note"
      WORKING="$j"
      log "⚠ claim 缺失但作业 $j（lane $n）仍 RUNNING —— 已补回 claim，防止并发写 RUN_DIR"
      break;; esac
  done
fi

# ---- 死亡记账与指数退避 -------------------------------------------------------
#
# 在「到手即死」的集群上，无脑每周期补满会变成纯 churn：作业一秒就被清掉，
# 下个周期再补，永远填不满、还吵到别人。按 lane 记连续即死次数做指数退避。
#
# 存活时长是【上界估计】：keepalive 只在自己的周期上采样，不知道作业精确死亡时刻。
# 只用来分类「即死 / 跑过一阵」，不要拿它当性能数据。
record_and_backoff() {           # $1=lane  -> 回显 0=可提交 1=退避中
  local lane="$1" f="$STATE_DIR/lane.$lane"
  local last_job="" last_sub=0 consec=0
  [ -f "$f" ] && . "$f"

  if [ -n "$last_job" ] && ! printf '%s\n' "$QUEUE" | grep -q "^$last_job|"; then
    # 上个周期记录的作业已经不在队列里了 -> 它结束了
    local life=$(( $(now) - last_sub ))
    if [ "$life" -lt "$INSTANT_DEATH_SEC" ]; then
      consec=$((consec+1))
      log "lane $lane：作业 $last_job 存活 ≲${life}s（到手即死），连续第 $consec 次"
    else
      [ "$consec" -gt 0 ] && log "lane $lane：作业 $last_job 存活 ≈${life}s，退避计数清零"
      consec=0
    fi
    last_job=""
  fi

  local wait=0
  if [ "$consec" -gt 0 ]; then
    wait=$(( BACKOFF_BASE_SEC * (1 << (consec > 5 ? 5 : consec - 1)) ))
    [ "$wait" -gt "$BACKOFF_MAX_SEC" ] && wait="$BACKOFF_MAX_SEC"
  fi
  local since=$(( $(now) - last_sub ))
  { echo "last_job=$last_job"; echo "last_sub=$last_sub"; echo "consec=$consec"; } > "$f"

  if [ "$consec" -gt 0 ] && [ "$since" -lt "$wait" ]; then
    return 1
  fi
  return 0
}

mark_submitted() {               # $1=lane $2=jobid
  local f="$STATE_DIR/lane.$1" consec=0
  [ -f "$f" ] && consec="$(sed -n 's/^consec=//p' "$f")"
  { echo "last_job=$2"; echo "last_sub=$(now)"; echo "consec=${consec:-0}"; } > "$f"
}

# ---- 僵尸 PENDING 报警 -------------------------------------------------------
#
# 卡在 QOSGrpNodeLimit / AssocGrpNodeLimit 这类原因上的作业可能永远不会跑，
# 却一直占着 MaxSubmitPU 名额，把真正有机会的 lane 挤掉。
# 本脚本【不会】scancel —— 取消作业必须由人决定。只报警。
printf '%s\n' "$QUEUE" | awk -F'|' -v zh="$PENDING_ZOMBIE_HOURS" '
  $3 ~ /^PENDING/ && $5 != "" { print $1"|"$2"|"$4"|"$5 }' | while IFS='|' read -r j n r v; do
  sub_epoch="$(date -d "$v" +%s 2>/dev/null || echo 0)"
  [ "$sub_epoch" -eq 0 ] && continue
  age_h=$(( ( $(now) - sub_epoch ) / 3600 ))
  if [ "$age_h" -ge "$PENDING_ZOMBIE_HOURS" ]; then
    flag="$STATE_DIR/zombie.$j"
    [ -f "$flag" ] || { log "⚠ 僵尸 PENDING：作业 $j（$n）已排队 ${age_h}h，原因 '$r'。占着 MaxSubmitPU 名额，可能永远不会跑 —— 需要人来决定是否 scancel（本脚本不取消任何作业）"; : > "$flag"; }
  fi
done

# ---- 逐路补位 ----------------------------------------------------------------
#
# 有作业在干活时仍维持少量【待命路】：干活的作业随时可能被杀，届时队列里必须
# 已经有人排着，否则要从队尾重排、白等几小时。但不维持全部 lane —— 待命路拿到
# 节点会因 claim 被占而立即退出，频繁起落在共享集群上是无谓 churn。
STANDBY_N=2
if [ -n "$WORKING" ]; then
  log "作业 $WORKING 正在干活，队列中 $N_QUEUED 路（仅维持前 $STANDBY_N 路待命）"
fi

N_BEFORE="$N_QUEUED"
idx=0
for spec in "${LANES[@]}"; do
  idx=$((idx+1))
  lane="${spec%%|*}"; extra="${spec#*|}"

  if [ -n "$WORKING" ] && [ "$idx" -gt "$STANDBY_N" ]; then continue; fi
  in_queue "$lane" && continue
  if [ "$N_QUEUED" -ge "$MAX_QUEUED" ]; then
    log "已达队列上限 $MAX_QUEUED，跳过 $lane"; continue
  fi
  record_and_backoff "$lane" || continue

  # shellcheck disable=SC2086
  out="$(sbatch "${SBATCH_COMMON[@]}" $extra -J "$lane" \
          -o "$LOG_DIR/${lane}-%j.out" --export=ALL,RUNCONF="$RUNCONF" \
          "$SUBMIT" 2>&1)"
  if [ $? -eq 0 ]; then
    jid="$(printf '%s' "$out" | grep -oE '[0-9]+$')"
    log "补位 $lane -> $out"
    mark_submitted "$lane" "${jid:-0}"
    N_QUEUED=$((N_QUEUED+1))
  else
    log "补位 $lane 失败: $out"
  fi
done

[ "$N_QUEUED" -eq "$N_BEFORE" ] && log "心跳：无需补位（队列中 $N_QUEUED 路，claim=${WORKING:-无})"
exit 0
