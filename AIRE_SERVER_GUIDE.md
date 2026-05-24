# AIRE 服务器使用说明

本文档记录 AIRE 服务器的连接方式、Slurm 作业系统、分区资源、常用命令和推荐使用流程，方便后续使用者接手。

信息基于 2026-05-20 的只读检查结果整理。服务器资源状态、模块版本、分区限制和 QOS 策略可能会随管理员调整而变化，使用前建议用本文中的只读命令再确认一次。

## 1. 基本概况

AIRE 是通过 Slurm 调度系统使用的集群服务器。不要直接在登录节点长时间跑训练、评估、并行计算或大内存任务；正式计算应通过 `sbatch` 提交到计算节点。

本机 SSH 配置中已有 `aire` 主机别名：

```sshconfig
Host aire
    HostName aire.leeds.ac.uk
    User <your-username>
    ProxyJump rash
```

也就是说，本地连接 `aire` 时会先经过跳板机 `rash`。

已确认的远端信息：

```text
登录节点: login4.aire.lee.alces.network
用户: <your-username>
默认目录: /users/<your-username>
用户 scratch 根目录: 通常为 /mnt/scratch/<username>
```

对当前 SSH 配置里的 `<your-username>` 用户，scratch 根目录是 `/mnt/scratch/<your-username>`。不同用户或不同项目不应复用某个固定项目路径，应先确认自己的目录规划。

本文档中的 `<PROJECT_DIR>`、`<JOBID>`、`<project_name>` 是占位符，使用时需要替换成实际路径、作业号或项目名。

## 2. 登录服务器

从本地终端登录：

```bash
ssh aire
```

执行一次性只读命令：

```bash
ssh aire 'hostname; whoami; pwd; date'
```

如果连接失败，优先检查：

```bash
ssh rash 'hostname'
ssh -vv aire
```

这里 `rash` 是跳板机。因为当前 SSH 配置使用密码或 keyboard-interactive 认证，可能会提示输入 Leeds 账号密码或多因素认证。

## 3. 登录节点使用原则

登录节点适合做轻量操作：

- 编辑脚本
- 查看日志
- 提交 Slurm 作业
- 查看队列状态
- 少量文件管理
- 很短的小命令测试

不要在登录节点做这些事：

- 直接运行训练任务
- 长时间运行 Python 评估脚本
- 大规模数据预处理
- 多进程 CPU 任务
- GPU 任务
- 大内存任务

正式计算统一写成 `sbatch` 脚本提交。

## 4. 文件系统和目录建议

常见路径：

```text
/users/<username>
/mnt/scratch/<username>
```

`/users/<username>` 是 home 目录，适合放配置、轻量脚本、小文件。
`/mnt/scratch/<username>` 是用户 scratch 空间，适合放项目代码、数据、中间结果、模型输出、日志和检查点。

不同项目可以放在 scratch 下不同路径，例如：

```text
/mnt/scratch/<username>/projects/<project_name>
/mnt/scratch/<username>/<project_name>
/mnt/scratch/<username>/work/<project_name>
```

推荐每个项目内部保持类似结构：

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

建议：

- 大文件、训练数据、checkpoint、评估结果放 scratch。
- home 目录只放小文件和配置。
- 输出日志建议统一放到项目内 `logs/` 或 `reports/.../`。
- 作业脚本建议放 `jobs/` 或对应实验目录。
- 重要结果需要定期备份到本地或更稳定的存储。

查看磁盘空间：

```bash
df -h "$HOME"
df -h /mnt/scratch/"$USER"
du -sh <PROJECT_DIR>
```

## 5. Slurm 命令概览

已确认可用的 Slurm 命令：

```text
sbatch
srun
sinfo
squeue
sacct
```

常用命令：

```bash
# 查看分区概况
sinfo

# 用更清晰的格式查看分区、节点、GPU、CPU、内存
sinfo -o "%20P %8a %8D %10t %12G %8c %10m %20f"

# 查看自己的队列
squeue -u "$USER"

# 查看自己的队列，带时间限制和节点原因
squeue -u "$USER" -o "%.18i %.9P %.24j %.2t %.10M %.10l %.6D %R"

# 查看某个作业详细信息
scontrol show job <JOBID>

# 查看历史作业记录
sacct -j <JOBID> --format=JobID,JobName,Partition,State,Elapsed,Timelimit,AllocCPUS,ReqMem,NNodes,NodeList

# 取消作业。谨慎使用
scancel <JOBID>
```

## 6. 分区资源

2026-05-20 只读检查时看到的分区如下。

| 分区 | 用途 | 节点数量 | 单节点 CPU | 单节点内存 | GPU | 最长时间 |
| --- | --- | ---: | ---: | ---: | --- | --- |
| `nodes` | 默认 CPU 分区 | 52 | 168 | 约 755 GiB | 无 | 2 天 |
| `gpu` | GPU 作业 | 28 | 24 | 约 250 GiB | 每节点 3 张 L40S | 2 天 |
| `himem` | 高内存 CPU 作业 | 2 | 168 | 约 2.3 TiB | 无 | 2 天 |
| `teachingnodes` | 教学分区 | 11 | 168 | 约 755 GiB | 无 | 8 小时 |

默认分区是 `nodes`。GPU 作业必须显式指定 `--partition=gpu` 和 GPU 资源。

### 6.1 CPU 分区 `nodes`

适合：

- CPU 训练或评估
- 数据预处理
- 多线程数值计算
- 不需要 GPU 的批处理任务

已看到配置：

```text
PartitionName=nodes
Nodes=node[001-052]
TotalNodes=52
TotalCPUs=8736
MaxTime=2-00:00:00
QoS=nodeslimits
```

QOS 限制检查结果：

```text
nodeslimits: cpu=1024,mem=4601G
```

### 6.2 GPU 分区 `gpu`

适合：

- PyTorch / CUDA 训练
- GPU 推理
- GPU 加速评估

已看到配置：

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

单个 GPU 节点示例：

```text
NodeName=gpu001
CPUTot=24
RealMemory=256656M
Gres=gpu:l40s:3
```

QOS 限制检查结果：

```text
gpulimits: cpu=120,gres/gpu=15
```

提交 GPU 作业时常见资源写法：

```bash
#SBATCH --partition=gpu
#SBATCH --gres=gpu:1
#SBATCH --cpus-per-task=4
#SBATCH --mem=80G
```

如果需要多 GPU，例如单节点 2 张卡：

```bash
#SBATCH --partition=gpu
#SBATCH --gres=gpu:2
#SBATCH --cpus-per-task=8
#SBATCH --mem=160G
```

不要申请远超实际需要的 GPU、CPU 或内存，否则会增加排队时间，也会占用团队配额。

### 6.3 高内存分区 `himem`

适合：

- 超大矩阵
- 大规模数据预处理
- 大内存 CPU 推理或评估
- 普通 `nodes` 分区内存不够的任务

已看到配置：

```text
PartitionName=himem
Nodes=himem[01-02]
TotalNodes=2
TotalCPUs=336
MaxTime=2-00:00:00
```

单个 himem 节点示例：

```text
NodeName=himem01
CPUTot=168
RealMemory=2321256M
```

使用时显式指定：

```bash
#SBATCH --partition=himem
#SBATCH --cpus-per-task=32
#SBATCH --mem=500G
```

### 6.4 教学分区 `teachingnodes`

适合课程或教学账号相关任务。已看到最长运行时间为 8 小时：

```text
PartitionName=teachingnodes
MaxTime=08:00:00
QoS=teaching_qos
```

QOS 限制检查结果：

```text
teaching_qos:
  MaxWall=08:00:00
  MaxTRESPU=cpu=8
  MaxJobsPU=15
  MaxSubmitPU=30
```

如果不是教学任务，通常不使用这个分区。

## 7. 模块环境

服务器使用 environment modules。已确认：

```bash
module --version
# Modules Release 5.3.0
```

查看模块：

```bash
module avail
module spider pytorch
module list
```

常见模块包括：

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

推荐在作业脚本中明确清空并加载模块：

```bash
module purge
module load pytorch/2.5.1
```

不要依赖交互 shell 里偶然加载过的模块。每个 `sbatch` 脚本都应该自包含地声明运行环境。

## 8. sbatch 脚本基本结构

一个作业脚本通常包含：

1. shebang
2. `#SBATCH` 资源声明
3. `set -euo pipefail`
4. 进入项目目录
5. 加载模块或激活环境
6. 设置环境变量
7. 执行实际命令

通用模板：

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

提交：

```bash
sbatch jobs/my_job.sbatch
```

查看：

```bash
squeue -u "$USER"
```

## 9. GPU 作业模板

适用于单卡 PyTorch 任务：

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

GPU 脚本中至少应包含类似资源声明：

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

## 10. CPU 作业模板

适用于普通 CPU 任务：

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

## 11. 高内存作业模板

适用于普通节点内存不够的任务：

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

## 12. 交互式调试

短时间调试可以用 `srun` 申请交互资源。不要在登录节点直接跑实际计算。

CPU 交互 shell：

```bash
srun --partition=nodes --time=00:30:00 --cpus-per-task=4 --mem=16G --pty bash
```

GPU 交互 shell：

```bash
srun --partition=gpu --gres=gpu:1 --time=00:30:00 --cpus-per-task=4 --mem=32G --pty bash
```

进入交互节点后再加载模块：

```bash
module purge
module load pytorch/2.5.1
python -c 'import torch; print(torch.cuda.is_available()); print(torch.cuda.get_device_name(0) if torch.cuda.is_available() else "no cuda")'
```

交互调试完成后退出 shell：

```bash
exit
```

## 13. 日志管理

推荐所有作业设置：

```bash
#SBATCH --output=<PROJECT_DIR>/logs/%x_%j.out
#SBATCH --error=<PROJECT_DIR>/logs/%x_%j.err
```

其中：

- `%x` 是 job name
- `%j` 是 job id

查看日志：

```bash
tail -n 100 logs/my_job_123456.out
tail -f logs/my_job_123456.out
tail -n 100 logs/my_job_123456.err
```

如果日志写在其他实验目录，也可以按 job id 查找：

```bash
find <PROJECT_DIR> -name "*<JOBID>*.out" -o -name "*<JOBID>*.err"
```

## 14. 检查现有作业

接手服务器时，不要假设当前没有任务在跑。先查看自己的作业：

```bash
squeue -u "$USER" -o "%.18i %.9P %.24j %.2t %.10M %.10l %.6D %R"
```

对某个作业查看详细信息：

```bash
scontrol show job <JOBID>
```

重点关注：

- `Partition`：作业跑在哪个分区。
- `NodeList` 和 `BatchHost`：实际运行节点。
- `ReqTRES` 和 `AllocTRES`：请求和分配的 CPU、内存、GPU。
- `Command`：提交的 sbatch 脚本。
- `WorkDir`：提交时的工作目录。
- `StdOut` 和 `StdErr`：标准输出和错误日志路径。

如果不是自己明确要管理的作业，不要取消或改动。

## 15. Python 和环境

系统默认 Python 检查结果：

```text
/usr/bin/python
/usr/bin/python3
Python 3.9.18
```

模块中还有：

```text
python/3.13.0
miniforge/24.7.1
pytorch/2.5.1
pixi/0.41.4
```

推荐方式：

- 优先沿用项目已有作业脚本中的模块和环境配置。
- 如果项目有自己的 conda、pixi 或 venv 环境，写在 `sbatch` 脚本中显式激活。
- 始终设置 `PYTHONPATH` 指向项目根目录，避免 import 找不到本地包。

常见环境变量：

```bash
export PYTHONPATH="$PROJECT:${PYTHONPATH:-}"
export PYTHONNOUSERSITE=1
export OMP_NUM_THREADS="${SLURM_CPUS_PER_TASK:-1}"
```

## 16. 从本地同步文件

从本地传到服务器：

```bash
rsync -avP ./local_dir/ aire:<PROJECT_DIR>/local_dir/
```

从服务器拉回本地：

```bash
rsync -avP aire:<PROJECT_DIR>/reports/ ./reports/
```

同步单个文件：

```bash
scp my_script.py aire:<PROJECT_DIR>/tools/
scp aire:<PROJECT_DIR>/logs/job.out ./
```

建议：

- 大目录优先用 `rsync -avP`，可以断点续传。
- 不要频繁同步 `.git/`、缓存、临时文件、巨大 checkpoint。
- 可以使用 `--exclude` 排除无关文件。

示例：

```bash
rsync -avP \
  --exclude .git \
  --exclude __pycache__ \
  --exclude "*.pyc" \
  ./ \
  aire:<PROJECT_DIR>/
```

## 17. 推荐工作流

典型开发和运行流程：

1. 在本地或服务器项目目录中修改代码。
2. 准备 `sbatch` 脚本，明确分区、时间、CPU、内存、GPU 和日志路径。
3. 在登录节点提交：

   ```bash
   sbatch jobs/my_job.sbatch
   ```

4. 查看排队和运行状态：

   ```bash
   squeue -u "$USER"
   scontrol show job <JOBID>
   ```

5. 查看日志：

   ```bash
   tail -f logs/my_job_<JOBID>.out
   tail -f logs/my_job_<JOBID>.err
   ```

6. 任务结束后检查状态：

   ```bash
   sacct -j <JOBID> --format=JobID,JobName,State,ExitCode,Elapsed,MaxRSS,AllocCPUS,ReqMem
   ```

7. 把重要结果同步回本地或备份位置。

## 18. 资源申请建议

资源申请要从小到大逐步试：

- 快速 smoke test：`time=00:10:00`，小 CPU/GPU/内存。
- 正式小任务：按实际需要申请，例如 `gpu:1`, `cpus=4`, `mem=32G-80G`。
- 大任务：先根据小任务日志估算资源，再扩大。

GPU 作业建议：

- 单卡任务先申请 `--gres=gpu:1`。
- CPU 数量通常按 dataloader、预处理和 IO 需求设定，例如 4 或 8。
- 内存不确定时先看历史脚本。当前示例单卡任务申请了 80G。
- 多卡任务要确认代码真的支持多 GPU，否则申请多卡只会浪费资源。

CPU 作业建议：

- 明确设置 `--cpus-per-task`。
- 对 NumPy、OpenMP、PyTorch CPU 任务设置 `OMP_NUM_THREADS`。
- 大内存任务不要盲目在 `nodes` 分区跑，必要时使用 `himem`。

时间建议：

- 分区最长时间不代表每个任务都应该申请最长时间。
- 时间申请越合理，越利于调度器安排。
- 如果任务会超过 2 天，需要改造为 checkpoint/resume 或拆分任务。

## 19. 常见问题排查

### 19.1 作业一直排队

查看原因：

```bash
squeue -u "$USER" -o "%.18i %.9P %.24j %.2t %.10M %.10l %.6D %R"
scontrol show job <JOBID>
```

常见原因：

- 请求 GPU 太多
- 请求内存太大
- 请求时间太长
- QOS 或账号配额限制
- 分区资源繁忙
- 节点维护

### 19.2 Python 找不到本地包

在脚本里设置：

```bash
PROJECT=<PROJECT_DIR>
cd "$PROJECT"
export PYTHONPATH="$PROJECT:${PYTHONPATH:-}"
```

### 19.3 CUDA 不可用

确认作业提交到了 GPU 分区并申请了 GPU：

```bash
#SBATCH --partition=gpu
#SBATCH --gres=gpu:1
```

在作业脚本中打印：

```bash
python - <<'PY'
import torch
print(torch.cuda.is_available())
print(torch.cuda.get_device_name(0) if torch.cuda.is_available() else "no cuda")
PY
```

### 19.4 作业 OOM 或被杀

检查：

```bash
sacct -j <JOBID> --format=JobID,State,ExitCode,Elapsed,MaxRSS,ReqMem,AllocCPUS
tail -n 200 <error-log>
```

处理：

- 增加 `--mem`
- 减小 batch size
- 减少 dataloader workers
- 分块处理数据
- 如果确实需要大内存，改用 `himem`

### 19.5 日志没有输出

检查：

- `#SBATCH --output` 路径是否存在
- `#SBATCH --error` 路径是否存在
- 作业是否还没开始运行
- 脚本是否在很早阶段失败

建议在脚本开头加：

```bash
echo "job_id=$SLURM_JOB_ID"
echo "node=$SLURMD_NODENAME"
echo "workdir=$(pwd)"
date
```

## 20. 只读检查命令清单

接手服务器时，可以先运行这些只读命令了解状态：

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

## 21. 操作安全注意事项

谨慎操作：

- `rm -rf`
- `mv` 覆盖目录
- `rsync --delete`
- `scancel`
- 修改 `.bashrc`
- 修改共享环境
- 删除 `runs/`、`logs/`、`reports/`、`checkpoints/`

建议：

- 删除前先 `ls` 或 `find` 确认范围。
- 大规模删除前先移动到临时目录观察。
- 不确定的作业不要取消。
- 不确定的旧结果不要覆盖。
- 运行新实验时用新的 job name 和输出目录。

## 22. 最小可用 sbatch 示例

如果只是验证 Slurm 能否工作，可以提交一个很短的 CPU 作业：

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

提交前确保日志目录存在：

```bash
mkdir -p <PROJECT_DIR>/logs
sbatch hello_slurm.sbatch
```

## 23. 交接时应说明的信息

交接给新使用者时，建议同时说明：

- 账号和认证方式
- 是否有 VPN 或校园网络要求
- SSH 别名是否已经配置
- 项目实际路径
- 当前活跃作业
- 重要数据位置
- 重要 checkpoint 位置
- 常用 sbatch 脚本位置
- 使用的 Python/conda/pixi/module 环境
- 哪些目录可以清理，哪些不能动
- 结果同步和备份方式

## 24. 快速参考

```bash
# 登录
ssh aire

# 进入某个项目
cd <PROJECT_DIR>

# 分区
sinfo
sinfo -o "%20P %8a %8D %10t %12G %8c %10m"

# 提交
sbatch jobs/my_job.sbatch

# 查看自己的作业
squeue -u "$USER"

# 查看作业详情
scontrol show job <JOBID>

# 查看历史
sacct -j <JOBID>

# 查看模块
module avail
module load pytorch/2.5.1

# 查看日志
tail -f logs/<job_name>_<job_id>.out

# 取消作业，谨慎
scancel <JOBID>
```
