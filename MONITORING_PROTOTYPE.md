# AIRE Monitoring Prototype

`scripts/aire_monitor_snapshot.py` is the local-only monitoring collector for AIRE. It gathers a read-only Slurm snapshot over SSH and prints JSON that is consumed by the macOS app, the menu bar monitor, and the desktop widget.

## Scope

The collector batches **all remote commands into a single SSH round-trip**: one small POSIX shell script runs remotely and prints section-delimited output, which is parsed locally. Each section carries its own exit status, so one failing command only loses its own section instead of discarding the snapshot.

Commands executed remotely (all read-only):

- `hostname`, `whoami`, `pwd`, `date` — remote identity and timestamp
- `squeue -u "$USER" --json` — preferred job source when the cluster's Slurm supports it
- `squeue -u "$USER" -h -o '...'` — pipe-format fallback for older Slurm versions and local parse failures
- `scontrol show job -o <ids>` — per-job detail for the fallback path
- `sinfo -h -o '...'` — partition summary
- `sinfo -N -h -o '...'` — node-level state
- `scontrol show node -o` — node detail (GPU allocation, load, power, free memory)
- `df -Pk "$HOME"`, `quota -s` — home filesystem usage and quota
- `df -Pk /mnt/scratch`, `lfs quota -h -u "$USER" /mnt/scratch` — scratch usage and quota

It does not:

- install anything on the server
- write remote files
- submit jobs
- cancel jobs
- modify shell config
- require any server-side agent

Before collecting, the script probes the ControlMaster socket (`ssh -O check`) when a `--control-path` is supplied, so a dead session produces an immediate "connection lost" error instead of a hanging batch.

## Run

From this repo:

```bash
python3 scripts/aire_monitor_snapshot.py --pretty
```

Use a different SSH host alias:

```bash
python3 scripts/aire_monitor_snapshot.py --host aire --pretty
```

Use explicit AIRE settings directly through VPN:

```bash
python3 scripts/aire_monitor_snapshot.py \
  --username <your-username> \
  --aire-hostname aire.leeds.ac.uk \
  --no-jump-host \
  --control-path .runtime/ssh-control/%C \
  --pretty
```

Use explicit AIRE and jump-host settings when not on the VPN (both control paths are required so refreshes reuse the authenticated masters):

```bash
python3 scripts/aire_monitor_snapshot.py \
  --username <your-username> \
  --aire-hostname aire.leeds.ac.uk \
  --jump-hostname rash.leeds.ac.uk \
  --use-jump-host \
  --control-path .runtime/ssh-control/aire-<your-username>-jump.sock \
  --jump-control-path .runtime/ssh-control/jump-<your-username>-rash.sock \
  --pretty
```

Write a local sample snapshot:

```bash
python3 scripts/aire_monitor_snapshot.py --pretty > snapshot.json
```

## Self-Test

The parsers ship with embedded fixtures and can be exercised without any SSH connection:

```bash
python3 scripts/aire_monitor_snapshot.py --self-test
```

This covers section splitting, `squeue --json` parsing (including array jobs and unlimited time limits), pipe-format job parsing, node GRES fallbacks, quota/over-quota markers, and duration formatting. It exits 0 when all checks pass.

## Output Model

The script emits a `ClusterSnapshot` JSON object:

```text
{
  "collected_at": "...",
  "remote": { ... },
  "jobs": [ ... ],
  "partitions": [ ... ],
  "nodes": [ ... ],
  "storage": [ ... ],
  "errors": [ ... ]
}
```

Main entities:

- `remote`: remote hostname, user, current directory, and remote timestamp
- `jobs`: current jobs for the remote user — merged from `squeue --json` when available, otherwise from pipe-format `squeue` enriched with `scontrol show job -o` (submit/start/end times, work dir, command, stdout/stderr paths, TRES)
- `partitions`: grouped Slurm partition state from `sinfo`
- `nodes`: node-level state from `sinfo -N` merged with `scontrol show node -o` (GPU totals/allocated/idle, memory, load, power where exposed)
- `storage`: one entry per filesystem (home and scratch) with used/quota/limit/available GB, used percent, file counts and file limits, and an over-quota flag — sourced from `quota -s`, `lfs quota`, and `df`
- `errors`: SSH failures, missing sections, or per-section non-zero exit statuses

The command exits with status `0` when the snapshot contains no errors, and `1` otherwise — while still printing whatever partial data was collected.

## Consumers

- The macOS app (`MonitorService.collectSnapshot`) runs this script on every refresh and decodes the JSON directly.
- The desktop widget runs it only as a fallback when `.runtime/latest_snapshot.json` is missing or stale (see [MACOS_APP.md](MACOS_APP.md)).
