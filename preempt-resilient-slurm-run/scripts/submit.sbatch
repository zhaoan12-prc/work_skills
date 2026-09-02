#!/bin/bash
#SBATCH -N 1

# ---- 整个脚本体包在 { } 里，不是排版洁癖（SKILL.md 第 6 条）-------------------
# bash 按字节偏移量边读边执行脚本，每条顶层命令执行完就 lseek 回下一条的偏移量。
# 长跑集群上边跑边改脚本是常态 —— 一旦原地改写（同 inode），正在跑的作业
# 下一次 seek 就落到错位的字节上，会重复执行整段循环、把半行内容当命令跑。
# 包成一条复合命令后，bash 必须先完整解析完才能开始执行，之后文件怎么改都无关。
# 末尾的 exit 保证永远读不到 } 之后的内容。改这个文件时别把 { } 弄丢。
{
# 其余 sbatch 参数由 keepalive.sh 在命令行给（lane 名、账号、QOS、日志路径）。
#
# 作业本体。拿到节点后：
#   1) 节点体检 —— 不合格立刻退出，【不消费任何任务】
#   2) 抢 claim —— 判不出持有者死活就 fail-closed 退出（绝不并发写 RUN_DIR）
#   3) 循环跑任务队列 —— 按退出码分流，被杀时任务自动回到队列
#   4) 退出时只在 claim 仍属于自己时才释放

set -uo pipefail

# ---- RUNCONF 必须自带兜底，不能只靠 --export（SKILL.md 第 8 条）--------------
# `sbatch --export=ALL,VAR=val` 是原版 slurm 的写法，不是所有集群跑的都是原版。
# 实测一台 "spur" 重实现完全不认这个合并写法：VAR 不进作业环境，但 sbatch 照样返回 0。
# 症状：作业落到节点 1-2 秒死，ExitCode=1:0 而 DerivedExitCode=0:0（= 一个 step 都
# 没产生），-o 指的 .out 是 0 字节，唯一那行报错被单独丢到 WorkDir/<impl>-<jobid>.out。
# 【装配时把下面这一行改成你的 runconf.sh 绝对路径。】
RUNCONF_FALLBACK="/PATH/TO/YOUR/runconf.sh"
RUNCONF="${RUNCONF:-$RUNCONF_FALLBACK}"
[ -r "$RUNCONF" ] || {
  echo "!! 读不到 RUNCONF=$RUNCONF —— --export 没生效且 RUNCONF_FALLBACK 没改。见 SKILL.md 第 8 条" >&2
  exit 1
}
# shellcheck disable=SC1090
. "$RUNCONF"

JOB="${SLURM_JOB_ID:-unknown}"
CLAIM_DIR="$RUN_DIR/.claim"
CLAIM_HEARTBEAT="$CLAIM_DIR/heartbeat"
# worker 自证标记。登录节点的 keepalive 看不出一个 RUNNING 的 lane 作业到底是
# 「在干活」还是「在热备」——两者都是 RUNNING。它据此补 claim 会补到热备头上，
# 造成幽灵 claim（谁都不接管、队列永久卡死）。所以真正拿到 claim 的作业在这里
# 留一个只有自己会写的标记，keepalive 只认这个标记，不认 RUNNING。
WORKER_DIR="$RUN_DIR/.worker"
Q="$RUN_DIR/queue"
mkdir -p "$Q/done" "$Q/failed" "$Q/.inflight" "$Q/.attempts" "$LOG_DIR" "$WORKER_DIR"

say() { echo ">>> $*"; }
say "$(hostname)  $(date -u)  JOB=$JOB  LANE=${SLURM_JOB_NAME:-?}"

# ---- 1) 节点体检 --------------------------------------------------------------
#
# --exclusive 不一定兑现。实测拿到过一个正在跑别家 32 节点训练的节点，
# 每卡只剩不到一半显存。此时开跑不是「慢一点」，是数据不可信 + 大概率 OOM，
# 而且如果你的任务队列在 agent 返回后无条件出队，这一次还会白烧掉一个任务。
#
# 所以：体检在【取任务之前】。不合格 -> 写 BLOCKED 报告 -> 退出，队列一动不动。
blocked() {
  local why="$1"
  local f="$RUN_DIR/BLOCKED_$(hostname)_${JOB}.md"
  { echo "# 节点不可用：$(hostname) / job $JOB"; echo; echo "$(date -u)"; echo;
    echo "## 原因"; echo; echo "$why"; echo;
    echo '## 现场'; echo '```'; "${PREFLIGHT_DUMP[@]}" 2>&1 | head -40; echo '```'; } > "$f"
  say "节点体检不通过，已写 $f，退出（未消费任何任务）"
  exit 0
}
PREFLIGHT_DUMP=(bash -c 'command -v rocm-smi >/dev/null && rocm-smi --showmeminfo vram 2>&1 | head -30; command -v nvidia-smi >/dev/null && nvidia-smi 2>&1 | head -30; ps -eo user,pid,comm --no-headers | sort -u -k1,1 | head -20')

if [ "${PREFLIGHT_GPU_FREE_GIB:-0}" -gt 0 ] || [ "${PREFLIGHT_GPU_COUNT:-0}" -gt 0 ]; then
  need_mib=$(( ${PREFLIGHT_GPU_FREE_GIB:-0} * 1024 ))
  bad=0; seen=0
  if command -v rocm-smi >/dev/null 2>&1; then
    # rocm-smi 各版本输出格式不稳，取「Total/Used」两个数算差值
    while read -r total used; do
      seen=$((seen+1))
      free=$(( (total - used) / 1024 / 1024 ))
      [ "$free" -lt "$need_mib" ] && bad=$((bad+1))
    done < <(rocm-smi --showmeminfo vram --csv 2>/dev/null | awk -F, 'NR>1 && NF>=3 {print $2, $3}')
  elif command -v nvidia-smi >/dev/null 2>&1; then
    while read -r free; do
      seen=$((seen+1)); [ "$free" -lt "$need_mib" ] && bad=$((bad+1))
    done < <(nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits 2>/dev/null)
  fi
  # 读不到 GPU 信息时【不要放行】。这正是本 skill 第 2 条批评的 fail-open：
  # 一个连卡都枚举不出来的节点，不是「体检通过」，是「体检做不了」。
  # 在 GPU 作业上，这两者的正确处理都是不跑。
  if [ "$seen" -eq 0 ]; then
    case "${PREFLIGHT_ON_UNKNOWN:-block}" in
      warn) say "警告：读不到 GPU 信息，PREFLIGHT_ON_UNKNOWN=warn，放行" ;;
      *)    blocked "读不到任何 GPU 信息（rocm-smi/nvidia-smi 都不可用或无输出）。
体检做不了 ≠ 体检通过。若这个节点本来就没有 GPU，说明 lane 的 sbatch 参数申请错了资源。
确实要放行请在 runconf.sh 里设 PREFLIGHT_ON_UNKNOWN=warn。" ;;
    esac
  else
    [ "$bad" -gt 0 ] && blocked "$bad/$seen 张卡空闲显存 < ${PREFLIGHT_GPU_FREE_GIB} GiB。--exclusive 未兑现，节点上有别的作业。"
    [ "$seen" -lt "${PREFLIGHT_GPU_COUNT:-0}" ] && blocked "只看到 $seen 张卡，要求 ${PREFLIGHT_GPU_COUNT} 张。"
  fi
fi

if [ "${PREFLIGHT_NO_FOREIGN_PROC:-0}" -eq 1 ]; then
  me="$(id -un)"
  foreign="$(ps -eo user,comm --no-headers 2>/dev/null \
             | awk -v me="$me" '$1!=me && $1!="root" && $2 ~ /python|torchrun|ray|tritonserver/ {print; exit}')"
  [ -n "$foreign" ] && blocked "节点上有别的用户的计算进程：$foreign"
fi
say "节点体检通过"

# ---- 2) claim 互斥 ------------------------------------------------------------
#
# mkdir 是原子操作。抢到的干活；没抢到的判断持有者死活。
#
# 【关键】不要用 squeue 判活。计算节点上通常没装 slurm 客户端 ——
# `squeue 2>/dev/null || true` 会把 "command not found" 吞成空串，
# 于是「持有者不在队列 -> 接管」的分支被无条件命中，存活性检查 fail-open。
# 实测后果：0 次正确退让 / 17 次抢占，其中 10 次受害者存活不到 60 秒，
# 两个副本并发写同一个目录，测量结果全脏。
#
# 改用心跳文件判活：不依赖任何 slurm 命令，且信息不足时 fail-CLOSED。
# 解锁（回收死人留下的 claim）由登录节点的 keepalive.sh 负责。
HEARTBEAT_PID=""
stamp_claim() {
  : > "$WORKER_DIR/$JOB"         # 自证：本作业是 worker，不是热备
  echo "$JOB"                    > "$CLAIM_DIR/jobid"
  hostname                       > "$CLAIM_DIR/host"
  echo "${SLURM_JOB_NAME:-?}"    > "$CLAIM_DIR/lane"
  date -u                        > "$CLAIM_DIR/since"
  date +%s                       > "$CLAIM_HEARTBEAT"
}
start_heartbeat() {
  # >/dev/null 2>&1 不是为了安静：后台子 shell 会继承作业的 stdout，
  # 而它内部的 `sleep` 是【孙子进程】—— kill 子 shell 杀不到它。
  # 那个 sleep 会攥着作业的 stdout 直到超时，日志管道永远等不到 EOF。
  ( while :; do date +%s > "$CLAIM_HEARTBEAT" 2>/dev/null || exit 0; sleep "$HEARTBEAT_SEC"; done ) \
      >/dev/null 2>&1 &
  HEARTBEAT_PID=$!
}
stop_heartbeat() {
  [ -n "$HEARTBEAT_PID" ] || return 0
  pkill -P "$HEARTBEAT_PID" 2>/dev/null   # 先杀掉里面正在跑的 sleep
  kill "$HEARTBEAT_PID" 2>/dev/null
  HEARTBEAT_PID=""
}

# ---- claim 获取 + 热备驻留（SKILL.md 第 9 条）---------------------------------
# 原版行为是「claim 被占就退出」。在节点很容易拿到的队列上（burst / preemptible），
# 这等于挂不住路：备用路提交后几秒拿到节点、再几秒因为看见 claim 而退出，
# squeue 里长期只剩干活的那 1 路。改成占住节点盯心跳，持有者一断就地接管 ——
# 真正的收益是抢占发生时省掉重排队 + 重拉容器 + 服务冷启动。
# 热备【不起容器、不碰 GPU】，只占 slurm 分配；三道让出闸见下。
# 独占配额的 QOS 上别开这个，设 STANDBY_HOLD=0 回到原版行为。
STANDBY_HOLD="${STANDBY_HOLD:-0}"
STANDBY_POLL_SEC="${STANDBY_POLL_SEC:-30}"
STANDBY_HOLD_MAX_SEC="${STANDBY_HOLD_MAX_SEC:-43200}"

CLAIM_WHY=""
acquire_claim() {   # 返回 0=拿到 claim，1=没拿到（持有者还活着，或判不出死活）
  if mkdir "$CLAIM_DIR" 2>/dev/null; then
    stamp_claim; start_heartbeat
    say "claim 获取成功，本作业执行实际工作"
    return 0
  fi
  local owner owner_host hb age
  owner="$(cat "$CLAIM_DIR/jobid" 2>/dev/null || true)"
  owner_host="$(cat "$CLAIM_DIR/host" 2>/dev/null || true)"
  hb="$(cat "$CLAIM_HEARTBEAT" 2>/dev/null || echo 0)"
  case "$hb" in ''|*[!0-9]*) hb=0 ;; esac
  if [ "$hb" -eq 0 ]; then
    # 判不出死活 -> fail-CLOSED，绝不接管。回收死人的 claim 是登录节点 keepalive 的活。
    # 措辞是接口：selftest 第 3 条按原文 grep "fail-closed" / "仍在跳，本作业退出"。改前先看那边。
    CLAIM_WHY="claim 无心跳信息（持有者 ${owner:-未知} @ ${owner_host:-未知}），无法判活；fail-closed"
    return 1
  fi
  age=$(( $(date +%s) - hb ))
  if [ "$age" -lt "$CLAIM_STALE_AFTER" ]; then
    CLAIM_WHY="run 已被作业 $owner @ ${owner_host:-?} 认领，心跳 ${age}s 前仍在跳"
    return 1
  fi
  say "claim 心跳已停 ${age}s（> ${CLAIM_STALE_AFTER}s），持有者 ${owner:-未知} 判定已死，本作业接管。"
  stamp_claim; start_heartbeat
  return 0
}

if ! acquire_claim; then
  if [ "$STANDBY_HOLD" != "1" ]; then
    say "$CLAIM_WHY，本作业退出。"
    say "（若持有者确已死亡，登录节点的 keepalive.sh 会在下个周期回收 claim）"
    exit 0
  fi
  say "$CLAIM_WHY —— 转入【热备】：占住本节点盯心跳，持有者一断就地接管。"
  sb_start="$(date +%s)"; sb_last_log=0
  while :; do
    # 让出闸一：收工哨兵
    if [ -f "$STOP_SENTINEL" ]; then say "热备期间看见停止哨兵，释放节点退出。"; exit 0; fi
    # 让出闸二：队列清空 —— 少了这条，活全跑完后热备还会攥着机器直到 walltime
    if [ -z "$(find "$Q" -maxdepth 1 -type f 2>/dev/null | head -1)" ] \
       && [ -z "$(find "$Q/.inflight" -maxdepth 1 -type f 2>/dev/null | head -1)" ]; then
      say "热备期间队列已清空，没活可干，释放节点退出。"; exit 0
    fi
    # 让出闸三：占用封顶
    sb_age=$(( $(date +%s) - sb_start ))
    if [ "$sb_age" -ge "$STANDBY_HOLD_MAX_SEC" ]; then
      say "热备已占 ${sb_age}s，到 STANDBY_HOLD_MAX_SEC 上限，释放节点退出。"; exit 0
    fi
    if [ $(( sb_age - sb_last_log )) -ge 600 ]; then
      say "[热备 ${sb_age}s] $CLAIM_WHY"; sb_last_log="$sb_age"
    fi
    sleep "$STANDBY_POLL_SEC"
    acquire_claim && break
  done
fi

# 释放 claim —— 【只在它仍属于本作业时】才删。
# 无条件 rm -rf 是个活雷：本作业退出会删掉抢占者正在用的 claim，
# 于是下一路又能 mkdir 成功，与正在干活的作业并发。
cleanup() {
  stop_heartbeat
  rm -f "$WORKER_DIR/$JOB"
  # 被 SIGKILL 时这里根本不会执行 —— 所以 .inflight 回收必须在【下次启动时】做，
  # 不能指望退出路径。见下面 sweep_inflight。
  if [ "$(cat "$CLAIM_DIR/jobid" 2>/dev/null || true)" = "$JOB" ]; then
    rm -rf "$CLAIM_DIR"
  else
    say "claim 已不属于本作业（现属 $(cat "$CLAIM_DIR/jobid" 2>/dev/null || echo 无)），不删除。"
  fi
}
trap cleanup EXIT

# ---- 3) 任务队列 --------------------------------------------------------------
#
# 这里有个反直觉但极重要的点：
#
#   ❌  run_task "$t"; mv -f "$t" "$Q/done/"
#
# 这样写，`mv` 不看退出码，在任务返回后【无条件】执行。于是一个拿不到 GPU、
# 或者刚起步就被杀的副本，会把任务「消费」掉却什么都没做。在到手即死的集群上，
# 整个队列可能在没有任何一个任务真正跑起来的情况下全部进 done/。
#
# 更糟的是这个 bug 没法从任务文件那一侧绕开 —— 任务里写「失败就把自己写回队列」
# 是无效的，因为写回的正是马上要被 mv 掉的那个路径。绕开它需要额外的守卫文件
# 互相重建，一堆疤痕组织。修根因只要几行：
#
#   ✅  取任务 -> 移进 .inflight/ -> 跑 -> 按 rc 分流 -> 被杀则留在 .inflight/，
#       下次启动时 sweep 回队列（被杀不算任务失败，不计入 attempt）
sweep_inflight() {
  local n=0
  for f in "$Q/.inflight"/*; do
    [ -e "$f" ] || continue
    mv -f "$f" "$Q/$(basename "$f")" && n=$((n+1))
  done
  [ "$n" -gt 0 ] && say "回收上次被中断的 $n 个任务到队列（被杀不计入失败次数）"
}
sweep_inflight

attempts_of() { cat "$Q/.attempts/$1" 2>/dev/null || echo 0; }
next_task()   { find "$Q" -maxdepth 1 -type f -name '*' 2>/dev/null | sort | head -1; }

if [ "${QUEUE_MODE:-1}" -ne 1 ]; then
  say "单任务模式"; eval "$TASK_CMD"; exit $?
fi

idle=0
while :; do
  [ -f "$STOP_SENTINEL" ] && { say "发现哨兵，收工"; break; }

  t="$(next_task)"
  if [ -z "$t" ]; then
    idle=$((idle+1))
    if [ "$idle" -ge "${IDLE_RESCAN_MAX:-15}" ]; then
      say "队列空且已等待 $idle 轮，释放节点"; break
    fi
    say "队列空，保留节点等待新任务（$idle/${IDLE_RESCAN_MAX}）"
    sleep "${IDLE_RESCAN_SEC:-120}"; continue
  fi
  idle=0

  b="$(basename "$t")"
  a=$(( $(attempts_of "$b") + 1 ))
  mv -f "$t" "$Q/.inflight/$b" || continue
  say "===== 任务 [$b] 第 $a 次尝试 $(date -u '+%H:%M:%SZ') ====="

  run_task "$Q/.inflight/$b"; rc=$?
  echo "$a" > "$Q/.attempts/$b"

  if [ "$rc" -eq 0 ]; then
    mv -f "$Q/.inflight/$b" "$Q/done/$b"
    say "任务 [$b] 成功 -> done/"
  elif [ "$a" -ge "${TASK_MAX_ATTEMPTS:-3}" ]; then
    mv -f "$Q/.inflight/$b" "$Q/failed/$b"
    say "任务 [$b] 第 $a 次仍失败（rc=$rc），已达上限 -> failed/"
  else
    mv -f "$Q/.inflight/$b" "$Q/$b"
    say "任务 [$b] 失败（rc=$rc），放回队列，将重试（$a/${TASK_MAX_ATTEMPTS}）"
  fi
done

say "作业 $JOB 正常结束 $(date -u)"

exit 0
}
