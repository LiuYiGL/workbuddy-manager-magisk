#!/bin/sh
# 在 Android 手机的 Alpine chroot 内原生构建 WorkBuddy Manager 模块。
#
# 不需要 Docker/QEMU：手机本身就是 arm64，apk/pip/go 都是原生执行。
#
# 约定路径（chroot 内）：
#   /build/repo                      本仓库快照
#   /build/pkg.tar.gz                WorkBuddy Manager 发布包
#   /build/alpine-minirootfs.tar.gz  Alpine minirootfs（与构建 chroot 同版本）
#   /build/go.tgz                    go<version>.linux-arm64.tar.gz
#   /build/src                       解压后的发布包
#   /build/target                    组装出的目标 rootfs
#   /build/module                    模块目录
#   /build/dist                      输出 zip
#
# 由宿主机（PC）通过 adb 建好 chroot、bind mount 与 /build 后调用：
#   chroot <rootfs> /bin/sh /build/repo/tools/ondevice/build-in-alpine.sh
set -eu

WORK=${WORK:-/build}
REPO=${REPO:-$WORK/repo}
PKG=${PKG:-$WORK/pkg.tar.gz}
ALPINE_MINI=${ALPINE_MINI:-$WORK/alpine-minirootfs.tar.gz}
GO_TGZ=${GO_TGZ:-$WORK/go.tgz}
GO_VERSION=${GO_VERSION:-1.27.3}
GOPROXY=${GOPROXY:-https://goproxy.cn,direct}
PIP_INDEX=${PIP_INDEX:-https://pypi.tuna.tsinghua.edu.cn/simple}

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
# 清掉从 Android/adb 继承的、会影响构建的变量
unset GOFLAGS GO111MODULE PIP_TARGET PYTHONPATH PYTHONHOME 2>/dev/null || true
# adb root 的环境里 TMPDIR 往往指向 /data/local/tmp，而 chroot 内没有 /data；
# Go 会因此创建 work dir 失败。这里全部改到 chroot 内。
export HOME=/root
export TMPDIR=/tmp
export GOTMPDIR=/build/go-tmp
export GOCACHE=/build/go-cache
export GOMODCACHE=/build/go-mod
mkdir -p "$TMPDIR" "$GOTMPDIR" "$GOCACHE" "$GOMODCACHE"

log() { echo; echo "== $* =="; }

[ -f "$PKG" ] || { echo "缺少发布包：$PKG" >&2; exit 1; }
[ -f "$ALPINE_MINI" ] || { echo "缺少 Alpine minirootfs：$ALPINE_MINI" >&2; exit 1; }
[ -f "$GO_TGZ" ] || { echo "缺少 Go 工具链：$GO_TGZ" >&2; exit 1; }
[ -d "$REPO" ] || { echo "缺少仓库快照：$REPO" >&2; exit 1; }

# ── 1. 构建 chroot 里的依赖 ────────────────────────────
if ! command -v python3 >/dev/null 2>&1 || ! command -v zip >/dev/null 2>&1; then
  log "安装构建依赖（apk）"
  apk add --no-cache bash curl ca-certificates tzdata python3 py3-pip \
      git coreutils findutils sed grep gzip tar xz jq zip
fi

# ── 2. 解压发布包、组装 payload ────────────────────────
log "解压发布包"
rm -rf "$WORK/src" "$WORK/module" "$WORK/dist"
mkdir -p "$WORK/src" "$WORK/module/assets" "$WORK/module/bin" "$WORK/dist"
tar -xzf "$PKG" -C "$WORK/src"
SRC=$(ls -d "$WORK/src"/workbuddy-manager-* 2>/dev/null | head -n 1)
[ -f "$SRC/server/main.py" ] || { echo "发布包缺少 server/main.py" >&2; exit 1; }
[ -f "$SRC/web/out/index.html" ] || { echo "发布包缺少 web/out/index.html" >&2; exit 1; }

TAG=$(tr -d '\r\n' < "$SRC/.version")
APP_VERSION=${TAG#v}
# 产物文件名可用 WBM_MODULE_TAG 指定（如 v2.11.9-android.1）；默认跟上游版本。
MODULE_TAG=${WBM_MODULE_TAG:-$TAG}
[ -n "$APP_VERSION" ] || APP_VERSION=$(sed -n "s/.*version='\([^']*\)'.*/\1/p" "$SRC/server/main.py" | head -n 1)

PAYLOAD="$WORK/module/payload/app"
mkdir -p "$PAYLOAD/web"
cp -a "$SRC/server" "$PAYLOAD/server"
cp -a "$SRC/web/out" "$PAYLOAD/web/out"
cp -a "$SRC/deploy" "$PAYLOAD/deploy"
mkdir -p "$PAYLOAD/upstream"
cp -a "$SRC/upstream/." "$PAYLOAD/upstream/"
cp -f "$SRC/.version" "$PAYLOAD/.version"
for f in CHANGELOG.md README.md README.en.md LICENSE; do
  [ -f "$SRC/$f" ] && cp -f "$SRC/$f" "$PAYLOAD/$f"
done
if [ -d "$SRC/docs" ]; then
  mkdir -p "$PAYLOAD/docs"
  cp -f "$SRC"/docs/*.md "$PAYLOAD/docs/" 2>/dev/null || true
fi
rm -rf "$PAYLOAD/upstream/auths" "$PAYLOAD/upstream/data" \
       "$PAYLOAD/upstream/config.json" "$PAYLOAD/upstream/.git"
mkdir -p "$PAYLOAD/upstream/auths" "$PAYLOAD/upstream/data"

# ── 3. 原生编译上游 ────────────────────────────────────
log "解压 Go 工具链"
rm -rf "$WORK/go"
tar -C "$WORK" -xzf "$GO_TGZ"
rm -rf "$WORK/go/test" "$WORK/go/doc" "$WORK/go/misc" "$WORK/go/api"

export GOROOT="$WORK/go"
export PATH="$GOROOT/bin:$PATH"
export CGO_ENABLED=0 GOOS=linux GOARCH=arm64
export GOPROXY GOTOOLCHAIN=auto
go version

log "编译上游（原生 arm64）"
cd "$PAYLOAD/upstream"
for spec in \
  "wb2api ./cmd/server" \
  "signin_bin ./cmd/signin" \
  "login ./cmd/login" \
  "credit ./cmd/credit" \
  "trial_bin ./cmd/trial" \
  "activity_bin ./cmd/activity"; do
  name=${spec%% *}
  pkg=${spec#* }
  if [ ! -d "$pkg" ]; then
    [ "$name" = wb2api ] && { echo "缺少 $pkg" >&2; exit 1; }
    echo "  跳过不存在的 $pkg"
    continue
  fi
  echo "  build $name"
  go build -trimpath -ldflags="-s -w" -o "$name" "$pkg"
done
chmod 755 wb2api signin_bin login credit trial_bin activity_bin 2>/dev/null || true
cd "$WORK"

# ── 4. 组装目标 rootfs ─────────────────────────────────
log "组装目标 rootfs（apk --root）"
rm -rf "$WORK/target"
mkdir -p "$WORK/target"
tar -xzf "$ALPINE_MINI" -C "$WORK/target"
mkdir -p "$WORK/target/proc" "$WORK/target/dev" "$WORK/target/sys" \
         "$WORK/target/workbuddy" "$WORK/target/tmp" \
         "$WORK/target/etc/apk" "$WORK/target/opt/wbm/wheels"
cp -f /etc/apk/repositories "$WORK/target/etc/apk/repositories"
echo "nameserver 223.5.5.5" > "$WORK/target/etc/resolv.conf"
chmod 1777 "$WORK/target/tmp"

# apk --root 会在目标里跑包脚本；挂上 /proc /dev /sys 更稳
mount -o bind /proc "$WORK/target/proc" 2>/dev/null || true
mount -o bind /dev  "$WORK/target/dev"  2>/dev/null || true
mount -o bind /sys  "$WORK/target/sys"  2>/dev/null || true

apk --root "$WORK/target" --initdb --no-cache add \
  bash curl ca-certificates tzdata jq python3 py3-pip libstdc++ \
  git coreutils findutils sed grep gzip tar xz

umount "$WORK/target/sys" 2>/dev/null || true
umount "$WORK/target/dev" 2>/dev/null || true
umount "$WORK/target/proc" 2>/dev/null || true

rm -f "$WORK/target/.dockerenv" 2>/dev/null || true

# ── 5. 离线 wheelhouse ─────────────────────────────────
log "下载 Python wheel（arm64/musl）"
python3 -m pip install --no-cache-dir --break-system-packages \
  --index-url "$PIP_INDEX" --upgrade pip >/dev/null
python3 -m pip download --no-cache-dir --only-binary=:all: \
  --index-url "$PIP_INDEX" \
  --dest "$WORK/target/opt/wbm/wheels" \
  -r "$PAYLOAD/server/requirements.txt"
[ -n "$(ls -A "$WORK/target/opt/wbm/wheels")" ] || { echo "wheelhouse 为空" >&2; exit 1; }

# ── 6. Go 工具链与运行时脚本写入目标 ───────────────────
log "写入 Go 工具链与运行时脚本"
mkdir -p "$WORK/target/opt"
cp -a "$WORK/go" "$WORK/target/opt/go"
rm -rf "$WORK/target/opt/go/test" "$WORK/target/opt/go/doc" \
       "$WORK/target/opt/go/misc" "$WORK/target/opt/go/api"

cp -a "$REPO/rootfs-overlay/." "$WORK/target/"
chmod -R 755 "$WORK/target/opt/wbm/bin" \
             "$WORK/target/usr/local/bin/docker" \
             "$WORK/target/usr/local/bin/systemctl"

{
  echo "app_version=$APP_VERSION"
  echo "module_tag=$MODULE_TAG"
  echo "alpine=3.22.7"
  echo "go=$GO_VERSION"
  echo "built_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  echo "upstream_id=$(cat "$PAYLOAD/upstream/.upstream-id" 2>/dev/null || echo unknown)"
} > "$WORK/module/build-info.txt"

log "打包 rootfs"
tar -C "$WORK/target" -cf - . | gzip -9 > "$WORK/module/assets/rootfs-arm64.tar.gz"
ls -lh "$WORK/module/assets/rootfs-arm64.tar.gz"

# ── 7. 组装模块 ────────────────────────────────────────
log "组装模块目录"
cp -f "$REPO/module.prop" "$WORK/module/module.prop"
cp -f "$REPO/customize.sh" "$REPO/service.sh" "$REPO/uninstall.sh" "$WORK/module/"
cp -a "$REPO/webroot" "$WORK/module/"
cp -a "$REPO/bin/." "$WORK/module/bin/"
mkdir -p "$WORK/module/META-INF/com/google/android"
cp -f "$REPO/META-INF/com/google/android/update-binary" \
      "$REPO/META-INF/com/google/android/updater-script" \
      "$WORK/module/META-INF/com/google/android/"
cp -f "$WORK/module/build-info.txt" "$WORK/module/" 2>/dev/null || true

VERSION_CODE=$(printf '%s' "$APP_VERSION" | awk -F. '{printf "%d%02d%02d", $1, $2, $3}')
sed -i "s/@APP_VERSION@/${APP_VERSION}/; s/@APP_VERSION_CODE@/${VERSION_CODE}/" \
  "$WORK/module/module.prop"

chmod 755 "$WORK/module/customize.sh" "$WORK/module/service.sh" \
          "$WORK/module/uninstall.sh" "$WORK/module/bin/"* \
          "$WORK/module/META-INF/com/google/android/update-binary"
chmod 644 "$WORK/module/module.prop" \
          "$WORK/module/META-INF/com/google/android/updater-script"

log "生成 zip"
OUT="$WORK/dist/WorkBuddyManager-${MODULE_TAG}-arm64.zip"
rm -f "$OUT"
( cd "$WORK/module" && zip -qrX -9 "$OUT" . )
ls -lh "$OUT"
sha256sum "$OUT" 2>/dev/null || true

echo
echo "构建完成：$OUT"
