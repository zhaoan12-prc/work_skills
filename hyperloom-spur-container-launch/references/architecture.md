# Four-layer launcher contract

Read this reference when creating a launcher, tracing startup, or diagnosing a
run that dies before optimization.

## Layer 1: matrix dispatcher on the login node

The dispatcher reads enabled rows from `models.tsv` and supports:

```bash
./hl_matrix.sh                 # dry run
./hl_matrix.sh --go            # launch enabled rows
./hl_matrix.sh --status        # summarize container/log state
./hl_matrix.sh --stop-all      # stop matrix containers
./hl_matrix.sh --go --only KEY1,KEY2
```

Before launch, reject `node=TBD`, duplicate enabled keys, and any duplicate
`node:gpu` claim. Launch rows sequentially or with controlled staggering so
image pulls and Claude downloads do not saturate the shared link.

The matrix file should use a visible placeholder such as `-` for an empty
server-argument, extra-environment, or image field. Empty TSV cells are easy to
misread and shift.

## Layer 2: one-row launcher on the login node

The row launcher:

1. Resolves exactly one row by key.
2. Maps the matrix node to its cluster hostname.
3. Uses `squeue -u "$USER" -t RUNNING` to find the caller's allocation.
4. Creates private dependency trees and run directories.
5. Passes only explicit, quoted values across `spur exec`; do not assume login
   shell exports survive the hop.
6. Invokes the node Docker layer with workspace and run key.

Support `--status`, `--logs`, `--stop`, `--force`, and optionally
`--foreground`. Container name, log path, and optional run tag must be derived
identically in every layer.

Dependency isolation matters because installers and optimizers modify their
checkouts. A practical layout is:

```text
deps_master/{GEAK,Magpie,InferenceX,TraceLens}
deps/<run-key>/{GEAK,Magpie,InferenceX,TraceLens}
```

Hardlinked copies are acceptable only when the tools replace files atomically
rather than editing shared inodes in place. If that assumption is uncertain,
use ordinary copies or separate clones.

## Layer 3: Docker launcher on the compute node

Select the serving image from the framework default unless the matrix row
overrides it. Model/image compatibility is part of the run configuration.

The container generally needs:

```text
--network=host --ipc=host --shm-size 64g
--device=/dev/kfd --device=/dev/dri
--group-add video
--cap-add=SYS_PTRACE
--security-opt seccomp=unconfined
ROCR_VISIBLE_DEVICES=<matrix mask>
HOME=/root
TMPDIR=/tmp/hl_<run-key>
```

Mount the workspace read-write, model roots read-only, and any required source
checkout at its original absolute path. Avoid setting both
`ROCR_VISIBLE_DEVICES` and `HIP_VISIBLE_DEVICES`; the masks can compose and hide
all GPUs for nonzero masks.

Before creating a container:

- Resolve model symlinks and prove their targets fall under a mounted root.
- Detect an existing container with the same exact name.
- If running, leave it alone unless `--force` was explicitly supplied.
- If stopped and the workflow supports resume, restart it.
- Warn when another container advertises an overlapping GPU mask.

Use a shared log as well as Docker logs:

```bash
exec bash "$WS/hl_incontainer.sh" 2>&1 | tee -a "$LOG"
```

Detached mode should omit `--rm` when stopped-container restart, exit-code
inspection, or filesystem persistence is required.

## Layer 4: container driver

Recommended setup order:

1. Read and validate the matrix row.
2. Assert GPU-mask count equals tensor parallelism.
3. Export workload variables.
4. Install the internal CA bundle.
5. Source the secret file and run the Claude setup.
6. Source the common Hyperloom/GEAK environment.
7. Run the Hyperloom installer.
8. Verify pinned dependency refs after installers that may force-checkout them.
9. Check GPU visibility, `claude_agent_sdk`, knowledge-store reachability, and
   stale serving processes.
10. Start `python -m hyperloom.inference_optimizer.cli ... optimize`.

Write a launch-info file and use it to resume only unfinished sessions. A
terminal report or terminal machine state must stop automatic resume; otherwise
the launcher can overwrite a completed run.

## Claude and gateway configuration

Keep credentials in a user-owned mode-`600` file. The exact variable names and
gateway path depend on the current environment, but an Anthropic-compatible
setup commonly needs:

```text
ANTHROPIC_BASE_URL
ANTHROPIC_API_KEY
ANTHROPIC_CUSTOM_HEADERS
ANTHROPIC_MODEL
```

Header-authenticated gateways may require a subscription key plus a user
header even when an API key variable is also set. Preserve the gateway's exact
base-URL convention: some clients append `/v1/messages`, so adding `/v1` in the
configured root can produce a doubled path.

Do not infer current endpoint or model support from an old workspace. Verify it
from current local configuration or the applicable gateway setup skill.

Claude Code may be installed by an official native installer while Hyperloom's
Python installation separately installs `claude-agent-sdk`. Verify:

```bash
command -v claude
claude --version
python3 -c 'from claude_agent_sdk import ClaudeAgentOptions, ClaudeSDKClient'
```

If reproducibility matters, pin the CLI version. Installing `latest` on each
entry can change behavior between restarts; record the resolved version in the
container log.

## Failure signatures

| Signature | Likely cause |
|---|---|
| No running allocation found | Matrix points to a node where the current user has no `RUNNING` job |
| Model exists on host but not in container | Missing model root mount or unresolved symlink target |
| GPUs disappear only for masks such as `4,5` | Both ROCR and HIP masks were set and composed |
| Claude reports missing subscription key | Custom gateway header missing or malformed |
| Claude reports model missing with a doubled path | Anthropic base URL incorrectly includes `/v1` |
| CLI works but workflow exits after receiving a task ID | SDK missing, causing fallback to a short-lived `claude -p` path |
| GEAK unexpectedly runs `main` | Ref variable was not exported before an installer force-checkout |
| Kernel compilation crashes or reports environment unavailable | Compiler temporary directory is on shared NFS |
| Empty or truncated traces | Serving image does not match the profiler/instrumentation requirements |
| Two containers stall with flat GPUs | Overlapping GPU masks or a duplicate container was allowed |

## Evidence to report

For a launch or diagnosis, report:

- command used at layer 1 or 2;
- matrix key, current node, GPU mask, framework, and image;
- Slurm job ID used by `spur exec`;
- container name and state;
- shared log and artifact paths;
- Claude CLI version and gateway probe result without credential values;
- SDK import result;
- whether optimization started, resumed, completed, or failed at a named phase.
