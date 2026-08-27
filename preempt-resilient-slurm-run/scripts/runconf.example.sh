#!/bin/bash
# runconf.sh —— 一次 run 的全部配置。keepalive.sh 和 submit.sbatch 都 source 它。
# 复制成 runconf.sh 放进你的 RUN_DIR，改这一个文件就够了；脚本本身不用动。

# ---- 路径 --------------------------------------------------------------------
# RUN_DIR 必须在所有节点都能看到的共享盘上（NFS/Lustre）。
# 它同时是：claim 锁的位置、任务队列的位置、日志的位置。
RUN_DIR="${RUN_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
LOG_DIR="$RUN_DIR/logs"

# ---- 任务：作业拿到节点后到底跑什么 -------------------------------------------
# 队列模式（推荐）：RUN_DIR/queue/*.md 一个文件一个任务，按文件名排序取。
#   作业循环取任务 -> 执行 -> 按退出码分流到 queue/done/ 或 queue/failed/。
#   队列空了就等 IDLE_RESCAN_MAX 轮，还空就释放节点。
# 单任务模式：把 TASK_CMD 设成你的命令，QUEUE_MODE=0。
QUEUE_MODE=1
IDLE_RESCAN_MAX=15          # 队列空后再等几轮（每轮 IDLE_RESCAN_SEC）
IDLE_RESCAN_SEC=120

# 队列模式下，每个任务文件怎么执行。$1 = 任务文件绝对路径。
# 默认按 agent 跑；换成 `bash "$1"` 就是纯 shell 任务。
run_task() {
  local task="$1"
  claude -p "$(cat "$task")" \
      --permission-mode bypassPermissions \
      --model claude-sonnet-4.6
}

# 单任务模式用：
TASK_CMD='echo "set TASK_CMD in runconf.sh"'

# 任务失败重试次数。超过就进 queue/failed/，不再重放。
TASK_MAX_ATTEMPTS=3

# ---- lane：往队列里挂几张彩票 -------------------------------------------------
# 格式：<lane名>|<sbatch 额外参数>
# 同一个 run 跨多个 QOS/account 挂多路。哪路先拿到节点，claim 锁保证只有它干活，
# 其余到手即退，成本接近零。MaxSubmitPU 允许几张就买几张。
LANES=(
  "myrun-hi|-A my-account   --qos=my-high-qos"
  "myrun-lo|-A my-account   --qos=my-burst-qos -t 720"
  "myrun-lo2|-A my-account2 --qos=my-burst-qos -t 720"
)
MAX_QUEUED=8                # 队列里本 run 的作业总数上限

# sbatch 公共参数（节点数、卡数、时限等）
SBATCH_COMMON=(-N 1 --exclusive --gpus-per-node=8)

# ---- 节点体检：作业拿到节点后先自检，不合格就把任务放回队列并退出 --------------
# 见 SKILL.md「--exclusive 不一定兑现」。设成 0 关闭。
PREFLIGHT_GPU_COUNT=8
PREFLIGHT_GPU_FREE_GIB=250    # 每卡需要的空闲显存；0 = 不检查
PREFLIGHT_NO_FOREIGN_PROC=1   # 检查有没有别的用户的容器/torchrun 占卡
# 读不到任何 GPU 信息时怎么办。block（默认）= 拦住并退出；warn = 打印警告后放行。
# 默认 block 是刻意的：「体检做不了」不等于「体检通过」。读不到卡通常意味着
# lane 的 sbatch 参数申请错了资源，这时候跑起来的数据是废的。
PREFLIGHT_ON_UNKNOWN=block

# ---- claim 互斥 --------------------------------------------------------------
CLAIM_STALE_AFTER=600       # 心跳停多久判持有者已死（秒）。要 > keepalive 周期 ×2
HEARTBEAT_SEC=60

# ---- 补位与退避 --------------------------------------------------------------
KEEPALIVE_PERIOD_SEC=180     # keepalive 多久跑一次（cron/daemon 的周期，写在这里供退避计算）
INSTANT_DEATH_SEC=120        # 作业存活短于这个值算「到手即死」（被抢占/被清）
BACKOFF_BASE_SEC=180         # 退避基数
BACKOFF_MAX_SEC=3600         # 退避上限
PENDING_ZOMBIE_HOURS=6       # PENDING 超过这么久且原因不变 -> 报警（僵尸名额）

# ---- 收工 --------------------------------------------------------------------
# 只有这个哨兵文件存在才停止补位。
# 千万别用「某个产物文件存在」当完成判据 —— 见 SKILL.md 第 4 条。
STOP_SENTINEL="$RUN_DIR/.keepalive_stop"
