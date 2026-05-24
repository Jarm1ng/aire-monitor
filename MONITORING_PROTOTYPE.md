# AIRE Monitoring Prototype

This is the first local-only monitoring layer for AIRE. It collects a read-only Slurm snapshot over SSH and prints JSON that can later be consumed by a macOS menu bar app, a full macOS app, or a shared backend for iOS.

## Scope

The prototype only runs read-only commands through the existing SSH host alias:

- `hostname`, `whoami`, `pwd`, `date`
- `squeue`
- `sinfo`

It does not:

- install anything on the server
- write remote files
- submit jobs
- cancel jobs
- modify shell config
- require any server-side agent

## Run

From this repo:

```bash
python3 scripts/aire_monitor_snapshot.py --pretty
```

Use a different SSH host alias:

```bash
python3 scripts/aire_monitor_snapshot.py --host aire --pretty
```

Use explicit AIRE and jump-host settings:

```bash
python3 scripts/aire_monitor_snapshot.py \
  --username <your-username> \
  --aire-hostname aire.leeds.ac.uk \
  --jump-hostname rash.leeds.ac.uk \
  --control-path .runtime/ssh-control/%C \
  --pretty
```

Write a local sample snapshot:

```bash
python3 scripts/aire_monitor_snapshot.py --pretty > snapshot.json
```

## Output Model

The script emits a `ClusterSnapshot` JSON object:

```text
{
  "collected_at": "...",
  "remote": { ... },
  "jobs": [ ... ],
  "partitions": [ ... ],
  "nodes": [ ... ],
  "errors": [ ... ]
}
```

Main entities:

- `remote`: remote hostname, user, current directory, and remote timestamp
- `jobs`: current jobs for the remote user
- `partitions`: grouped Slurm partition state from `sinfo`
- `nodes`: node-level state from `sinfo -N`
- `errors`: command failures or timeouts

The command exits with status `0` when all collection commands succeed. It exits with status `1` if any SSH or Slurm command fails, while still printing whatever partial data was collected.

## Next Step

The next implementation step should be a small local UI or service boundary:

- either a macOS SwiftUI prototype that calls this script and renders the JSON
- or a tiny local HTTP endpoint that serves this JSON to both macOS and iOS clients

For the first app MVP, the most useful views are:

- current jobs table
- partitions summary
- GPU/node status table
- last refresh time and collection errors
