# AIRE Server User Guide

This document summarizes how to connect to the AIRE cluster, how to use Slurm, what the main partitions provide, and what conventions are recommended for day-to-day work. It is intended as a handover guide for future users.

The information below is based on read-only checks made on 2026-05-20. Cluster resources, module versions, partition limits, and QOS rules can change, so users should re-check the current state with the read-only commands listed in this guide.

## 1. Overview

AIRE is a Slurm-managed HPC cluster. Long-running training, evaluation, parallel CPU work, GPU jobs, and memory-heavy workloads should not be run directly on login nodes. Production work should be submitted through `sbatch`.

The recommended SSH configuration is in `config/aire_ssh_config.example`. Copy the Host blocks you need into `~/.ssh/config`, and create the control-socket directory first:

```bash
mkdir -m 700 ~/.ssh/ctl
```

The `aire` alias is the direct route and requires the University VPN (Ivanti):

```sshconfig
Host aire
    HostName aire.leeds.ac.uk
    User <your-username>
    NumberOfPasswordPrompts 1
    ControlMaster auto
    ControlPersist 24h
    ControlPath ~/.ssh/ctl/aire-%C
```

When off the VPN, use the `aire-jump` alias instead, which routes through the `rash.leeds.ac.uk` jump host (password + Duo twice: once for rash, once for AIRE). The full set of Host blocks (`aire`, `rash`, `aire-jump`, all using `~/.ssh/ctl/*-%C` control sockets and `NumberOfPasswordPrompts 1`) is in `config/aire_ssh_config.example`.

Confirmed remote information:

```text
Login node: login4.aire.lee.alces.network
User: <your-username>
Default home: /users/<your-username>
User scratch root: usually /mnt/scratch/<username>
```

For the current SSH user `<your-username>`, the scratch root is `/mnt/scratch/<your-username>`. Do not treat any single project path as a server-wide default; each project may live in a different location.

In this document, `<PROJECT_DIR>`, `<JOBID>`, and `<project_name>` are placeholders. Replace them with the actual project path, Slurm job id, or project name.

## 2. Connecting

Log in from a local terminal:

```bash
ssh aire
```

Run a one-off read-only command:

```bash
ssh aire 'hostname; whoami; pwd; date'
```

If the connection fails, first confirm the VPN is connected, then inspect the verbose output:

```bash
ssh -vv aire
```

When off the VPN, use the jump-host route instead:

```bash
ssh rash 'hostname'
ssh aire-jump 'hostname'
```

Here `rash` is the jump host. The SSH configuration uses password or keyboard-interactive authentication, so it may prompt for a Leeds password or multi-factor authentication.

## 3. Login Node Rules

Login nodes are for lightweight work:

- Editing scripts
- Inspecting logs
- Submitting Slurm jobs
- Checking queue status
- Small file operations
- Very short test commands

Do not use login nodes for:

- Training jobs
- Long Python evaluation scripts
- Large data preprocessing
- Multi-process CPU workloads
- GPU workloads
- High-memory workloads

Write compute work as `sbatch` scripts and submit it to Slurm.

## 4. Filesystems and Project Layout

Common paths:

```text
/users/<username>
/mnt/scratch/<username>
```

`/users/<username>` is the home directory. Use it for configuration, small scripts, and small files.

`/mnt/scratch/<username>` is user scratch space. Use it for project code, datasets, intermediate outputs, model outputs, logs, and checkpoints.

Projects can be placed under different scratch paths, for example:

```text
/mnt/scratch/<username>/projects/<project_name>
/mnt/scratch/<username>/<project_name>
/mnt/scratch/<username>/work/<project_name>
```

A useful project structure is:

```text
<PROJECT_DIR>
├── checkpoints
├── configs
├── data
├── jobs
├── logs
├── reports
├── runs
├── src
├── tests
└── tools
```

Recommendations:

- Put large files, datasets, checkpoints, and evaluation outputs on scratch.
- Keep home for small files and configuration.
- Put logs under `logs/` or a project-specific experiment directory.
- Put Slurm scripts under `jobs/` or next to the experiment they run.
- Back up important results to local storage or another durable location.

Check disk usage:

```bash
df -h "$HOME"
df -h /mnt/scratch/"$USER"
du -sh <PROJECT_DIR>
```

## 5. Slurm Command Reference

Confirmed Slurm commands:

```text
sbatch
srun
sinfo
squeue
sacct
```

Common commands:

```bash
# Partition overview
sinfo

# More detailed partition, node, GPU, CPU, and memory view
sinfo -o "%20P %8a %8D %10t %12G %8c %10m %20f"

# Your jobs
squeue -u "$USER"

# Your jobs with time limits and pending/running reasons
squeue -u "$USER" -o "%.18i %.9P %.24j %.2t %.10M %.10l %.6D %R"

# Detailed job information
scontrol show job <JOBID>

# Historical accounting for a job
sacct -j <JOBID> --format=JobID,JobName,Partition,State,Elapsed,Timelimit,AllocCPUS,ReqMem,NNodes,NodeList

# Cancel a job. Use carefully
scancel <JOBID>
```

## 6. Partitions

Partition information observed on 2026-05-20:

| Partition | Purpose | Nodes | CPUs per node | Memory per node | GPU | Max time |
| --- | --- | ---: | ---: | ---: | --- | --- |
| `nodes` | Default CPU partition | 52 | 168 | about 755 GiB | none | 2 days |
| `gpu` | GPU jobs | 28 | 24 | about 250 GiB | 3 L40S per node | 2 days |
| `himem` | High-memory CPU jobs | 2 | 168 | about 2.3 TiB | none | 2 days |
| `teachingnodes` | Teaching workloads | 11 | 168 | about 755 GiB | none | 8 hours |

The default partition is `nodes`. GPU jobs must explicitly request the `gpu` partition and GPU resources.

### 6.1 CPU Partition: `nodes`

Use for:

- CPU training or evaluation
- Data preprocessing
- Multi-threaded numerical work
- Batch jobs that do not need GPUs

Observed configuration:

```text
PartitionName=nodes
Nodes=node[001-052]
TotalNodes=52
TotalCPUs=8736
MaxTime=2-00:00:00
QoS=nodeslimits
```

Observed QOS limit:

```text
nodeslimits: cpu=1024,mem=4601G
```

### 6.2 GPU Partition: `gpu`

Use for:

- PyTorch / CUDA training
- GPU inference
- GPU-accelerated evaluation

Observed configuration:

```text
PartitionName=gpu
Nodes=gpu[001-028]
TotalNodes=28
TotalCPUs=672
Total GPUs=84
Per-node GRES=gpu:l40s:3
MaxTime=2-00:00:00
QoS=gpulimits
```

Example single GPU node shape:

```text
NodeName=gpu001
CPUTot=24
RealMemory=256656M
Gres=gpu:l40s:3
```

Observed QOS limit:

```text
gpulimits: cpu=120,gres/gpu=15
```

Typical single-GPU request:

```bash
#SBATCH --partition=gpu
#SBATCH --gres=gpu:1
#SBATCH --cpus-per-task=4
#SBATCH --mem=80G
```

Example two-GPU single-node request:

```bash
#SBATCH --partition=gpu
#SBATCH --gres=gpu:2
#SBATCH --cpus-per-task=8
#SBATCH --mem=160G
```

Do not request more GPU, CPU, or memory than needed. Oversized requests increase queue time and consume quota.

### 6.3 High-Memory Partition: `himem`

Use for:

- Very large matrices
- Large-scale data preprocessing
- Memory-heavy CPU inference or evaluation
- Jobs that do not fit in regular `nodes` memory

Observed configuration:

```text
PartitionName=himem
Nodes=himem[01-02]
TotalNodes=2
TotalCPUs=336
MaxTime=2-00:00:00
```

Example high-memory node shape:

```text
NodeName=himem01
CPUTot=168
RealMemory=2321256M
```

Example request:

```bash
#SBATCH --partition=himem
#SBATCH --cpus-per-task=32
#SBATCH --mem=500G
```

### 6.4 Teaching Partition: `teachingnodes`

Use for teaching-related workloads. The observed maximum runtime is 8 hours:

```text
PartitionName=teachingnodes
MaxTime=08:00:00
QoS=teaching_qos
```

Observed QOS limit:

```text
teaching_qos:
  MaxWall=08:00:00
  MaxTRESPU=cpu=8
  MaxJobsPU=15
  MaxSubmitPU=30
```

If the work is not teaching-related, this partition is usually not the right choice.

## 7. Environment Modules

AIRE uses environment modules:

```bash
module --version
# Modules Release 5.3.0
```

Inspect modules:

```bash
module avail
module spider pytorch
module list
```

Common modules observed:

```text
cuda/12.4.1
cuda/12.6.2
gcc/13.2.0
gcc/14.2.0
python/3.13.0
miniforge/24.7.1
pytorch/2.5.1
pixi/0.41.4
apptainer/1.3.6
openmpi/5.0.6
```

In job scripts, explicitly clear and load modules:

```bash
module purge
module load pytorch/2.5.1
```

Do not rely on modules loaded in an interactive shell. Each `sbatch` script should define its own runtime environment.

## 8. Basic `sbatch` Structure

A job script usually contains:

1. Shebang
2. `#SBATCH` resource declarations
3. `set -euo pipefail`
4. Change into the project directory
5. Load modules or activate the environment
6. Set environment variables
7. Run the actual command

Generic template:

```bash
#!/bin/bash
#SBATCH --job-name=my_job
#SBATCH --partition=nodes
#SBATCH --time=02:00:00
#SBATCH --cpus-per-task=8
#SBATCH --mem=32G
#SBATCH --output=<PROJECT_DIR>/logs/%x_%j.out
#SBATCH --error=<PROJECT_DIR>/logs/%x_%j.err

set -euo pipefail

PROJECT=<PROJECT_DIR>
cd "$PROJECT"

module purge
module load pytorch/2.5.1

export PYTHONPATH="$PROJECT:${PYTHONPATH:-}"
export PYTHONNOUSERSITE=1

python tools/my_script.py
```

Submit:

```bash
sbatch jobs/my_job.sbatch
```

Check:

```bash
squeue -u "$USER"
```

## 9. GPU Job Template

Single-GPU PyTorch template:

```bash
#!/bin/bash
#SBATCH --job-name=gpu_eval
#SBATCH --partition=gpu
#SBATCH --gres=gpu:1
#SBATCH --time=10:00:00
#SBATCH --cpus-per-task=4
#SBATCH --mem=80G
#SBATCH --output=<PROJECT_DIR>/logs/%x_%j.out
#SBATCH --error=<PROJECT_DIR>/logs/%x_%j.err

set -euo pipefail

PROJECT=<PROJECT_DIR>
cd "$PROJECT"

module purge
module load pytorch/2.5.1

export PYTHONPATH="$PROJECT:${PYTHONPATH:-}"
export PYTHONNOUSERSITE=1

python - <<'PY'
import torch
print("cuda_available", torch.cuda.is_available())
if torch.cuda.is_available():
    print("device", torch.cuda.get_device_name(0))
PY

python tools/<your_gpu_script>.py --device cuda
```

At minimum, a GPU job should include resource declarations similar to:

```bash
#SBATCH --partition=gpu
#SBATCH --gres=gpu:1
#SBATCH --time=10:00:00
#SBATCH --cpus-per-task=4
#SBATCH --mem=80G
module purge
module load pytorch/2.5.1
export PYTHONPATH="$PROJECT:${PYTHONPATH:-}"
export PYTHONNOUSERSITE=1
```

## 10. CPU Job Template

Template for a regular CPU job:

```bash
#!/bin/bash
#SBATCH --job-name=cpu_job
#SBATCH --partition=nodes
#SBATCH --time=04:00:00
#SBATCH --cpus-per-task=16
#SBATCH --mem=64G
#SBATCH --output=<PROJECT_DIR>/logs/%x_%j.out
#SBATCH --error=<PROJECT_DIR>/logs/%x_%j.err

set -euo pipefail

PROJECT=<PROJECT_DIR>
cd "$PROJECT"

module purge
module load pytorch/2.5.1

export PYTHONPATH="$PROJECT:${PYTHONPATH:-}"
export PYTHONNOUSERSITE=1
export OMP_NUM_THREADS="${SLURM_CPUS_PER_TASK:-1}"

python tools/<your_cpu_script>.py
```

## 11. High-Memory Job Template

Template for jobs that need more memory than a regular CPU node:

```bash
#!/bin/bash
#SBATCH --job-name=himem_job
#SBATCH --partition=himem
#SBATCH --time=08:00:00
#SBATCH --cpus-per-task=32
#SBATCH --mem=500G
#SBATCH --output=<PROJECT_DIR>/logs/%x_%j.out
#SBATCH --error=<PROJECT_DIR>/logs/%x_%j.err

set -euo pipefail

PROJECT=<PROJECT_DIR>
cd "$PROJECT"

module purge
module load pytorch/2.5.1

export PYTHONPATH="$PROJECT:${PYTHONPATH:-}"
export PYTHONNOUSERSITE=1
export OMP_NUM_THREADS="${SLURM_CPUS_PER_TASK:-1}"

python tools/<your_large_memory_script>.py
```

## 12. Interactive Debugging

For short debugging sessions, request interactive resources with `srun`. Do not run real compute work directly on the login node.

CPU interactive shell:

```bash
srun --partition=nodes --time=00:30:00 --cpus-per-task=4 --mem=16G --pty bash
```

GPU interactive shell:

```bash
srun --partition=gpu --gres=gpu:1 --time=00:30:00 --cpus-per-task=4 --mem=32G --pty bash
```

After entering the interactive node:

```bash
module purge
module load pytorch/2.5.1
python -c 'import torch; print(torch.cuda.is_available()); print(torch.cuda.get_device_name(0) if torch.cuda.is_available() else "no cuda")'
```

Exit when done:

```bash
exit
```

## 13. Logs

Recommended log declarations:

```bash
#SBATCH --output=<PROJECT_DIR>/logs/%x_%j.out
#SBATCH --error=<PROJECT_DIR>/logs/%x_%j.err
```

Where:

- `%x` is the Slurm job name
- `%j` is the Slurm job id

Inspect logs:

```bash
tail -n 100 logs/my_job_123456.out
tail -f logs/my_job_123456.out
tail -n 100 logs/my_job_123456.err
```

If logs are stored in another experiment directory, search by job id:

```bash
find <PROJECT_DIR> -name "*<JOBID>*.out" -o -name "*<JOBID>*.err"
```

## 14. Checking Existing Jobs

When taking over the account, do not assume there are no active jobs. Check your queue first:

```bash
squeue -u "$USER" -o "%.18i %.9P %.24j %.2t %.10M %.10l %.6D %R"
```

Inspect a specific job:

```bash
scontrol show job <JOBID>
```

Pay attention to:

- `Partition`: which partition the job is using.
- `NodeList` and `BatchHost`: where the job is running.
- `ReqTRES` and `AllocTRES`: requested and allocated CPU, memory, and GPU resources.
- `Command`: submitted sbatch script.
- `WorkDir`: working directory at submission time.
- `StdOut` and `StdErr`: standard output and error log paths.

Do not cancel or modify jobs unless you are explicitly responsible for them.

## 15. Python and Runtime Environments

Observed system Python:

```text
/usr/bin/python
/usr/bin/python3
Python 3.9.18
```

Additional relevant modules:

```text
python/3.13.0
miniforge/24.7.1
pytorch/2.5.1
pixi/0.41.4
```

Recommendations:

- Prefer the module and environment setup already used by the project.
- If the project uses conda, pixi, or venv, activate it explicitly in the `sbatch` script.
- Set `PYTHONPATH` to the project root if local package imports need it.

Common environment variables:

```bash
export PYTHONPATH="$PROJECT:${PYTHONPATH:-}"
export PYTHONNOUSERSITE=1
export OMP_NUM_THREADS="${SLURM_CPUS_PER_TASK:-1}"
```

## 16. Syncing Files

Local to server:

```bash
rsync -avP ./local_dir/ aire:<PROJECT_DIR>/local_dir/
```

Server to local:

```bash
rsync -avP aire:<PROJECT_DIR>/reports/ ./reports/
```

Single files:

```bash
scp my_script.py aire:<PROJECT_DIR>/tools/
scp aire:<PROJECT_DIR>/logs/job.out ./
```

Recommendations:

- Use `rsync -avP` for large directories because it can resume transfers.
- Avoid syncing `.git/`, cache directories, temporary files, and large checkpoints unless needed.
- Use `--exclude` for irrelevant files.

Example:

```bash
rsync -avP \
  --exclude .git \
  --exclude __pycache__ \
  --exclude "*.pyc" \
  ./ \
  aire:<PROJECT_DIR>/
```

## 17. Recommended Workflow

Typical workflow:

1. Edit code locally or inside the project directory on the server.
2. Prepare an `sbatch` script with explicit partition, time, CPU, memory, GPU, and log paths.
3. Submit from the login node:

   ```bash
   sbatch jobs/my_job.sbatch
   ```

4. Check queue and status:

   ```bash
   squeue -u "$USER"
   scontrol show job <JOBID>
   ```

5. Inspect logs:

   ```bash
   tail -f logs/my_job_<JOBID>.out
   tail -f logs/my_job_<JOBID>.err
   ```

6. Check final accounting:

   ```bash
   sacct -j <JOBID> --format=JobID,JobName,State,ExitCode,Elapsed,MaxRSS,AllocCPUS,ReqMem
   ```

7. Sync important results back to local storage or another backup location.

## 18. Resource Request Guidance

Start small and scale up:

- Smoke test: `time=00:10:00`, small CPU/GPU/memory.
- Regular small job: request what is actually needed, for example `gpu:1`, `cpus=4`, `mem=32G-80G`.
- Large job: estimate from smaller runs before increasing resources.

GPU guidance:

- Start with `--gres=gpu:1`.
- Choose CPUs based on dataloading, preprocessing, and IO needs, often 4 or 8.
- If memory is uncertain, start from similar previous jobs.
- Only request multiple GPUs if the code actually supports multi-GPU execution.

CPU guidance:

- Set `--cpus-per-task` explicitly.
- For NumPy, OpenMP, or PyTorch CPU workloads, set `OMP_NUM_THREADS`.
- Use `himem` for genuinely memory-heavy jobs instead of over-requesting on `nodes`.

Time guidance:

- The partition max time is not a target.
- Request a realistic runtime to help the scheduler.
- If the job needs more than 2 days, add checkpoint/resume or split it into smaller jobs.

## 19. Troubleshooting

### 19.1 Job Stays Pending

Check the reason:

```bash
squeue -u "$USER" -o "%.18i %.9P %.24j %.2t %.10M %.10l %.6D %R"
scontrol show job <JOBID>
```

Common reasons:

- Too many GPUs requested
- Too much memory requested
- Runtime request is too long
- QOS or account limits
- Busy partition
- Nodes under maintenance

### 19.2 Python Cannot Import Local Packages

Set the project root:

```bash
PROJECT=<PROJECT_DIR>
cd "$PROJECT"
export PYTHONPATH="$PROJECT:${PYTHONPATH:-}"
```

### 19.3 CUDA Is Not Available

Make sure the job is on the GPU partition and requests a GPU:

```bash
#SBATCH --partition=gpu
#SBATCH --gres=gpu:1
```

Print CUDA status inside the job:

```bash
python - <<'PY'
import torch
print(torch.cuda.is_available())
print(torch.cuda.get_device_name(0) if torch.cuda.is_available() else "no cuda")
PY
```

### 19.4 Job OOMs or Gets Killed

Check accounting and error logs:

```bash
sacct -j <JOBID> --format=JobID,State,ExitCode,Elapsed,MaxRSS,ReqMem,AllocCPUS
tail -n 200 <error-log>
```

Possible fixes:

- Increase `--mem`
- Reduce batch size
- Reduce dataloader workers
- Process data in chunks
- Move to `himem` if the memory need is real

### 19.5 No Logs Are Written

Check:

- Does the `#SBATCH --output` directory exist?
- Does the `#SBATCH --error` directory exist?
- Has the job actually started?
- Did the script fail before writing anything?

Useful header:

```bash
echo "job_id=$SLURM_JOB_ID"
echo "node=$SLURMD_NODENAME"
echo "workdir=$(pwd)"
date
```

## 20. Read-Only Inspection Checklist

Run these commands when taking over or checking the server state:

```bash
hostname -f
whoami
pwd
date

command -v sbatch
command -v srun
command -v sinfo
command -v squeue
command -v sacct

sinfo -o "%20P %8a %8D %10t %12G %8c %10m %20f"
sinfo -s -o "%20P %8a %8l %8D %10t %12G %8c %10m"

scontrol show partition nodes
scontrol show partition gpu
scontrol show partition himem
scontrol show partition teachingnodes

squeue -u "$USER" -o "%.18i %.9P %.24j %.2t %.10M %.10l %.6D %R"

module --version
module avail

df -h "$HOME"
df -h /mnt/scratch/"$USER"
```

## 21. Safety Notes

Use extra care with:

- `rm -rf`
- `mv` over existing directories
- `rsync --delete`
- `scancel`
- Editing `.bashrc`
- Modifying shared environments
- Deleting `runs/`, `logs/`, `reports/`, or `checkpoints/`

Recommendations:

- Run `ls` or `find` before deleting.
- For large cleanup, move files to a temporary location first.
- Do not cancel jobs you do not understand.
- Do not overwrite old results unless you know they are disposable.
- Use new job names and new output directories for new experiments.

## 22. Minimal `sbatch` Test

For a quick Slurm sanity check, submit a short CPU job:

```bash
#!/bin/bash
#SBATCH --job-name=hello_slurm
#SBATCH --partition=nodes
#SBATCH --time=00:05:00
#SBATCH --cpus-per-task=1
#SBATCH --mem=1G
#SBATCH --output=<PROJECT_DIR>/logs/%x_%j.out
#SBATCH --error=<PROJECT_DIR>/logs/%x_%j.err

set -euo pipefail

echo "job_id=$SLURM_JOB_ID"
echo "node=$SLURMD_NODENAME"
hostname
date
```

Before submitting, ensure the log directory exists:

```bash
mkdir -p <PROJECT_DIR>/logs
sbatch hello_slurm.sbatch
```

## 23. Handover Checklist

When handing this server over to another user, document:

- Account and authentication method
- VPN or campus network requirements
- Whether the SSH alias is configured
- Actual project paths
- Currently active jobs
- Important data locations
- Important checkpoint locations
- Common sbatch script locations
- Python, conda, pixi, venv, or module setup
- Which directories are safe to clean
- Result syncing and backup workflow

## 24. Quick Reference

```bash
# Login
ssh aire

# Enter a project
cd <PROJECT_DIR>

# Partitions
sinfo
sinfo -o "%20P %8a %8D %10t %12G %8c %10m"

# Submit
sbatch jobs/my_job.sbatch

# Your jobs
squeue -u "$USER"

# Job details
scontrol show job <JOBID>

# History
sacct -j <JOBID>

# Modules
module avail
module load pytorch/2.5.1

# Logs
tail -f logs/<job_name>_<job_id>.out

# Cancel, carefully
scancel <JOBID>
```
