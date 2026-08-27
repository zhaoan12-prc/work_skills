#!/bin/bash
# keepalive_daemon.sh —— 没有 scrontab/crontab 时的退路：登录节点上的常驻循环。
#
#   nohup /path/to/keepalive_daemon.sh > /dev/null 2>&1 &
#   echo $! > .keepalive_daemon.pid
#
# 注意这是【退路】不是首选：登录节点重启、被清进程、你退出登录被 systemd-logind
# 连坐杀掉，它都会没。必须有人周期性确认它还活着（`ps -p $(cat .keepalive_daemon.pid)`）。
# 有 scrontab 就用 scrontab —— 那是调度器托管的，不依赖任何会话。

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNCONF="${RUNCONF:-$HERE/runconf.sh}"
# shellcheck disable=SC1090
. "$RUNCONF"

PERIOD="${KEEPALIVE_PERIOD_SEC:-180}"
echo "$$" > "$RUN_DIR/.keepalive_daemon.pid"
while :; do
  [ -f "$STOP_SENTINEL" ] && { echo "[$(date -u)] 哨兵存在，守护进程退出" >> "$RUN_DIR/keepalive.log"; break; }
  RUNCONF="$RUNCONF" bash "$HERE/keepalive.sh"
  sleep "$PERIOD"
done
rm -f "$RUN_DIR/.keepalive_daemon.pid"
