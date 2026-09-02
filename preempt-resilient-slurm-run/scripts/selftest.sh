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

echo "== 6. 运行期间原地改写脚本不影响正在跑的作业（SKILL.md 第 6 条）=="
sandbox
grep -qx '{' submit.sbatch && ok "脚本体被 { } 包住" || bad "脚本体被 { } 包住" "顶层没有单独的 { 行，改写防护失效"
echo 'echo SELFTEST_MARKER; sleep 4' > queue/only.sh
( job 6001 > run6.out 2>&1 ) & JP=$!
sleep 2
# 真·原地改写：`cat > file` 截断同一个 inode（sed -i 会换 inode，测不出来）
{ head -1 submit.sbatch
  for i in $(seq 1 60); do echo "# INSERTED $i ------------------------------------------"; done
  tail -n +2 submit.sbatch
} > .tmp.rewrite && cat .tmp.rewrite > submit.sbatch && rm -f .tmp.rewrite
wait "$JP"
[ "$(grep -c SELFTEST_MARKER run6.out)" = "1" ] && ok "任务只跑了一次（没有因偏移错位重复执行）" \
  || bad "任务只跑一次" "跑了 $(grep -c SELFTEST_MARKER run6.out) 次"
grep -q 'command not found' run6.out \
  && bad "改写后没有执行到错位内容" "$(grep -m1 'command not found' run6.out)" \
  || ok "改写后没有执行到错位内容"
cd /tmp && rm -rf "$T"


echo "== 7. RUNCONF 兜底：--export 没生效时要吵，不要静默秒死（SKILL.md 第 8 条）=="
sandbox
echo 'exit 0' > queue/a.sh
# 不给 RUNCONF 环境变量，模拟 --export=ALL,VAR=val 在非原版实现上失效
OUT="$(env -u RUNCONF SLURM_JOB_ID=1701 SLURM_JOB_NAME=lane bash ./submit.sbatch 2>&1)"; RC=$?
if grep -q '^RUNCONF_FALLBACK="/PATH/TO/YOUR/runconf.sh"' ./submit.sbatch; then
  # 未装配状态：必须报错退出，且说清楚是哪儿的问题
  [ "$RC" -ne 0 ] && saw '读不到 RUNCONF' \
    && ok "未装配 RUNCONF_FALLBACK 时报错退出（rc=$RC）" \
    || bad "未装配时应报错退出" "rc=$RC out=$(printf '%s' "$OUT" | head -2)"
  [ -f queue/a.sh ] && ok "报错退出时不消费任务" || bad "报错退出时不消费任务" "a.sh 不见了"
else
  ok "RUNCONF_FALLBACK 已装配（跳过未装配用例）"
fi
cd /tmp && rm -rf "$T"

echo "== 8. 热备驻留：不退出、且三道让出闸有效（SKILL.md 第 9 条）=="
sandbox
sed -i 's/^CLAIM_STALE_AFTER=600.*/CLAIM_STALE_AFTER=600; HEARTBEAT_SEC=3600\nSTANDBY_HOLD=1; STANDBY_POLL_SEC=1; STANDBY_HOLD_MAX_SEC=3600/' runconf.sh
# 造一个活着的持有者：claim 存在 + 心跳是新的
mkdir -p .claim; echo 9999 > .claim/jobid; hostname > .claim/host; date +%s > .claim/heartbeat
echo 'exit 0' > queue/a.sh
job 1801 > sb.out 2>&1 &
JP=$!
sleep 4
if kill -0 "$JP" 2>/dev/null; then ok "claim 被活持有者占着时不退出（转入热备）"; else
  bad "热备应驻留" "作业 4s 内就退了：$(head -3 sb.out)"; fi
grep -q '转入【热备】' sb.out && ok "日志写明进入热备" || bad "日志写明进入热备" "$(head -3 sb.out)"
# 让出闸二：队列清空 -> 应在一个 poll 周期内自己退出，且【不】接管 claim
rm -f queue/a.sh
for _ in $(seq 1 15); do kill -0 "$JP" 2>/dev/null || break; sleep 1; done
if kill -0 "$JP" 2>/dev/null; then
  bad "队列清空后热备应让出节点" "15s 后还在跑"; kill -9 "$JP" 2>/dev/null
else
  ok "队列清空后热备让出节点"
fi
wait "$JP" 2>/dev/null
[ "$(cat .claim/jobid 2>/dev/null)" = "9999" ] \
  && ok "热备退出时没有动活持有者的 claim" \
  || bad "热备不得动别人的 claim" "claim/jobid 现在是 $(cat .claim/jobid 2>/dev/null)"
cd /tmp && rm -rf "$T"


echo "== 9. 幽灵 claim：keepalive 不得把 claim 补到热备头上，也不得给补出来的 claim 续命 =="
# 2026-09-02 实测事故：热备也是 RUNNING，keepalive 凭 RUNNING 把 claim 补给了一路热备，
# 又每周期代刷心跳，于是所有路都看到「心跳新鲜」永远退让 —— 队列卡死 22 分钟。
sandbox
sed -i 's/^CLAIM_STALE_AFTER=600.*/CLAIM_STALE_AFTER=600; HEARTBEAT_SEC=3600\nSTANDBY_HOLD=1; STANDBY_POLL_SEC=1; STANDBY_HOLD_MAX_SEC=5/' runconf.sh

# 9a) worker 标记只有真 worker 会写
echo 'exit 0' > queue/a.sh
OUT="$(job 1901)"
[ -f .worker/1901 ] && bad "worker 退出后应清掉自己的标记" "$(ls .worker)" \
  || ok "worker 跑完清掉了自己的 worker 标记"
saw 'claim 获取成功' && ok "无 claim 时正常成为 worker" || bad "无 claim 时应成为 worker" "$OUT"

# 9b) 热备【不】写 worker 标记
mkdir -p .claim; echo 9999 > .claim/jobid; hostname > .claim/host; date +%s > .claim/heartbeat
echo 'exit 0' > queue/b.sh
job 1902 > sb9.out 2>&1 & JP=$!
sleep 3
[ -f .worker/1902 ] \
  && { bad "热备不得写 worker 标记" "存在 .worker/1902"; kill -9 "$JP" 2>/dev/null; } \
  || ok "热备不写 worker 标记（keepalive 因此不会误补 claim 给它）"
kill -9 "$JP" 2>/dev/null; wait "$JP" 2>/dev/null

# 9c) 心跳过期的 claim 必须能被接管 —— 哪怕它带着 keepalive 的 note
rm -rf .claim; mkdir -p .claim
echo 9999 > .claim/jobid; hostname > .claim/host
echo $(( $(date +%s) - 700 )) > .claim/heartbeat        # 700s > CLAIM_STALE_AFTER=600
echo "restored by keepalive: claim missing while 9999 RUNNING" > .claim/note
echo 'exit 0' > queue/c.sh
OUT="$(job 1903)"
saw '判定已死，本作业接管' \
  && ok "带 note 的过期 claim 可被接管（幽灵 claim 会自愈）" \
  || bad "带 note 的过期 claim 应可接管" "$(printf '%s' "$OUT" | head -3)"
[ -f queue/done/c.sh ] && ok "接管后继续消费队列" || bad "接管后应消费队列" "c.sh 没进 done"
cd /tmp && rm -rf "$T"


echo
printf '结果：%d 通过 / %d 失败\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
