#!/bin/bash
# preflight.sh —— 上线前跑一次，探清这个集群到底长什么样。
#
# 每一项检查都对应一个真实踩过的坑。别跳过：其中「计算节点上有没有 squeue」
# 这一项，答错的代价是互斥锁从头到尾没生效过一次，而它【不会报错】，只会静默地
# 让两个作业并发写同一个目录。
#
# 用法：
#   bash preflight.sh            # 登录节点部分
#   sbatch -N1 --wrap 'bash /path/to/preflight.sh --on-node'   # 计算节点部分

set -uo pipefail
ON_NODE=0
[ "${1:-}" = "--on-node" ] && ON_NODE=1

hr() { printf '%s\n' "------------------------------------------------------------"; }
ck() { printf '%-46s %s\n' "$1" "$2"; }

if [ "$ON_NODE" -eq 0 ]; then
  echo "== 登录节点 =="; hr
  for c in sbatch squeue scancel scontrol sinfo sacct scrontab; do
    ck "$c" "$(command -v $c >/dev/null && echo 有 || echo '缺失')"
  done
  hr
  echo "== 你的 QOS 限额（决定能挂几张彩票）=="
  sacctmgr -nP show qos format=Name,Priority,MaxTRESPU,MaxJobsPU,MaxSubmitPU,MaxWall,PreemptMode 2>/dev/null \
    | awk -F'|' '{printf "  %-24s prio=%-6s node=%-10s jobs=%-4s submit=%-4s wall=%-10s preempt=%s\n",$1,$2,$3,$4,$5,$6,$7}'
  echo
  echo "  PreemptMode=cancel  -> 作业会被【取消】而不是挂起，EXIT trap 不保证执行。"
  echo "  Priority 低的 QOS   -> 到手即死是常态，必须做指数退避。"
  hr
  echo "== 持久触发方式（keepalive 必须在作业之外，且不依赖交互会话）=="
  ck "scrontab" "$(command -v scrontab >/dev/null && echo '有（首选）' || echo '缺失')"
  ck "crontab"  "$(command -v crontab  >/dev/null && echo 有 || echo '缺失')"
  echo "  两个都没有 -> 只能 nohup 守护进程，登录节点重启就没了，要有人复查。"
  hr
  echo "== 共享盘 =="
  df -h "$(pwd)" 2>/dev/null | tail -1
  echo "  盘写满（>95%）时 whoami/date 这类 fork+触盘的命令会卡在 D 态且不可杀，"
  echo "  连累整个 keepalive 挂住。脚本里已改用 shell 内建变量规避。"
  hr
  echo "下一步：sbatch -N1 --wrap 'bash $0 --on-node' 看计算节点部分"
  exit 0
fi

echo "== 计算节点 $(hostname) =="; hr
echo "【最关键的一项】计算节点上有没有 slurm 客户端："
miss=0
for c in squeue sbatch scontrol sinfo sacct; do
  if command -v $c >/dev/null; then ck "  $c" "有"; else ck "  $c" "缺失"; miss=$((miss+1)); fi
done
echo
if [ "$miss" -gt 0 ]; then
  cat <<'EOF'
  ⚠ 计算节点【没有】完整的 slurm 客户端。

  这意味着作业自己无法判断别的作业死没死。任何写成
      STATE="$(squeue -h -j $OWNER -o '%T' 2>/dev/null || true)"
      case "$STATE" in RUNNING*) exit 0;; *) 接管;; esac
  的互斥锁都是坏的 —— "command not found" 被 2>/dev/null 吞掉，STATE 恒为空串，
  于是永远走「接管」分支。检查 fail-open，而且完全静默。

  正确做法（本 skill 采用）：
    计算节点 = 心跳文件判活 + fail-CLOSED（判不出就退出，绝不并发）
    登录节点 = keepalive 用 squeue 做判活权威，负责回收死人留下的锁
EOF
else
  echo "  计算节点有 slurm 客户端，可以直接 squeue 判活（仍建议叠一层心跳，"
  echo "  squeue 在控制器繁忙时会超时返回空，同样 fail-open）。"
fi
hr
echo "== --exclusive 是否兑现 =="
echo "本作业以 --exclusive 申请。看看节点上有没有别人："
me="$(id -un)"
ps -eo user,pid,comm --no-headers 2>/dev/null | awk -v me="$me" '$1!=me && $1!="root"' | sort -u -k1,1 | head -10
echo "（有输出 = --exclusive 没兑现，作业必须自带节点体检）"
hr
echo "== GPU 可见性与空闲显存 =="
command -v rocm-smi   >/dev/null && rocm-smi --showmeminfo vram 2>&1 | head -20
command -v nvidia-smi >/dev/null && nvidia-smi --query-gpu=index,memory.total,memory.free --format=csv 2>&1
echo "ROCR_VISIBLE_DEVICES=${ROCR_VISIBLE_DEVICES:-未设}  HIP_VISIBLE_DEVICES=${HIP_VISIBLE_DEVICES:-未设}"
hr
echo "== 时钟 =="
echo "计算节点 $(date -u '+%s  %Y-%m-%dT%H:%M:%SZ')"
echo "（心跳判活依赖两边时钟一致。偏差大于 CLAIM_STALE_AFTER 会导致误判。）"
