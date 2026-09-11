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
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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
  echo "== 当前用户的 account / QOS 关联 =="
  # account 归属会被管理员调整，旧 runconf 里的 -A 可能突然失效。spur 的
  # sacctmgr 不支持 association/user 的 -P 格式，也可能忽略 user= 过滤，因此
  # 读取普通表格后只保留用户名精确匹配的行。
  SCHED_USER="${PREFLIGHT_SLURM_USER:-$(id -un)}"
  ASSOC_RAW="$(sacctmgr show user "$SCHED_USER" withassoc format=User,Account,QOS,DefaultQOS 2>/dev/null || true)"
  ASSOC_ROWS="$(printf '%s\n' "$ASSOC_RAW" | awk -v u="$SCHED_USER" '$1 == u')"
  if [ -n "$ASSOC_ROWS" ]; then
    printf '%s\n' "$ASSOC_ROWS" | sed 's/^/  /'
  else
    echo "  ⚠ 无法读取用户 $SCHED_USER 的关联；不能静态验证 lane，请以调度器提交结果为准。"
  fi

  # 如果调用方给了 RUNCONF（或脚本旁已经装配了 runconf.sh），检查每条 lane
  # 指定的 account/QOS 是否出现在同一条用户关联里。只报告配置错误，绝不自动
  # 换到默认 account 或其他 QOS，因为那会改变资源池和抢占语义。
  RUNCONF_PATH="${RUNCONF:-}"
  [ -z "$RUNCONF_PATH" ] && [ -r "$HERE/runconf.sh" ] && RUNCONF_PATH="$HERE/runconf.sh"
  if [ -n "$RUNCONF_PATH" ]; then
    if [ ! -r "$RUNCONF_PATH" ]; then
      echo "  ✗ RUNCONF 不可读：$RUNCONF_PATH"
      exit 1
    fi
    if [ -z "$ASSOC_ROWS" ]; then
      echo "  ✗ 无法验证用户 $SCHED_USER 的 account/QOS 关联；为避免提交到错误资源池，preflight fail-closed。"
      exit 1
    fi
    # shellcheck source=/dev/null
    . "$RUNCONF_PATH"
    lane_errors=0
    for spec in "${LANES[@]:-}"; do
      lane="${spec%%|*}"
      extra="${spec#*|}"
      account=""
      qos=""
      read -r -a words <<< "$extra"
      for ((i=0; i<${#words[@]}; i++)); do
        case "${words[$i]}" in
          -A|--account) i=$((i+1)); account="${words[$i]:-}" ;;
          --account=*) account="${words[$i]#*=}" ;;
          -q|--qos) i=$((i+1)); qos="${words[$i]:-}" ;;
          --qos=*) qos="${words[$i]#*=}" ;;
        esac
      done

      if [ -z "$account" ]; then
        echo "  ⚠ lane $lane 未显式指定 account；调度器会使用默认 account。"
        continue
      fi
      assoc_line="$(printf '%s\n' "$ASSOC_ROWS" | awk -v u="$SCHED_USER" -v a="$account" '$1 == u && $2 == a {print; exit}')"
      if [ -z "$assoc_line" ]; then
        echo "  ✗ lane $lane：用户 $SCHED_USER 不属于 account $account"
        lane_errors=$((lane_errors+1))
        continue
      fi
      if [ -n "$qos" ] && ! printf '%s\n' "$assoc_line" | tr ',' ' ' \
          | awk -v q="$qos" '{for (i=1; i<=NF; i++) if ($i == q) found=1} END {exit !found}'; then
        echo "  ✗ lane $lane：account $account 未显示允许 QOS $qos"
        lane_errors=$((lane_errors+1))
        continue
      fi
      echo "  ✓ lane $lane：account=$account qos=${qos:-<default>}"
    done
    if [ "$lane_errors" -gt 0 ]; then
      echo "  配置失败：$lane_errors 条 lane 的 account/QOS 与当前用户关联不匹配。"
      echo "  请修改 runconf.sh；不要静默改用默认 account 或其他 QOS。"
      exit 1
    fi
  else
    echo "  未提供 RUNCONF；这里只展示关联，不校验 LANES。"
    echo "  装配后运行：RUNCONF=/abs/path/runconf.sh bash $0"
  fi
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
echo "== 作业以【谁】的身份跑、PATH 是什么（2026-09-07 加）=="
# spur 实测：sbatch 作业以 root 跑，HOME=/opt/spur。于是 runconf 里写
# export PATH="${HOME}/bin:..." 会指到 /opt/spur/bin，你装在 ~/bin 的命令
# 全部 "command not found"。而且报错只落在 .err 里，作业表现为
# 「启动正常、几十秒后消失」，从 .out 完全看不出来。
echo "id      : $(id 2>&1)"
echo "HOME    : ${HOME:-<unset>}"
echo "USER    : ${USER:-<unset>}"
echo "PATH    : $PATH"
echo "/home 挂载: $(mount 2>/dev/null | grep -w /home | head -1 || echo '未挂载 —— ~ 下的东西计算节点看不到')"
if [ "${HOME:-}" != "$(getent passwd "$(id -u)" 2>/dev/null | cut -d: -f6)" ] \
   || [ "$(id -un)" = "root" ]; then
  cat <<'EOF'
  ⚠ 作业身份/HOME 与登录节点不同。runconf.sh 里【不要用 ${HOME}】，
    把 HOME 和 PATH 都写成绝对路径：
        export HOME=/home/YOUR_USER
        export PATH="/home/YOUR_USER/bin:/home/YOUR_USER/.local/bin:${PATH}"
    注意 wrapper 脚本常常还要靠 $HOME 找配置（api key、token），
    只改 PATH 不改 HOME 一样会失败。
EOF
fi
echo "-- run_task 需要的命令能不能找到（按需增删）--"
for c in claude node python3 docker; do
  printf "  %-10s %s\n" "$c" "$(command -v "$c" 2>/dev/null || echo '缺失')"
done
hr
echo "== 时钟 =="
echo "计算节点 $(date -u '+%s  %Y-%m-%dT%H:%M:%SZ')"
echo "（心跳判活依赖两边时钟一致。偏差大于 CLAIM_STALE_AFTER 会导致误判。）"
