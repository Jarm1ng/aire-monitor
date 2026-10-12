# Leeds HPC Monitoring Prototype

`scripts/hpc_snapshot.py` (renamed from `aire_monitor_snapshot.py`) is the local-only monitoring collector behind Leeds HPC Monitor. One invocation gathers a read-only Slurm and storage snapshot from **one** cluster over SSH and prints it as JSON. The macOS app runs one collector per cluster (AIRE and Calder), each over that cluster's own ControlMaster; the menu bar monitor and the desktop widget show the results.

The engine is cluster-agnostic. Everything that differs between clusters arrives on the command line: the cluster id and name (echoed in the output), the login host and route, and the storage layout (`--storage-spec`). Its only built-in cluster knowledge is a fallback name and login host for the ids `aire` and `calder`, used when `--cluster-name` or `--hostname` is omitted.

## Scope

The collector batches **all remote commands into a single SSH round-trip**: one small POSIX shell script runs remotely and prints section-delimited output (`=====HPC-SECTION:<name>=====` ... `=====HPC-STATUS:<name>:<rc>=====`), which is parsed locally. Each section carries its own exit status, so one failing command only loses its own section instead of discarding the snapshot.

Commands executed remotely (all read-only):

- `hostname -f`, `whoami`, `$PWD`, `date -Iseconds`: remote identity and timestamp
- `squeue -u "$USER" --json`: preferred job source when the cluster's Slurm supports it
- `squeue -u "$USER" -h -o '%i|%P|%j|%u|%T|%M|%l|%D|%R'`: pipe-format fallback for older Slurm versions and local parse failures
- `scontrol show job -o <id>`, once per job id: per-job detail for the fallback path (a job that finishes in between is skipped, not fatal)
- `sinfo -h -o '%P|%a|%D|%t|%G|%c|%m|%f|%l'`: partition summary, including the time limit
- `sinfo -N -h -o '%N|%P|%t|%C|%m|%G|%f|%E'`: node-level state
- `scontrol show node -o`: node detail (GPU allocation, load, power, free memory)
- for each storage volume: `[ -d ]` on the candidate directories, `df -Pk <dir>`, then `quota -s -w` (falling back to `quota -s`), or `lfs project -d <dir>` followed by `lfs quota -p <id>` or `lfs quota -u "$USER"` on the directory's mount (see [Storage Spec](#storage-spec))

If `squeue` is not on the non-interactive `PATH`, the script first sources `/etc/profile` with its output discarded. It never reads user dotfiles.

It does not:

- install anything on the server
- write remote files
- submit jobs
- cancel jobs
- modify shell config
- require any server-side agent
- prompt for, receive or forward a password

Every ssh invocation runs with `BatchMode=yes`, every authentication method disabled (password, keyboard-interactive, public key, GSSAPI) and `ControlMaster=no`. The collector can therefore only ride an already-authenticated ControlMaster, and it never creates or replaces one. When a `--control-path` is supplied, it first probes the master with `ssh -O check`, so a dead session produces an immediate "connection lost" error instead of a hanging round trip. Host, user and jump-host names that are not plain ssh words (for example anything starting with `-`) are refused before ssh runs.

## Command Line

| Option | Meaning |
| --- | --- |
| `--cluster-id ID` | Cluster identifier echoed in `cluster.id`. Default `aire`. Also the default `--host` alias. |
| `--cluster-name NAME` | Name echoed in `cluster.name`. Default: `AIRE` / `Calder` for the known ids, otherwise the id in upper case. |
| `--username USER` | Explicit mode (what the app uses): connect as `USER` to `--hostname`. |
| `--hostname HOST` | Login host in explicit mode, e.g. `aire.leeds.ac.uk` or `calder.leeds.ac.uk`. Defaults to the known host for `aire` / `calder`. The single-cluster spelling `--aire-hostname` is still accepted as a hidden, deprecated alias. |
| `--host ALIAS` | Alias mode, for manual testing only. Without `--username` the script runs plain `ssh ALIAS` and relies on your `~/.ssh/config`. Defaults to the cluster id. |
| `--use-jump-host` / `--no-jump-host` | Explicit-mode route: tunnel through the jump host, or connect directly. Direct is the default when neither is given. |
| `--jump-hostname HOST` | Jump host. Default `rash.leeds.ac.uk`. |
| `--control-path PATH` | Socket of the cluster's authenticated ControlMaster. Required with `--use-jump-host`. |
| `--jump-control-path PATH` | Socket of the authenticated jump ControlMaster. Required with `--use-jump-host`; the ProxyCommand rides it with `-W %h:%p`. |
| `--storage-spec JSON` | Storage volumes to report, see below. Default `[{"label": "Home", "paths": ["$HOME"], "quota": "nfs"}]`. |
| `--timeout N` | **Total** time budget in seconds for the whole collection. Default 30, minimum 1. |
| `--pretty` | Pretty-print the JSON. |
| `--self-test` | Run the embedded self-tests and exit. Never runs ssh. |

`--timeout` is not a per-command limit. It covers the socket probe (at most 10 s) plus the single SSH round trip, so the JSON is always printed before a caller watchdog slightly longer than the budget fires: the app passes `--timeout 30` and kills the process after 40 s. Storage runs last in the remote script, and each `df`/`quota`/`lfs` call there is bounded with coreutils `timeout` at a third of the budget, clamped to 2–10 s. That bound is best effort; a login node without a usable `timeout` runs the commands unbounded. When the round trip runs out of budget after every core section has arrived, the snapshot is still usable: the timeout is reported as a warning, and only the later sections (typically storage) may be missing or partial.

## Storage Spec

`--storage-spec` is a JSON list with one object per volume:

```json
{"label": "Scratch", "paths": ["/scratch-calder/users/$USER", "/scratch-calder/$USER"], "quota": "lustre", "optional": false}
```

- `label`: non-empty and unique. The app identifies storage rows by label, and a label containing "home", "scratch" or "flash" also picks the row's icon and trend series.
- `paths`: one or more candidate directory templates. The first one that exists as a directory on the login node wins.
- `quota`: `nfs`, `lustre` or `none`. Default `none`.
- `optional`: default `false`.

**Path templates.** `$USER`, `${USER}`, `$HOME` and `${HOME}` are the only tokens expanded, and they are expanded **remotely**, on the login node, inside double quotes. Every other character is single-quoted literally, including other `$VAR`s, backticks, `$(...)`, globs, spaces and quotes, so a spec cannot inject shell syntax into the remote script. Paths must not contain a newline or NUL. Wrap the whole argument in single quotes so your local shell does not expand `$USER` either.

**Quota methods.**

- `nfs`: `quota -s -w`, or `quota -s` on builds without `-w`. The quota row is matched to the directory's filesystem source as reported by `df` (for the shared `/users` home, the `<server>:/export/users` export), then to the same export path on a differently spelled server, then to the mount point. Result: `quota_type: "nfs"`, `source: "quota"`.
- `lustre`: the mount point comes from `df -P`. If `lfs project -d <dir>` reports a non-zero project id, the collector runs `lfs quota -p <id> <mount>` and reports `quota_type: "lustre-project"` with `project_id` set; this is how Calder scratch and flash are accounted. Otherwise it runs `lfs quota -u $USER <mount>` and reports `quota_type: "lustre-user"`, as on AIRE scratch. Raw (non `-h`) output is requested, so sizes are exact KiB. Figures that lfs prints in brackets (some Lustre servers did not answer) are used as printed and flagged with a warning. Result: `source: "lfs quota"`.
- `none`: `df` only.

If the quota command yields nothing usable, the row falls back to the filesystem-wide `df` figures (`quota_type: "df"`, `source: "df"`) and a warning is added; `quota: "none"` takes this path without a warning. If `df` produced nothing either, the row is reported as `unavailable` with a warning.

**Missing directories.** An `optional` volume with no existing candidate is omitted. A required one is still emitted, with `source: "unavailable"`, null numbers, `path` set to the first candidate as expanded remotely, and a warning that lists the candidates tried.

**Validation.** At most 16 volumes and 16384 characters. An invalid spec becomes a single entry in `errors`, and no SSH connection is made.

These are the specs the app passes, taken from `ClusterProfile.swift` (the app encodes them with sorted keys and an explicit `optional`):

```bash
AIRE_SPEC='[
  {"label": "Home",    "optional": false, "paths": ["$HOME"], "quota": "nfs"},
  {"label": "Scratch", "optional": false, "paths": ["/scratch-aire/users/$USER", "/mnt/scratch/$USER", "/mnt/scratch/users/$USER"], "quota": "lustre"},
  {"label": "Flash",   "optional": true,  "paths": ["/flash-aire/users/$USER", "/mnt/flash/$USER", "/mnt/flash/users/$USER"], "quota": "lustre"}
]'

CALDER_SPEC='[
  {"label": "Home",    "optional": false, "paths": ["$HOME"], "quota": "nfs"},
  {"label": "Scratch", "optional": false, "paths": ["/scratch-calder/users/$USER", "/scratch-calder/$USER"], "quota": "lustre"},
  {"label": "Flash",   "optional": true,  "paths": ["/flash-calder/users/$USER", "/flash-calder/$USER"], "quota": "lustre"}
]'
```

AIRE's `/scratch-aire` and `/flash-aire` candidates come first so the profile follows the expected Aire 2.0 move without an app update; until then the `/mnt/scratch` directory matches and Flash is usually omitted. Home is the same NFS export on both clusters, so both snapshots report the same home quota.

## Run

From this repo. Replace `<username>` with your university username and `<hash>` with the socket hash described below.

The simplest manual run replays the exact invocation the app uses for a cluster. The app writes it, password-free, to `.runtime/clusters/<id>/collector.json` after signing in:

```bash
python3 -c 'import json, subprocess, sys
args = json.load(open(".runtime/clusters/calder/collector.json"))["arguments"]
sys.exit(subprocess.call([sys.executable, "scripts/hpc_snapshot.py", *args, "--pretty"]))'
```

Explicit mode, directly over the VPN, reusing the app's Calder master:

```bash
python3 scripts/hpc_snapshot.py \
  --cluster-id calder --cluster-name Calder \
  --username <username> \
  --hostname calder.leeds.ac.uk \
  --no-jump-host \
  --control-path ~/.ssh/ctl/calder-<hash>.sock \
  --storage-spec "$CALDER_SPEC" \
  --pretty
```

Explicit mode through the rash jump host when not on the VPN. Both control paths are required, so the refresh reuses the authenticated AIRE master and the shared jump master:

```bash
python3 scripts/hpc_snapshot.py \
  --cluster-id aire --cluster-name AIRE \
  --username <username> \
  --hostname aire.leeds.ac.uk \
  --use-jump-host --jump-hostname rash.leeds.ac.uk \
  --control-path ~/.ssh/ctl/aire-<hash>.sock \
  --jump-control-path ~/.ssh/ctl/jump-<hash>.sock \
  --storage-spec "$AIRE_SPEC" \
  --pretty
```

Socket names: for a cluster master, `<hash>` is the first 12 hex characters of the SHA-256 of `<username>@<host>:direct`, or of `<username>@<host>:via-rash.leeds.ac.uk` on the rash route. For the jump master it is the hash of `<username>@rash.leeds.ac.uk`. For example:

```bash
printf '%s' '<username>@calder.leeds.ac.uk:direct' | shasum -a 256 | cut -c1-12
```

Alias mode works with your own `~/.ssh/config` (for example the blocks in [config/aire_ssh_config.example](config/aire_ssh_config.example)). Open a master first with `ssh calder` (or `ssh calder-jump`) and keep it alive, then run:

```bash
python3 scripts/hpc_snapshot.py --cluster-id calder --host calder --storage-spec "$CALDER_SPEC" --pretty
```

The collector forces `ControlMaster=no` and disables every authentication method, so alias mode only works while a master for that alias is open; otherwise ssh fails at once with an authentication error. Without `--control-path` no socket probe is made.

To write a local sample snapshot, redirect any of the commands above, e.g. `... --pretty > snapshot.json`. `snapshot.json` is gitignored. It contains your username, paths and quota figures, so do not commit or paste it (see [SECURITY.md](SECURITY.md)).

## Self-Test

The parsers and the generated remote shell can be exercised without any SSH connection:

```bash
python3 scripts/hpc_snapshot.py --self-test
```

It prints `All <n> self-tests passed` and exits 0, or prints each failing check to stderr and exits 1. It never runs the real ssh client. It covers:

- GRES parsing (`gpu:l40s:3`, `gpu:nvidia_h200:8`, typed, indexed and list forms), size and count units, and over-quota markers
- `squeue --json` (array jobs, unlimited time limits, unusable payloads), the pipe format (`|` inside job names), the array-job detail join and `key=value` parsing
- partitions with and without the `%l` time-limit column
- NFS quota output (wrapped and single-line layouts, export-path matching, grace columns) and lfs quota output (user and project quotas, raw and `-h` values, wrapped rows, bracketed "inaccurate" figures, grace forms)
- path-template rendering and quoting, storage-spec validation, and the generated script (candidates, markers, time-limit column, per-command storage timeout)
- synthetic AIRE and Calder round trips, including the `df` fallback, Lustre user and project quotas, an omitted optional Flash volume, errors versus warnings, and timeout handling
- CLI parsing: the deprecated `--aire-hostname` alias, the default timeout and name, refusing option-like hosts, and the jump ProxyCommand
- the generated remote script, run under the local `/bin/sh` against a stub directory tree with stub `df`/`quota`/`lfs`/`timeout`, including a stalled `df`
- `collect_snapshot` driven through a stub `ssh` executable: non-UTF-8 remote bytes, the total `--timeout` budget, and a dead master short-circuiting before any round trip

The Swift half of the contract is covered by `Tests/AIREMonitorAppTests`: `CollectorArgumentsTests` checks the argument list the app passes (and records in `collector.json`), and `SnapshotDecodingTests` checks that the app decodes the collector's output. Run them with `Tests/AIREMonitorAppTests/run_tests.sh`.

## Output Model

The script prints one `ClusterSnapshot` JSON object on stdout, always as UTF-8:

```text
{
  "collected_at": "...",
  "cluster": { "id": "calder", "name": "Calder" },
  "remote": { ... },
  "jobs": [ ... ],
  "partitions": [ ... ],
  "nodes": [ ... ],
  "storage": [ ... ],
  "errors": [ ... ],
  "warnings": [ ... ]
}
```

Main entities:

- `collected_at`: the local clock at collection time, ISO 8601 in UTC
- `cluster`: the `--cluster-id` and `--cluster-name` this snapshot belongs to. The desktop widget checks it, so a fallback collection is never shown under the wrong cluster.
- `remote`: `host` (the configured login host, or the alias), plus the login node's `hostname`, `user`, `cwd` and `remote_time`
- `jobs`: current jobs for the remote user, taken from `squeue --json` when available, otherwise from pipe-format `squeue` enriched with `scontrol show job -o`. Fields: `job_id`, `partition`, `name`, `user`, `state`, `elapsed`, `time_limit`, `nodes`, `reason_or_node_list`, and the optional details `submit_time`, `start_time`, `end_time`, `work_dir`, `command`, `stdout_path`, `stderr_path`, `batch_host`, `node_list`, `num_cpus`, `num_tasks`, `req_tres`, `alloc_tres`, `tres_per_node`
- `partitions`: one row per partition and state group as `sinfo` prints them: `partition` (default-partition `*` stripped), `availability`, `node_count`, `state`, `gres`, `cpus_per_node`, `memory_mb_per_node`, `features`, and `time_limit`, the `sinfo %l` string such as `2-00:00:00` (Calder's limit) or `infinite`, or `null` when the remote output predates the column
- `nodes`: `sinfo -N` merged with `scontrol show node -o`: `node`, `partitions`, `state`, `cpu_allocated`/`cpu_idle`/`cpu_other`/`cpu_total`, `memory_mb`, `gres`, `features`, `reason`, `gpu_total`/`gpu_allocated`/`gpu_idle`, `memory_allocated_mb`, `memory_free_mb`, `cpu_load`, `current_watts`, `average_watts` (power where exposed)
- `storage`: one row per reported volume, in spec order (see below)
- `errors` and `warnings`: see [Errors and warnings](#errors-and-warnings)

A storage row looks like this (values elided):

```text
{
  "label": "Scratch",
  "path": "/scratch-calder/users/<username>",
  "filesystem": "<df filesystem source>",
  "source": "lfs quota",
  "used_gb": ..., "quota_gb": ..., "limit_gb": ..., "available_gb": ..., "used_percent": ...,
  "file_count": ..., "file_quota": ..., "file_limit": ...,
  "over_quota": false,
  "quota_type": "lustre-project",
  "project_id": <project-id>,
  "mount": "/scratch-calder"
}
```

- `path` is the **resolved** user directory (the first existing candidate), not the template.
- `source` is `quota` (NFS `quota`), `lfs quota`, `df` (filesystem-wide fallback) or `unavailable` (required volume with no directory, or no figures at all).
- `quota_type` is `nfs`, `lustre-project`, `lustre-user` or `df`. `project_id` is the Lustre project id for `lustre-project` rows and `null` otherwise. `mount` is the mount point from `df`.
- Sizes are in GiB. A quota or limit of 0 means "no limit" and becomes `null`. `limit_gb` is the hard limit, or the soft quota when there is no hard limit. `available_gb` is `limit_gb - used_gb` (never below 0), or `df`'s available space when there is no limit. `used_percent` is `used_gb / limit_gb`, clamped to 0–100, or `df`'s percentage. `over_quota` is true when `quota`/`lfs` marks a figure with `*` or `+`.

### Errors and warnings

`errors` mean the refresh failed; the app treats any error as a failed refresh and keeps showing the previous snapshot. They include:

- a dead or unreachable master, an SSH failure, or a timeout before the core sections finished
- configuration problems: an invalid `--storage-spec`, or `--use-jump-host` without both control paths
- a core section (`remote`, `jobs`, `partitions`, `nodes`) that is missing or exited non-zero
- an internal collector error. The JSON is still printed, and the traceback goes to stderr.

`warnings` never fail a refresh. They include:

- an enrichment section (`job_details`, `node_details`, `storage`) that is missing or exited non-zero
- a quota method falling back to `df`
- a required storage directory that does not exist
- lfs figures marked inaccurate
- a round-trip timeout after every core section had completed

A failing `squeue --json` (for example on a Slurm without JSON support) is neither: the pipe-format sections are used silently. Remote output that is not valid UTF-8 is decoded leniently (invalid bytes become U+FFFD) instead of losing the snapshot.

The command exits with status `0` when `errors` is empty, and `1` otherwise, while still printing whatever partial data was collected.

## Consumers

- The macOS app (`MonitorService.collectSnapshot`) runs this script with `/usr/bin/python3` for each cluster on every refresh and decodes the JSON directly. The arguments come from `MonitorService.collectorArguments`: explicit mode, the cluster id and name, the cluster's ControlMaster socket, the shared jump socket on the rash route, the profile's storage spec, and `--timeout 30`. After a refresh without errors, the app writes `.runtime/clusters/<id>/latest_snapshot.json` (plus the trend history and job-state files) and records the same argument list in `.runtime/clusters/<id>/collector.json`.
- The desktop widget follows `.runtime/clusters/*/latest_snapshot.json`. Only when a cluster's file is missing or stale, and that cluster has a `collector.json`, does the widget run the collector itself, with exactly those arguments and separately for each cluster (see [MACOS_APP.md](MACOS_APP.md)).
