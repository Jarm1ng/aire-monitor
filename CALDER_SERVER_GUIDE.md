# Calder 服务器使用说明

本文档记录 Calder 集群的连接方式、存储与配额、Slurm 分区资源、模块环境、作业模板和从 AIRE 迁移的要点，与 [AIRE_SERVER_GUIDE.md](AIRE_SERVER_GUIDE.md) 配套阅读。两套集群通用的做法（项目目录结构、日志管理、同步、安全操作习惯等）不在这里重复，请直接参考 AIRE 文档的对应章节。

信息基于 2026-10-12（Calder 开放首日）和 2026-11-11 两次只读检查以及当时的官方文档整理。标注“2026-10-12 实测”或“2026-11-11 实测”的内容来自登录节点上的只读命令（`sinfo`、`scontrol`、`sacctmgr`、`module`、`lfs` 等），没有提交作业、没有进入计算节点。Calder 的配置仍在变化：2026-11-11 所有分区都改了名，默认分区也换成了节点全部 drain 的 `cpu_genoa`（见第 7.1 节），官方文档还没有跟上。使用前建议用本文中的只读命令再确认一次。

本文档中的 `<username>`、`<PROJECT_DIR>`、`<JOBID>`、`<project-id>`、`<env_name>` 是占位符，使用时替换成自己的用户名、项目路径、作业号、Lustre project id 或 Conda 环境名。

## 1. 基本概况

Calder 是 University of Leeds 新增的共享高性能计算集群，2026-10-12（周一）向研究人员开放，与 AIRE 并行提供 CPU、GPU 和存储资源。系统由 MTI 中标、采用 Dell 硬件，并有 Cambridge Research Computing 提供服务支持；使用中遇到问题仍通过 Leeds Research Computing 处理。

Calder 是一套**独立**的集群：有自己的登录节点、自己的 Slurm 控制器（Slurm 24.11.5，2026-10-12 和 2026-11-11 实测相同；AIRE 为 24.05.3）和自己的 Scratch/Flash 文件系统。作业在哪个集群的登录节点提交，就由哪个集群调度；查看 Calder 作业要在 Calder 上运行 `squeue`，在一个集群上运行 `sinfo` 也看不到另一个集群的节点。两者共享的只有大学账号和 `/users` 下的 Home 目录。

2026-11-11 实测：Calder 控制器的 `scontrol show config` 报告 `ClusterName = aire`（AIRE 自己的控制器仍是 `aire.lee.alces.network`），Calder 的调度器上还有由 AIRE 同代硬件组成的分区 `cpu_genoa` 和 `gpu_lovelace`（见第 7.1 节）。两者仍是两套独立的调度器，各自需要单独的 SSH 会话。这些现象看起来与官方宣布的 Aire 2.0 升级有关，但官方没有任何说明，这里只是观察，不是确定的事实。

和 AIRE 一样，不要在登录节点上长时间跑训练、评估、并行计算或大内存任务；正式计算应通过 `sbatch` 提交到计算节点。

官方资料入口：

- [上线公告](https://arc.leeds.ac.uk/knowledge-centre/calder-opens-to-researchers-at-the-university-of-leeds/)
- [Calder 文档主页](https://arcdocs.leeds.ac.uk/calder/welcome.html)
- [系统总览](https://arcdocs.leeds.ac.uk/calder/system/start.html)、[集群架构](https://arcdocs.leeds.ac.uk/calder/system/hpc_architecture.html)

## 2. 硬件对比

下表为官方公布规格（GB/TB 沿用官方十进制写法；Linux 和 Slurm 常用二进制单位，数字对不上时先换算再比较）。来源：[节点规格](https://arcdocs.leeds.ac.uk/calder/system/node_types.html)、[比较 FAQ](https://arcdocs.leeds.ac.uk/calder/getting_started/faq.html)；2026-11-11 复查时这两个页面上的节点数和 GPU 数没有变化。Slurm 实际列出的 Calder 节点数与官方不同，表中一并注明日期。

| 项目 | AIRE | Calder |
| --- | --- | --- |
| CPU 节点核心总数 | 9,072 | 12,288（按官方 96 台计） |
| 标准 CPU 节点 | 52 台，每台 168 核 | 官方 96 台，每台 128 核；Slurm 登记 98 台（2026-10-12 实测）、95 台（2026-11-11 实测） |
| 标准 CPU 处理器 | 2 × AMD EPYC 9634 | 2 × AMD EPYC 9555 |
| 标准 CPU 节点内存 | 768 GB | 768 GB |
| 独立高内存节点 | 2 台，每台约 2.3 TB | 无 |
| GPU 节点 | 28 台，每台 3 张卡 | 官方 7 台，每台 8 张卡；2026-11-11 实测 Slurm 只列出 6 台 |
| GPU 型号和总数 | 84 × NVIDIA L40S | 官方 56 × NVIDIA H200 NVL；2026-11-11 实测 Slurm 中为 48 张 |
| 单卡显存 | 48 GB GDDR6 | 141 GB HBM3e |
| GPU 节点 CPU | EPYC 9254，每台 24 核 | 2 × EPYC 9555，每台 128 核 |
| GPU 节点系统内存 | 256 GB | 1.5 TB |
| GPU 节点本地存储 | 2 × 480 GB M.2 | 6.4 TB E3.S NVMe |
| 节点间网络 | Omni-Path | NDR InfiniBand（400 Gb/s） |
| GPU 节点内连接 | PCIe | 官方写为 NVLink 4-way bridges |
| Lustre Scratch 标称容量 | 3.7 PB | 约 6.3 PB |
| NVMe Lustre Flash 标称容量 | 139 TB | 约 246 TB |

理解这张表时注意：

- H200 单卡显存约为 L40S 的 2.9 倍，这不是训练速度倍数；实际速度还取决于模型、精度、数据加载、存储和多卡通信。
- 141 GB 是单卡显存，1.5 TB 是 GPU 节点的系统内存；多张卡的显存不会自动合成一个内存池。
- “4-way NVLink bridges”不等于 8 张卡完全互联，八卡拓扑和跨节点性能截至 2026-10-12 尚未实测。
- Calder 的官方数字与 Slurm 列出的数量不一致，原因没有公布；实际可用的资源以当时的 `sinfo` 为准（见第 7.1 节）。
- 2026-11-11 实测 Calder 的调度器上还有 AIRE 同代的节点：`cpu_genoa`（8 台 Genoa CPU 节点）和 `gpu_lovelace`（1 台 L40 节点），当时全部处于 drain 状态，不在上表的 Calder 官方规格里。
- Calder 没有独立的高内存分区。单节点内存（2026-11-11 Slurm 登记约 717 GiB）不够时，AIRE 的 `himem` 仍是选项。

适合放到 Calder 的典型工作：显存需求大的深度学习、三维视觉、医学影像，以及多节点 CPU 模拟。少量串行任务、已有成熟 AIRE 环境的项目、需要大内存 CPU 节点的程序，继续留在 AIRE 也可以。以代表性任务的正确性、耗时和资源需求为准来选择。

## 3. 账号

- 已有 AIRE HPC 账号的用户**自动覆盖 Calder**，不需要另外申请。用户名、密码和 Duo 与 AIRE 相同。
- Home 目录 `/users/<username>` 在两个集群上是同一个目录（见第 6 节）。Scratch 数据**不会**自动迁移到 Calder。
- 新用户通过 [HPC Account form](https://it.leeds.ac.uk/it?id=sc_cat_item&sys_id=4c002dd70f235f00a82247ece1050ebc) 申请。学术人员、博士后和研究型研究生可以直接申请；本科和授课型硕士学生需要导师支持。账号不可共享。参见 [账号说明](https://arcdocs.leeds.ac.uk/calder/getting_started/request_account.html)。
- 在 Calder 上用 `sacctmgr` 查看自己的账号关联，集群名显示为 `aire`、account 为 `default`、QoS 为 `normal`（2026-10-12 和 2026-11-11 实测相同）；2026-11-11 实测 Calder 控制器本身也报告 `ClusterName = aire`。实际登录节点和分区确实是 Calder 的，不必因此怀疑连错了集群：AIRE 的控制器报告的是 `aire.lee.alces.network`，两边仍是独立的调度器（见第 1 节）。`normal` 的限额字段是空的，但这不代表没有限制，GPU 分区另有分区 QoS（见第 7.2 节）。

## 4. 连接 Calder

### 4.1 连接信息

| 项目 | 值 |
| --- | --- |
| 登录域名 | `calder.leeds.ac.uk` |
| SSH 跳板机 | `rash.leeds.ac.uk`（与 AIRE 共用） |
| 认证方式 | 大学账号密码 + Duo（keyboard-interactive） |
| 公钥登录 | 官方明确**不支持**用户 SSH 公钥 |
| 登录节点 | `calder-login-*`，域名通过 DNS 轮询分配到多个登录节点（2026-11-17 `calder-login-1`、`calder-login-2` 维护，见第 5 节） |

参考：[Logging on](https://arcdocs.leeds.ac.uk/calder/getting_started/logging_on.html)、IT 知识库 [How to Connect to HPC](https://it.leeds.ac.uk/it?id=kb_article_view&sysparm_article=KB0019686)（需大学账号登录）。

### 4.2 选择路线

- **校内有线网络**：直连 `calder.leeds.ac.uk`，一次密码 + Duo。
- **校外或 Eduroam**：IT 知识库要求关闭 VPN、经 `rash.leeds.ac.uk` 跳板连接。新连接通常要先后完成 rash 和 Calder 两次密码 + Duo。
- **大学 VPN**：公开的 Logging on 页面仍写校外可以用 VPN 或跳板机，与 IT 知识库的说法不一致。2026-10-12 实测：在连着大学 VPN 的 Mac 上直连 Calder 成功。这只说明当时那条路径可用，VPN 直连失败时改用 rash 路线。

### 4.3 SSH 配置示例

`config/aire_ssh_config.example` 已经包含 AIRE 和 Calder 的 Host 块，下面的 `calder`、`rash` 块与其中的选项完全相同（示例文件里用户名占位符写作 `<your-username>`），可以直接加入 `~/.ssh/config`（不要把填入真实用户名的副本提交到仓库）。唯一的区别是 `calder-jump`：示例文件默认写 `ProxyJump %r@rash.leeds.ac.uk`，这里用的是示例文件注释中给出的 `ProxyJump rash` 写法，原因见下面的说明。如果还没有控制套接字目录，先创建：

```bash
mkdir -m 700 ~/.ssh/ctl
```

直连路线（校内网络或 VPN）：

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

跳板路线（校外，经 rash）需要一个 `Host rash` 块。按 AIRE 示例配置过的可以直接复用，没有的话加上：

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

说明：

- `NumberOfPasswordPrompts 1` 是有意设置的：密码输错立即失败，而不是反复重发，避免触发大学身份系统的账号锁定。
- `ControlMaster` + `ControlPersist 24h` 让认证过的连接被后续 `ssh`、`scp`、`rsync` 复用，24 小时内通常不必再走一次 Duo。
- `ProxyJump rash` 让跳板这一段也使用 `Host rash` 块的设置（包括 `NumberOfPasswordPrompts 1` 和控制连接），已有的 rash 连接会被复用；AIRE 的跳板别名也写成 `ProxyJump rash` 时，两个集群可以共用一次 rash 认证。写成 `ProxyJump %r@rash.leeds.ac.uk` 时主机名匹配不到 `Host rash`，这些设置不会生效。
- Host 块的顺序有影响：OpenSSH 多数选项取第一次匹配到的值，具体的 Host 块应放在 `Host *` 这类通配规则之前。

### 4.4 登录和验证

```bash
ssh calder
ssh calder 'hostname; whoami; pwd; date'
```

预期主机名为 `calder-login-*`，当前目录为 `/users/<username>`。以 `hostname` 的输出确认真正登录成功，不要用“端口能连上”或“看到 SSH banner”代替。

不在校内网络时：

```bash
ssh rash 'hostname'
ssh calder-jump 'hostname'
```

### 4.5 主机密钥指纹

首次连接时 SSH 会要求确认主机密钥。本仓库不收录主机密钥指纹（实测值可能随服务器更换而过期）：请对照学校官方渠道核对，或在可信网络下完成第一次连接。Calder 与 AIRE 是不同主机，各自在 `known_hosts` 中有独立记录，无需删除 AIRE 的记录。之后如果出现指纹不一致或 `REMOTE HOST IDENTIFICATION HAS CHANGED` 告警，先核对学校说明或联系管理员。不要关闭主机密钥校验，不要清空整个 `known_hosts`；确认密钥确实更换后，只删除对应主机的记录（`ssh-keygen -R calder.leeds.ac.uk`）。

查看本机已记录的指纹：

```bash
ssh-keygen -l -F calder.leeds.ac.uk
```

### 4.6 已知现象：认证前断开或 “Not allowed at this time”

2026-10-12 实测：`calder.leeds.ac.uk` 通过 DNS 轮询指向多个登录节点，其中某个节点有时在认证**之前**就关闭连接，或者输出 `Not allowed at this time` 后断开；稍后再连又恢复正常。

- 这**不是**密码错误，也不能说明 Calder 未开放，因为此时密码还没有发送。
- 等一两分钟再连接即可，不要密集循环重试。
- 长期配置保留域名，不要把某个登录节点 IP 写死。
- 反复出现时，记录时间、使用的路线和原始错误，联系 Research Computing。

有限诊断（带超时，只试一次）：

```bash
host calder.leeds.ac.uk
ssh -v -o ConnectTimeout=8 -o ConnectionAttempts=1 calder
```

确需区分是哪个登录节点出问题时，可以临时指定 DNS 当前返回的某个地址，同时继续用域名校验主机密钥：

```bash
ssh -o HostName=<login-node-ip> \
    -o HostKeyAlias=calder.leeds.ac.uk \
    -o StrictHostKeyChecking=yes \
    -o ConnectTimeout=8 \
    -o ConnectionAttempts=1 \
    calder
```

### 4.7 其他连接注意事项

- `ssh -o BatchMode=yes` 会禁止交互认证，在没有可复用的控制连接时一定会报 `Permission denied`，这不代表密码错误或账号不可用。
- 非交互 SSH（`ssh calder '命令'`）里可能没有 `module` 命令，见第 8 节。
- 需要远程图形程序时，IT 知识库给出 `ssh -X calder` 的 X11 转发方式，本机需要可用的 X server。

## 5. 登录节点使用原则

2026-10-12 实测的一台登录节点：Rocky Linux 9.8，2 × AMD EPYC 9335（共 64 核），约 754 GiB 内存，默认 Shell 为 Bash 5.1，系统 Python 为 3.9。登录节点由所有用户共享。

> **注意**（2026-11-11 登录节点 `/etc/motd` 公告）：`calder-login-1` 和 `calder-login-2` 计划在 2026-11-17（周二）15:00–17:00 重启维护，这两台上的会话届时都会被终止，公告建议改用 `calder-login-3` 或 `calder-login-4`。`calder.leeds.ac.uk` 可能分配到任意一台登录节点，登录后用 `hostname` 确认自己在哪一台；留在 login-1/2 上的长时间会话（tmux 会话、SSH 控制连接等）会在当天 15:00 结束，之后重新连接需要再认证一次。公告写的时区是 BST，而 11 月英国已改用 GMT，对具体时间有疑问时向 Research Computing 确认。

登录节点适合做轻量操作：

- 编辑脚本、查看日志
- 提交 Slurm 作业、查看队列
- 少量文件管理和数据传输
- 很短的小命令测试

不要在登录节点做这些事：

- 直接运行训练、评估或长时间的 Python 脚本
- 大规模数据预处理、多进程 CPU 任务、大内存任务
- GPU 相关测试（登录节点上的 CUDA 检查不能代替 H200 上的验证）
- 不限并行度的编译（编译 CUDA 扩展等时设置 `MAX_JOBS` 之类的并行上限）

学校要求合理使用共享资源，管理员可以结束干扰系统或其他用户的进程。正式计算统一写成 `sbatch` 脚本提交。

## 6. 文件系统和目录建议

2026-10-12 实测的个人目录：

```text
/users/<username>                     Home，AIRE 与 Calder 共享
/scratch-calder/users/<username>      Calder 磁盘 Lustre Scratch
/flash-calder/users/<username>        Calder NVMe Lustre Flash 个人目录
```

注意路径中有 `users` 这一层。部分官方页面的示例写作 `/scratch-calder/<username>`，以自己账号实际存在的目录为准：

```bash
ls -ld /users/"$USER" /scratch-calder/users/"$USER" /flash-calder/users/"$USER"
```

### 6.1 各区域的用途

| 区域 | 用途 | 备份与清理 |
| --- | --- | --- |
| Home `/users/<username>` | 配置、脚本、Conda 环境等小文件；**与 AIRE 共享**，配额 65 GiB | 官方说明有备份；频率和保留期未查明 |
| Scratch `/scratch-calder/users/<username>` | 项目代码、数据集、训练输出、checkpoint、日志 | **无备份**；遵守配额和清理政策 |
| Flash `/flash-calder/users/<username>` | 已确认存在且可写的个人 NVMe 目录 | 保留和清理政策尚未确认，不要当作长期存储 |
| 作业期临时目录（`$TMP_SHARED`、`$TMP_LOCAL` 等） | 作业期间的 I/O 密集临时数据 | 按官方说明作业结束即清理，重要输出要在作业内及时保存 |

Home 共享带来的影响：

- `/users/<username>` 在 AIRE 和 Calder 上是同一个 NFS 目录、同一个 65 GiB 配额，用 `quota -s` 在任一集群上查看到的是同一份用量。
- 修改 `.bashrc`、`.bash_profile`、`.condarc`，升级或删除 Home 里的 Conda 环境，会同时影响两个集群。给 Calder 建单独的环境（见第 8 节），不要直接升级 AIRE 正在使用的环境。

关于 `$SCRATCH`：2026-10-12 实测登录节点上 `$SCRATCH` 未设置，加载 `calder/cpu` 或 `calder/hopper` 后仍未设置；2026-11-11 复查，登录节点上 `$SCRATCH` 和 `$FLASH` 仍未设置。官方 [Storage Options](https://arcdocs.leeds.ac.uk/calder/usage/file_management/storage_options.html) 说明 `$SCRATCH` 和 `$TMP_SHARED` 在作业中设置，但截至 2026-10-12 尚未用作业验证。脚本里写明完整路径，不要依赖这个变量。

项目目录建议和 AIRE 相同（参见 AIRE 文档第 4 节），例如：

```text
/scratch-calder/users/<username>/projects/<project_name>
```

### 6.2 配额查询

Home 是 NFS 配额：

```bash
quota -s
```

Calder 的 Scratch 和 Flash 使用 **Lustre project 配额**，按目录上的 project id 计量，而不是 AIRE 那样的按用户配额。先从自己的目录查出 project id，再查该 project 的配额：

```bash
# 输出的第一列就是 project id
lfs project -d /scratch-calder/users/"$USER"
lfs quota -h -p <project-id> /scratch-calder

lfs project -d /flash-calder/users/"$USER"
lfs quota -h -p <project-id> /flash-calder
```

一次性查看全部配额（就是 Leeds HPC Monitor 内置终端里 Calder 的 “Quota” 快捷命令，这里拆成多行；不存在的目录会被跳过，挂载点取自 `df`）：

```bash
quota -s
for d in /scratch-calder/users/$USER /flash-calder/users/$USER; do
    p=$(lfs project -d "$d" 2>/dev/null | awk '{print $1}')
    [ -n "$p" ] && lfs quota -h -p "$p" "$(df -P "$d" | awk 'NR==2{print $NF}')"
done
```

注意：

- 不要只看 `lfs quota -u "$USER"`：在 Calder 上它可能显示零限额，但这不代表没有限制，真正生效的是 project 配额。
- project id 来自目录本身的元数据，与 Slurm account 名（`default`）无关，每个用户的 id 也不同，不要照抄别人的。
- 空间和文件数（inode）是两种独立的限制。大量小图片、解压后的数据集和 Conda 包可能先耗尽文件数。
- 官方 [配额政策](https://arcdocs.leeds.ac.uk/calder/usage/file_management/filesystem_quotas.html) 给出的通用默认值是每个项目 1 TB、150 万个文件。2026-10-12 实测某账户 Scratch 和 Flash 的空间软/硬限额为 1T/1.1T，文件数硬限额为 100 万，低于官方通用值，规划时以自己 `lfs quota` 的输出为准。
- `df -h /scratch-calder /flash-calder` 显示的是整个文件系统的容量，所有用户共享，不等于个人剩余配额。

申请增加配额需要说明研究用途、目标文件系统、所需空间和文件数、截止日期以及归档清理计划。官方政策把扩容作为临时安排，最长六个月，可再次申请；到期前必须把超出默认配额的数据移走或删除。

## 7. Slurm 和分区资源

Calder 使用独立的 Slurm 控制器，常用命令与 AIRE 相同（`sbatch`、`srun`、`sinfo`、`squeue`、`sacct`、`scontrol`、`scancel`）。分区名、默认分区、GPU 写法和资源规则都与 AIRE 不同，**不能直接复用 AIRE 的 `#SBATCH` 行，也不能省略 `--partition`**。

### 7.1 分区

> **注意**：2026-11-11 起 Calder 的默认分区是 `cpu_genoa`，而它的 8 个节点全部处于 drain 状态（不再接收新作业）。没写 `--partition` 的 `sbatch` 或 `srun` 作业会进入 `cpu_genoa`，一直排队、不会开始；照抄官方 Jobs 页的 CPU 示例也是这样，因为那些示例不写分区。CPU 作业一律写 `--partition=cpu_turin`，GPU 作业写 `--partition=gpu_hopper`。

2026-11-11 实测看到的分区如下（节点数为 Slurm 列出的数量，包含 drain 或已占用的节点；内存为 Slurm 登记值换算）。

| 分区 | 用途 | 节点数量 | 单节点 CPU | 单节点内存 | GPU | 最长时间 |
| --- | --- | ---: | ---: | ---: | --- | --- |
| `cpu_turin` | 标准 CPU 分区（Turin），CPU 作业用这个 | 95 | 128 | 约 717 GiB | 无 | 2 天 |
| `gpu_hopper` | H200 GPU 分区 | 6 | 128 | 约 1.4 TiB | 每节点 8 张 H200（141 GB），共 48 张 | 2 天 |
| `cpu_genoa` | **默认分区**；AIRE 同代的 Genoa CPU 节点，全部 drain | 8 | 168 | 约 717 GiB | 无 | 2 天 |
| `gpu_lovelace` | AIRE 同代的 L40 节点，drain | 1 | 24 | 约 238 GiB | 3 张 L40（`gpu:nvidia_l40:3`） | 2 天 |

分区在 2026-11-11 改了名：`calder-cpu-turin` → `cpu_turin`（旧名是当时的默认分区），`calder-gpu-hopper` → `gpu_hopper`，`aire-cpu-genoa` → `cpu_genoa`，`aire-gpu-lovelace` → `gpu_lovelace`。旧名已经失效，脚本里还写着旧名时 `sbatch` 会报 invalid partition 错误、拒绝提交；遇到这个错误先运行 `sinfo -s` 查看当前的分区名。官方 Jobs 页 2026-11-11 仍写旧名 `calder-gpu-hopper`（见第 14 节），分区名以调度器本身的输出为准。

2026-11-11 实测的节点：

- `cpu_turin`：`calder-cpu[001-090,092-096]`，`calder-cpu091` 未列出。
- `gpu_hopper`：`calder-h200-[01-03,05-07]`，`calder-h200-04` 不再列出；每节点登记 `gpu:nvidia_h200:8`，Slurm 中共 48 张 H200，少于官方规格的 7 台、56 张（见第 2 节）。
- `cpu_genoa`：`node[056-063]`，全部为 `drain`、`drain*` 或 `drain$`。
- `gpu_lovelace`：只有 `gpu028`，状态 `drain*`（drain 原因为 NHC 的内核版本检查）；这台节点在 AIRE 的 `gpu` 分区里也列出，状态为 `down$`。

各分区由 `NodeSets=nodegroup_*` 定义，节点 feature 分别为 `nodegroup_cpu_turin`、`nodegroup_gpu_hopper`、`nodegroup_cpu_genoa`、`nodegroup_gpu_lovelace`。四个分区的最长运行时间都是 `2-00:00:00`（48 小时），超过 48 小时的任务需要改造为 checkpoint/resume 或拆分。

查看分区：

```bash
sinfo -s                      # 当前分区名和节点数，默认分区名后带 *
sinfo -o "%20P %8a %12l %6D %10t %24G %6c %10m"
scontrol show partition cpu_turin
scontrol show partition gpu_hopper
```

### 7.2 资源规则

以下规则来自官方 [Jobs](https://arcdocs.leeds.ac.uk/calder/usage/jobs.html) 页面（2026-11-11 复查）和 2026-11-11 实测的分区、QoS 配置（原始值见第 7.3 节），尚未用实际作业逐条验证：

- `cpu_turin`（官方 Jobs 页称为 Calder 的标准计算分区）每个作业**最少分配 8 核**。纯串行程序也会占用 8 核，可以考虑把多个独立任务合并，或继续在 AIRE 上跑。
- 每个作业都写 `--time`：官方要求始终指定时间限制，2026-11-11 实测各分区也没有设置默认时长（`DefaultTime=NONE`）。
- GPU 写法为 `--gres=gpu:nvidia_h200:N`，N 是**每个节点**的卡数，不是整个作业的总数。`gpu_lovelace` 的 L40 写作 `gpu:nvidia_l40:N`。
- **GPU 和 CPU 上限**：官方 Jobs 页写每个作业、每个用户同时最多 16 张 GPU，最多 2 个节点；2026-11-11 实测 GPU 分区的 QoS `gpulimits` 是每用户、每作业最多 15 张 GPU 和 120 个 CPU 核。两处说法不一致，而且 Calder 的 `AccountingStorageEnforce` 为 `none`，这些 QoS 上限是否真正强制执行也不明确。按每个用户在 GPU 分区同时不超过 15 张 GPU、120 个 CPU 核来规划，两种说法都能满足。这 120 核只计 GPU 分区里的作业，`cpu_turin` 没有分区 QoS。GPU job array 的每个子任务都计入这个上限。
- 没有单独指定 CPU 和内存时，`gpu_hopper` 每张 GPU 默认配 16 核和约 189 GiB 系统内存（2026-11-11 实测 `DefCpuPerGPU=16`、`DefMemPerGPU=193333`）。按这个默认值，合计 8 张卡就是 128 核，已超过 120 核；用 8 张及以上时要显式写更少的 CPU，例如 `--cpus-per-gpu=8`。内存同理：一个节点上 8 张卡的默认内存合计 1546664M，超过节点登记的 1469330M，所以占满一个节点 8 张卡的作业还要写 `--mem` 或 `--mem-per-gpu`（7 张卡时默认值仍放得下）。
- `gpulimits` 还要求至少申请 1 张 GPU（`MinTRES` 为 `gres/gpu=1`）。纯 CPU 作业提交到 `cpu_turin`，不要放进 `gpu_hopper`。
- `--mem` 是每节点系统内存，不是显存；`--mem` 和 `--mem-per-cpu` 不要同时使用。
- `#SBATCH` 行不做 Shell 变量展开，`--output=$SCRATCH/...` 不会生效，写完整路径或使用 `%x`、`%j` 等 Slurm 替换符。

常见 GPU 资源写法：

```bash
#SBATCH --partition=gpu_hopper
#SBATCH --gres=gpu:nvidia_h200:1
#SBATCH --cpus-per-task=16
#SBATCH --mem=128G
```

申请更多 CPU 或 GPU 不会让单线程、单卡代码自动并行；多卡训练需要代码本身支持分布式。不要申请远超实际需要的资源，否则排队更久。

### 7.3 调度配置

`scontrol show config` 的部分内容（2026-11-11 实测；调度和优先级几项与 2026-10-12 相同）：

| 配置项 | 值 | 含义 |
| --- | --- | --- |
| `ClusterName` | `aire` | Calder 控制器报告的集群名；AIRE 的控制器是 `aire.lee.alces.network`，两者仍是独立的调度器（见第 1 节） |
| `SchedulerType` | `sched/backfill` | 启用 backfill 调度（`SchedulerParameters` 为空） |
| `PriorityType` | `priority/multifactor` | 多因素优先级 |
| `PriorityWeightFairShare` | `0` | fairshare 权重为零（2026-10-12 和 2026-11-11 相同；与官方描述不同，见第 14 节）；`Age`、`Assoc`、`JobSize`、`QOS` 的权重也都是 0 |
| `PriorityWeightPartition` | `1000` | 只有分区因素有权重 |
| `PriorityDecayHalfLife`、`PriorityMaxAge` | `7-00:00:00` | 使用量衰减半衰期和等待时间上限都是 7 天 |
| `SelectTypeParameters` | `CR_CORE` | 以 CPU 核为单位分配，同一节点可以同时运行多个作业 |
| `EnforcePartLimits` | `ANY` | 提交时检查分区限制（如 48 小时），超出的作业直接被拒绝 |
| `AccountingStorageEnforce` | `none` | 没有启用关联和 QoS 限额的强制执行，下表的 QoS 上限是否真正生效不明确（AIRE 为 `associations,limits,qos`） |
| `MaxArraySize` | `10001` | job array 最大编号为 10000（2026-10-12 为 `1001`，最大编号 1000） |
| `MaxJobCount` | `100000` | 整个调度器同时保存的作业总数上限，不是每用户的限额 |
| `JobSubmitPlugins` | `lua` | 提交插件可能附加规则（例如最少核数），内部逻辑未知 |

2026-11-11 实测的分区 QoS 和作业默认值（`scontrol show partition`、`sacctmgr show qos`）：

| 分区 | 分区 QoS 和上限 | 作业默认值和其他设置 |
| --- | --- | --- |
| `cpu_turin` | 无（`QoS=N/A`） | 没有 `JobDefaults`；`AllowAccounts=ALL` |
| `gpu_hopper` | `gpulimits`：每用户、每作业最多 `cpu=120,gres/gpu=15`，至少 `gres/gpu=1` | `DefCpuPerGPU=16`、`DefMemPerGPU=193333`（约 189 GiB）；`DenyAccounts=teaching` |
| `gpu_lovelace` | `gpulimits`（同上） | `DefCpuPerGPU=8`、`DefMemPerGPU=85619`（约 84 GiB）；`DenyAccounts=teaching` |
| `cpu_genoa` | `nodeslimits`：每用户、每作业最多 `cpu=1024,mem=4601G` | `Default=YES`；`DenyAccounts=teaching` |

四个分区都是 `MaxNodes=UNLIMITED`、`OverSubscribe=NO`、`State=UP`。`cpu_genoa` 分区本身是 `UP`，所以不写分区的作业能提交进去，只是节点全部 drain，开始不了。账号默认的 QoS `normal` 以及 `himemlimits`、`funded_qos` 没有设置限额；`teaching_qos` 为每用户、每作业 8 核，最长 8 小时，每用户最多 15 个运行中的作业、最多提交 30 个。

优先级配置会随管理员调整变化，可以用 `sprio`、`sshare` 查看当下情况。参见 [Calder 排队优先级](https://arcdocs.leeds.ac.uk/calder/usage/job_priority.html)。

## 8. 模块环境

Calder 使用 **Lmod** 分层模块（2026-10-12 实测 Lmod 8.7.64，AIRE 是 Environment Modules 5.3），模块路径为 `/uol/apps/calder/modules`。先加载软件层，之后才能看到 Calder 的编译器、MPI 库和应用；加载软件层之前，`module avail` 只列出这两个软件层本身和 OpenHPC 基础模块（EasyBuild、`gnu12`、hwloc、libfabric、papi、pmix、prun、ucx；2026-11-11 实测）：

| 软件层 | 用途 |
| --- | --- |
| `calder/cpu` | CPU 软件栈 |
| `calder/hopper` | H200（Hopper）GPU 软件栈，CUDA 在这一层 |

```bash
module avail                 # 只显示当前可加载的层
module load calder/cpu       # 或 calder/hopper
module avail
module spider miniforge3     # 搜索整个模块树及加载顺序
module list
```

`module avail` 找不到某个软件时，先用 `module spider` 查它在哪一层，不要直接认定没有安装。加载 `calder/hopper` 只是切换软件栈，不等于分配到了 GPU。参见 [模块说明](https://arcdocs.leeds.ac.uk/calder/system/module_system.html)。

2026-10-12 实测的软件：

| 软件 | 结果 |
| --- | --- |
| 系统 Python | `/usr/bin/python3`，Python 3.9 |
| `miniforge3/26.1.1-3` | `calder/cpu` 和 `calder/hopper` 两层均可加载；conda 26.1.1、mamba 2.5.0、自带 Python 3.13 |
| `cuda/13.3.0` | 位于 `calder/hopper` 层；模块树中也有 cuDNN 和 NCCL |
| Apptainer | `/usr/bin/apptainer`，1.5.3，**无需加载模块** |
| PyTorch | 没有独立的 `pytorch` 模块，需要装在自己的 Conda 环境里（或使用容器） |

非交互 SSH 或作业脚本中出现 `module: command not found` 时，不代表没有模块系统，先初始化 Lmod：

```bash
source /etc/profile.d/lmod.sh
export MODULEPATH=/uol/apps/calder/modules
```

### 8.1 Python 和 Conda 环境

学校要求用 Miniforge 代替 Anaconda，Conda 环境放在 Home，研究数据和输出放在 Scratch。参见 [环境管理](https://arcdocs.leeds.ac.uk/calder/usage/environment_management.html)、[Miniforge](https://arcdocs.leeds.ac.uk/calder/software/tools/miniforge.html)。

```bash
module load calder/cpu
module load miniforge3/26.1.1-3
conda env create -f environment.yaml
conda activate <env_name>
```

建议：

- 给 Calder 单独建环境（例如名字带 `calder`），不要升级 AIRE 正在使用的环境；Home 共享，改动会同时影响两边。
- 只加载 Miniforge 时，`python`、`python3` 仍可能指向系统 Python 3.9，要先激活环境。
- 不要用 `conda init` 或在 `.bash_profile` 里自动加载固定模块；在每个作业脚本里自包含地加载模块和环境。
- 预编译的 PyTorch 自带 CUDA runtime，不一定需要加载 `cuda/13.3.0`；编译自定义 CUDA 扩展时才需要匹配的 toolkit 和编译器。
- Apptainer 容器使用 GPU 时加 `--nv`，同样需要通过 Slurm 申请资源。参见 [Calder Apptainer](https://arcdocs.leeds.ac.uk/calder/software/tools/apptainer.html)。
- 多人需要的软件可以提交 [软件安装申请](https://it.leeds.ac.uk/it?id=sc_cat_item&sys_id=48d5a6d70f275f00a82247ece1050ea0)。

## 9. 作业模板

> **注意**：每个模板都写了 `--partition`，复制时不要删掉。2026-11-11 起不写分区的作业会进入节点全部 drain 的默认分区 `cpu_genoa` 一直排队（见第 7.1 节）；CPU 作业用 `cpu_turin`，GPU 作业用 `gpu_hopper`。

下面的模板没有在 Calder 上实际运行过，资源量只是示例，需要按项目调整。模板在加载模块和激活 Conda 前后用 `set +u` / `set -u` 临时放宽未定义变量检查，因为 Lmod 和 Conda 的初始化脚本可能引用未定义的变量，在 `set -u` 下直接报错退出。日志目录要在提交前创建：

```bash
mkdir -p <PROJECT_DIR>/logs
```

### 9.1 CPU 作业

```bash
#!/bin/bash
#SBATCH --job-name=cpu_job
#SBATCH --partition=cpu_turin
#SBATCH --time=04:00:00
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=16
#SBATCH --mem=64G
#SBATCH --output=<PROJECT_DIR>/logs/%x_%j.out
#SBATCH --error=<PROJECT_DIR>/logs/%x_%j.err

set -euo pipefail

PROJECT=<PROJECT_DIR>
cd "$PROJECT"

set +u
# 非交互 Shell 中可能没有 module 函数
if ! command -v module >/dev/null 2>&1; then
    source /etc/profile.d/lmod.sh
    export MODULEPATH=/uol/apps/calder/modules
fi
module purge
module load calder/cpu
module load miniforge3/26.1.1-3
eval "$(conda shell.bash hook)"
conda activate <env_name>
set -u

export PYTHONPATH="$PROJECT:${PYTHONPATH:-}"
export PYTHONNOUSERSITE=1
export OMP_NUM_THREADS="${SLURM_CPUS_PER_TASK:-1}"

python tools/<your_cpu_script>.py
```

`--cpus-per-task` 不要低于 8（`cpu_turin` 最少分配 8 核）。

### 9.2 单 GPU 作业

```bash
#!/bin/bash
#SBATCH --job-name=gpu_job
#SBATCH --partition=gpu_hopper
#SBATCH --gres=gpu:nvidia_h200:1
#SBATCH --time=10:00:00
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=16
#SBATCH --mem=128G
#SBATCH --output=<PROJECT_DIR>/logs/%x_%j.out
#SBATCH --error=<PROJECT_DIR>/logs/%x_%j.err

set -euo pipefail

PROJECT=<PROJECT_DIR>
cd "$PROJECT"

set +u
if ! command -v module >/dev/null 2>&1; then
    source /etc/profile.d/lmod.sh
    export MODULEPATH=/uol/apps/calder/modules
fi
module purge
module load calder/hopper
module load miniforge3/26.1.1-3
eval "$(conda shell.bash hook)"
conda activate <env_name>
set -u

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

### 9.3 多节点资源声明片段

每用户的 GPU 上限按 15 张计（见第 7.2 节），跨 2 个节点时每节点最多 7 张，共 14 张：

```bash
#SBATCH --partition=gpu_hopper
#SBATCH --nodes=2
#SBATCH --gres=gpu:nvidia_h200:7
#SBATCH --cpus-per-gpu=8
#SBATCH --time=01:00:00
```

不能写成 `gpu:nvidia_h200:14`（那是每节点 14 张，单节点只有 8 张）；每节点 8 张、共 16 张则超过 `gpulimits` 的 15 张。不写 CPU 时每张卡默认配 16 核，14 张卡就是 224 核，超过 120 核的上限，所以这里写 `--cpus-per-gpu=8`（共 112 核）。每节点 7 张卡时默认内存仍放得下；占满一个节点 8 张卡的作业还要写 `--mem` 或 `--mem-per-gpu`，因为 8 倍默认值超过节点登记的内存（第 7.2 节）。`--cpus-per-gpu` 不能和 `--cpus-per-task` 同时使用，改按进程数申请 CPU 时，同样要让两个节点合计不超过 120 核。这个片段只声明资源，还需要项目自己的进程数、内存、分布式启动方式（`torchrun`、`srun` 等）和 NCCL 环境。跨节点通信性能截至 2026-10-12 尚未实测，先用小规模测试确认扩展效率。

CPU 上跨两个节点的 MPI 程序可以按每节点 128 个进程声明（256 个进程不等于一个进程开 256 个线程），再加载 `calder/cpu` 层里兼容的 MPI 模块：

```bash
#SBATCH --partition=cpu_turin
#SBATCH --nodes=2
#SBATCH --ntasks-per-node=128
#SBATCH --cpus-per-task=1
#SBATCH --time=01:00:00
```

### 9.4 数组作业和依赖

```bash
# 100 个子任务，最多 10 个同时运行
#SBATCH --array=1-100%10
```

每个子任务用 `$SLURM_ARRAY_TASK_ID` 选择自己的输入。GPU 数组的每个子任务都计入每用户 15 张卡、120 个 CPU 核的上限（第 7.2 节），例如每个子任务 1 张卡、16 核时，同时运行的不要超过 7 个（`%7`）。2026-11-11 实测 `MaxArraySize=10001`，数组编号最大为 10000（2026-10-12 时为 `1001`）。多阶段流程可以用 `sbatch --dependency=afterok:<JOBID>`，只在前序作业成功后才开始；`afterany` 在前序结束后就开始，包括失败和超时。

### 9.5 最小测试作业

验证 Slurm 能否工作：

```bash
#!/bin/bash
#SBATCH --job-name=hello_calder
#SBATCH --partition=cpu_turin
#SBATCH --time=00:05:00
#SBATCH --cpus-per-task=8
#SBATCH --mem=4G
#SBATCH --output=<PROJECT_DIR>/logs/%x_%j.out
#SBATCH --error=<PROJECT_DIR>/logs/%x_%j.err

set -euo pipefail

echo "job_id=$SLURM_JOB_ID"
echo "node=$SLURMD_NODENAME"
echo "SCRATCH=${SCRATCH:-<unset>} TMP_SHARED=${TMP_SHARED:-<unset>} TMPDIR=${TMPDIR:-<unset>}"
hostname
date
```

顺便打印作业内的存储变量，确认第 6 节提到的 `$SCRATCH`、`$TMP_SHARED` 在作业中是否设置。

## 10. 交互式调试

短时间调试用 `srun` 申请交互资源，同样会占用调度资源；用完 `exit` 释放。`srun` 也要写 `--partition`，否则会在默认分区 `cpu_genoa` 一直等待（见第 7.1 节）：

```bash
# CPU（至少 8 核）
srun --partition=cpu_turin --time=00:30:00 --cpus-per-task=8 --mem=16G --pty bash

# 单张 H200
srun --partition=gpu_hopper --gres=gpu:nvidia_h200:1 --time=00:30:00 --cpus-per-task=16 --mem=64G --pty bash
```

进入计算节点后再加载模块和环境。学校不建议把交互资源当作长期运行 Jupyter、RStudio 等的开发工作站，代码开发尽量在本地完成。

## 11. 查看作业和排队

登录节点上的查询命令不申请资源，但不要在紧密循环中高频执行：

```bash
squeue --me
squeue --me -o "%.18i %.18P %.24j %.2t %.10M %.10l %.6D %R"
squeue --job=<JOBID> --start          # 预计开始时间，只是估计
scontrol show job <JOBID>
sacct -j <JOBID> --format=JobID,JobName,Partition,State,ExitCode,Elapsed,MaxRSS,AllocCPUS,ReqMem,AllocTRES%40
sprio -u "$USER"
sshare -u "$USER"
```

节点状态的含义：

- `MIXED`：节点上部分资源已分配。
- `PLANNED`：backfill 调度器为更高优先级的作业预留了该节点。
- `DRAIN`：节点不再接收新作业。`sinfo` 中状态后面的 `*` 表示节点没有响应，`$` 表示节点处于维护预约中，例如 2026-11-11 `cpu_genoa` 节点显示的 `drain*`、`drain$`。

所以不能用“GPU 总数减去已分配数”直接算出马上可用的卡数，也不能仅凭节点显示 `IDLE` 就断定作业会立即开始。作业从 `squeue` 中消失后，用 `sacct` 查看最终状态。

`scancel <JOBID>` 会终止作业，可能丢失未保存的结果，只取消自己明确要停的作业。

## 12. 数据传输

传输在本地电脑和登录节点之间进行，先传输入、再提交作业，不要在作业中做外部下载。参见 [数据传输说明](https://arcdocs.leeds.ac.uk/calder/usage/file_management/data_transfer.html)。

```bash
# 先 dry run 预览
rsync -avP --dry-run ./dataset/ calder:/scratch-calder/users/<username>/dataset/

# 确认无误后去掉 --dry-run
rsync -avP ./dataset/ calder:/scratch-calder/users/<username>/dataset/

# 取回结果
rsync -avP calder:<PROJECT_DIR>/reports/ ./reports/
```

不在校内网络时把 `calder` 换成 `calder-jump`。不要随手加 `--delete`。大量小文件可以先打包再传，减少元数据开销。

AIRE 和 Calder 之间：

- Home 共享，`/users/<username>` 下的文件两边直接可见，不需要传输。
- Scratch 不共享。不要假定 AIRE 的 `/mnt/scratch/<username>` 在 Calder 上可见，需要时先在 Calder 登录节点上 `ls -ld /mnt/scratch/"$USER"` 看一下。集群间直接互传截至 2026-10-12 未验证，稳妥做法是经本地中转。
- 中央 HPC Globus 服务官方描述为仍在开发中，暂不要依赖。

## 13. 从 AIRE 迁移检查清单

已有的 AIRE 工作可以继续保留。建议先在 Calder 跑通一个代表性任务，而不是一次性迁移全部环境和数据。参见 [迁移 FAQ](https://arcdocs.leeds.ac.uk/calder/getting_started/faq.html)。

| 项目 | AIRE | Calder | 需要做什么 |
| --- | --- | --- | --- |
| 登录 | `aire.leeds.ac.uk` | `calder.leeds.ac.uk` | 新增 SSH Host 块（第 4.3 节），账号密码不变 |
| Home | `/users/<username>` | 同一个目录 | 不要为 Calder 改动 AIRE 正在用的启动文件和环境 |
| Scratch | `/mnt/scratch/<username>` | `/scratch-calder/users/<username>` | 自行把需要的数据传过去，作业路径全部改写 |
| 配额 | Lustre 用户配额 | Lustre project 配额 | 改用 `lfs project -d` + `lfs quota -p` 查询 |
| CPU 分区 | `nodes`（168 核，默认分区） | `cpu_turin`（128 核，最少 8 核；2026-11-11 前名为 `calder-cpu-turin`），不是默认分区 | 始终写 `--partition=cpu_turin`：AIRE 上省略分区会进 `nodes`，Calder 上会进节点全部 drain 的默认分区 `cpu_genoa` 一直排队；按 128 核重新规划线程和进程数 |
| GPU 分区 | `gpu` + `--gres=gpu:N`（L40S） | `gpu_hopper` + `--gres=gpu:nvidia_h200:N`（2026-11-11 前名为 `calder-gpu-hopper`） | 改分区和 gres；默认配套 CPU/内存与 AIRE 不同 |
| GPU 上限 | `gpulimits`：每用户 15 张 GPU、120 核，强制执行 | `gpulimits` 同为每用户 15 张、120 核（2026-11-11 实测，是否强制执行不明确）；官方 Jobs 页写 16 张、最多 2 个节点 | 按不超过 15 张 GPU、120 核规划，多卡作业显式写 CPU 数（第 7.2 节） |
| 高内存 | `himem` | 无 | 单节点约 717 GiB（2026-11-11 Slurm 登记值）不够时留在 AIRE |
| 教学分区 | `teachingnodes` | 无 | 教学任务留在 AIRE |
| 模块 | 平面模块，如 `pytorch/2.5.1` | Lmod 分层，先 `calder/cpu` 或 `calder/hopper` | 不能照抄旧 `module load` 行；没有 `pytorch` 模块，改用 Conda 环境 |
| MPI 和网络 | Omni-Path | InfiniBand | 重新编译或核对 MPI 栈 |
| 已编译扩展 | — | — | 按新的 Python、编译器、CUDA 和 GPU 架构重新编译，不要复制旧缓存或 site-packages |
| 结果核对 | — | — | 用相同输入、精度和版本比较结果与耗时；不同 GPU 的浮点结果不一定逐位相同 |

验收顺序建议：环境导入 → 短数据读取 → 小规模计算 → checkpoint 保存与恢复 → 完整任务。

关于 AIRE 2.0：官方软件页和欢迎页（2026-11-11）把 AIRE 正在进行的升级称为 Aire 2.0（新的软件栈、分层模块），存储页预计其 Scratch 和 Flash 路径会改为 `/scratch-aire` 和 `/flash-aire`。确认变更前不要把这些路径当成已经存在的目录。2026-11-11 实测 Calder 的控制器报告 `ClusterName = aire`，还调度着 AIRE 同代的节点（`cpu_genoa`、`gpu_lovelace`），看起来与这次升级有关，但官方没有说明，这只是观察（见第 1 节）。参见 [存储选项](https://arcdocs.leeds.ac.uk/calder/usage/file_management/storage_options.html)、[软件说明](https://arcdocs.leeds.ac.uk/calder/software/start.html)。

## 14. 官方文档与实测的差异

“实测”一栏未注明日期的是 2026-10-12 的结果；官方的 Jobs、节点规格和 FAQ 页面于 2026-11-11 复查。

| 项目 | 官方文档或旧示例 | 实测 |
| --- | --- | --- |
| 分区名 | Jobs 页（2026-11-11）仍写 `--partition=calder-gpu-hopper`、`-p calder-gpu-hopper`；CPU 分区只称为标准计算分区，CPU 示例不写 `--partition` | 2026-11-11 起为 `cpu_turin`、`gpu_hopper`、`cpu_genoa`、`gpu_lovelace`，用旧名提交会报 invalid partition 错误 |
| 默认分区 | Jobs 页没有说明 | 2026-11-11 为节点全部 drain 的 `cpu_genoa`，不写 `--partition` 的作业（包括照抄的官方 CPU 示例）一直排队 |
| GPU 上限 | Jobs 页：每个作业、每个用户同时最多 16 张 GPU，最多 2 个节点 | 2026-11-11 `gpulimits` QoS 为每用户、每作业 15 张 GPU、120 核；`AccountingStorageEnforce=none`，是否强制执行不明确 |
| CPU 节点数 | 96 台（节点规格页和 FAQ） | 2026-10-12 Slurm 登记 98 台；2026-11-11 为 95 台，`calder-cpu091` 未列出 |
| GPU 节点数和 GPU 总数 | 7 台、56 张 H200 | 2026-11-11 Slurm 只列出 6 台、48 张，`calder-h200-04` 不再列出 |
| GPU 节点名 | Jobs 页写 `calder-gpu-h200-001` 等 | 2026-10-12 Slurm 中为 `calder-h200-01` 至 `calder-h200-07`；2026-11-11 为 `calder-h200-[01-03,05-07]` |
| Scratch 路径 | `/scratch-calder/<username>`，部分页面仍是 AIRE 路径 | `/scratch-calder/users/<username>` |
| 文件数默认限额 | 通用配额页为 150 万 | 实测账户 Scratch 和 Flash 硬限额为 100 万 |
| `$SCRATCH` | 说明在作业中设置 | 登录节点上未设置（加载模块后也未设置）；2026-11-11 复查仍未设置，`$FLASH` 也未设置；作业内未验证 |
| 公平份额 | 优先级文档描述 fairshare 参与排序 | `PriorityWeightFairShare=0` |
| VPN | 公开登录页允许 VPN 或跳板机；IT 知识库要求关 VPN 走 rash | VPN 直连实测成功 |
| Miniforge | 专页从 `calder/cpu` 加载 | `calder/cpu` 和 `calder/hopper` 均可加载 |
| 作业临时 Flash | 存储页已有 Calder 变量，Jobs 页仍写细节待完善 | 未用作业验证 |
| Flash 容量 | 官方约 246 TB | 挂载的文件系统约 183 TB，差异原因未知 |

官方页面没有“最后更新”日期，也没有更新记录（2026-11-11 复查），分区名要以调度器本身为准（`sinfo -s`、`scontrol show partition`）：照官方示例提交时报 invalid partition 错误，先用 `sinfo -s` 查看当前分区名再改脚本。遇到这些差异时，以自己账号实际的路径、限额和命令输出为准，长期政策和文档错误交给 Research Computing 确认。

尚未确认的事项：H200 驱动版本与实际拓扑、作业期临时目录的实际行为、QoS 上限是否强制执行、`calder-cpu091` 和 `calder-h200-04` 没有列出的原因、`cpu_genoa` 和 `gpu_lovelace` 的节点是否及何时恢复、Calder 调度器与 Aire 2.0 的关系、个人 Flash 目录的保留政策、Home 备份频率、Flash 容量差异、计算预算或计费规则、离校后账号与数据保留期限。不要把它们当成已确定的事实。

## 15. 常见问题排查

| 现象 | 先确认的内容 |
| --- | --- |
| SSH 超时 | 当前网络、VPN 与 rash 路线是否匹配（第 4.2 节） |
| 认证前断开或 `Not allowed at this time` | 登录节点拒绝新连接，不是密码错误；等一会再连（第 4.6 节） |
| 主机密钥变更告警 | 核对指纹和学校说明，不要关闭校验或清空 `known_hosts`（第 4.5 节） |
| `Permission denied` | 是否用了 `BatchMode`、密码和 Duo 是否完成、是否走了 password/keyboard-interactive |
| `module: command not found` | 非交互 Shell，先 `source /etc/profile.d/lmod.sh` |
| 模块找不到 | 是否加载了 `calder/cpu` 或 `calder/hopper`；用 `module spider` 查加载顺序 |
| Python 或 Conda 不对 | `command -v python`；环境是否激活；是否仍是系统 Python 3.9 |
| 提交时报 invalid partition 错误 | 脚本里是否还是 2026-11-11 前的旧分区名（`calder-cpu-turin`、`calder-gpu-hopper`，或照抄的官方示例）；用 `sinfo -s` 查看当前分区名，改成 `cpu_turin` 或 `gpu_hopper`（第 7.1 节） |
| 作业一直排队，`squeue` 显示分区为 `cpu_genoa` | 提交时没写 `--partition`，进了节点全部 drain 的默认分区；取消后加上 `--partition=cpu_turin` 或 `--partition=gpu_hopper` 重新提交 |
| 作业被拒绝或一直排队 | 分区名是否为当前名称，gres 是否改成 Calder 写法；CPU 是否 ≥ 8；GPU 作业是否超过 15 张 GPU 或 120 个 CPU 核（第 7.2 节）；占满一个节点 8 张卡时是否写了 `--mem` 或 `--mem-per-gpu`；时间是否超过 48 小时 |
| CUDA 不可用 | 作业是否提交到 `gpu_hopper` 并申请了 `gpu:nvidia_h200:N` |
| 写入报配额或空间不足 | 用 project 配额（不是 `-u`）同时查空间和文件数；Home 是 AIRE 与 Calder 合用的 65 GiB |
| `$SCRATCH` 为空或旧路径不存在 | 写完整路径 `/scratch-calder/users/<username>` |
| 作业 OOM | `sacct` 的 `MaxRSS` 和 `ReqMem`；系统内存和显存是不同限制 |

## 16. 使用规则、支持和致谢

- 计算节点上的工作必须经过 Slurm，不要绕过队列。
- 当前规则禁止在 HPC 上存储或处理个人及敏感数据；经过适当去标识、无法识别个人的数据通常可以使用。真实临床数据还需按学校的数据分类和研究安排核对，拿不准时联系 Research Computing。参见 [使用规则](https://arcdocs.leeds.ac.uk/calder/getting_started/rules_regulations.html)。
- 支持渠道：[Research IT query form](https://bit.ly/arc-help)、[Research IT 服务入口](https://leeds.service-now.com/it?id=sc_cat_item&sys_id=7587b2530f675f00a82247ece1050eda)，或发邮件到 [RCTeam@leeds.ac.uk](mailto:RCTeam@leeds.ac.uk)。参见 [支持说明](https://arcdocs.leeds.ac.uk/calder/support/start.html)。
- 报告连接问题时附上发生时间、使用的路线（直连/VPN/rash）、原始错误和失败阶段；报告作业问题时附上 Job ID、提交脚本、stdout、stderr 和 `sacct` 输出。不要发送密码、验证码或与问题无关的私人内容。
- 培训课程：HPC0（Linux）、HPC1（HPC 入门）、HPC2（软件使用），日期见 [ARC 课程](https://arc.leeds.ac.uk/courses/) 和 [培训说明](https://arcdocs.leeds.ac.uk/calder/support/training_courses.html)。

论文、海报和报告使用过学校 HPC 时，官方建议的致谢语句：

> This work was undertaken on the HPC systems at the University of Leeds, UK.

## 17. 用 Leeds HPC Monitor 监控 Calder

本仓库的 macOS 应用 Leeds HPC Monitor（原 AIRE Monitor）同时监控 AIRE 和 Calder，用 `./scripts/run_macos_app.sh` 构建并启动，详细说明见 [MACOS_APP.md](MACOS_APP.md)。这里只说明与 Calder 相关的部分。

- **两个集群并行监控**：每个集群有自己独立的 SSH 控制连接、刷新循环（每 10 秒一次，连续失败时逐步放慢到 60 秒）、快照缓存、历史趋势、作业通知、文件浏览器和终端。总览页、菜单栏和桌面小组件把两个集群放在一起显示，并用各自的集群标识区分；GPU 数量只在集群之间比较、从不相加，因为型号不同（Calder 是 H200 和 L40，AIRE 是 L40S）。
- **一套账号、一次输入**：用户名、密码（勾选 “Remember in Keychain” 后在 macOS 钥匙串里只存一份，两个集群共用）和连接路线对两个集群通用。路线是全局设置，在侧边栏用 “Direct (VPN)” / “rash jump” 切换：前者直连每个集群，后者经 rash 跳板。
- **Duo 按集群分别确认**：点 “Connect all” 时各集群依次登录，Duo 推送一个接一个到达。直连路线每个集群一次 Duo；rash 路线先为 rash 确认一次（rash 跳板连接由两个集群共用，健康时直接复用），再为每个集群各确认一次。如果某个集群报告密码错误，排队中的其他集群登录会被取消，避免用同一个错误密码触发账号锁定。
- **只监控其中一个**：在侧边栏 “Advanced” 中可以关闭 Calder（或 AIRE）的开关，关闭后该集群不再刷新，“Connect all” 也会跳过它；同一处可以修改每个集群的登录主机（Calder 默认 `calder.leeds.ac.uk`）。
- **分区和 GPU**：Calder 的分区卡片使用 2026-11-11 起的新分区名：`gpu_hopper` 显示为 H200 GPU 分区，`cpu_turin` 显示为标准 CPU 分区，`gpu_lovelace` 和 `cpu_genoa` 标注为 Calder 调度器上的 AIRE 同代节点；GPU 池分为 H200（`gpu_hopper`）和 L40（`gpu_lovelace`）。app 没有说明的分区也会按数据归类（有 GPU gres 的算 GPU 分区，其余算 CPU 分区），以后分区再改名，节点也不会从界面上消失。最长运行时间取自 `sinfo`。侧边栏的 “Notify when a GPU frees up” 在某个集群从没有空闲 GPU 变为至少一张空闲时提醒一次，对 Calder 和 AIRE 分别判断。
- **默认分区**：快照采集脚本会记录 Slurm 的默认分区（`sinfo` 中带 `*` 的那个），“Partitions” 标签页把它标为 “Default”。默认分区没有可用节点时（例如 2026-11-11 Calder 的 `cpu_genoa`），这个标记会变成警告，提示不写 `--partition` 的作业会在那里一直等待。
- **存储面板**：Calder 显示 Home、Scratch（`/scratch-calder/users/<username>`，兼容 `/scratch-calder/<username>`）和 Flash（`/flash-calder/users/<username>`，目录存在时才显示）。Scratch 和 Flash 先用 `lfs project -d` 找到目录的 project id，再按 project 配额显示，标注为 “Lustre project quota” 和对应的 project id；目录没有 project id 时退回 Lustre 用户配额。Home 标注为所有集群共享，菜单栏只显示一次，不会被重复计算。
- **内置终端**：复用 app 已经认证的控制连接，不需要再次 Duo。Calder 的快捷命令有 `squeue --me`、`sinfo`、配额查询（即第 6.2 节的一次性查询）、“GPU nodes”（`sinfo -N -p gpu_hopper`）和 `htop`。“GPU nodes” 使用最新快照里的分区列表，集群以后再改 GPU 分区名时会跟着用新名字，不会报 “invalid partition”。
- **文件浏览器**：每个集群一个，快捷入口来自该集群实际解析到的 Home、Scratch、Flash 目录。服务器端回收站目录名沿用旧版本的 `.aire-trash`；因为 Home 共享，`~/.aire-trash` 在 AIRE 和 Calder 上是同一个目录。放进回收站只是移动，文件在清空回收站之前仍然占用配额。
- **认证前断开**：遇到第 4.6 节的现象时，app 会提示 “closed the connection before authentication”，明确说明这是服务器端拒绝、不是密码错误。走 rash 路线时，只要 rash 跳板本身仍然正常，就不会因为 Calder 登录节点拒绝连接而重建跳板，AIRE 的连接不受影响。
- **主机密钥**：app 以 `StrictHostKeyChecking=accept-new` 连接，使用默认的 `~/.ssh/known_hosts`：第一次连接时自动记录主机密钥，之后密钥若变化则拒绝连接。想在首次连接前核对指纹，先在终端手动 `ssh calder` 一次（第 4.5 节），app 之后会沿用 `~/.ssh/known_hosts` 里的这条记录（如果按示例文件把密钥固定到了单独的 `UserKnownHostsFile`，app 看不到那份文件）。
- **app 不使用第 4.3 节的 Host 块**：app 直接连接 `calder.leeds.ac.uk`，使用自己的控制套接字（`~/.ssh/ctl/calder-<hash>.sock`，rash 为 `~/.ssh/ctl/jump-<hash>.sock`）。打开 **Share with Terminal and Claude sessions**（默认打开）时，app 还会把正在使用的会话链接到 `~/.ssh/ctl/calder.sock`，以及每个匹配的别名（主机、端口 22 和用户名都相同）的 `ControlPath`（即第 4.3 节 `%C` 命名的套接字）；那个路径上已有你自己的活动会话时则不动它。这样终端里的 `ssh calder`、`scp`、`rsync` 直接复用 app 的会话，不再输入密码、不再收 Duo 推送；因为是同一个会话，`ssh -O exit calder` 也会关掉 app 的会话。关闭共享后，终端里的 `ssh calder` 仍需要单独认证一次。app 调用的仍是系统 `ssh`，`~/.ssh/config` 中能匹配 `calder.leeds.ac.uk` 的通配规则（例如 `Host *`）依然会生效。
- **只读采集**：快照采集脚本 `scripts/hpc_snapshot.py` 只在登录节点上运行只读命令（`squeue`、`scontrol show job`、`sinfo`、`df`、`quota`、`lfs` 等），不写远端文件、不提交作业。取消作业、改动文件只在你在界面上主动操作时发生。

## 18. 快速参考

```bash
# 登录（校外用 calder-jump）
ssh calder

# 分区（默认分区名后带 *）
sinfo -s
sinfo -o "%20P %8a %12l %6D %10t %24G %6c %10m"

# 提交（脚本里必须写 --partition=cpu_turin 或 --partition=gpu_hopper）
sbatch jobs/my_job.sbatch

# 查看自己的作业
squeue --me

# 作业详情和历史
scontrol show job <JOBID>
sacct -j <JOBID>

# 模块
module load calder/hopper
module load miniforge3/26.1.1-3

# 配额
quota -s
lfs project -d /scratch-calder/users/"$USER"
lfs quota -h -p <project-id> /scratch-calder

# 取消作业，谨慎
scancel <JOBID>
```
