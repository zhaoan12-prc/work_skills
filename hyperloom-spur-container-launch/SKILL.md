---
name: hyperloom-spur-container-launch
description: Build, adapt, audit, and operate Hyperloom matrix launchers on AMD GPU clusters using an existing Slurm allocation, `spur exec`, detached Docker containers, and automatic in-container Claude Code setup. Use for Hyperloom launch workspaces, `models.tsv` matrices, container startup failures, Claude/GEAK preflight, per-run dependency isolation, status/log/stop operations, or reproducing the four-layer launcher pattern. Do not use for ordinary `sbatch` workflows that do not involve Hyperloom or spur-managed allocations.
---

# Hyperloom Spur Container Launch

Use a four-layer launcher so model configuration, cluster access, container
construction, and in-container setup remain independently inspectable:

```text
matrix dispatcher -> one-row launcher -> compute-node Docker launcher -> container driver
```

The intended local names are `hl_matrix.sh`, `hl_launch.sh`,
`hl_node_docker.sh`, and `hl_incontainer.sh`. Preserve equivalent existing
names when adapting a workspace.

## Required behavior

- Start from the login node through layer 1 or 2. Do not invoke the Docker
  layer directly because per-run dependency materialization happens first.
- Reuse a `RUNNING` Slurm allocation owned by the invoking user on the target
  node. Find its job ID with `squeue`, then enter it with `spur exec`.
- Do not submit a new allocation unless the user separately asks for one.
- Read each run from a tab-separated matrix containing at least: enabled flag,
  key, framework, tensor parallelism, node, GPU mask, model path, precision,
  maximum model length, server arguments, extra environment, and image.
- Reject duplicate enabled GPU claims on the same node before launching.
- Give every run private writable dependency checkouts and artifact paths.
  A shared read-only or hardlinked dependency master may seed those copies.
- Start the GPU container detached, with a stable name and a log on shared
  storage. Preserve stopped containers when restart/resume depends on their
  filesystem or exit status.
- Mount model paths at the same absolute paths used on the host. Resolve model
  symlinks and mount every root needed by their targets.
- Keep HIP/compiler temporary files on node-local storage such as `/tmp`, not
  shared NFS.

## Claude inside the container

Claude Code is a container runtime dependency in this pattern. The operator
does not need to install it on the login node or bake it into every serving
image.

On each container entry:

1. Set `HOME` and put the user-local binary directory on `PATH`.
2. Install the cluster CA needed by Node and Python clients.
3. Load credentials from a mode-`600` secret file without printing values.
4. Install Claude Code with the official installer, or honor an explicit
   version pin required for reproducibility.
5. Configure the Anthropic-compatible gateway, custom authentication headers,
   model, onboarding state, and noninteractive operation.
6. Make a small real request and record only success/failure and the CLI
   version.
7. Run the Hyperloom installer, which must make `claude_agent_sdk` importable.
   Treat a failed SDK import as fatal before starting a multi-hour run.

Keep the CLI and SDK distinction clear: Claude Code supplies the `claude`
binary; the Python `claude-agent-sdk` supplies the orchestration client. A
healthy launcher verifies both.

Never copy credentials from another user's workspace, show secret values, or
commit generated `.env`, Claude settings, tokens, or API keys. Recreate a
user-owned secret file and retain only required variable names in examples.

## Workflow

When reviewing or adapting an existing workspace:

1. Read its README, matrix, four launcher layers, environment setup, Claude
   setup, and recent container logs. Do not source unknown scripts during
   inspection.
2. Run `scripts/audit_workspace.sh <workspace>` for structural and shell checks.
3. Compare actual logs with the current matrix. Call out node, image, branch,
   or model differences because a workspace may have been edited after a run.
4. Verify prerequisites: existing allocation, model visibility, dependency
   master, writable artifact/log directories, secret-file mode, image access,
   gateway reachability, CLI version, SDK import, GPU count, and non-overlapping
   masks.
5. Use the matrix dry run before a real launch. When the user asked to launch,
   continue through the real command and inspect the first startup log through
   Claude/SDK preflight.
6. Report the exact entry command, container/log names, target node and GPU
   mask, and where artifacts will be written.

For the complete layer contracts, restart behavior, and failure signatures,
read [references/architecture.md](references/architecture.md).

The original known-good local example is
`/shared_nfs/yueliu14/hl_matrix_0828_kbtune`. Treat it as read-only evidence;
generalize paths, users, nodes, models, refs, and credentials into the target
workspace.

## Completion checks

- The dry run selects the intended rows and finds no GPU overlap.
- The one-row launcher resolves a running allocation belonging to the current
  user.
- The compute-node layer starts the expected named container and shared log.
- The log shows Claude Code installed/configured and a real gateway probe
  succeeded.
- `claude_agent_sdk` imports from the Python interpreter Hyperloom will use.
- Hyperloom reaches its optimize phase, or a specific preflight error is
  reported with the command and log path needed to fix it.
