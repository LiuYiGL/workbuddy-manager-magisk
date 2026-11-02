# 构建参数（tools/build.sh 会 source）
WBM_UPSTREAM_REPO_OWNER=ithtelab
WBM_UPSTREAM_REPO_NAME=workbuddy-manager

# Alpine 3.22 -> Python 3.12.16（musllinux wheel 覆盖最完整）
ALPINE_VERSION=3.22
# 官方 Go 工具链（用于在设备上重建上游）；可在命令行用 GO_VERSION 覆盖
GO_VERSION=1.27.3

# 目标架构（当前模块只发布 arm64）
WBM_ABI=arm64
WBM_GOARCH=arm64
