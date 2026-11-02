#!/usr/bin/env bash
# 交叉编译上游 workbuddy2api（linux/arm64，CGO_ENABLED=0 静态）。
#
# 优先用本机 Go（GOOS=linux GOARCH=arm64 直接交叉编译）；
# 没有 Go 时用 Docker 的 golang 镜像（宿主机架构即可，无需 QEMU）。
#
# 用法：tools/build-upstream.sh <upstream-dir> [arm64]
set -euo pipefail

SRC=${1:?用法: build-upstream.sh <upstream-dir> [arm64]}
ARCH=${2:-arm64}
case "$ARCH" in
  arm64)  GOARCH=arm64 ;;
  amd64|x86_64) GOARCH=amd64 ;;
  *) echo "不支持的架构：$ARCH" >&2; exit 1 ;;
esac

GO_VERSION=${GO_VERSION:-1.27.3}
GOPROXY=${GOPROXY:-https://goproxy.cn,direct}

build_list=(
  "wb2api ./cmd/server"
  "signin_bin ./cmd/signin"
  "login ./cmd/login"
  "credit ./cmd/credit"
  "trial_bin ./cmd/trial"
  "activity_bin ./cmd/activity"
)

run_go() {
  if command -v go >/dev/null 2>&1; then
    ( cd "$SRC" && CGO_ENABLED=0 GOOS=linux GOARCH="$GOARCH" GOPROXY="$GOPROXY" \
        GOTOOLCHAIN=auto go "$@" )
  elif command -v docker >/dev/null 2>&1; then
    docker run --rm \
      -v "$SRC:/src" -w /src \
      -v "${WBM_GOMOD_CACHE:-$PWD/.cache/gomod}:/gomodcache" \
      -e CGO_ENABLED=0 -e GOOS=linux -e GOARCH="$GOARCH" \
      -e GOPROXY="$GOPROXY" -e GOTOOLCHAIN=auto -e GOMODCACHE=/gomodcache \
      "golang:${GO_VERSION}-alpine" go "$@"
  else
    echo "需要 Go 或 Docker 才能构建上游二进制" >&2
    return 127
  fi
}

echo "== 构建上游（linux/$GOARCH）=="
for spec in "${build_list[@]}"; do
  name=${spec%% *}
  pkg=${spec#* }
  if [ ! -d "$SRC/$pkg" ]; then
    if [ "$name" = wb2api ]; then
      echo "缺少上游主程序：$SRC/$pkg" >&2
      exit 1
    fi
    echo "  跳过不存在的 $pkg"
    continue
  fi
  echo "  $name"
  run_go build -trimpath -ldflags="-s -w" -o "$SRC/$name" "$pkg"
done

for f in wb2api signin_bin login credit trial_bin activity_bin; do
  if [ -f "$SRC/$f" ]; then
    chmod 755 "$SRC/$f"
    printf '  %-14s %10s bytes\n' "$f" "$(stat -c %s "$SRC/$f" 2>/dev/null || wc -c < "$SRC/$f")"
  fi
done
echo "上游二进制构建完成"
