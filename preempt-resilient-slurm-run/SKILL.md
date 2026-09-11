---
name: preempt-resilient-slurm-run
description: Keeps a long-running job alive on a Slurm cluster that cancels or preempts jobs out from under you. Use when jobs get reaped mid-run, when a job dies and nothing re-queues so the node is lost for hours, when two copies of a run corrupt the same output directory, when --exclusive is not honored, when a work queue gets silently consumed by copies that never actually ran, when editing the submit script mid-run makes already-running jobs execute garbage, when jobs die one second after landing with an empty stdout file, or when standby lanes vanish from the queue as fast as you submit them. Provides a lane-lottery keepalive, a fail-closed claim mutex with an off-node liveness authority, and a work queue where killed tasks return to the queue instead of being lost.
---

# 在会杀作业的集群上跑长任务

在被抢占/被 reaper 周期清理的集群上，一个要跑十几个小时的任务不可能一次跑完。
真正的问题**不是**「作业被杀了」——那是环境事实，改不了。真正的问题是被杀之后：

- 队列里没人排着，要从队尾重排，白等几小时;
- 下一个副本和还没死透的上一个**并发写同一个目录**，结果全脏;
- 任务队列被一个连 GPU 都没拿到的副本**消费掉**，工作凭空蒸发。

这个 skill 解决的是后面三件事。

## 必须达到的终态

- 队列里**永远**有本 run 的作业排着（除非哨兵文件说收工）。
- 任何时刻**至多一个**作业在写 `RUN_DIR`。
- 作业被 SIGKILL 时，正在跑的任务**回到队列**，不算失败、不丢。
- 拿到坏节点（`--exclusive` 没兑现）的副本**不消费任何任务**就退出。
- 补位有指数退避，不在共享集群上空转刷屏。
- 收工只认哨兵文件，不认「某个产物存在」。

## 十二条硬教训

每一条都对应一次真实事故。第 1、2、8 条是静默失败——不看日志你不会知道自己中招了。

### 1. 补位逻辑必须在作业【外面】

reaper 和抢占用 SIGKILL 级手段。被杀进程自己的 `trap ... EXIT` **不保证执行**。
所以「作业在退出时把自己重新排队」这个设计一定失败，而且恰恰在最需要它的时候失败。

补位必须由外部周期性触发：`scrontab`（首选，调度器托管）或登录节点的守护进程（退路）。

### 2. 不要用 `squeue` 判断别的作业死没死 —— 计算节点上通常没有它

这条是整套东西里最贵的一课。常见写法：

```bash
OWNER_STATE="$(squeue -h -j "$OWNER" -o '%T' 2>/dev/null || true)"
case "$OWNER_STATE" in
  RUNNING*) exit 0 ;;      # 持有者还活着，让位
  *)        接管 ;;         # 持有者死了，接管
esac
```

计算节点上**根本没装 slurm 客户端**。`2>/dev/null` 把 "command not found" 吞掉，
`|| true` 把非零退出码吞掉，`OWNER_STATE` 恒为空串，于是**永远**走「接管」分支。
存活性检查 fail-open，而且完全静默——日志里只有一行"发现陈旧 claim，本作业接管"，
看起来还挺合理。

实测后果：**0 次正确退让，17 次抢占，其中 10 次受害者存活不到 60 秒。**
两个副本并发写同一个目录，几个小时的测量数据全部不可信。

正确的分工：

| | 能力 | 策略 |
|---|---|---|
| 计算节点 | 没有 slurm 客户端，**无权**判活 | 心跳文件 + **fail-CLOSED**（判不出就退出） |
| 登录节点 | 有 `squeue`，是判活权威 | keepalive 回收死人留下的锁，负责**解锁** |

只做 fail-closed 那一半会**锁死整条 run**：持有者被 SIGKILL 后锁留在原地、心跳不再更新，
之后每一路都退出，队列一直补位、永远没人干活。两半必须同时上线。

`preflight.sh --on-node` 会替你查这一项。

### 3. 释放锁时必须确认它还是你的

```bash
trap 'rm -rf "$CLAIM_DIR"' EXIT      # ❌ 活雷
```

无条件删。如果你已经被别人接管了，你退出时会删掉**别人正在用的**锁，
下一路又能 `mkdir` 成功，和正在干活的作业并发。

```bash
trap '[ "$(cat "$CLAIM_DIR/jobid")" = "$JOB" ] && rm -rf "$CLAIM_DIR"' EXIT   # ✅
```

### 4. 完成判据用哨兵文件，不要用「产物存在」

「跑出 `final_report.md` 就收工」这种判据的问题是：产物往往在**中途**就出现了
（先渲染一版、后面继续迭代）。判据一旦提前满足，守护进程一拉起就自杀，队列停止补位，
而你以为它还在跑。

只认一个显式哨兵：`.keepalive_stop`，由人或收尾任务显式创建。

### 5. 任务出队必须看退出码 —— 否则队列会被空烧

```bash
run_task "$t"; mv -f "$t" "$Q/done/"     # ❌
```

`mv` 不看 rc，在任务返回后**无条件**执行。一个拿不到 GPU、或刚起步就被杀的副本
会把任务「消费」掉却什么都没做。在到手即死的集群上，整个队列可能在
**没有任何一个任务真正跑起来**的情况下全部进 `done/`。

更阴的是这个 bug **没法从任务文件那一侧绕开**：在任务里写「失败就把自己写回队列」
是无效的，因为写回的正是马上要被 `mv` 掉的那个路径。想绕开需要额外的守卫文件互相重建
——一堆疤痕组织，还是修不干净。

修根因只要几行：

```bash
取任务 -> mv 进 .inflight/ -> 跑 -> 按 rc 分流 -> 被杀就留在 .inflight/
                                                  下次启动时 sweep 回队列
```

被杀**不算**任务失败，不计入重试次数——那不是任务的错。

### 6. 升级脚本要用 `mv`，而且脚本体要包在 `{ }` 里

bash 执行脚本时**不会**把文件一次读进内存。它按字节偏移量边读边执行，
每执行完一条顶层命令就 `lseek` 回下一条的偏移量。所以在作业运行期间
**原地改写**这个脚本（同 inode），正在跑的作业下一次 seek 会落到错位的字节上。

实测（6 KB 脚本，跑到一半在顶部插 2.5 KB）：

```
loop 1..6                              <- 循环正常跑完
small.sh: line 104: adding: command not found   <- 半行内容被当成命令执行
loop 1..6                              <- 整个循环又跑了一遍
```

"脚本够小 bash 会整读" 是错的，6 KB 照样中招。这条特别阴，因为长跑集群上
**边跑边改脚本是常态** —— 你修的正是那个正在被执行的文件。

两道防线，都要上：

```bash
# 1. 装新版本一律用 mv：新 inode，正在跑的作业继续读旧 inode 上的旧内容
mv submit.sbatch.new submit.sbatch          # ✅
cp -f submit.sbatch.new submit.sbatch       # ❌ 同 inode，原地重写

# 2. 脚本体整个包进 { }：bash 必须先完整解析这条复合命令才能开始执行
{
  ...整个脚本...
  exit 0
}                                            # exit 保证永远读不到 } 之后
```

第 2 条是真正的保险 —— 它让第 1 条即使被忘了也不致命。本 skill 的
`submit.sbatch` 已经这么包好了，改的时候别把 `{ }` 弄丢。

**适用范围**：`sbatch` 在**提交时**就把脚本内容快照进调度器了，作业启动时执行的是
那一刻的快照，运行期间不读磁盘。所以已经在跑的**批处理作业**其实不受原地改写影响。
真正会中招的是**直接 `bash foo.sh` 跑起来的长命脚本** —— keepalive daemon 每个 tick
重新读一次 `keepalive.sh`，selftest，以及任何 `nohup ./x.sh &` 的守护进程。

但快照这件事有它自己的坑，而且更常见：**装了新版本，队列里已经 PENDING 的作业
还是旧版。** 它们会一直带着你刚修掉的那个 bug 跑，直到重排。改完关键逻辑后要么等队列
自然排干，要么明确知道自己在和一批旧脚本共存 —— 后者意味着新旧两套 claim 语义
同时在线（旧版 fail-open 会抢、退出还会无条件删锁），需要外部防卫兜住。


## 装配

```bash
mkdir -p ~/myrun && cd ~/myrun
cp /shared_nfs/zhaoan12/work_skills/preempt-resilient-slurm-run/scripts/* .
cp runconf.example.sh runconf.sh
```

**第一步永远是探底**，不要跳过：

```bash
bash preflight.sh                                   # 登录节点
sbatch -N1 --wrap 'bash ~/myrun/preflight.sh --on-node'   # 计算节点
```

重点看三处：计算节点有没有 `squeue`（决定第 2 条要不要紧）；
QOS 表里 `PreemptMode=cancel` 和 `Priority`（决定退避要多凶）；当前用户实际关联的
account/QOS（决定 lane 能不能提交）。装配好 `runconf.sh` 后再运行一次：

```bash
RUNCONF=/绝对路径/runconf.sh bash preflight.sh
```

它会逐条检查 `LANES` 中的 account/QOS。检查失败时修改 `runconf.sh` 并重跑，不能静默
换到默认 account 或其他 QOS。

然后改 `runconf.sh`：`LANES`（跨 QOS/account 挂几张彩票）、`run_task`（任务怎么跑）、
`PREFLIGHT_GPU_FREE_GIB`（节点体检门槛）。

体检读不到 GPU 信息时默认 **拦住**（`PREFLIGHT_ON_UNKNOWN=block`）。这是刻意的：
「体检做不了」不等于「体检通过」，放行就是第 2 条那类 fail-open。确认过环境、
明知读不到卡也无所谓，才改成 `warn`。

改完脚本先跑自测，不需要 GPU、不提交任何作业：

```bash
bash selftest.sh          # 覆盖 claim、队列、热备、节点体检和 account/QOS 的关键断言
```

任务丢进 `queue/`，按文件名排序执行：

```bash
mkdir -p queue && cp mytask-01.md mytask-02.md queue/
```

起 keepalive（**首选 scrontab**，它由调度器托管，不依赖你的登录会话）：

```bash
scrontab -e
# */3 * * * * RUNCONF=/home/me/myrun/runconf.sh /home/me/myrun/keepalive.sh
```

没有 scrontab 才用守护进程，并且**要有人定期确认它还活着**：

```bash
mkdir -p logs
setsid nohup ./keepalive_daemon.sh >> logs/keepalive_daemon.err 2>&1 </dev/null &
ps -p "$(cat .keepalive_daemon.pid)" || echo "死了，重拉"
```

收工：

```bash
touch .keepalive_stop
```

## 日常检查

```bash
squeue -u "$USER"                    # 每个 lane 都在？
tail -20 keepalive.log               # 补位/退避/回收/僵尸报警
cat .claim/jobid .claim/host         # 谁在干活
ls queue/ queue/.inflight/ queue/failed/   # 队列/在跑/放弃
```

`keepalive.log` 里这几行是要当回事的：

- `⚠ claim 缺失但作业 N 仍 RUNNING —— 已补回` — 有别的副本误删了锁（第 3 条）。
- `lane X：作业 N 存活 ≲Ms（到手即死），连续第 K 次` — 该 lane 在退避，正常。
- `⚠ 僵尸 PENDING：作业 N 已排队 Nh，原因 'QOSGrpNodeLimit'` — 可能永远不会跑，
  却占着 `MaxSubmitPU` 名额把有机会的 lane 挤掉。

## 这个 skill 不做的事

- **不 scancel 任何作业。** 取消作业必须由人决定，脚本只报警。僵尸 PENDING 也只报警。
- 不处理**多节点**作业（`-N > 1`）。claim 只保护「一个 RUN_DIR 一个 writer」，
  作业内部的 rank 协调是另一回事。
- 不做 checkpoint。任务被杀会**从头重试**。任务本身要么够短（＜ 典型存活时长），
  要么自己带断点续跑。长流程请切成多个队列任务，用文件传递中间状态。
- 存活时长是**上界估计**（keepalive 按周期采样，不知道精确死亡时刻），
  只够用来分类「即死 / 跑过一阵」，别当性能数据。

### 7. 「谁是持有者」要两条判据同时看，只看一条会给抢占背书

登录节点那半边的防卫（第 1 条）如果只问「当前锁指向的作业在不在跑」，
那么一个**活着的**抢占者会被它认成「正常交接」—— 防卫非但不拦，还替抢占者续心跳。
只有在抢占者自己已经死掉时才夺回，等于覆盖不到抢占这个场景。

实测长这样：一个带旧版脚本的作业因为 `squeue` 抖了一下（第 2 条）误判持有者已死、
fail-open 抢了锁；持有者当时正跑到一半。防卫日志写的是「正常交接，认可」。
两个节点于是同时对同一个输出目录写了 36 分钟。

判据要改成两条同时满足才承认交接：

```bash
alive() { [ "$(squeue -h -j "$1" -o '%T' 2>/dev/null | tr -d ' ')" = "RUNNING" ]; }

if [ -n "$LAST_GOOD" ] && [ "$CUR" != "$LAST_GOOD" ] && alive "$LAST_GOOD"; then
    restore "$LAST_GOOD"        # 抢占者活着，但上一任也活着 -> split-brain，夺回
else
    LAST_GOOD="$CUR"            # 上一任确实不 RUNNING 了 -> 合法交接
fi
```

`alive()` 严格只认 `RUNNING`：`COMPLETING` 是在收尾，此时交接是合法的，别拦。

**发现之后不要急着回滚。** 把锁抢回原持有者，会让抢占者正在跑的活变成脱缰进程
（下面「已知毛刺」的 `docker exec` 那条），还会让两边同时写状态文件。
正确做法是**修判据、不回溯**：新版启动时把当前持有者认下来，从此刻起只拦新的抢占，
让抢占者把手上这一轮走完。代价是白跑一轮，比制造第二个 split-brain 便宜。

推论：**每个阶段的产物都同时落一份 `<name>.<jobid>` 边车副本**。
split-brain 真发生时，后来者会覆盖同名文件，边车副本是唯一能把前一任成果捞回来的东西。
实测就是靠这个把一份跑了 76 分钟的中间产物救了回来。

### 8. 别用 `--export` 传关键变量，也别指望 stderr 会并进 `-o`

`sbatch --export=ALL,VAR=val` 是原版 slurm 的写法。**不是所有集群跑的都是原版
slurm。** 实测一台跑 "spur" 重实现的集群完全不认这个合并写法：`VAR` 根本不进作业
环境，但 `sbatch` 照样返回 0、照样给你一个 jobid。

后果长这样，非常难认：

```
JobState=FAILED  Reason=NonZeroExitCode
ExitCode=1:0     DerivedExitCode=0:0
```

`-o` 指的那个 `.out` 是 **0 字节**。作业拿到节点后 1-2 秒就死，keepalive 立刻补位，
补上去又死 —— 队列看起来一直在动，其实一个任务都没跑。

两个诊断要点：

- **`DerivedExitCode=0:0` 而 `ExitCode` 非零 = 一个 step 都没产生**，
  也就是批处理脚本根本没被启动成功，不是你的脚本内部崩了。别去查脚本逻辑。
- **`.out` 是 0 字节不代表没有报错。** 那台集群**不把 stderr 并进 `-o`**：
  没给 `-e` 时它单独写到 `WorkDir/spur-<jobid>.out`。唯一那行报错
  （`spur_job.sh: line 21: RUNCONF: ...`）在共享盘根目录躺了半小时没人看见。

所以两条都要做：

```bash
# a) sbatch 一律显式给 -e，别赌它会合并
sbatch ... -o "$LOG_DIR/${lane}-%j.out" -e "$LOG_DIR/${lane}-%j.err" ...

# b) submit.sbatch 里给关键变量写死绝对路径兜底，不依赖任何 --export 语义
RUNCONF_FALLBACK="/abs/path/to/your/runconf.sh"   # 装配时改这一行
RUNCONF="${RUNCONF:-$RUNCONF_FALLBACK}"
[ -r "$RUNCONF" ] || { echo "!! 读不到 RUNCONF=$RUNCONF" >&2; exit 1; }
```

顺带一个同源的坑：**这类实现会在 `sbatch` 那一刻就把脚本快照进自己的库**
（`scontrol show job` 的 `Command=` 显示的是脚本内容而不是路径，节点上跑的是
`/var/spool/<impl>/job<N>/<impl>_job.sh`）。**改磁盘上的 `submit.sbatch` 对已经排队的
作业无效。** 要么按第 6 条把 `submit.sbatch` 做薄、只留一行调运行时才读的
`job_body.sh`，要么认了、把旧作业重提一遍。

### 9. 备用路拿到节点后不要退出 —— 要热备驻留

原版行为是：备用路落到节点，发现 claim 被人占着，就干净退出（第 3 条的 fail-closed）。
在**节点很容易拿到**的队列上（比如低优先级的 burst/preemptible QOS），这等于挂不住路：
备用路提交后几秒就拿到节点、再几秒就因为看见 claim 而退出，`squeue` 里长期只剩
正在干活的那 1 路。你以为挂了 4 路，实际只有 1 路。

改成备用路**占住节点不退**，盯着 claim 心跳当热备：

```bash
if ! acquire_claim; then
  [ "$STANDBY_HOLD" = "1" ] || { say "$CLAIM_WHY —— 退出。"; exit 0; }
  say "$CLAIM_WHY —— 转入热备：占住本节点盯心跳，持有者一断就地接管。"
  sb_start="$(date +%s)"
  while :; do
    [ -f "$STOP_SENTINEL" ] && exit 0                      # 闸一：收工哨兵
    queue_empty && exit 0                                  # 闸二：没活可干就让出节点
    [ $(( $(date +%s) - sb_start )) -ge "$STANDBY_HOLD_MAX_SEC" ] && exit 0   # 闸三：占用封顶
    sleep "$STANDBY_POLL_SEC"
    acquire_claim && break
  done
fi
```

真正的收益不是「看起来是 4 路」，是**持有者被抢占的那一刻热备原地接管**：
省掉重新排队 + 重新拉容器 + 服务冷启动。在 `PreemptMode=cancel`、典型存活
20-30 分钟的集群上，这经常就是「跑得完」和「永远跑不完」的差别。

三件事必须同时做对：

- **热备绝不接管活着的持有者**，判据仍然是第 3、7 条那套（心跳读不到就 fail-CLOSED，
  只有心跳停超过 `CLAIM_STALE_AFTER` 才接管）。热备只是把「退出」换成「继续等」。
- **热备期间不起容器、不碰 GPU**，只占 slurm 分配。否则第二个副本会去动持有者的服务。
- **必须有让出闸**。上面三道：收工哨兵 / 队列清空 / `STANDBY_HOLD_MAX_SEC` 封顶。
  少了第二道，任务全跑完之后热备还会攥着机器直到 walltime。

代价要跟人讲清楚：满编时会占 N 台整机，其中 N-1 台空转。在
preemptible/burst 这类「边角产能、随时被高优先级抢走」的 QOS 上这是可接受的；
在独占配额的 QOS 上就别开，设 `STANDBY_HOLD=0` 回到原版行为。

还有一个连带项：**keepalive 判断「这一路挂上了没有」必须把 `RUNNING` 也算进去**，
不能只认 `PENDING`。热备路是 RUNNING 状态，只认 PENDING 会导致对同一路重复提交，
撞上 QOS 的 `MaxSubmitPU` 被打回。

### 10. 挑队列看的是「多久能落到节点」，不是 priority

直觉是把优先级最高的 QOS 排满，剩下的余量再挂低优先级。这个直觉在有
`GrpTRES` 配额的 QOS 上是错的：priority 决定的是**同一个资源池里谁先拿**，
`GrpTRES` 决定的是**这个池子一共有多大**。池子被自己组的长作业占满时，
priority 再高也只是排在一条不动的队伍最前面。

实测的一组对照（同一天、同一个集群）：

| QOS | Priority | 限额 | 实际表现 |
|---|---|---|---|
| 高优先级 QOS | 10000 | `GrpTRES=node=8`，长期被同组 24h 作业占满 | pending 原因全是 `QOSGrpNodeLimit`，等待以小时计 |
| burst QOS | 100 | `MaxSubmitPU=4`，无节点配额 | 提交后几秒落到节点 |

诊断只要两条命令：`squeue` 的 `%r`（NODELIST(REASON)）列看 pending 原因，
`sacctmgr show qos <name> format=Name,Priority,GrpTRES,MaxSubmitPU` 看限额。
pending 原因是 `QOSGrpNodeLimit` / `QOSGrpCpuLimit` 这类**配额类**原因时，
这一路就不是「在排队」，是「在等一个不会腾出来的池子」——挂着只会让
`squeue` 好看，不会让活早开始。原因是 `Priority` / `Resources` 才是真在排队。

所以：**先量各 QOS 的落地时间，把 lane 全押在落得下去的那个上**，
哪怕它 priority 低、会被抢占。抢占至少还能重投，等不到节点连重投的机会都没有。

**但别指望热备能兜住 burst 的抢占。** 实测（2026-09-02）：4 路 lane 分别在
crsuse2-m2m-036 / 084 / 217 / 075 四台**不同**节点上，10:44–10:50 六分钟内全灭 ——
burst 的回收是按池子整批做的，持有者和备胎同批被收，第 9 条的「就地接管」从未发生。
恢复完全靠 keepalive 重投，空窗 9 分钟，被打断的那一 leg 从头重跑。

所以第 9 条的热备买到的是**单点抢占**的秒级接管，买不到批量回收的任何东西。
唯一真正抗批量回收的是**任务本身能断点续跑**：队列切得越细，一次回收丢得越少。
lane 冗余是止血，任务粒度才是治本。

### 11. 引入热备之后，「RUNNING」不再等于「在干活」——凭 RUNNING 补 claim 会造出幽灵

登录节点的 keepalive 有一条自愈逻辑：claim 丢了但某一路 lane 还 RUNNING，就把 claim
补回去指向它，防止下一路进来并发写 RUN_DIR。这条逻辑在**没有热备**的年代是对的：
RUNNING 的 lane 只可能是 worker。

加了第 9 条的热备之后它就错了，而且是**静默错**：热备也是 RUNNING。

2026-09-02 实测：持有者被抢占，keepalive 把 claim 补给了一路**热备**。接着第二个缺陷
接管——keepalive 还会「代持有者刷心跳」，于是这个幽灵 claim 永远新鲜：

* 每一路热备（包括被指为持有者的那一路自己）都看到心跳 fresh，全部继续退让
* 没有任何人接管，`.inflight` 里的任务永远回不到队列
* 队列**永久卡死**，而且从外面看一切正常：4 路 RUNNING、claim 有主、心跳在跳

卡了 22 分钟才被发现，唯一的破绽是 `.claim/note` 写着 `restored by keepalive`，
以及那一路的日志在说「run 已被作业 <我自己> 认领」。

两条修法，缺一不可：

1. **worker 自证。** 真正 `mkdir` 到 claim 的作业在 `$RUN_DIR/.worker/<jobid>` 留个空文件，
   退出时删掉。keepalive 的自愈只认这个标记，不认 RUNNING。宁可不补，也不能补出幽灵。
2. **不给自己补出来的 claim 续命。** 补过的 claim 带 `note` 文件；keepalive 见到 `note`
   就跳过代刷心跳。这样即使第 1 条判错了，claim 也会在 `CLAIM_STALE_AFTER` 之后
   自然腐烂、被正常接管流程回收——**错误有自愈期限，而不是永久锁死**。

一般化的教训：**任何"代替别人证明他还活着"的机制，都必须有一个它无法续期的过期时间。**
心跳的价值全在「停了就能判死」，一个永远不会停的心跳比没有心跳更糟——
没有心跳还能 fail-closed 报警，永远新鲜的假心跳会让所有保护逻辑安静地站到错误的一边。

### 12. account 是会变的；每次 run 都要重新验证 account/QOS 组合

不要把上一次能提交的 `-A` 当成永久配置。管理员调整组归属后，旧 account 会被调度器
直接拒绝；更危险的做法是看到拒绝后自动删掉 `-A` 或改用另一个 QOS，这会让任务进入
完全不同的资源池，抢占、配额和计费语义也随之改变。

`preflight.sh` 会列出当前用户的 account/QOS 关联。给它传入已装配的 `RUNCONF` 后，它还会
逐条解析 `LANES` 中的 `-A/--account` 与 `-q/--qos`，确认二者出现在同一条用户关联里：

```bash
RUNCONF=/abs/path/runconf.sh bash preflight.sh
```

关联不存在时 preflight 必须非零退出。正确处理是让操作者显式更新 `runconf.sh` 后重试；
skill 不替操作者猜新的 account，也不静默换 QOS。

## 已知毛刺

- **任务如果是 `docker exec` 进常驻容器跑的，作业被杀不等于工作停了。** 容器进程挂在
  dockerd 下，不在 slurm 的 cgroup 里，会活下来继续跑、继续往共享盘写 ——
  日志断了（stdout 的管道死了）而产物还在长，非常难发现。实测遇到过一次：
  节点已经分给别人，我们的孤儿 benchmark 还在那台机器上占着 8 张卡跑了 38 分钟。
  teardown 必须显式 `docker stop`，并且要能从作业外面触发。
- 坏节点会在体检失败后立刻退出，但下个周期还会被补位、再拿到同一个坏节点。
  没有节点黑名单。lane 级退避能缓解，治不了根。
- `rocm-smi --csv` 各版本输出格式不稳，显存体检可能读不到数。此时按
  `PREFLIGHT_ON_UNKNOWN` 处理（默认 block，作业退出且不消费任务）。上线前务必用
  `preflight.sh --on-node` 确认一次，否则每一路都会在体检这里被拦住。
- 心跳判活依赖登录节点和计算节点**时钟一致**。偏差大于 `CLAIM_STALE_AFTER` 会误判。
  `preflight.sh --on-node` 会打印计算节点时间供比对。
