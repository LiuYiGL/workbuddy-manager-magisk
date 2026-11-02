# WorkBuddy Manager · Android Magisk / KernelSU 模块

把 [ithtelab/workbuddy-manager](https://github.com/ithtelab/workbuddy-manager)
（腾讯 CodeBuddy 账号池管理控制台 + OpenAI 兼容反代网关）跑在 Android 手机上。

- **安装完全离线**：模块 zip 内含 Alpine rootfs、Python 运行时与依赖 wheel、
  上游 Go 源码和预编译二进制、以及 Go 工具链；安装时只解压和本地 `pip install`。
- **保留面板自带的更新能力**：面板里的「检查更新 / 一键更新」仍可用；上游源码
  更新后会在**设备上**用随包 Go 工具链重新编译并重启，不依赖 Docker。
- **Magisk / KernelSU 通用**：标准模块格式（`module.prop` + `customize.sh` +
  `service.sh`），arm64 设备，Android 8.0+。

> 上游项目说明：管理端持有账号凭据，默认只监听 `127.0.0.1`。不要在没有
> HTTPS/访问控制的情况下把 7864 端口直接暴露到公网。

---

## 一、上游项目分析结论（决定本模块形态的事实）

发布包 `workbuddy-manager-vX.Y.Z.tar.gz`（约 12 MB）的结构：

```
server/          Python 3.11+ / FastAPI 管理端（约 4.7 MB 源码）
web/out/         Next.js 静态导出（约 9.6 MB）
upstream/        workbuddy2api 的 Go 源码（被本项目维护，随包分发）
deploy/          install.sh、update.py（一键更新器）等
docs/ README CHANGELOG .version
```

运行形态：

| 组件 | 技术 | 默认端口 |
|---|---|---|
| 管理端 | Python + FastAPI + uvicorn | 7864 |
| 上游网关 | Go（`workbuddy2api`，OpenAI 兼容反代） | 7863 |
| 数据库 | 管理端用 SQLite；PostgreSQL 仅用于可选备份 | — |

管理端的一键更新逻辑（`deploy/update.py`）：

1. 查 GitHub Release，下载 tar.gz，核对发布页给出的 **sha256**；
2. 用新包里的 `server/`、`web/out/` 替换旧代码（先备份）；
3. 用新包的 `server/requirements.txt` 跑 `python -m pip install`；
4. 如果包内 `upstream/.upstream-id` 与本机不同，同步上游源码并
   **`docker compose up -d --build --force-recreate` 重建容器**；
5. 重启管理端：容器里退出进程交给编排层；宿主机上执行
   `systemctl restart workbuddy-web`。

Android 上不能直接照搬的两点：

- **没有 Docker**：上游重建那一步会失败。
- **没有 systemd/Python/Go**：重启与运行时都需要自己提供。

本模块的对应设计：

| 上游依赖 | Android 上的替代 |
|---|---|
| Docker + compose（重建上游） | chroot 内的 `docker` 命令垫片 → 用随包 Go 工具链 `go build`，原子替换二进制后重启原生进程 |
| systemd（重启管理端） | chroot 内的 `systemctl` 命令垫片 → 结束管理端进程，外部监督进程立即用新代码拉起 |
| 容器/宿主 Python 环境 | rootfs 内 Alpine Python 3.12 + 持久化的 `/workbuddy/pylibs` |
| 容器/宿主 Go 环境 | rootfs 内官方 Go 工具链（`/opt/go`） |

**关键点：两个垫片都不在 `server/` 或 `deploy/` 里**，所以面板一键更新替换代码、
甚至替换更新器本身，都不会破坏它们。更新器始终执行它原本的逻辑，只是把
`docker` / `systemctl` 两个命令路由到了 Android 实现。

---

## 二、运行架构

```
Android (root)
└─ Magisk/KernelSU service.sh
   └─ wbm-supervise（宿主机侧监督进程，持久化目录里）
      ├─ 建立 bind mount：/proc /dev /sys + DATA -> rootfs/workbuddy
      ├─ 写 rootfs/etc/resolv.conf（从 Android 网络取 DNS）
      ├─ chroot rootfs /opt/wbm/bin/start-upstream
      │    └─ workbuddy2api (Go, 127.0.0.1:7863)
      └─ chroot rootfs /opt/wbm/bin/start-manager
           └─ python -m server.serve (127.0.0.1:7864)
                ├─ SQLite: /workbuddy/data/manager.db
                ├─ 更新器: /workbuddy/app/server/deploy/update.py
                └─ 依赖: /workbuddy/pylibs (PYTHONPATH / PIP_TARGET)
```

浏览器访问 `http://127.0.0.1:7864/`（手机本机），或按需改为
`WB_MANAGER_HOST=0.0.0.0` 后从局域网访问。

### 持久化路径

| 路径 | 内容 | 模块升级时 |
|---|---|---|
| `/data/adb/modules/workbuddy_manager/rootfs` | Alpine + Python + Go + 离线 wheel + 垫片 | 随模块替换 |
| `/data/adb/workbuddy-manager/app` | 管理端 / 上游代码、`.version`、`.env`、上游 `config.json`、`auths/`、`data/` | 保留 |
| `/data/adb/workbuddy-manager/data` | 面板 SQLite、日志、更新状态 | 保留 |
| `/data/adb/workbuddy-manager/pylibs` | pip 安装的 Python 依赖 | 保留 |
| `/data/adb/workbuddy-manager/go` | Go 模块缓存 / 构建缓存 | 保留 |
| `/data/adb/workbuddy-manager/logs` | supervisor / manager / setup 日志 | 保留 |
| `/data/adb/workbuddy-manager/etc/resolv.conf` | 手动覆盖 DNS（可选） | 保留 |

chroot 内看到的持久化目录是 `/workbuddy`（bind mount）。

---

## 三、安装

1. 从本仓库的 **Actions → Build WorkBuddy Manager Android module** 下载最新
   artifact（或 Releases 里的 zip）：`WorkBuddyManager-vX.Y.Z-arm64.zip`。
2. Magisk 应用 → 模块 → 从本地安装；KernelSU 同理。
3. **安装过程不需要联网**。rootfs 解压约 350–450 MB；加上安装临时文件与 Python 依赖，请预留 **1 GB 以上**可用空间。
4. 安装完成后重启设备（或执行 `sh /data/adb/workbuddy-manager/bin/wbm-ctl start`）。
5. 手机浏览器打开 `http://127.0.0.1:7864/`。
   首次安装会在 Magisk/KernelSU 安装日志里打印随机管理员密码，也保存在：
   ```bash
   cat /data/adb/workbuddy-manager/webui.txt
   ```

> 以下命令都需要 root（`adb shell` 后执行 `su`，或在 KernelSU/Magisk 的
> root shell 中运行）。

### 局域网访问（可选）

```bash
# 编辑 /data/adb/workbuddy-manager/app/.env
WB_MANAGER_HOST=0.0.0.0
```
然后：

```bash
sh /data/adb/workbuddy-manager/bin/wbm-ctl restart
```

管理端持有全部账号凭据，`0.0.0.0` 意味着同网段设备都能访问登录页；只在可信
网络中这样做，并确保使用强密码。上游 `7863` 始终只绑定 `127.0.0.1`。

---

## 四、更新

### 面板内一键更新

「设置 → 系统更新」保持可用：

- **更新管理端**：下载并校验 Release（sha256），替换 `server/`、`web/out/`、
  `deploy/`，用 pip 安装新依赖，最后通过 `systemctl` 垫片重启。
- **更新上游**：同步包内 `upstream/` 源码；如果 `.upstream-id` 变化，
  更新器调用 `docker compose up -d --build --force-recreate`，垫片在设备上执行：
  1. 用 `/opt/go/bin/go` 以 `CGO_ENABLED=0` 编译 6 个上游二进制到 `*.new`；
  2. 全部成功后才停止旧进程并原子替换；
  3. 重新启动上游并等待 `/healthz`。

在手机上首次完整编译上游通常需要 1–5 分钟（取决于 CPU 与 Go 构建缓存），
更新器单步超时已放宽到 30 分钟。

### 更新时的网络问题

更新本身必然需要联网（下载 Release、Go 模块、新 Python 依赖）。在国内网络下
可在 `.env` 中配置：

```ini
# GitHub 镜像（更新器原生支持）
WB_GITHUB_MIRROR=https://gh-proxy.com/
# 或给更新器指定 HTTP 代理
WB_UPDATE_PROXY=http://127.0.0.1:7890
# PyPI 镜像（更新时 pip 新依赖用）
PIP_INDEX_URL=https://pypi.tuna.tsinghua.edu.cn/simple
# Go 模块代理（设备上重建上游用）
WB_GOPROXY=https://goproxy.cn,direct
# 若 Go 本身需要走 HTTP 代理（Go 只认 HTTPS_PROXY/HTTP_PROXY）
# HTTPS_PROXY=http://127.0.0.1:7890
```

修改后 `wbm-ctl restart`。

### 只更新面板、不动上游

在 `.env` 中设置 `WB_SYNC_UPSTREAM=0`。此时上游源码不随包同步，更新更快，
但后面仍需自行处理上游差异。默认（不设置）是同步并重建，能力与上游 Docker
部署一致。

---

## 五、命令行

```bash
CTL=/data/adb/workbuddy-manager/bin/wbm-ctl
sh $CTL status                  # 进程、健康检查、面板地址
sh $CTL start|stop|restart
sh $CTL logs 300 manager        # supervisor | manager | setup | upstream | out | update | all
sh $CTL password                # 初始管理员密码
sh $CTL shell                   # 进入 Alpine chroot（调试用）
sh $CTL doctor                  # 环境/挂载/DNS/端口/磁盘自检
sh $CTL rebuild-upstream        # 手动在设备上重建上游
```

### DNS

Android 没有给普通进程使用的 `/etc/resolv.conf`；监督进程会从
`getprop net.dns1..4` 或 `dumpsys connectivity` 提取 DNS 写进 chroot。
网络切换后最长 60 秒自动刷新。若自动探测失败（部分 ROM），手动覆盖：

```bash
mkdir -p /data/adb/workbuddy-manager/etc
cat > /data/adb/workbuddy-manager/etc/resolv.conf <<'EOF'
nameserver 223.5.5.5
nameserver 119.29.29.29
EOF
sh /data/adb/workbuddy-manager/bin/wbm-ctl restart
```

---

## 六、构建模块

### GitHub Actions（推荐）

仓库自带 `.github/workflows/build.yml`：

- `workflow_dispatch`：可指定上游版本，留空跟随最新 Release；
- 每周一自动构建最新 Release；
- 打 `v*` tag 时额外把 zip 附到本仓库的 Release。

产物：`WorkBuddyManager-vX.Y.Z-arm64.zip`。

### 本地构建

需要 **Docker（buildx + arm64 模拟）**、`curl`、`zip`；Go 可选（没有时用
`golang` 镜像交叉编译上游）。

**没有 Docker 的机器（例如 Windows 本机）不需要装环境**：把仓库推到 GitHub，
在 Actions 里手动运行 `Build WorkBuddy Manager Android module`，然后下载
artifact 即可。工作流会在 Ubuntu runner 上用 QEMU 构建 arm64 rootfs。

```bash
bash tools/build.sh                 # 跟随最新 Release
WB_VERSION=2.11.9 bash tools/build.sh
```

构建流程：

1. 下载并解压上游 Release；
2. 组装 `payload/app`（`server/`、`web/out/`、`deploy/`、`upstream/` 源码）；
3. 交叉编译 `wb2api` 等 6 个 linux/arm64 静态二进制；
4. `docker buildx build --platform linux/arm64` 构建 rootfs：
   Alpine 3.22 + Python 3.12 + pip + 离线 wheel + Go 1.27 + 运行时脚本；
5. `docker export` 成 `assets/rootfs-arm64.tar.gz`；
6. 组装模块并 zip。

`WBM_SKIP_ROOTFS=1` 可复用 `.cache/rootfs-arm64.tar.gz`（先用 `WBM_SAVE_ROOTFS=1` 生成）做快速迭代。
静态检查（无需 Docker/Go）：

```bash
bash tools/check.sh
```

---

## 七、限制与说明

- **仅 arm64（aarch64）**：`customize.sh` 会拒绝其它架构。x86_64/armeabi 需要
  各自构建 musllinux/Go 运行时，当前未提供。
- **Android 8.0+**，需要 Magisk 或 KernelSU 提供的 root 与 `chroot`
  （Magisk/KernelSU 自带 busybox 兜底）。
- **首次启动较慢**：需要离线安装 Python 依赖；上游更新需要设备内 Go 编译。
- **磁盘占用**：rootfs 约 200–300 MB，安装后删除 zip 内临时文件；更新时
  `update.py` 会在 `app/backup-<时间>` 保留旧代码，长期使用请定期清理。
- **更新过程中不要重刷模块**：安装脚本会检测更新锁，发现面板正在一键更新时
  会拒绝安装，等它完成后再刷即可。
- **上游更新依赖内置运行时版本**：如果未来上游要求更高的 Python（当前 3.12）
  或 Go（当前 1.27）版本，设备内更新会在安装依赖/编译阶段失败并保留旧版本；
  重新构建并刷入新版模块包即可。
- **如果上游彻底改动更新机制**（例如不再使用 `docker compose` / `systemctl`
  这两个命令），垫片需要同步适配；这同样通过更新模块包解决。
- **管理端与上游都以 root 运行**（chroot 内）。这是 Magisk 模块的常规形态，
  也意味着任何能访问面板管理员账号的人都拥有该 root 环境里的执行能力。
  请使用强密码，默认不要监听 `0.0.0.0`。
- **上游端口固定为 `127.0.0.1:7863`**，面板端口可在 `.env` 中修改
  （`WB_MANAGER_PORT`，同时 `wbm-ctl` 的健康检查会跟着读 `.env`）。
  不要在上游 `config.json` 里改成别的端口，除非同时调整
  `/opt/wbm/bin/wbm-env.sh` 中的 `WB2API_BASE`。
- **遵守上游的使用边界**：本项目只用于管理本人及亲属自愿授权的账号；禁止批量
  注册、账号交易、代注册、接码、盗号、绕过平台风控等用途。完整声明见上游
  README。模块只做 Android 运行时适配，不改变上游的业务边界。
- **桌面客户端相关功能**（`WB_LOCAL_IMPORT`、cc-switch/ZCode 自动导入等）在
  Android 上没有意义，保持默认关闭。
- **卸载默认保留用户数据**（账号凭据、数据库、日志）。彻底清理：
  ```bash
  rm -rf /data/adb/workbuddy-manager
  ```

---

## 八、排障

| 现象 | 处理 |
|---|---|
| 面板打不开 | `sh $CTL status`；`sh $CTL logs 300 manager`；确认 supervisor/manager 进程 |
| 重启后服务没起来 | 确认模块已启用；执行 `sh $CTL start`；看 `logs 200 supervisor` |
| 用一段时间后进程消失 | 部分 ROM 的后台清理会杀进程；关闭电池优化/加入白名单，或 `sh $CTL start` |
| 上游 `502` / 未连接 | `sh $CTL logs 300 upstream`；`sh $CTL rebuild-upstream` |
| DNS 解析失败 | `sh $CTL doctor` 看 resolv.conf；按上文手动覆盖 DNS |
| 更新卡在「同步随包上游」 | 设备在编译 Go；看 `logs 300 update`；超时 30 分钟 |
| 更新下载失败 | `.env` 配 `WB_GITHUB_MIRROR` 或 `WB_UPDATE_PROXY` |
| 依赖缺失 / 面板启动即退出 | `sh $CTL logs 500 setup`；`sh $CTL shell` 后手动 `pip install` |
| 挂载失败 | `sh $CTL doctor`；`mount \| grep workbuddy`；重启设备后重试 |
| 想完全重装运行时 | 重新刷同一模块 zip；`app/` 与用户数据会保留 |

日志位置：

```
/data/adb/workbuddy-manager/logs/supervisor.log
/data/adb/workbuddy-manager/logs/manager.log
/data/adb/workbuddy-manager/logs/setup.log
/data/adb/workbuddy-manager/data/update.log
/data/adb/workbuddy-manager/app/upstream/data/server.err.log
/data/adb/workbuddy-manager/app/upstream/data/server.out.log
```

---

## 九、目录结构（本仓库）

```
module.prop                  模块元数据（版本由构建脚本替换）
customize.sh                 离线安装：解压 rootfs、装代码、装依赖
service.sh                   开机启动监督进程
uninstall.sh                 停止服务、卸载挂载（保留数据）
bin/
  wbm-lib.sh                 宿主机侧公共函数
  wbm-ctl                    命令行管理
  wbm-supervise              监督进程
rootfs-overlay/              构建时写入 rootfs 的文件
  opt/wbm/bin/               chroot 内启停、重建、健康检查
  usr/local/bin/docker       Docker 命令垫片
  usr/local/bin/systemctl    systemctl 命令垫片
tools/
  build.sh                   一键构建模块
  build-upstream.sh          交叉编译上游
  rootfs.Dockerfile          arm64 rootfs 定义
  env.sh                     版本固定
  check.sh                   本地静态检查
.github/workflows/build.yml  CI 自动构建
```

上游管理端/网关的许可证见随包 `LICENSE`（MIT）。本模块只做 Android 运行时适配，
不修改上游业务代码。
