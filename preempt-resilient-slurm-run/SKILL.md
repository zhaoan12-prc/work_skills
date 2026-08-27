---
name: preempt-resilient-slurm-run
description: Keeps a long-running job alive on a Slurm cluster that cancels or preempts jobs out from under you. Use when jobs get reaped mid-run, when a job dies and nothing re-queues so the node is lost for hours, when two copies of a run corrupt the same output directory, when --exclusive is not honored, or when a work queue gets silently consumed by copies that never actually ran. Provides a lane-lottery keepalive, a fail-closed claim mutex with an off-node liveness authority, and a work queue where killed tasks return to the queue instead of being lost.
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

## 五条硬教训

每一条都对应一次真实事故。前两条是静默失败——不看日志你不会知道自己中招了。

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

重点看两处：计算节点有没有 `squeue`（决定第 2 条要不要紧）；
QOS 表里 `PreemptMode=cancel` 和 `Priority`（决定退避要多凶）。

然后改 `runconf.sh`：`LANES`（跨 QOS/account 挂几张彩票）、`run_task`（任务怎么跑）、
`PREFLIGHT_GPU_FREE_GIB`（节点体检门槛）。

体检读不到 GPU 信息时默认 **拦住**（`PREFLIGHT_ON_UNKNOWN=block`）。这是刻意的：
「体检做不了」不等于「体检通过」，放行就是第 2 条那类 fail-open。确认过环境、
明知读不到卡也无所谓，才改成 `warn`。

改完脚本先跑自测，不需要 GPU、不提交任何作业：

```bash
bash selftest.sh          # 17 条断言，覆盖上面五条教训
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
nohup ./keepalive_daemon.sh >/dev/null 2>&1 &
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

## 已知毛刺

- 坏节点会在体检失败后立刻退出，但下个周期还会被补位、再拿到同一个坏节点。
  没有节点黑名单。lane 级退避能缓解，治不了根。
- `rocm-smi --csv` 各版本输出格式不稳，显存体检可能读不到数。此时按
  `PREFLIGHT_ON_UNKNOWN` 处理（默认 block，作业退出且不消费任务）。上线前务必用
  `preflight.sh --on-node` 确认一次，否则每一路都会在体检这里被拦住。
- 心跳判活依赖登录节点和计算节点**时钟一致**。偏差大于 `CLAIM_STALE_AFTER` 会误判。
  `preflight.sh --on-node` 会打印计算节点时间供比对。
