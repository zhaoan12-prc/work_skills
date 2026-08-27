#!/bin/bash
# selftest.sh —— 在【登录节点】跑，不需要 GPU、不需要提交任何作业。
# 用假的 SLURM_JOB_ID 直接驱动 submit.sbatch，验证 5 条关键性质。
#
# 改完脚本先跑这个。它抓到过两个真 bug：
#   - 心跳子 shell 里的 sleep 是孙子进程，kill 不到，会攥着作业 stdout 到超时
#   - 读不到 GPU 信息时体检 fail-open 放行（正是 SKILL.md 第 2 条批评的那类错）
#
#   bash selftest.sh

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s — %s\n' "$1" "$2"; }
sandbox() {
  T="$(mktemp -d /tmp/prst-selftest.XXXXXX)"; cd "$T" || exit 1
  cp "$HERE"/submit.sbatch "$HERE"/keepalive.sh "$T"/ 2>/dev/null
  sed -e "s|^RUN_DIR=.*|RUN_DIR=\"$T\"|" > runconf.sh <<'EOF'
RUN_DIR="PLACEHOLDER"
LOG_DIR="$RUN_DIR/logs"
QUEUE_MODE=1; IDLE_RESCAN_MAX=1; IDLE_RESCAN_SEC=1; TASK_MAX_ATTEMPTS=3
PREFLIGHT_GPU_COUNT=0; PREFLIGHT_GPU_FREE_GIB=0; PREFLIGHT_NO_FOREIGN_PROC=0
CLAIM_STALE_AFTER=600; HEARTBEAT_SEC=3600
STOP_SENTINEL="$RUN_DIR/.keepalive_stop"
run_task() { bash "$1"; }
EOF
  mkdir -p queue/.inflight queue/.attempts queue/done queue/failed
}
# 注意：不要写成 `job N | grep -q ...`。grep -q 一匹配就退出，作业还在往管道里写，
# 于是 SIGPIPE + `set -o pipefail` 会把整条管道判成失败——哪怕 grep 明明匹配上了。
# 先把输出整个抓进变量，再匹配。
job()  { RUNCONF="$T/runconf.sh" SLURM_JOB_ID="$1" SLURM_JOB_NAME=lane bash ./submit.sbatch 2>&1; }
saw()  { printf '%s' "$OUT" | grep -q "$1"; }

echo "== 1. 任务按退出码分流（SKILL.md 第 5 条）=="
sandbox
echo 'exit 0' > queue/a.sh; echo 'exit 7' > queue/b.sh
START=$(date +%s); job 1001 >/dev/null; ELAPSED=$(( $(date +%s) - START ))
[ -f queue/done/a.sh ]   && ok "成功任务 -> done/"        || bad "成功任务 -> done/" "在 $(ls queue queue/done queue/failed)"
[ -f queue/failed/b.sh ] && ok "失败任务重试到上限 -> failed/" || bad "失败任务 -> failed/" "在 $(ls queue queue/done queue/failed)"
[ "$ELAPSED" -lt 20 ] && ok "作业退出不挂起（${ELAPSED}s）" || bad "作业退出不挂起" "耗时 ${ELAPSED}s，心跳的 sleep 可能还攥着 stdout"
cd /tmp && rm -rf "$T"

echo "== 2. 被 SIGKILL 的任务回到队列，不计失败（SKILL.md 第 5 条）=="
sandbox
echo 'exit 0' > queue/.inflight/long.sh          # 模拟被杀时卡在 .inflight/
OUT="$(job 2002)"
saw '回收上次被中断' && ok "启动时 sweep 回队列" || bad "sweep 回队列" "$OUT"
[ -f queue/done/long.sh ] && ok "回收后正常跑完" || bad "回收后跑完" "$(ls queue/done)"
[ "$(cat queue/.attempts/long.sh 2>/dev/null)" = "1" ] && ok "被杀不计入重试次数" || bad "被杀不计入重试" "attempts=$(cat queue/.attempts/long.sh 2>/dev/null)"
cd /tmp && rm -rf "$T"

echo "== 3. claim 互斥四条路径（SKILL.md 第 2、3 条）=="
sandbox
mkdir -p .claim; echo 9001 > .claim/jobid; echo nodeA > .claim/host; date +%s > .claim/heartbeat
OUT="$(job 9002)"; saw '仍在跳，本作业退出' && ok "心跳新鲜 -> 后来者退让" || bad "心跳新鲜 -> 退让" "被抢了"
[ "$(cat .claim/jobid)" = "9001" ] && ok "退让者没抢走 claim" || bad "退让者没抢走 claim" "现属 $(cat .claim/jobid)"
[ -d .claim ] && ok "退让者没删掉别人的 claim" || bad "退让者没删别人的 claim" "claim 被误删"
rm -f .claim/heartbeat
OUT="$(job 9003)"; saw 'fail-closed' && ok "无心跳 -> fail-closed 不并发" || bad "无心跳 -> fail-closed" "放行了"
[ "$(cat .claim/jobid)" = "9001" ] && ok "fail-closed 后 claim 未变" || bad "fail-closed 后 claim 未变" "现属 $(cat .claim/jobid)"
expr "$(date +%s)" - 700 > .claim/heartbeat
OUT="$(job 9004)"; saw '判定已死，本作业接管' && ok "心跳超时 -> 允许接管（不会死锁）" || bad "心跳超时 -> 接管" "没接管，会死锁"
cd /tmp && rm -rf "$T"

echo "== 4. 节点体检不通过时不消费任务 =="
sandbox
sed -i 's/PREFLIGHT_GPU_COUNT=0/PREFLIGHT_GPU_COUNT=8/; s/PREFLIGHT_GPU_FREE_GIB=0/PREFLIGHT_GPU_FREE_GIB=250/' runconf.sh
echo 'exit 0' > queue/precious.sh
OUT="$(job 3001)"; saw '未消费任何任务' && ok "体检不通过 -> 退出" || bad "体检不通过 -> 退出" "没拦住"
[ -f queue/precious.sh ] && ok "任务仍在队列（没被空烧）" || bad "任务仍在队列" "被消费了：$(ls queue/done queue/failed)"
[ ! -d .claim ] && ok "体检在抢锁之前（没留下 claim）" || bad "体检在抢锁之前" "留下了 claim"
ls BLOCKED_* >/dev/null 2>&1 && ok "写了 BLOCKED 报告" || bad "写 BLOCKED 报告" "没写"

echo "== 5. 显式放行开关 =="
echo 'PREFLIGHT_ON_UNKNOWN=warn' >> runconf.sh
OUT="$(job 3002)"; saw 'PREFLIGHT_ON_UNKNOWN=warn，放行' && ok "warn 可显式放行" || bad "warn 显式放行" "没生效"
cd /tmp && rm -rf "$T"

echo
printf '结果：%d 通过 / %d 失败\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
