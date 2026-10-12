# Calder Server User Guide

This document summarizes what the Calder cluster is, how it differs from AIRE, how to connect, where to keep data, how to use Slurm on its partitions, and how to move existing AIRE work across. It is the Calder companion to `AIRE_SERVER_GUIDE_EN.md` and is intended as a handover guide for future users.

Calder opened to researchers on Monday 2026-10-12. Everything marked as observed below comes from read-only checks made from a login node on that day (Europe/London); no compute nodes were requested and no jobs were submitted. The official documentation links were checked on the same day. Service configuration, software, limits and documentation were still being updated at launch, so re-check the current state with the read-only commands in this guide before relying on any number.

In this document, `<username>`, `<PROJECT_DIR>`, `<JOBID>`, `<project-id>` and `<project_name>` are placeholders. Replace them with your university username, the actual project path, a Slurm job id, your directory's Lustre project id, or a project name.

## 1. Overview

Calder is a new shared Slurm-managed HPC cluster at the University of Leeds. It runs alongside AIRE rather than replacing it: it has its own login nodes, its own Slurm controller (observed Slurm 24.11.5; AIRE runs 24.05.3), its own scratch and flash filesystems, and its own software tree. Jobs submitted on AIRE do not appear in Calder's `squeue`, and vice versa. Only the university account and the home directory are shared with AIRE.

According to the launch announcement, Calder was procured through an academically led process won by MTI, uses Dell hardware, and is supported by Cambridge Research Computing. Questions and problems still go to Leeds Research Computing, not to the vendors.

As on AIRE, login nodes are for preparation only. Training, evaluation, parallel CPU work and GPU jobs must be submitted through Slurm, normally with `sbatch`. A submitted batch job keeps running after you disconnect.

When to choose which cluster:

- Calder suits workloads that need large GPU memory (141 GB per H200), many GPUs per node, or multi-node CPU simulation over InfiniBand.
- AIRE may remain the better fit for serial or lightly threaded work (Calder's CPU partition allocates at least 8 cores), for jobs that need a dedicated high-memory node (Calder has none), and for projects with a mature, working AIRE environment.
- Decide with a representative job: compare correctness, runtime and resource use, not headline specifications.

Official sources: [launch announcement](https://arc.leeds.ac.uk/knowledge-centre/calder-opens-to-researchers-at-the-university-of-leeds/), [documentation home](https://arcdocs.leeds.ac.uk/calder/welcome.html), [system overview](https://arcdocs.leeds.ac.uk/calder/system/start.html), [architecture](https://arcdocs.leeds.ac.uk/calder/system/hpc_architecture.html).

## 2. Hardware Compared with AIRE

Published specifications (official GB/TB units; Linux and Slurm on the cluster report binary units, so do not compare prefixes alone):

| Item | AIRE | Calder |
| --- | --- | --- |
| Total CPU-node cores | 9,072 | 12,288 (96 standard nodes, official) |
| Standard CPU nodes | 52 × 168 cores | 96 × 128 cores official; Slurm lists 98 (observed) |
| Standard node CPUs | 2 × AMD EPYC 9634 | 2 × AMD EPYC 9555 (Turin) |
| Standard node memory | 768 GB | 768 GB |
| Dedicated high-memory nodes | 2, about 2.3 TB each | none |
| GPU nodes | 28 × 3 GPUs | 7 × 8 GPUs |
| GPUs | 84 × NVIDIA L40S | 56 × NVIDIA H200 NVL |
| Memory per GPU | 48 GB GDDR6 | 141 GB HBM3e (4.8 TB/s per the FAQ) |
| GPU node CPUs | EPYC 9254, 24 cores | 2 × EPYC 9555, 128 cores |
| GPU node memory | 256 GB | 1.5 TB |
| GPU node local disk | 2 × 480 GB M.2 | 6.4 TB E3.S Gen5 SED |
| Interconnect | Omni-Path | NDR InfiniBand, 400 Gb/s |
| GPU links within a node | PCIe | NVLink 4-way bridges |
| Lustre scratch (nominal) | 3.7 PB | about 6.3 PB |
| Lustre NVMe flash (nominal) | 139 TB | about 246 TB |

Notes:

- The CPU totals exclude CPUs in GPU nodes.
- An H200 has about 2.94 times the memory of an L40S. That is not a speed ratio: real speed depends on the model, precision, kernels, data loading, storage and communication.
- 141 GB is per-GPU memory; 1.5 TB is the GPU node's system memory. GPU memory across cards is not one pool that any program can use.
- "NVLink 4-way bridges" does not mean all eight GPUs in a node are fully interconnected. Multi-GPU topology and performance were not measured.

Sources: [node types](https://arcdocs.leeds.ac.uk/calder/system/node_types.html), [comparison FAQ](https://arcdocs.leeds.ac.uk/calder/getting_started/faq.html).

## 3. Accounts

- An existing AIRE HPC account already covers Calder; there is no separate Calder account to request. The username, password and Duo setup are the same as on AIRE.
- Your home directory is the same on both clusters (see section 6). Scratch data is not shared or migrated automatically.
- Academic staff, postdocs and postgraduate researchers can request an account; undergraduate and taught-masters students need supervisor support. Use the [HPC account form](https://it.leeds.ac.uk/it?id=sc_cat_item&sys_id=4c002dd70f235f00a82247ece1050ebc).
- Accounts are personal and tied to your university identity. Never share an account or password.
- Access for external collaborators and after leaving the university was not documented at launch; ask Research Computing.

Sources: [requesting an account](https://arcdocs.leeds.ac.uk/calder/getting_started/request_account.html), [FAQ](https://arcdocs.leeds.ac.uk/calder/getting_started/faq.html).

## 4. Connecting

### 4.1 Hosts and Routes

```text
Login host:   calder.leeds.ac.uk   (DNS round-robin over several login nodes)
Login nodes:  calder-login-*
Jump host:    rash.leeds.ac.uk     (the same SSH gateway used for AIRE)
Account:      your university username and password, plus Duo MFA
```

There are two routes:

- **Direct:** connect straight to `calder.leeds.ac.uk`. One Duo approval.
- **Via rash:** tunnel through `rash.leeds.ac.uk`. A fresh connection needs two Duo approvals, one for rash and one for Calder; an already-open rash session reduces this.

Which route applies depends on your network, and the official pages disagree:

- The IT article [How to Connect to HPC](https://it.leeds.ac.uk/it?id=kb_article_view&sysparm_article=KB0019686) (university login required) says to connect directly from the wired campus network, and to use rash, with the VPN switched off, from off campus and from eduroam.
- The public [Logging on](https://arcdocs.leeds.ac.uk/calder/getting_started/logging_on.html) page says off-campus users can use either the VPN or the SSH gateway, and counts eduroam and the St James's NHS network as off campus.
- Observed on 2026-10-12: a direct login from a Mac connected to the University VPN succeeded. That shows the route worked from that machine on that day, not that every VPN setup will work.

Prefer the current IT article. If a different route already works for you, keep it.

Authentication is password plus keyboard-interactive (Duo). The official documentation states that user SSH public keys are not supported on Calder, so do not set up `authorized_keys`-based login.

### 4.2 SSH Configuration

`config/aire_ssh_config.example` contains Host blocks for both clusters (`aire`, `aire-jump`, `calder`, `calder-jump`) and for the `rash` jump host. Copy the ones you need into `~/.ssh/config`, and never commit a copy that contains your real username. Create the control-socket directory first if it does not exist:

```bash
mkdir -m 700 ~/.ssh/ctl
```

Direct route (wired campus network, or a VPN route that works for you):

```sshconfig
Host calder
    HostName calder.leeds.ac.uk
    User <username>
    PubkeyAuthentication no
    PreferredAuthentications password,keyboard-interactive
    KbdInteractiveAuthentication yes
    PasswordAuthentication yes
    NumberOfPasswordPrompts 1
    ControlMaster auto
    ControlPersist 24h
    ControlPath ~/.ssh/ctl/calder-%C
    ServerAliveInterval 30
    ServerAliveCountMax 10
    ConnectTimeout 20
```

The jump route (off campus, eduroam) needs a `Host rash` block. Reuse the one from the AIRE setup if you already have it; otherwise add:

```sshconfig
Host rash
    HostName rash.leeds.ac.uk
    User <username>
    PubkeyAuthentication no
    PreferredAuthentications password,keyboard-interactive
    KbdInteractiveAuthentication yes
    PasswordAuthentication yes
    NumberOfPasswordPrompts 1
    ControlMaster auto
    ControlPersist 24h
    ControlPath ~/.ssh/ctl/rash-%C
    ServerAliveInterval 30
    ServerAliveCountMax 10
    ConnectTimeout 20
```

```sshconfig
Host calder-jump
    HostName calder.leeds.ac.uk
    User <username>
    ProxyJump rash
    PubkeyAuthentication no
    PreferredAuthentications password,keyboard-interactive
    KbdInteractiveAuthentication yes
    PasswordAuthentication yes
    NumberOfPasswordPrompts 1
    ControlMaster auto
    ControlPersist 24h
    ControlPath ~/.ssh/ctl/calder-jump-%C
    ServerAliveInterval 30
    ServerAliveCountMax 10
    ConnectTimeout 20
```

Notes:

- Always use the name `calder.leeds.ac.uk`; do not pin a login-node IP address in your configuration.
- `NumberOfPasswordPrompts 1` is deliberate: a mistyped password fails at once instead of being resent, which could otherwise push the account towards a lockout.
- `ControlMaster auto` with `ControlPersist 24h` lets later `ssh`, `scp` and `rsync` commands reuse an authenticated connection without another Duo approval.
- `ProxyJump rash` makes the jump leg use the `Host rash` block (including `NumberOfPasswordPrompts 1` and its control socket), so an open rash connection is reused. If `aire-jump` also uses `ProxyJump rash`, both clusters share one rash login. The example file writes `ProxyJump %r@rash.leeds.ac.uk` instead: that also works, but the name `rash.leeds.ac.uk` does not match `Host rash`, so those settings do not apply and each new master opens its own rash hop.
- The distinct `ControlPath` prefixes plus `%C` (a hash of local host, remote host, port and user) keep the `calder`, `calder-jump`, `rash`, `aire` and `aire-jump` sockets separate.
- OpenSSH uses the first value it finds for most options, so specific `Host` blocks must come before any `Host *` block that would otherwise override them. Check with `ssh -G calder` and `ssh -G calder-jump`.

### 4.3 First Login

```bash
ssh calder
ssh calder 'hostname; whoami; pwd; date'
```

Off campus, test the jump host first, then Calder through it:

```bash
ssh rash 'hostname'
ssh calder-jump 'hostname'
```

Approve the Duo prompt on your phone. On the first connection SSH asks you to confirm Calder's host key. This repository does not ship fingerprints (a recorded value can go stale when servers are replaced): verify the key against an official University of Leeds source, or with a first connection made from a trusted network. Calder is a different host from AIRE, so it gets its own `known_hosts` entry; there is no reason to remove AIRE's entries. Show the fingerprint you have recorded with:

```bash
ssh-keygen -l -F calder.leeds.ac.uk
```

If SSH later reports a mismatch or `REMOTE HOST IDENTIFICATION HAS CHANGED`, check the university's announcements or ask Research Computing before accepting it. Never disable host-key checking or wipe `known_hosts` to get past the warning; once a change is confirmed, remove only that host's entry (`ssh-keygen -R calder.leeds.ac.uk`).

Confirm you reached Calder:

```bash
hostname     # expect calder-login-*
id -un       # expect <username>
pwd          # expect /users/<username>
```

A TCP connection or an SSH banner is not a successful login; only a shell prompt on `calder-login-*` is.

Once a ControlMaster connection is open, further `ssh`, `scp` and `rsync` commands to the same alias reuse it without another Duo prompt. Commands run with `-o BatchMode=yes` cannot answer password or Duo prompts, so a `Permission denied` from them only means no reusable session exists, not that the password is wrong.

### 4.4 "Not allowed at this time" and Connections Closed Before Authentication

Observed on 2026-10-12: `calder.leeds.ac.uk` resolved to four IPv4 login addresses. One of them first closed the connection before authentication, later printed `Not allowed at this time`, and recovered later the same day; another address accepted the login normally. Recent OpenSSH servers (9.8 and later) send `Not allowed at this time` when they drop a new connection under their connection limits (`MaxStartups`, per-source penalties).

Messages such as these mean the server refused the connection before checking your password:

```text
Not allowed at this time
kex_exchange_identification: Connection closed by remote host
kex_exchange_identification: read: Connection reset by peer
Connection closed by <address> port 22
```

They do not mean the password is wrong, and on their own they do not prove that Calder is closed. What to do:

1. Wait a minute and connect again. Avoid tight retry loops, because the server's rate limiting can keep refusing a source that keeps reconnecting.
2. If it persists, run one bounded verbose attempt and note which stage fails (DNS, TCP, banner, authentication or shell):

   ```bash
   ssh -v -o ConnectTimeout=8 -o ConnectionAttempts=1 calder
   ```

3. To tell whether one particular login node is the problem, list the addresses DNS currently returns (`getent ahostsv4 calder.leeds.ac.uk` on Linux, `dscacheutil -q host -a name calder.leeds.ac.uk` on macOS) and try one of them while still verifying Calder's host key:

   ```bash
   ssh -o HostName=<login-node-ip> \
       -o HostKeyAlias=calder.leeds.ac.uk \
       -o StrictHostKeyChecking=yes \
       -o ConnectTimeout=8 -o ConnectionAttempts=1 \
       calder
   ```

   This stops if the key does not match, or if you have never accepted Calder's key under its name. Use it for diagnosis only; keep the hostname in your configuration.

4. If the problem continues, report the time, route, network and raw error to Research Computing (see section 17).

## 5. Login Node Rules

Login nodes are for lightweight work:

- Editing scripts
- Inspecting logs
- Submitting Slurm jobs
- Checking queue status
- Small file operations and transfers
- Very short test commands

Do not use login nodes for:

- Training jobs
- Long Python evaluation scripts
- Large data preprocessing
- Multi-process CPU workloads
- GPU workloads
- Large parallel builds (cap compile parallelism, for example with `MAX_JOBS`, when building extensions)

Administrators may kill processes that disrupt the system or other users, and serious misuse can lead to suspended access.

Observed login node on 2026-10-12 (a shared machine, not resources allocated to you):

```text
OS:       Rocky Linux 9.8 (Blue Onyx), x86_64
CPU:      2 × AMD EPYC 9335 (32 cores each, 64 cores visible)
Memory:   about 754 GiB visible
Shell:    /bin/bash (Bash 5.1.8)
Python:   /usr/bin/python3, Python 3.9.25
```

## 6. Filesystems, Quotas and Data Lifecycle

### 6.1 Paths

Observed on 2026-10-12 for a regular account:

```text
/users/<username>                   Home, the SAME directory as on AIRE
/scratch-calder/users/<username>    Lustre scratch
/flash-calder/users/<username>      Lustre NVMe flash (personal directory)
```

Note the `users/` level. Some official pages show `/scratch-calder/<username>` or still show AIRE paths; check what actually exists for you:

```bash
ls -ld "$HOME" /scratch-calder/users/"$USER" /flash-calder/users/"$USER"
```

`$SCRATCH` was unset on the login nodes, including after loading `calder/cpu` or `calder/hopper`. The official [storage options](https://arcdocs.leeds.ac.uk/calder/usage/file_management/storage_options.html) page says `$SCRATCH` and `$TMP_SHARED` are set inside jobs. Do not build paths from `$SCRATCH` on a login node; write the real path.

Because Home is shared, anything you change there (dotfiles, conda environments, caches, permissions) affects AIRE and Calder at the same time.

A useful project structure, as on AIRE:

```text
/scratch-calder/users/<username>/<project_name>     # = <PROJECT_DIR>
├── configs
├── data
├── jobs
├── logs
├── checkpoints
├── runs
├── src
└── tools
```

### 6.2 What Each Area Is For

| Area | Use for | Backup and cleanup |
| --- | --- | --- |
| Home (`/users/<username>`) | Scripts, configuration, environment files, conda environments, small files | Backed up per the official docs (frequency and retention not documented at launch) |
| Scratch (`/scratch-calder/users/<username>`) | Active datasets, training outputs, checkpoints, analysis results | Not backed up; not wiped at job end, but subject to quota and cleanup policy |
| Job shared flash (`$TMP_SHARED`) | I/O-heavy temporary data shared by a job's nodes | Cleared at the end of the job (per docs) |
| Node-local temporary space | Single-node temporary data and caches | Not shared between nodes; cleared at the end of the job (per docs) |
| Personal flash (`/flash-calder/users/<username>`) | Fast working data | Exists and is writable; retention policy not confirmed — do not treat it as an archive |

The job-temporary lifecycle above is documented behaviour that had not been verified in a Calder job at launch. Print the variables inside a job before relying on them, and never invent a path if one is undefined. Save checkpoints as the job runs; a single copy step at the end of a job may never run if the job times out or crashes. Archive final results to appropriate research storage. Sources: [storage overview](https://arcdocs.leeds.ac.uk/calder/system/storage_filesystem.html), [jobs](https://arcdocs.leeds.ac.uk/calder/usage/jobs.html).

### 6.3 Quotas

Home is one NFS export with a 65 GiB quota, shared with AIRE (the same quota appears from both clusters):

```bash
quota -s
```

Calder scratch and flash use Lustre **project** quotas keyed by the project id attached to your directory, not per-user quotas. Look up the id first, then query it:

```bash
lfs project -d /scratch-calder/users/"$USER"        # first column is <project-id>
lfs quota -h -p <project-id> /scratch-calder
lfs project -d /flash-calder/users/"$USER"
lfs quota -h -p <project-id> /flash-calder
```

One line that does both lookups:

```bash
lfs quota -h -p "$(lfs project -d /scratch-calder/users/$USER | awk '{print $1}')" /scratch-calder
```

Notes:

- `lfs quota -u "$USER" /scratch-calder` can show zero limits on Calder; that does not mean there is no limit. The project quota is what applies. (AIRE's `/mnt/scratch` uses per-user quotas, so the AIRE command does not carry over.)
- The project id comes from your directory's own metadata. It is not the Slurm account name (`default`) and it differs between users, so never copy someone else's.
- Space and inodes (number of files and directories) are separate limits. Datasets of many small images, and conda environments, can exhaust inodes long before space.
- Official default per project: 1 TB on scratch and on flash, and 1.5 million inodes. Observed on 2026-10-12 for one account: a 1T soft / 1.1T hard space limit and a 1,000,000 inode hard limit on each. Plan against your own `lfs quota` output.
- Free space on the whole filesystem is not your remaining quota.
- Quota increases are temporary (up to six months, renewable). Explain the research purpose, filesystem, size and file count needed, end date, and archive/cleanup plan. Move or delete data above the default before the increase expires; do not count on a grace period. See the [quota policy](https://arcdocs.leeds.ac.uk/calder/usage/file_management/filesystem_quotas.html).

Check usage of a project directory:

```bash
du -sh <PROJECT_DIR>
find <PROJECT_DIR> | wc -l      # rough inode count
```

### 6.4 Sharing Data

Share through the appropriate group or ACLs (`ls -l`, `getfacl`), never with `chmod -R 777`. Group membership is managed by administrators. Remember that permission changes in Home apply on both clusters. See [data sharing](https://arcdocs.leeds.ac.uk/calder/usage/file_management/data_sharing.html).

## 7. Slurm Partitions

Partition information observed on 2026-10-12:

| Partition | Purpose | Nodes | CPUs per node | Memory per node | GPU | Max time |
| --- | --- | ---: | ---: | ---: | --- | --- |
| `calder-cpu-turin` | Default CPU partition | 98 | 128 | 772480M (about 754 GiB) | none | 2 days |
| `calder-gpu-hopper` | GPU jobs | 7 | 128 | 1546664M (about 1.5 TiB) | 8 H200 per node | 2 days |

Both partitions have `MaxTime=2-00:00:00` (48 hours); work that needs longer must checkpoint and resume, or be split into smaller jobs. The default partition is `calder-cpu-turin`, so GPU jobs must name `calder-gpu-hopper` and request GPUs explicitly. GPU nodes are `calder-h200-01` to `calder-h200-07`, each with `Gres=gpu:nvidia_h200:8`. Node counts are configured totals, including nodes that are drained or busy; memory figures are Slurm's registered values, not measured physical memory.

The AIRE partition names (`nodes`, `gpu`, `himem`, `teachingnodes`) do not exist on Calder.

### 7.1 Resource Rules

From the official [jobs page](https://arcdocs.leeds.ac.uk/calder/usage/jobs.html), not verified by test jobs at launch:

- The CPU partition allocates a minimum of 8 cores per job, even for a serial program.
- A user can use at most 16 GPUs at once, on at most 2 nodes.
- A GPU job that does not specify CPUs and memory gets about 16 cores and 192 GB of system memory per GPU.
- `--time` should always be set explicitly; 48 hours is the maximum.

### 7.2 Key Options

| Option | Meaning |
| --- | --- |
| `--partition=calder-cpu-turin` | CPU partition (default) |
| `--partition=calder-gpu-hopper` | H200 GPU partition |
| `--gres=gpu:nvidia_h200:N` | N H200s **per node**, not per job |
| `--nodes` | Number of nodes |
| `--ntasks` / `--ntasks-per-node` | Number of processes (MPI ranks) |
| `--cpus-per-task` | CPUs per process, for threads and data loaders |
| `--mem` | System memory per node (not GPU memory) |
| `--mem-per-cpu` | System memory per CPU; do not combine with `--mem` |
| `--time` | Wall-clock limit, at most `2-00:00:00` |
| `--output` / `--error` | Log paths; `%x` is the job name, `%j` the job id |
| `--array=1-100%10` | 100 array tasks, at most 10 running at once |

`#SBATCH` lines are read by Slurm, not by the shell: variables such as `$SCRATCH` or `$HOME` are not expanded there. Use absolute paths or Slurm patterns such as `%j`.

Requesting more CPUs or GPUs does not make a program parallel. OpenMP needs threads configured, MPI needs a proper launcher, and multi-GPU training needs the project's own distributed setup. Most MPI programs start with `srun`, but some application pages specify `mpirun`; follow the application's own documentation. See the [scheduler](https://arcdocs.leeds.ac.uk/calder/system/job_scheduler.html) page.

### 7.3 Scheduler Configuration (Observed)

Observed on 2026-10-12 with `scontrol show config`:

```text
SchedulerType=sched/backfill
PriorityType=priority/multifactor
PriorityWeightFairShare=0
PriorityWeightAge=0
PriorityWeightPartition=1000
MaxArraySize=1001          (highest array index is 1000)
SelectTypeParameters=CR_CORE
JobSubmitPlugins=lua       (may enforce extra rules; not inspected)
```

The official [job priority](https://arcdocs.leeds.ac.uk/calder/usage/job_priority.html) page describes fair-share scheduling, while the observed fair-share weight was zero. Treat the documentation as the intended policy and the configuration as a snapshot; neither is a guarantee of current behaviour.

Account-association queries (`sacctmgr`) on Calder returned the cluster name `aire`, account `default` and QoS `normal`. This does not mean you are logged in to AIRE; `hostname` and the partition names confirm where you are. Empty limit fields in the QoS output do not mean there are no limits.

## 8. Environment Modules and Python

Calder uses Lmod with a hierarchical module tree, unlike AIRE's flat Environment Modules setup. Observed on 2026-10-12:

```text
Module system:       Lmod 8.7.64
Module root:         /uol/apps/calder/modules
Top-level modules:   calder/cpu, calder/hopper
Miniforge:           miniforge3/26.1.1-3 (under both calder/cpu and calder/hopper)
                     conda 26.1.1, mamba 2.5.0, bundled Python 3.13.12
CUDA:                cuda/13.3.0 (under calder/hopper); cuDNN and NCCL also listed
Containers:          /usr/bin/apptainer, Apptainer 1.5.3 (no module needed)
PyTorch:             no module named pytorch; install it in a conda environment
System Python:       /usr/bin/python3, Python 3.9.25
```

Load a software layer first (`calder/cpu` for CPU work, `calder/hopper` for the GPU partition); compilers, MPI and applications become visible only after that. `module avail` shows only what is loadable now; `module spider <name>` searches the whole tree and shows the load order:

```bash
module load calder/hopper
module avail
module spider miniforge3
module spider cuda
```

Loading `calder/hopper` does not give you a GPU; only a job on `calder-gpu-hopper` does.

In non-interactive SSH sessions, `module` may be undefined (`module: command not found`). That does not mean Lmod is missing; initialise it for that shell only:

```bash
source /etc/profile.d/lmod.sh
export MODULEPATH=/uol/apps/calder/modules
```

Python and conda recommendations:

- Use Miniforge rather than Anaconda (university policy). Keep conda environments in Home and research data in scratch. See [environment management](https://arcdocs.leeds.ac.uk/calder/usage/environment_management.html) and [Miniforge](https://arcdocs.leeds.ac.uk/calder/software/tools/miniforge.html).
- Create separate Calder environments instead of upgrading environments that AIRE jobs use: Home is shared, so changes reach both clusters. Compiled packages may also differ between the clusters.
- After loading Miniforge, `python` can still point at the system Python until you activate an environment. Check with `command -v python`.
- Do not run `conda init` or load fixed modules from `.bashrc` / `.bash_profile`; set up the environment inside each job script. See the [shell configuration FAQ](https://arcdocs.leeds.ac.uk/calder/getting_started/faq.html#shell-configuration).
- Record dependencies in an `environment.yaml`; `conda env export` captures an exact run record, `--from-history` only the explicit requests (without pip packages).

Example environment file (a base only; add your project's dependencies):

```yaml
name: calder-project
channels:
  - conda-forge
dependencies:
  - python=3.12
  - pip
  - numpy
```

```bash
module load calder/cpu
module load miniforge3/26.1.1-3
conda env create -f environment.yaml
```

CUDA and containers:

- A precompiled framework wheel, the CUDA toolkit used to build custom extensions, and the host NVIDIA driver are separate layers. The existence of the `cuda/13.3.0` module does not mean a project must load it, nor that PyTorch is installed.
- Test `torch.cuda.is_available()` only inside a GPU job; a login node cannot validate an H200 setup.
- Apptainer still needs a Slurm allocation; it does not bypass the queue, quotas or the host driver. Use `--nv` for GPU containers and keep Slurm's GPU visibility. MPI containers must match the host MPI/PMIx and network stack. See [Apptainer on Calder](https://arcdocs.leeds.ac.uk/calder/software/tools/apptainer.html).
- Software that many users need can be requested through the [software request form](https://it.leeds.ac.uk/it?id=sc_cat_item&sys_id=48d5a6d70f275f00a82247ece1050ea0) ([details](https://arcdocs.leeds.ac.uk/calder/getting_started/request_software.html)).

## 9. Job Templates

None of these templates had been run on Calder at the time of writing. Adjust resources to the job; they are starting points, not tuned values. Create the log directory before submitting (`mkdir -p <PROJECT_DIR>/logs`), and replace `<calder-env>` with your environment name.

The scripts use `set -eo pipefail` without `-u` because the Lmod and conda activation scripts have not been verified to be safe under `set -u` on Calder.

### 9.1 CPU Job

```bash
#!/bin/bash
#SBATCH --job-name=cpu_job
#SBATCH --partition=calder-cpu-turin
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=8
#SBATCH --mem=32G
#SBATCH --time=04:00:00
#SBATCH --output=<PROJECT_DIR>/logs/%x_%j.out
#SBATCH --error=<PROJECT_DIR>/logs/%x_%j.err

set -eo pipefail

PROJECT=<PROJECT_DIR>
cd "$PROJECT"

# A non-interactive shell may lack the module function (section 8).
if ! command -v module >/dev/null 2>&1; then
    source /etc/profile.d/lmod.sh
    export MODULEPATH=/uol/apps/calder/modules
fi
module purge
module load calder/cpu
module load miniforge3/26.1.1-3
eval "$(conda shell.bash hook)"
conda activate <calder-env>

export PYTHONPATH="$PROJECT:${PYTHONPATH:-}"
export PYTHONNOUSERSITE=1
export OMP_NUM_THREADS="${SLURM_CPUS_PER_TASK:-1}"

python tools/<your_cpu_script>.py
```

8 CPUs is the partition minimum, so a smaller request does not save anything.

### 9.2 Single-GPU Job

```bash
#!/bin/bash
#SBATCH --job-name=gpu_job
#SBATCH --partition=calder-gpu-hopper
#SBATCH --gres=gpu:nvidia_h200:1
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=16
#SBATCH --mem=128G
#SBATCH --time=04:00:00
#SBATCH --output=<PROJECT_DIR>/logs/%x_%j.out
#SBATCH --error=<PROJECT_DIR>/logs/%x_%j.err

set -eo pipefail

PROJECT=<PROJECT_DIR>
cd "$PROJECT"

# A non-interactive shell may lack the module function (section 8).
if ! command -v module >/dev/null 2>&1; then
    source /etc/profile.d/lmod.sh
    export MODULEPATH=/uol/apps/calder/modules
fi
module purge
module load calder/hopper
module load miniforge3/26.1.1-3
eval "$(conda shell.bash hook)"
conda activate <calder-env>

export PYTHONPATH="$PROJECT:${PYTHONPATH:-}"
export PYTHONNOUSERSITE=1

echo "job_id=$SLURM_JOB_ID node=$SLURMD_NODENAME"
nvidia-smi
python - <<'PY'
import torch
print("torch", torch.__version__, "cuda", torch.version.cuda)
print("cuda_available", torch.cuda.is_available())
if torch.cuda.is_available():
    print("device", torch.cuda.get_device_name(0))
PY

python tools/<your_gpu_script>.py --device cuda
```

### 9.3 Multi-GPU and Multi-Node Resource Lines

The GPU count in `--gres` is per node. All 16 GPUs a user may hold, across two full nodes:

```bash
#SBATCH --partition=calder-gpu-hopper
#SBATCH --nodes=2
#SBATCH --gres=gpu:nvidia_h200:8
#SBATCH --time=04:00:00
```

Not `gpu:nvidia_h200:16`. These lines only reserve resources: the project still has to define processes, CPU memory, the distributed launcher, rendezvous address and port, and the NCCL or MPI environment.

An MPI job across two CPU nodes, one rank per core:

```bash
#SBATCH --partition=calder-cpu-turin
#SBATCH --nodes=2
#SBATCH --ntasks-per-node=128
#SBATCH --cpus-per-task=1
#SBATCH --time=04:00:00
```

256 MPI ranks are not the same as one process with 256 threads. Load an MPI module compatible with the application (find it with `module spider`). Codes built for AIRE's Omni-Path stack must be rebuilt or checked for InfiniBand.

### 9.4 Array Jobs and Dependencies

```bash
#SBATCH --array=1-100%10

INPUT=$(sed -n "${SLURM_ARRAY_TASK_ID}p" inputs.txt)
```

`%10` only limits how many tasks run at once; it does not make them start sooner. Each task of a GPU array counts towards your 16-GPU limit. The highest array index is 1000.

Run a step only after another succeeds:

```bash
first=$(sbatch --parsable jobs/prepare.sbatch)
sbatch --dependency=afterok:"$first" jobs/train.sbatch
```

`afterany` runs after the first job ends for any reason, including failure and timeout.

### 9.5 Interactive Sessions

Interactive sessions use scheduler resources like any job; keep them short and `exit` when done.

```bash
srun --partition=calder-cpu-turin --cpus-per-task=8 --mem=16G --time=00:30:00 --pty bash
srun --partition=calder-gpu-hopper --gres=gpu:nvidia_h200:1 --cpus-per-task=16 --mem=64G --time=00:15:00 --pty bash
```

The university advises against using interactive allocations as long-running Jupyter, Spyder or RStudio workstations. For occasional remote GUI programs the IT article gives X11 forwarding (`ssh -X calder` or `ssh -X calder-jump`, with a local X server).

### 9.6 Minimal Test Job

```bash
#!/bin/bash
#SBATCH --job-name=hello_calder
#SBATCH --partition=calder-cpu-turin
#SBATCH --cpus-per-task=8
#SBATCH --mem=1G
#SBATCH --time=00:05:00
#SBATCH --output=<PROJECT_DIR>/logs/%x_%j.out
#SBATCH --error=<PROJECT_DIR>/logs/%x_%j.err

set -eo pipefail

echo "job_id=$SLURM_JOB_ID"
echo "node=$SLURMD_NODENAME"
echo "SCRATCH=${SCRATCH:-unset} TMP_SHARED=${TMP_SHARED:-unset} TMPDIR=${TMPDIR:-unset}"
hostname
date
```

```bash
mkdir -p <PROJECT_DIR>/logs
sbatch hello_calder.sbatch
```

This also shows which temporary-storage variables a Calder job actually receives.

## 10. Monitoring Jobs and the Cluster

These commands only query the scheduler. Avoid running them in tight loops.

```bash
# Partitions, limits, node states and GPUs
sinfo -o "%20P %8a %12l %6D %10t %24G %6c %10m"
scontrol show partition calder-cpu-turin
scontrol show partition calder-gpu-hopper
sinfo -N -p calder-gpu-hopper

# Your jobs (partition names are long, so widen %P)
squeue --me
squeue --me -o "%.18i %.18P %.24j %.2t %.10M %.10l %.6D %R"

# One job
squeue --job=<JOBID> --start
scontrol show job <JOBID>
sacct -j <JOBID> --format=JobID,JobName,Partition,State,ExitCode,Elapsed,AllocCPUS,ReqMem,MaxRSS,NodeList

# Priority and fair share
sprio -j <JOBID>
sshare

# Cancel, carefully
scancel <JOBID>
```

Reading the output:

- Job states: `PD` pending, `R` running, `CG` completing; in `sacct`, `COMPLETED`, `FAILED`, `TIMEOUT`, `OUT_OF_MEMORY`, `CANCELLED`. Once a job leaves `squeue`, use `sacct`.
- `--start` estimates change as the queue changes.
- Node states: `MIXED` means part of the node is allocated; `PLANNED` means backfill has reserved it for a higher-priority job; `DRAIN` means it accepts no new work. An `IDLE` node does not guarantee your request starts immediately, and total GPUs minus allocated GPUs is not the number you can get right now.
- Fair share is not a fixed balance of GPU hours to spend.

When taking over an account, check for existing jobs first and do not cancel or modify jobs you are not responsible for. Closing your terminal does not cancel a batch job.

## 11. Syncing Files

Transfer data through the login nodes before a job starts and fetch results after it ends; do not download external data from inside a running compute job. The SSH aliases work for `scp`, `sftp` and `rsync`, reusing an open ControlMaster connection. See [data transfer](https://arcdocs.leeds.ac.uk/calder/usage/file_management/data_transfer.html).

Preview first, then copy:

```bash
rsync -avhP --dry-run ./dataset/ calder:/scratch-calder/users/<username>/<project_name>/dataset/
rsync -avhP ./dataset/ calder:/scratch-calder/users/<username>/<project_name>/dataset/
```

Results back to the local machine:

```bash
rsync -avhP calder:<PROJECT_DIR>/results/ ./results/
```

Use `calder-jump` instead of `calder` when going through rash. A trailing `/` on the source copies the directory's contents. Do not add `--delete` unless you mean to delete extra files at the destination.

Recommendations:

- Pack many small files into archives where practical to save transfer time and inodes; count both the archive and the unpacked copy towards peak usage.
- Files under `/users/<username>` need no transfer between the clusters: Home is the same directory on both.
- AIRE scratch is not Calder scratch. Whether AIRE's `/mnt/scratch` is visible from Calder, and whether direct cluster-to-cluster copies work, was not checked; verify with `ls -ld /mnt/scratch/"$USER"` on a Calder login node before planning a move, otherwise copy through a machine that can reach both.
- Globus: the central HPC Globus service was described as still in development at launch, with Globus Personal as the interim option.

## 12. Migrating from AIRE to Calder

Keep existing AIRE work running and move one representative job first rather than everything at once. See the [migration FAQ](https://arcdocs.leeds.ac.uk/calder/getting_started/faq.html).

| Item | What to check |
| --- | --- |
| Login | Same university account; new host `calder.leeds.ac.uk`; new SSH aliases |
| Home | Shared; do not overwrite environments or dotfiles that AIRE jobs rely on |
| Scratch | New location `/scratch-calder/users/<username>`; data is not copied for you |
| Quotas | Lustre project quotas (`lfs project -d` + `lfs quota -p`) instead of AIRE's per-user scratch quota |
| Partitions | `nodes` → `calder-cpu-turin`; `gpu` → `calder-gpu-hopper`; no `himem` or `teachingnodes` |
| GPU requests | `--gres=gpu:1` on L40S → `--gres=gpu:nvidia_h200:N` (per node) |
| Resource defaults | Minimum 8 cores on CPU; about 16 cores + 192 GB per GPU by default; 16 GPUs / 2 nodes per user |
| Modules | Flat AIRE modules → Lmod hierarchy (`calder/cpu` or `calder/hopper` first); old `module load` lines will not work as-is |
| Python / PyTorch | No `pytorch` module; use a Miniforge environment |
| MPI and network | Omni-Path → InfiniBand; rebuild or re-check MPI codes |
| Compiled extensions | Check Python, compiler, CUDA and GPU architecture; do not just copy caches or `site-packages` |
| Paths in scripts | Replace `/mnt/scratch/...` paths and any `#SBATCH` lines that relied on variables |
| Results | Compare outputs, runtime and peak memory with the same inputs, precision, batch size and versions |

Suggested validation order: import the environment, read a small slice of data, run a small computation, save and restore a checkpoint, then run the full job. Floating-point results on different GPUs need not match bit for bit; judge them against the project's numerical tolerances. A change in batch size or precision also changes runtime, so do not attribute differences to the GPU alone.

AIRE itself is being upgraded ("Aire 2.0"). The official pages expect its scratch and flash paths to move to `/scratch-aire` and `/flash-aire`, with modules and documentation migrating gradually; do not assume those paths exist until they are announced. See [software](https://arcdocs.leeds.ac.uk/calder/software/start.html) and [storage options](https://arcdocs.leeds.ac.uk/calder/usage/file_management/storage_options.html).

When handing a Calder setup over to someone else, also document the project paths, active jobs, environment names, important data and checkpoint locations, which directories are safe to clean, and how results are backed up.

## 13. Troubleshooting

| Symptom | Check first |
| --- | --- |
| SSH times out | Network, DNS, VPN versus rash route; do not edit a working AIRE configuration |
| `Not allowed at this time`, or reset/closed before authentication | Server-side refusal, not a wrong password; wait, retry once, see section 4.4 |
| Host key changed warning | Verify with an official source; never disable checking or wipe `known_hosts` |
| `Permission denied` | BatchMode without a live session? Password/keyboard-interactive offered? Correct username? |
| `module: command not found` | Non-interactive shell; `source /etc/profile.d/lmod.sh` |
| Module not found | `MODULEPATH`, `calder/cpu` versus `calder/hopper` layer, `module spider` load order |
| Wrong Python or conda | `command -v python`; environment activated in the job? |
| GPU not visible | Running inside a GPU job with `--gres=gpu:nvidia_h200:N`? Framework built for CUDA? |
| `$SCRATCH` empty or old path missing | Login shell versus job environment; use the real path with `users/` |
| Quota or "no space" errors | Project space **and** inodes (`lfs quota -h -p`), not only `df` |
| Job rejected | Calder partition names and `gpu:nvidia_h200:N` gres (not AIRE's); at least 8 CPUs; at most 16 GPUs on 2 nodes; `--time` within 48 hours |
| Job pending for long | `squeue --me` reason, `sprio`; oversized CPU/memory/GPU/time requests; 16-GPU limit |
| Job timed out or OOM | `sacct` state and `MaxRSS`; system memory and GPU memory are different limits |
| MPI slots or cross-node errors | Task counts, MPI module, the application's documented launcher |
| Slow data loading | Data location, small-file count, CPU workers, GPU utilization |

## 14. Official Documentation versus Observed State

As of 2026-10-12:

| Item | Official docs / older examples | Observed on Calder |
| --- | --- | --- |
| Standard CPU nodes | 96 | Slurm lists 98 in `calder-cpu-turin` |
| GPU node names | Jobs page: `calder-gpu-h200-001`, … | `calder-h200-01` to `calder-h200-07` |
| Scratch user path | `/scratch-calder/<username>`; some pages still show AIRE paths | `/scratch-calder/users/<username>` |
| Inode limit | Default 1.5 million per project | 1,000,000 hard limit on a checked account |
| `$SCRATCH` | Set inside jobs | Unset on login nodes, even after loading `calder/cpu` or `calder/hopper`; not yet checked inside a job |
| Fair share | Priority page describes fair share | `PriorityWeightFairShare=0` |
| Off-campus route | Public page: VPN or gateway; IT article: rash with VPN off | Direct login over the University VPN worked from one Mac |
| Miniforge | Miniforge page loads it from `calder/cpu` | Loadable from both `calder/cpu` and `calder/hopper` |
| Job temporary flash | Storage page lists Calder variables; Jobs page example still says AIRE, details pending | Not verified in a Calder job |
| Flash capacity | About 246 TB | Mounted filesystem about 182.84 TB (decimal) |
| Scratch capacity | About 6.3 PB | Mounted filesystem about 6.09 PB (decimal) |

When the two disagree, use what you can verify for your own account, keep the command output, and ask Research Computing about policies and anomalies.

## 15. Not Yet Confirmed

At launch, these were not documented or not tested:

- H200 driver version, actual GPU topology, and 8-GPU or multi-node communication performance.
- The default CPU and memory per GPU, and the full set of enforced job limits, in practice.
- Actual behaviour of `$TMP_SHARED`, node-local temporary space and their cleanup in Calder jobs.
- Retention policy for personal flash directories; Home backup frequency and restore process.
- The reason for the gap between nominal and mounted flash capacity.
- Compute budgets or charging, reservations, buying dedicated nodes, SLAs, external collaborator access, and account/data retention after leaving.

## 16. Rules, Sensitive Data and Acknowledgement

- Sustained compute must go through Slurm; use login nodes only for preparation and light checks.
- Personal and sensitive data must not be stored or processed on the HPC systems. Properly de-identified data that cannot identify individuals is usually acceptable; for real clinical data, check the university's data classification and your research approvals, because removing names alone may not be enough. Ask Research Computing when unsure. The rules page was still being updated at launch: [rules and regulations](https://arcdocs.leeds.ac.uk/calder/getting_started/rules_regulations.html).
- Take extra care with `rm -rf`, `rsync --delete`, `scancel` and edits to shared dotfiles: Home is shared with AIRE.

When publications, posters or talks use the university's HPC, the suggested acknowledgement is:

> This work was undertaken on the HPC systems at the University of Leeds, UK.

## 17. Support and Training

- Open a trackable ticket with the [Research IT query form](https://bit.ly/arc-help), use the [Research IT service portal](https://leeds.service-now.com/it?id=sc_cat_item&sys_id=7587b2530f675f00a82247ece1050eda), or email [RCTeam@leeds.ac.uk](mailto:RCTeam@leeds.ac.uk).
- The RIE team runs the infrastructure, platform, storage and network; the research software engineers (RSE) help with code, profiling, refactoring, parallelisation and workflows. The documentation also links a Calder community space. See [support](https://arcdocs.leeds.ac.uk/calder/support/start.html).
- For connection problems, report the time and time zone, the alias and route, the network you were on, the raw error and the stage that failed. For job problems, add the job id, the submission script, stdout/stderr and `sacct` output. Remove passwords, codes, tokens and unrelated personal content first.
- Introductory courses: HPC0 (Linux), HPC1 (HPC), HPC2 (software). Dates are on [ARC courses](https://arc.leeds.ac.uk/courses/); see also [training](https://arcdocs.leeds.ac.uk/calder/support/training_courses.html).

## 18. Monitoring Calder with This App

The macOS app in this repository, Leeds HPC Monitor (formerly AIRE Monitor), watches AIRE and Calder at the same time. Build and launch it with `./scripts/run_macos_app.sh`; see `MACOS_APP.md` for details. What matters for Calder:

- **Enabling:** both clusters are on by default. Under **Advanced** in the sidebar, each cluster has an on/off switch and a host field (default `calder.leeds.ac.uk`; a blank field falls back to it). A cluster that is switched off never refreshes and is skipped by **Connect all**.
- **Sign-in:** one university username, one password (optionally saved as a single Keychain item used for every cluster) and one route for all clusters, chosen in the sidebar as **Direct (VPN)** or **rash jump**. **Connect all** signs in to one cluster at a time so Duo pushes arrive one by one. On the rash route the rash session is shared by both clusters and reused while it is healthy, so expect one push for rash and then one per cluster; on the direct route, one per cluster. If one cluster rejects the password, the remaining queued sign-ins are cancelled instead of retrying the same password.
- **Independent sessions:** each cluster has its own SSH ControlMaster, refresh loop (every 10 seconds, backing off up to 60 seconds while refreshes fail), snapshot cache, history, job notifications, GPU-free alert, terminals and file browser. A Calder connection refused before authentication (including `Not allowed at this time`) is reported as "closed the connection before authentication", a server-side refusal rather than a wrong password, and does not tear down a healthy rash session, so the AIRE connection stays up.
- **Host keys:** the app's sign-in uses `StrictHostKeyChecking=accept-new`: it records Calder's key on the first connection and refuses to connect if the key later changes. To check the fingerprint before that first connection, log in once with `ssh calder` in a terminal (section 4.3).
- **Separate from `~/.ssh/config`:** the app builds its own ssh options and keeps its own control sockets in `~/.ssh/ctl/`, which never collide with the `%C` sockets of section 4.2. A terminal `ssh calder` therefore still needs its own login, while the app's built-in terminal reuses the app's authenticated Calder session without another Duo prompt.
- **Partitions and GPUs:** `calder-gpu-hopper` is shown as the GPU partition with model `H200`, and `calder-cpu-turin` as the CPU partition. Time limits come from `sinfo`.
- **Storage:** Home, Scratch (`/scratch-calder/users/<username>`, falling back to `/scratch-calder/<username>`) and Flash (`/flash-calder/users/<username>`, falling back to `/flash-calder/<username>`; omitted if neither exists). Scratch and Flash figures come from the directory's Lustre project quota (`lfs project -d`, then `lfs quota -p`) and are labelled "Lustre project quota" with the project id; a directory without a project id falls back to the per-user Lustre quota. Home is marked as shared by all clusters, and the menu bar lists it once rather than once per cluster.
- **Terminal quick commands** for Calder: `squeue --me`, `sinfo`, a quota command (`quota -s` plus the scratch and flash project quotas, as in section 6.3), `sinfo -N -p calder-gpu-hopper`, and `htop` (falling back to `top`).
- **Overview, menu bar and desktop widget** show both clusters side by side, each tagged with its badge. Numbers are never added across clusters (an L40S and an H200 are different pools, and job ids are only unique within one cluster). The widget follows each cluster's `.runtime/clusters/<id>/latest_snapshot.json`; only when that file is missing or stale (the app is not refreshing that cluster) does it collect for that cluster itself, using the password-free argument list the app saved in `.runtime/clusters/<id>/collector.json`.
- **Files:** each cluster has its own file browser, with shortcuts to that cluster's resolved storage directories. The remote trash folder keeps the name `.aire-trash` for continuity; because Home is shared, the trash in your home directory is the same folder whether you browse from AIRE or Calder.

The snapshot collector (`scripts/hpc_snapshot.py`) only runs read-only commands and never writes remote files. Cancelling a job, or changing files in the file browser, happens only when you choose to do it.

## 19. Quick Reference

```bash
# Login
ssh calder              # direct
ssh calder-jump         # via rash

# Where am I
hostname; id -un; pwd

# Project
cd /scratch-calder/users/"$USER"/<project_name>

# Partitions and GPUs
sinfo -o "%20P %8a %12l %6D %10t %24G %6c %10m"
sinfo -N -p calder-gpu-hopper

# Submit and watch
sbatch jobs/my_job.sbatch
squeue --me
scontrol show job <JOBID>
sacct -j <JOBID>

# Quotas
quota -s
lfs quota -h -p "$(lfs project -d /scratch-calder/users/$USER | awk '{print $1}')" /scratch-calder
lfs quota -h -p "$(lfs project -d /flash-calder/users/$USER | awk '{print $1}')" /flash-calder

# Modules
module load calder/hopper          # or calder/cpu
module load miniforge3/26.1.1-3
module spider <name>

# GPU request lines
#SBATCH --partition=calder-gpu-hopper
#SBATCH --gres=gpu:nvidia_h200:1

# Logs
tail -f <PROJECT_DIR>/logs/<job_name>_<JOBID>.out

# Cancel, carefully
scancel <JOBID>
```
