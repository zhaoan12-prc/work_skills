#!/bin/bash
# keepalive_daemon.sh —— 没有 scrontab/crontab 时的退路：登录节点上的常驻循环。
#
#   setsid nohup /path/to/keepalive_daemon.sh >> logs/keepalive_daemon.err 2>&1 </dev/null &
#
# 注意这是【退路】不是首选：登录节点重启、被清进程、你退出登录被 systemd-logind
# 连坐杀掉，它都会没。必须有人周期性确认它还活着（`ps -p $(cat .keepalive_daemon.pid)`）。
# 有 scrontab 就用 scrontab —— 那是调度器托管的，不依赖任何会话。
#
# 2026-09-09 两处修复（起因：09-08 06:26 守护进程静默死亡，14:04 两路 burst 被抢占后
# 无人补位，run 白死 12h）：
#   1) keepalive.sh 外面套 timeout —— 09-09 02:32 实测它在 NFS 上 D 状态卡死 4 分钟
#      （wchan=nfs_start_io_read），没有 timeout 的话整个循环就永远停在那里，进程
#      「活着」但一次都不再补位，比直接死掉更难发现。
#   2) 每轮都往 keepalive.log 写一行心跳 —— 之前 keepalive.sh 不输出时日志毫无动静，
#      分不清「无需补位」和「守护进程已死」。

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNCONF="${RUNCONF:-$HERE/runconf.sh}"
# shellcheck disable=SC1090
. "$RUNCONF"

PERIOD="${KEEPALIVE_PERIOD_SEC:-180}"
CYCLE_TIMEOUT="${KEEPALIVE_CYCLE_TIMEOUT_SEC:-150}"   # < PERIOD，保证不重叠
echo "$$" > "$RUN_DIR/.keepalive_daemon.pid"
echo "[$(date -u +%FT%TZ)] 守护进程启动 pid=$$ period=${PERIOD}s cycle_timeout=${CYCLE_TIMEOUT}s" >> "$RUN_DIR/keepalive.log"
while :; do
  [ -f "$STOP_SENTINEL" ] && { echo "[$(date -u +%FT%TZ)] 哨兵存在，守护进程退出" >> "$RUN_DIR/keepalive.log"; break; }
  RUNCONF="$RUNCONF" timeout -k 10 "$CYCLE_TIMEOUT" bash "$HERE/keepalive.sh"
  rc=$?
  if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
    echo "[$(date -u +%FT%TZ)] ⚠ keepalive.sh 超过 ${CYCLE_TIMEOUT}s 被强制中断（rc=$rc，多半卡在 NFS 或 sbatch），本轮跳过，下一轮重试" >> "$RUN_DIR/keepalive.log"
  fi
  sleep "$PERIOD"
done
rm -f "$RUN_DIR/.keepalive_daemon.pid"
