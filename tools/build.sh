#!/usr/bin/env bash
# 构建可直接刷入 Magisk / KernelSU 的 arm64 模块 zip。
#
# 产物：dist/WorkBuddyManager-<module-tag>-arm64.zip
# 从 tag 构建时 module-tag 取 GITHUB_REF（如 v2.11.9-android.1）；
# 本地构建默认用上游版本 v2.11.9。
#
# 依赖：
#   · curl / tar / gzip / zip
#   · Docker（buildx，能构建 linux/arm64；GitHub Actions 用 QEMU 模拟）
#   · Go（可选；没有时用 Docker 的 golang 镜像交叉编译上游）
#
# 用法：
#   tools/build.sh                 # 自动取上游最新 Release
#   WB_VERSION=2.11.9 tools/build.sh
#
# 环境变量：
#   WB_VERSION     指定 WorkBuddy Manager 版本（不带 v）
#   ALPINE_VERSION / GO_VERSION  覆盖 tools/env.sh 中的固定值
#   WBM_SKIP_ROOTFS=1  复用 build/rootfs-arm64.tar（调试用）
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"
# shellcheck disable=SC1091
source "$ROOT/tools/env.sh"

BUILD="$ROOT/build"
DIST="$ROOT/dist"
CACHE="$ROOT/.cache"
MOD="$BUILD/module"
PAYLOAD="$MOD/payload/app"

mkdir -p "$BUILD" "$DIST" "$CACHE/releases" "$CACHE/gomod"

need() { command -v "$1" >/dev/null 2>&1 || { echo "缺少命令：$1" >&2; exit 1; }; }
need curl
need tar
need gzip
need zip

# ── 1. 解析版本 / 下载发布包 ────────────────────────────
OWNER=$WBM_UPSTREAM_REPO_OWNER
REPO=$WBM_UPSTREAM_REPO_NAME

APP_VERSION=${WB_VERSION:-}
if [ -z "$APP_VERSION" ]; then
  echo "== 查询上游最新 Release =="
  # 先走 releases/latest 的 302（不走 API，不受 60 次/小时限流影响）
  loc=$(curl -fsSI --retry 3 "https://github.com/$OWNER/$REPO/releases/latest" 2>/dev/null \
    | tr -d '\r' \
    | sed -n 's#^[Ll]ocation: .*/tag/\([^/]*\)$#\1#p' \
    | head -n 1 || true)
  APP_VERSION=${loc#v}
fi
if [ -z "$APP_VERSION" ]; then
  # 回退到 API（CI 里可传 GITHUB_TOKEN 提高限额）
  auth=()
  [ -n "${GITHUB_TOKEN:-}" ] && auth=(-H "Authorization: Bearer $GITHUB_TOKEN")
  api=$(curl -fsSL --retry 3 "${auth[@]}" \
        "https://api.github.com/repos/$OWNER/$REPO/releases/latest" || true)
  APP_VERSION=$(printf '%s' "$api" \
    | tr ',' '\n' \
    | sed -n 's/.*"tag_name":[[:space:]]*"v\{0,1\}\([^"]*\)".*/\1/p' \
    | head -n 1 || true)
fi
[ -n "$APP_VERSION" ] || { echo "无法确定上游版本；用 WB_VERSION=2.x.y 指定，或检查网络/GitHub API 限额" >&2; exit 1; }
TAG="v${APP_VERSION#v}"
# 产物文件名优先使用模块 tag；本地无 GITHUB_REF 时回退到上游版本。
MODULE_TAG=${WBM_MODULE_TAG:-}
if [ -z "$MODULE_TAG" ] && [ -n "${GITHUB_REF:-}" ]; then
  case "$GITHUB_REF" in
    refs/tags/*) MODULE_TAG=${GITHUB_REF#refs/tags/} ;;
  esac
fi
[ -n "$MODULE_TAG" ] || MODULE_TAG="$TAG"
APP_VERSION=${TAG#v}

PKG="$CACHE/releases/workbuddy-manager-$TAG.tar.gz"
URL="https://github.com/$OWNER/$REPO/releases/download/$TAG/workbuddy-manager-$TAG.tar.gz"
if [ ! -s "$PKG" ]; then
  echo "== 下载 $URL =="
  curl -fL --retry 3 --retry-delay 2 --connect-timeout 20 -o "$PKG.part" "$URL"
  mv "$PKG.part" "$PKG"
fi
echo "发布包：$PKG"
if command -v sha256sum >/dev/null 2>&1; then
  echo "sha256：$(sha256sum "$PKG" | cut -d' ' -f1)"
elif command -v shasum >/dev/null 2>&1; then
  echo "sha256：$(shasum -a 256 "$PKG" | cut -d' ' -f1)"
fi

rm -rf "$BUILD/src"
mkdir -p "$BUILD/src"
tar -xzf "$PKG" -C "$BUILD/src"
SRC="$BUILD/src/workbuddy-manager-$TAG"
[ -f "$SRC/server/main.py" ] || { echo "发布包结构异常：缺少 server/main.py" >&2; exit 1; }
[ -f "$SRC/web/out/index.html" ] || { echo "发布包结构异常：缺少 web/out/index.html" >&2; exit 1; }
[ -f "$SRC/upstream/go.mod" ] || { echo "发布包结构异常：缺少 upstream/ 源码" >&2; exit 1; }

# ── 2. 组装 payload（持久化安装目录里的内容）────────────
echo "== 组装 payload =="
rm -rf "$MOD"
mkdir -p "$PAYLOAD/web" "$PAYLOAD/upstream" "$MOD/assets" "$MOD/bin" \
         "$MOD/META-INF/com/google/android"

cp -a "$SRC/server" "$PAYLOAD/server"
cp -a "$SRC/web/out" "$PAYLOAD/web/out"
cp -a "$SRC/deploy" "$PAYLOAD/deploy"
cp -a "$SRC/upstream/." "$PAYLOAD/upstream/"
cp -f "$SRC/.version" "$PAYLOAD/.version"
for f in CHANGELOG.md README.md README.en.md LICENSE; do
  [ -f "$SRC/$f" ] && cp -f "$SRC/$f" "$PAYLOAD/$f"
done
# 用户文档（只带 md，不带截图 —— 面板不依赖图片，能省几 MB）
if [ -d "$SRC/docs" ]; then
  mkdir -p "$PAYLOAD/docs"
  cp -f "$SRC"/docs/*.md "$PAYLOAD/docs/" 2>/dev/null || true
fi

# 不把任何用户数据/本地配置带进发布包
rm -rf "$PAYLOAD/upstream/auths" "$PAYLOAD/upstream/data" \
       "$PAYLOAD/upstream/config.json" "$PAYLOAD/upstream/.git"
mkdir -p "$PAYLOAD/upstream/auths" "$PAYLOAD/upstream/data"

# ── 3. 预编译上游二进制 ─────────────────────────────────
echo "== 编译上游（linux/arm64）=="
WBM_GOMOD_CACHE="$CACHE/gomod" GO_VERSION="$GO_VERSION" \
  bash "$ROOT/tools/build-upstream.sh" "$PAYLOAD/upstream" arm64
[ -x "$PAYLOAD/upstream/wb2api" ] || { echo "上游二进制构建失败" >&2; exit 1; }

# ── 4. 构建 rootfs ──────────────────────────────────────
ROOTFS_TGZ="$MOD/assets/rootfs-arm64.tar.gz"
if [ "${WBM_SKIP_ROOTFS:-0}" = "1" ]; then
  cached=""
  for cand in "$CACHE/rootfs-arm64.tar.gz" "$BUILD/rootfs-arm64.tar.gz"; do
    [ -s "$cand" ] && { cached=$cand; break; }
  done
  if [ -n "$cached" ]; then
    echo "== 复用缓存的 rootfs：$cached =="
    cp -f "$cached" "$ROOTFS_TGZ"
  else
    echo "WBM_SKIP_ROOTFS=1 但没有可复用的 rootfs（.cache/ 或 build/ 下）" >&2
    exit 1
  fi
else
  need docker
  echo "== 构建 arm64 rootfs（首次/依赖变化时较慢）=="
  CTX="$BUILD/rootfs-context"
  rm -rf "$CTX"; mkdir -p "$CTX"
  cp "$ROOT/tools/rootfs.Dockerfile" "$CTX/Dockerfile"
  cp "$PAYLOAD/server/requirements.txt" "$CTX/requirements.txt"
  cp -a "$ROOT/rootfs-overlay" "$CTX/overlay"

  IMAGE="wbm-rootfs:${TAG}"
  extra_args=()
  [ -n "${WBM_GO_URL:-}" ] && extra_args+=(--build-arg "GO_URL=${WBM_GO_URL}")
  if docker buildx version >/dev/null 2>&1; then
    docker buildx build --platform linux/arm64 --load \
      --build-arg "ALPINE_VERSION=${ALPINE_VERSION}" \
      --build-arg "GO_VERSION=${GO_VERSION}" \
      "${extra_args[@]}" \
      -t "$IMAGE" -f "$CTX/Dockerfile" "$CTX"
  else
    docker build --platform linux/arm64 \
      --build-arg "ALPINE_VERSION=${ALPINE_VERSION}" \
      --build-arg "GO_VERSION=${GO_VERSION}" \
      "${extra_args[@]}" \
      -t "$IMAGE" -f "$CTX/Dockerfile" "$CTX"
  fi

  cid=$(docker create --platform linux/arm64 "$IMAGE")
  trap 'docker rm -f "$cid" >/dev/null 2>&1 || true' EXIT
  docker export "$cid" > "$BUILD/rootfs.tar"
  docker rm -f "$cid" >/dev/null 2>&1 || true
  trap - EXIT
  gzip -9 -c "$BUILD/rootfs.tar" > "$ROOTFS_TGZ"
  # 只有显式要求时才缓存：rootfs 与 Python 依赖版本绑定，盲目复用会把旧
  # wheel 带进新版本。CI 缓存里只放发布包与 Go 模块缓存。
  if [ "${WBM_SAVE_ROOTFS:-0}" = "1" ]; then
    cp -f "$ROOTFS_TGZ" "$CACHE/rootfs-arm64.tar.gz"
  fi

  # 结构自检
  tar -tzf "$ROOTFS_TGZ" > "$BUILD/rootfs.list"
  for p in opt/wbm/bin/start-manager opt/go/bin/go usr/local/bin/docker usr/local/bin/systemctl; do
    grep -qx "\(\./\)\?$p" "$BUILD/rootfs.list" || { echo "rootfs 缺少 $p" >&2; exit 1; }
  done
  grep -q '^\(\./\)\?opt/wbm/wheels/' "$BUILD/rootfs.list" || { echo "rootfs 不含离线 wheel" >&2; exit 1; }
fi
echo "rootfs 大小：$(du -h "$ROOTFS_TGZ" | cut -f1)"

# ── 5. 组装模块目录 ─────────────────────────────────────
echo "== 组装模块 =="
cp -f "$ROOT/module.prop" "$MOD/module.prop"
cp -f "$ROOT/customize.sh" "$ROOT/service.sh" "$ROOT/uninstall.sh" "$ROOT/action.sh" "$MOD/"
cp -f "$ROOT/META-INF/com/google/android/update-binary" "$MOD/META-INF/com/google/android/"
cp -f "$ROOT/META-INF/com/google/android/updater-script" "$MOD/META-INF/com/google/android/"
cp -a "$ROOT/bin/." "$MOD/bin/"

VERSION_CODE=$(printf '%s' "$APP_VERSION" | awk -F. '{printf "%d%02d%02d", $1, $2, $3}')
sed -i "s/@APP_VERSION@/${APP_VERSION}/; s/@APP_VERSION_CODE@/${VERSION_CODE}/" "$MOD/module.prop"

{
  echo "app_version=${APP_VERSION}"
  echo "module_tag=${MODULE_TAG}"
  echo "alpine=${ALPINE_VERSION}"
  echo "go=${GO_VERSION}"
  echo "built_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  echo "upstream_id=$(cat "$PAYLOAD/upstream/.upstream-id" 2>/dev/null || echo unknown)"
} > "$MOD/build-info.txt"

chmod 755 "$MOD/customize.sh" "$MOD/service.sh" "$MOD/uninstall.sh" "$MOD/action.sh" \
          "$MOD/bin/"* "$MOD/META-INF/com/google/android/update-binary"
chmod 644 "$MOD/module.prop" "$MOD/META-INF/com/google/android/updater-script"

# ── 6. 打包（保留 Unix 权限位）──────────────────────────
OUT="$DIST/WorkBuddyManager-${MODULE_TAG}-arm64.zip"
rm -f "$OUT"
( cd "$MOD" && zip -qrX -9 "$OUT" . )
echo
echo "== 完成 =="
echo "模块：$OUT"
echo "大小：$(du -h "$OUT" | cut -f1)"
if command -v sha256sum >/dev/null 2>&1; then
  sha256sum "$OUT" | sed 's/^/sha256：/'
fi
