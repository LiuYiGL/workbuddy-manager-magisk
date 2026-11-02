#!/bin/sh
# 本文件在 chroot 内被 source。所有路径都是 chroot 视角的路径：
#   /workbuddy  <- 绑定挂载到 /data/adb/workbuddy-manager（持久化目录）
#   /opt/wbm    <- 随 rootfs 替换的运行时脚本与离线 wheel
#   /opt/go     <- 随 rootfs 分发的 Go 工具链（用于在设备上重建上游）

# ── 管理端（Python / FastAPI）────────────────────────────
export WB_INSTALL_DIR=/workbuddy/app
export WB_DATA_DIR=/workbuddy/data
export WB_DB=/workbuddy/data/manager.db
export WB_USERS_FILE=/workbuddy/data/users.json
export WB_STATIC_DIR=/workbuddy/app/web/out

# ── 上游 workbuddy2api（Go，本机原生进程）─────────────────
export WB_UPSTREAM_DIR=/workbuddy/app/upstream
export WB_AUTH_DIR=/workbuddy/app/upstream/auths
export WB_UPSTREAM_CONFIG=/workbuddy/app/upstream/config.json
export WB2API_BASE=http://127.0.0.1:7863
export WB2API_MODE=native
export WB2API_START_SCRIPT=/opt/wbm/bin/start-upstream
export WB2API_STOP_SCRIPT=/opt/wbm/bin/stop-upstream
export WB2API_LOG_FILE=/workbuddy/app/upstream/data/server.err.log
export WB2API_CHAT_LOG_FILE=/workbuddy/app/upstream/data/server.out.log

# ── 更新器形态 ───────────────────────────────────────────
# update.py 在非容器环境里只会走 `systemctl restart <WB_SERVICE_NAME>`；
# /usr/local/bin/systemctl 是垫片，负责让监督进程重启管理端。
# 这样管理端自带的更新器**无需改动**，升级后仍逐字执行它的重启逻辑。
export WB_RUN_MODE=systemd
export WB_SERVICE_NAME=workbuddy-manager
# 设备上 Go 重建可能比服务器慢；把更新器的单步超时放宽到 30 分钟
export WB_UPDATE_STEP_TIMEOUT=1800

# ── Python 依赖位置 ─────────────────────────────────────
# 依赖统一装到持久化的 /workbuddy/pylibs，而不装进随模块替换的 rootfs：
#   · 面板里的一键更新会执行 `python -m pip install -r requirements.txt`，
#     PIP_TARGET 让新依赖也落在这里，模块升级不会把它们弄丢；
#   · PYTHONPATH 让 python 从这里导入。
export PIP_TARGET=/workbuddy/pylibs
export PYTHONPATH=/workbuddy/pylibs
export PIP_BREAK_SYSTEM_PACKAGES=1
export PIP_DISABLE_PIP_VERSION_CHECK=1
# 让更新器的 `pip install -r` 覆盖 target 里的旧版本
export PIP_UPGRADE=1
export PYTHONUNBUFFERED=1
export PYTHONDONTWRITEBYTECODE=1
export PYTHONUTF8=1
export LANG=C.UTF-8

# ── Go 工具链与缓存 ─────────────────────────────────────
export GOROOT=/opt/go
export GOPATH=/workbuddy/go
export GOMODCACHE=/workbuddy/go/pkg/mod
export GOCACHE=/workbuddy/go/cache
export GOTMPDIR=/workbuddy/go/tmp
# 不强制 GOFLAGS：与上游 Dockerfile 的 `go build` 行为一致（有 vendor/ 时也会用 vendor）。
# 也不钉 GOTOOLCHAIN：若未来 go.mod 要求更高的 Go，更新时允许 Go 自己下载新版工具链。
export GOTOOLCHAIN=auto
# 纯静态构建：产物直接跑在 Android 内核上，不依赖 bionic/glibc
export CGO_ENABLED=0
# 默认走国内可达的代理；用户可在 .env 里用 WB_GOPROXY 覆盖
export GOPROXY=${WB_GOPROXY:-https://goproxy.cn,direct}

# ── 其它 ────────────────────────────────────────────────
export TZ=${TZ:-Asia/Shanghai}
export HOME=/workbuddy/home
export TMPDIR=/workbuddy/tmp
export PATH=/workbuddy/pylibs/bin:/opt/go/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

mkdir -p \
  /workbuddy/run /workbuddy/logs /workbuddy/home /workbuddy/tmp \
  /workbuddy/pylibs /workbuddy/go/pkg/mod /workbuddy/go/cache /workbuddy/go/tmp \
  /workbuddy/app /workbuddy/app/upstream/auths /workbuddy/app/upstream/data \
  2>/dev/null || true

chmod 1777 /workbuddy/tmp 2>/dev/null || true
