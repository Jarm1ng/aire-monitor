# Leeds HPC Monitoring Prototype

`scripts/hpc_snapshot.py` (renamed from `aire_monitor_snapshot.py`) is the local-only monitoring collector behind Leeds HPC Monitor. One invocation gathers a read-only Slurm and storage snapshot from **one** cluster over SSH and prints it as JSON. The macOS app runs one collector per cluster (AIRE and Calder), each over that cluster's own ControlMaster; the menu bar monitor and the desktop widget show the results.

The engine is cluster-agnostic. Everything that differs between clusters arrives on the command line: the cluster id and name (echoed in the output), the login host and route, and the storage layout (`--storage-spec`). Its only built-in cluster knowledge is a fallback name and login host for the ids `aire` and `calder`, used when `--cluster-name` or `--hostname` is omitted.

## Scope

A refresh is normally **one SSH round trip**: one small POSIX shell script runs remotely and prints section-delimited output (`=====HPC-SECTION:<name>=====` ... `=====HPC-STATUS:<name>:<rc>=====`, then `=====HPC-TIME:<name>:<epoch>=====` with the login node's clock), which is parsed locally. Each section carries its own exit status, so one failing command only loses its own section, and the time markers feed `timings`. Comments are stripped before sending; the first line, `# hpc-round-trip: snapshot`, identifies the script in `ps` on the login node.

Sections run in this order, core ones first, so a slow enrichment section can only cost itself. Every command is read-only:

| Section | Commands |
| --- | --- |
| `remote` | `hostname -f`, `whoami`, `$PWD`, `date -Iseconds` |
| `partitions` | `sinfo -h -o '%P\|%a\|%D\|%t\|%G\|%c\|%m\|%f\|%l'`, including the time limit |
| `nodes` | `sinfo -N -h -o '%N\|%P\|%t\|%C\|%m\|%G\|%f\|%E'` |
| `jobs_json` | `squeue -u "$USER" --json`, indentation stripped with `sed` |
| `jobs` (fallback only) | `squeue -u "$USER" -h -o '%i\|%P\|%j\|%u\|%T\|%M\|%l\|%D\|%R'` |
| `node_details` | `scontrol show node -o` (GPU allocation, load, power, free memory) |
| `job_details` (fallback only) | `scontrol show job -o <id>`, once per job id in the listing; a pending array remainder is queried by its array id, and a job that finishes in between is skipped |
| `storage` (unless `--skip-storage`) | `ps -u "$USER" -o etimes= -o args=` (the stuck-storage guard), then per volume a bounded `test -d` on the candidates, `df -Pk <dir>`, and `quota -s -w` (falling back to `quota -s`) or `lfs project -d <dir>` followed by `lfs quota -p <id>` or `lfs quota -u "$USER"` on the directory's mount (see [Storage Spec](#storage-spec)) |

**Jobs.** `squeue --json` is the job source, so a normal refresh costs a handful of slurmctld RPCs whatever the number of jobs. Records are filtered by user locally, since older Slurm releases ignore `-u` with `--json`. The pipe listing and the per-job `scontrol` loop run in the same round trip only when `squeue --json` exits non-zero or prints no `"jobs"` key. When the JSON passes that remote check but cannot be used locally (invalid JSON, a non-empty `errors` list, an unreadable record), the collector makes one short second round trip with only `jobs` and `job_details`, provided at least 2 s of the budget remain. Jobs are a core requirement: a usable JSON payload or a clean pipe listing must arrive, or the refresh fails.

If `squeue` is not on the non-interactive `PATH`, the script first sources `/etc/profile` with its output discarded. It never reads user dotfiles. It exports `SLURM_BITSTR_LEN=0` so array task lists are printed in full and can be counted.

It does not:

- install anything on the server
- write remote files (not even a lock file)
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
| `--skip-storage` | Leave the storage section out of the remote script this time (quotas change slowly). The output has `"storage": null` and `"storage_skipped": true`. |
| `--timeout N` | **Total** time budget in seconds for the whole collection. Default 30, minimum 1. |
| `--pretty` | Pretty-print the JSON. |
| `--self-test` | Run the unit tests in `scripts/tests/test_snapshot.py` and exit with their status. Never runs ssh. |

`--timeout` is not a per-command limit. It covers the socket probe (at most 10 s) plus every round trip, so the JSON is always printed before a caller watchdog slightly longer than the budget fires: the app passes `--timeout 30` and kills the process after 40 s, and the widget's fallback allows the budget plus 20 s. When the budget runs out after every core section and the jobs listing have arrived, the snapshot is still usable: the timeout is reported as a warning naming the section it cut, and only the later sections (`node_details`, `job_details`, storage) may be missing or partial.

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

If the quota command yields nothing usable, the row falls back to the filesystem-wide `df` figures (`quota_type: "df"`, `source: "df"`) and a warning is added; `quota: "none"` takes this path without a warning. If `df` produced nothing either, the row is reported as `unavailable` (`no-figures`) with a warning.

**Missing directories.** An optional volume is omitted only when the remote side proved that none of its candidates exists. A required one is still emitted, with `source: "unavailable"`, `unavailable_reason: "missing"`, null numbers, `path` set to the first candidate as expanded remotely, and a warning that lists the candidates tried. A volume whose output was cut before any verdict (the budget ran out inside the storage section) is reported as `unavailable_reason: "not-collected"` with an empty `path`, optional or not; its `optional: true` lets a consumer show it only where that label had real figures before.

**Slow filesystems.** Storage runs last. Each `test -d`, `df`, `quota` and `lfs` call is bounded with coreutils `timeout -k 2` at a third of the budget, clamped to 2–10 s (10 s for the app). That bound is best effort: a login node without a usable `timeout` runs the commands unbounded, and the total budget is the only backstop.

- The existence probe is an external, bounded `test -d`, not the shell builtin, which would block the whole script on a hung mount. When it does not answer, the remote side prints `__HPC-STALLED__` and stops there instead of trying later candidates or calling the directory missing. The volume is reported as `unavailable` (`no-figures`) with the warning "Storage '<label>': <path> did not answer in time (the filesystem may be hung); usage not read".
- Killing the local ssh does not end a remote command stuck in filesystem I/O, so every refresh during a hang would leave another stuck process. Before any volume, the script uses `ps` to check whether one of your `df -Pk`, `quota -s`, `lfs quota`, `lfs project` or `test -d` processes has outlived its limit plus the kill grace and a few seconds (15 s for the app). If one has, all storage is skipped (`storage: null`, `storage_skipped: true`, a warning) until it is gone. The guard writes nothing on the cluster. It needs procps `ps -o etimes`; without it the check finds nothing and storage runs as before.

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

## Tests

The collector's unit tests live in [scripts/tests/test_snapshot.py](scripts/tests/test_snapshot.py). They never run the real ssh client or touch `~/.ssh`:

```bash
python3 scripts/tests/test_snapshot.py            # all tests
python3 scripts/tests/test_snapshot.py -k Array   # a subset (unittest -k)
python3 scripts/hpc_snapshot.py --self-test       # the same suite, via the collector
```

`--self-test` runs that file and exits with its status (2 if the file is missing). `scripts/test_all.sh collector` runs it too. It covers:

- GRES and TRES parsing (`gpu:l40s:3`, `gpu:nvidia_h200:8`, typed, indexed and list forms, empty AllocTRES versus no GPU TRES), size and count units, `key=value` parsing, and over-quota markers
- partitions with and without the `%l` time-limit column, and node Reasons containing `|`
- job arrays (task counts, throttles, remainder ids), `squeue --json` (unlimited limits, Slurm sentinels, unusable payloads, pretty versus compacted), the pipe format (`|` inside job names, the array-detail join), both sources yielding the same jobs, which source wins, and when the second round trip is needed
- NFS quota output (wrapped and single-line layouts, export-path matching, grace columns) and lfs quota output (user and project quotas, raw and `-h` values, wrapped rows, bracketed "inaccurate" figures, grace forms)
- storage rows: the `df` fallback, cut volumes (`not-collected`, never `missing`), stalled probes and the busy marker; path-template rendering and quoting; storage-spec validation
- the section protocol (time markers, timings, cut lines, naming the cut section) and assembled snapshots: `schema_version` first, errors versus warnings, the pipe-fallback warning, unknown GPU allocation, skipped and busy storage, timeouts
- the generated remote script: section order, no per-job loop on the JSON path, comment stripping, `--skip-storage`, syntax under sh, dash, bash and zsh (where installed); and the script run against stub `squeue`/`sinfo`/`scontrol`/`df`/`quota`/`lfs`/`timeout`/`ps` in a temp tree: the JSON path under each of those shells, then the pipe fallback, storage rows, a stalled `df`, a stalled existence probe and the stuck-storage guard under `/bin/sh`
- `collect_snapshot` through a stub `ssh` executable: non-UTF-8 remote bytes, a cut final line, the total `--timeout` budget, the jobs-only second round trip (including a failed one and one out of budget), `--skip-storage`, and a dead master short-circuiting before any round trip
- CLI parsing: the deprecated `--aire-hostname` alias, the default timeout and name, refusing option-like hosts, and the jump ProxyCommand

**Contract fixtures.** `Tests/Fixtures/collector_snapshot.json` is the collector's real output for the canned Calder refresh in the test file: an array remainder next to its running tasks, an idle H200 with empty AllocTRES, an L40S node without GPU TRES, an NHC Reason containing `|`, NFS plus Lustre-project quotas, and Flash proven absent. `Tests/Fixtures/collector_contract.json` holds the collector's constants (default timeout, jump host, known cluster names and hosts, storage reasons). After an output change, regenerate both with `python3 scripts/tests/test_snapshot.py --write-fixture`; the Python suite fails while they are stale.

**Swift side.** HPCCore (`Sources/HPCCore/SnapshotModels.swift`) decodes the schema leniently: a missing, null or wrong-typed field falls back to a neutral value, a malformed element is skipped and counted in `warnings`, unknown keys are ignored, and a `schema_version` newer than it supports is a warning, not a failure. In `Tests/AIREMonitorAppTests`, `CollectorContractTests` decodes the fixtures and checks that nothing is skipped, every emitted field survives a decode/encode round trip, array remainders and GPU figures mean the same on both sides, the constants match `HPCDefaults` and the cluster catalogue, and the fixtures are current. `CollectorArgumentsTests` checks the argument list the app passes and records in `collector.json`; `SnapshotDecodingTests` and `CoreSnapshotSchemaTests` cover decoding. Run them with `Tests/AIREMonitorAppTests/run_tests.sh`.

## Output Model

The script prints one `ClusterSnapshot` JSON object on stdout, always as UTF-8:

```text
{
  "schema_version": 1,
  "collected_at": "...",
  "cluster": { "id": "calder", "name": "Calder" },
  "remote": { ... },
  "jobs": [ ... ],
  "partitions": [ ... ],
  "nodes": [ ... ],
  "storage": [ ... ] | null,
  "errors": [ ... ],
  "warnings": [ ... ],
  "storage_skipped": false,
  "started_at": "...",
  "duration_ms": ...,
  "timings": { "probe": ..., "round_trip": ..., "jobs_json": ..., ... }
}
```

Main entities:

- `schema_version`: always the first key, currently `1`. It is bumped only for an incompatible change (a key renamed, removed or retyped); new keys keep the version.
- `collected_at`: the local clock when the last round trip returned, ISO 8601 in UTC, so it marks the moment the data describes. `started_at` is taken before the socket probe.
- `cluster`: the `--cluster-id` and `--cluster-name` this snapshot belongs to. The desktop widget checks it, so a fallback collection is never shown under the wrong cluster.
- `remote`: `host` (the configured login host, or the alias), plus the login node's `hostname`, `user`, `cwd` and `remote_time`
- `jobs`: current jobs for the remote user, from `squeue --json` or from the pipe-format fallback enriched with `scontrol show job -o`; both yield the same ids and fields. Fields: `job_id`, `partition`, `name`, `user`, `state`, `elapsed`, `time_limit`, `nodes`, `reason_or_node_list`, the optional details `submit_time`, `start_time`, `end_time`, `work_dir`, `command`, `stdout_path`, `stderr_path`, `batch_host`, `node_list`, `num_cpus`, `num_tasks`, `req_tres`, `alloc_tres`, `tres_per_node`, and the array fields below
- `partitions`: one row per partition and state group as `sinfo` prints them: `partition` (default-partition `*` stripped), `availability`, `node_count`, `state`, `gres`, `cpus_per_node`, `memory_mb_per_node`, `features`, and `time_limit`, the `sinfo %l` string such as `2-00:00:00` (Calder's limit) or `infinite`, or `null` when the remote output predates the column
- `nodes`: `sinfo -N` merged with `scontrol show node -o`: `node`, `partitions`, `state`, `cpu_allocated`/`cpu_idle`/`cpu_other`/`cpu_total`, `memory_mb`, `gres`, `features`, `reason`, `gpu_total`/`gpu_allocated`/`gpu_idle`, `memory_allocated_mb`, `memory_free_mb`, `cpu_load`, `current_watts`, `average_watts` (power where exposed). `gpu_allocated: null` means unknown (no `node_details` record, or a site that does not account GPUs as TRES), never idle; a node whose CfgTRES lists GPUs and whose AllocTRES lists none reports `0`.
- `storage`: one row per reported volume, in spec order (see below), or `null` when storage was not collected this time (`--skip-storage`, the stuck-storage guard, or a round trip that ended before the section). A consumer keeps its previous rows for `null`; `[]` means collected, no volumes.
- `storage_skipped`: `true` when storage was deliberately not collected (`--skip-storage` or the guard). `storage: null` with `storage_skipped: false` means the round trip never reached the section.
- `duration_ms` and `timings`: diagnostics. `duration_ms` is the whole collection (probe plus round trips). `timings` holds milliseconds for the local `probe`, `round_trip` and, when it ran, `jobs_fallback_round_trip`, plus one entry per remote section measured on the login node's clock (`prelude`, `remote`, `partitions`, `nodes`, `jobs_json`, `jobs`, `node_details`, `job_details`, `storage`).
- `errors` and `warnings`: see [Errors and warnings](#errors-and-warnings)

**Job arrays.** Every element of an array carries `array_job_id`; ordinary jobs have all four array fields `null`. A running task is `<array>_<task>`. The pending remainder of an array is one row whose `job_id` is the bare array id, with `array_pending_tasks` (the queued ids with the `%N` throttle stripped, e.g. `0-58`; `""` when Slurm did not say), `array_throttle` (`null` without a throttle) and `pending_task_count` (`null` when the list cannot be counted). Recognise the remainder by `array_pending_tasks`, never by its id: `scancel <array id>` would cancel the running tasks too. Its `req_tres` is per task, and its `stdout_path` names Slurm's "no value" task id (`..._4294967294.out`), not a real file.

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
  "mount": "/scratch-calder",
  "unavailable_reason": null,
  "optional": false
}
```

- `path` is the **resolved** user directory (the first existing candidate), not the template.
- `source` is `quota` (NFS `quota`), `lfs quota`, `df` (filesystem-wide fallback) or `unavailable`.
- `unavailable_reason` is set only for `unavailable` rows: `missing` (no candidate directory exists), `no-figures` (the directory exists, or its filesystem did not answer the probe, but nothing was read in time) or `not-collected` (the output never reached this volume).
- `optional` echoes the spec.
- `quota_type` is `nfs`, `lustre-project`, `lustre-user` or `df`. `project_id` is the Lustre project id for `lustre-project` rows and `null` otherwise. `mount` is the mount point from `df`.
- Sizes are in GiB. A quota or limit of 0 means "no limit" and becomes `null`. `limit_gb` is the hard limit, or the soft quota when there is no hard limit. `available_gb` is `limit_gb - used_gb` (never below 0), or `df`'s available space when there is no limit. `used_percent` is `used_gb / limit_gb`, clamped to 0–100, or `df`'s percentage. `over_quota` is true when `quota`/`lfs` marks a figure with `*` or `+`.

### Errors and warnings

`errors` mean the refresh failed. They include:

- a dead or unreachable master (`connection lost: ...`), an SSH failure, or a timeout before the core sections finished
- configuration problems: an invalid `--storage-spec`, `--use-jump-host` without both control paths, or a host or user name that is not a plain ssh word
- a core section (`remote`, `partitions`, `nodes`) that is missing or exited non-zero: `Section '<name>' missing from remote output` or `Section '<name>' failed with exit <n>`
- no usable jobs listing: neither a usable `squeue --json` payload nor a clean pipe-format `jobs` section (`Section 'jobs' ...`, or `No usable jobs listing (...)`). An unusable listing is an error, never an empty but healthy queue.
- `Remote output contained no sections (the remote shell ran nothing)`: ssh succeeded but no marker came back, for example from a login shell that is not POSIX sh
- an internal collector error (`Collector internal error: ...`). The JSON is still printed, and the traceback goes to stderr.

The app treats any error as a failed refresh. When the `remote` section answered, it counts the failure as Slurm trouble over a live session, not a lost connection, and keeps the previous rows of a core section that came back empty and is named in a `Section '<name>' ...` error, so keep that wording.

`warnings` never fail a refresh. They include:

- `Jobs read with the pipe-format fallback (<why the JSON was not used>)`
- an enrichment section (`node_details`, `job_details` on the fallback path, `storage` unless skipped) that is missing or exited non-zero
- `GPU allocation unknown for <n> GPU node(s) (node_details unavailable)`, counting only nodes the failed section left without a record
- `Skipped <n> unreadable job/partition/node line(s): '<first line>'`
- storage: a quota method falling back to `df`, a required directory that does not exist, a volume with no usage figures, a probe that did not answer in time, lfs figures marked inaccurate, and `Storage not collected: a df/quota/lfs from an earlier refresh is still stuck ...`
- a round-trip timeout after every core section had completed: `Timed out after <n>s: snapshot collection (core sections were complete; cut during <section>)`

Remote output that is not valid UTF-8 is decoded leniently (invalid bytes become U+FFFD) instead of losing the snapshot. A final line cut mid-way by a timeout is dropped, so a cut record is never read as complete.

The command exits with status `0` when `errors` is empty, and `1` otherwise, while still printing whatever partial data was collected.

## Consumers

- The macOS app (`MonitorService.collectSnapshot`) runs this script with `/usr/bin/python3` for each cluster on every refresh and decodes the JSON through HPCCore. The arguments come from `MonitorService.collectorArguments`: explicit mode, the cluster id and name, the jump host, the cluster's ControlMaster socket, the shared jump socket on the rash route, the profile's storage spec, and `--timeout 30`. It adds `--skip-storage` on most refreshes: storage is collected on the first refresh after start or sign-in, on a manual Refresh, while the Storage tab is open, and once the last collected rows are 5 minutes old; after a requested storage section comes back missing, automatic refreshes wait 60 s before asking again. The app rewrites `.runtime/clusters/<id>/latest_snapshot.json` after every refresh that reaches the login node, with skipped storage (and, after a Slurm failure, the failed sections) carried over from the previous snapshot. It records the argument list, never with `--skip-storage`, in `.runtime/clusters/<id>/collector.json`.
- The desktop widget follows `.runtime/clusters/*/latest_snapshot.json`. It runs the collector itself, with exactly the arguments in that cluster's `collector.json`, only while the app does not own the cluster (no fresh `app_state.json`; a paused or switched-off record holds at any age) and the snapshot is missing or stale. See [MACOS_APP.md](MACOS_APP.md).
