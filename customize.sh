#!/system/bin/sh
# WorkBuddy Manager（Android）安装脚本。
#
# 目标：安装过程**完全离线**。rootfs（Alpine + Python + Go 工具链 + 离线 wheel）、
# 管理端代码、上游源码与预编译二进制都随 zip 分发；安装时只做解压、复制与本地
# pip 安装，不访问网络。
#
# 兼容：Magisk / KernelSU（两者都执行 customize.sh）。Magisk 的 ui_print / abort
# 在 KernelSU 中也可用；这里仍做了兜底定义。

SKIPUNZIP=0

if ! command -v ui_print >/dev/null 2>&1; then
  ui_print() { echo "$1"; }
fi
if ! command -v abort >/dev/null 2>&1; then
  abort() { echo "! $1" >&2; exit 1; }
fi

# ── 基础变量 ────────────────────────────────────────────
MODID=workbuddy_manager
DATA=/data/adb/workbuddy-manager
MODDIR_FINAL=/data/adb/modules/$MODID
ROOTFS="$MODPATH/rootfs"

# 从模块脚本里读常量（避免两处写死）
. "$MODPATH/bin/wbm-lib.sh" 2>/dev/null || true
WBM_MODDIR=$MODPATH
WBM_ROOTFS=$ROOTFS
WBM_DATA=$DATA
export WBM_MODDIR WBM_ROOTFS WBM_DATA

ui_print "***************************************"
ui_print " WorkBuddy Manager (Android) 安装程序"
ui_print " Magisk / KernelSU · 离线安装"
ui_print "***************************************"
ui_print ""

# ── 平台检查 ────────────────────────────────────────────
arch=${ARCH:-$(uname -m)}
case "$arch" in
  arm64|aarch64) ;;
  *)
    ui_print "! 本模块目前只提供 arm64 (aarch64) 运行时。"
    ui_print "! 当前架构：$arch"
    abort "不支持的架构"
    ;;
esac
[ "$(getprop ro.build.version.sdk 2>/dev/null || echo 0)" -ge 26 ] 2>/dev/null || \
  ui_print "! 警告：Android 版本低于 8.0（API 26），未测试。"

# ── 磁盘空间 ────────────────────────────────────────────
free_kb=$(df -k /data 2>/dev/null | awk 'NR==2 {print $4}')
case "$free_kb" in
  ''|*[!0-9]*) ;;
  *) [ "$free_kb" -lt 900000 ] && abort "需要至少 900MB 可用空间（当前约 $((free_kb/1024))MB）" ;;
esac

# ── 停止旧实例 ──────────────────────────────────────────
# 面板的一键更新是脱离管理端的独立进程；若它正在替换 server/rootfs 相关文件，
# 此刻刷模块会破坏它。更新锁里是 worker 的 PID。
LOCK=$DATA/data/update.lock
if [ -f "$LOCK" ]; then
  lpid=$(cat "$LOCK" 2>/dev/null | tr -dc '0-9')
  if [ -n "$lpid" ] && kill -0 "$lpid" 2>/dev/null; then
    lst=$(sed 's/.*) //' "/proc/$lpid/stat" 2>/dev/null | cut -d' ' -f1)
    if [ "$lst" != "Z" ]; then
      abort "面板正在执行更新（pid $lpid），请等它完成后再安装模块"
    fi
  fi
fi

if [ -f "$DATA/bin/wbm-ctl" ]; then
  ui_print "- 停止已运行的服务…"
  sh "$DATA/bin/wbm-ctl" stop >/dev/null 2>&1 || true
fi

# 旧模块目录如果还有 bind mount（同一 mount namespace），必须先卸载；
# 否则 Magisk 替换模块目录时可能穿过挂载点操作 /workbuddy（用户数据）。
OLD_ROOTFS=$MODDIR_FINAL/rootfs
if [ -d "$OLD_ROOTFS" ]; then
  _save_rootfs=$WBM_ROOTFS
  WBM_ROOTFS=$OLD_ROOTFS
  wbm_umount_all
  WBM_ROOTFS=$_save_rootfs
  if grep -q " $OLD_ROOTFS/" /proc/mounts 2>/dev/null; then
    abort "旧运行时仍处于挂载状态，请重启设备后再安装模块"
  fi
fi

mkdir -p "$DATA" "$DATA/app" "$DATA/data" "$DATA/pylibs" "$DATA/run" \
         "$DATA/logs" "$DATA/home" "$DATA/tmp" "$DATA/etc" \
         "$DATA/go/pkg/mod" "$DATA/go/cache" "$DATA/go/tmp" "$DATA/bin"
chmod 700 "$DATA" 2>/dev/null || true

# ── 1. 解压 rootfs ──────────────────────────────────────
ui_print "- 解压 Android 运行时（Alpine + Python + Go）…"
rm -rf "$ROOTFS"
mkdir -p "$ROOTFS"
if ! wbm_tar -xzf "$MODPATH/assets/rootfs-arm64.tar.gz" -C "$ROOTFS"; then
  abort "rootfs 解压失败"
fi
if [ ! -x "$ROOTFS/opt/wbm/bin/start-manager" ]; then
  chmod -R 755 "$ROOTFS/opt/wbm/bin" "$ROOTFS/usr/local/bin" 2>/dev/null
fi
[ -x "$ROOTFS/bin/sh" ] || abort "rootfs 不完整（缺少 /bin/sh）"
chmod 1777 "$ROOTFS/tmp" 2>/dev/null || true
# 防御：docker export 可能带上 /.dockerenv。它会让 update.py 的自动探测
# 误判为“容器内部”（进而尝试 kill PID 1 = Android init）。我们显式设置了
# WB_RUN_MODE=systemd，但这里仍然清掉。
rm -f "$ROOTFS/.dockerenv" 2>/dev/null || true

# ── 2. 安装控制脚本到持久化目录 ─────────────────────────
ui_print "- 安装控制脚本…"
mkdir -p "$DATA/bin"
cp -f "$MODPATH/bin/wbm-lib.sh"   "$DATA/bin/"
cp -f "$MODPATH/bin/wbm-ctl"      "$DATA/bin/"
cp -f "$MODPATH/bin/wbm-supervise" "$DATA/bin/"
chmod 755 "$DATA/bin/"* 2>/dev/null

# ── 3. 安装管理端 / 上游代码 ────────────────────────────
# 版本比较：只有在包里版本 >= 现有版本时才覆盖，避免模块包比面板内
# “一键更新”的版本旧时把用户降级。
ver_ge() {
  awk -v a="$1" -v b="$2" 'BEGIN{
    sub(/^[vV]/,"",a); sub(/^[vV]/,"",b);
    na=split(a,A,"."); nb=split(b,B,".");
    for(i=1;i<=3;i++){ x=A[i]+0; y=B[i]+0;
      if(x>y){exit 0} if(x<y){exit 1} }
    exit 0
  }'
}

install_payload() {
  src="$MODPATH/payload/app"
  dst="$DATA/app"
  [ -d "$src" ] || return 0
  PAYLOAD_INSTALLED=0

  new_ver=$(cat "$src/.version" 2>/dev/null)
  cur_ver=$(cat "$dst/.version" 2>/dev/null)
  if [ -n "$cur_ver" ] && [ -n "$new_ver" ] && ver_ge "$cur_ver" "$new_ver"; then
    ui_print "- 保留现有代码（$cur_ver >= 包内 $new_ver）"
    return 0
  fi

  ui_print "- 安装管理端代码 ${new_ver:-（版本未知）}…"
  # 上游目录里的用户数据必须原样保留
  keep="$DATA/.upstream-keep.$$"
  rm -rf "$keep"; mkdir -p "$keep"
  for x in config.json auths data .git; do
    [ -e "$dst/upstream/$x" ] && wbm_cp -a "$dst/upstream/$x" "$keep/" 2>/dev/null
  done

  rm -rf "$dst/server" "$dst/web" "$dst/deploy" "$dst/docs" "$dst/upstream"
  for x in server web deploy docs upstream .version CHANGELOG.md README.md README.en.md LICENSE; do
    [ -e "$src/$x" ] && wbm_cp -a "$src/$x" "$dst/" 2>/dev/null
  done

  for x in config.json auths data .git; do
    [ -e "$keep/$x" ] && wbm_cp -a "$keep/$x" "$dst/upstream/" 2>/dev/null
  done
  rm -rf "$keep"

  mkdir -p "$dst/upstream/auths" "$dst/upstream/data"
  chmod 755 "$dst/upstream"/wb2api "$dst/upstream"/signin_bin \
              "$dst/upstream"/login "$dst/upstream"/credit \
              "$dst/upstream"/trial_bin "$dst/upstream"/activity_bin 2>/dev/null
  chmod 755 "$dst/upstream"/*.sh 2>/dev/null
  chmod 755 "$dst/upstream"/scripts/*.py "$dst/upstream"/scripts/*.sh 2>/dev/null
  PAYLOAD_INSTALLED=1
}
PAYLOAD_INSTALLED=0
install_payload

[ -f "$DATA/app/server/main.py" ] || abort "管理端代码安装失败（$DATA/app/server/main.py 不存在）"
if [ ! -f "$DATA/app/upstream/wb2api" ]; then
  ui_print "! 未找到预编译上游二进制，将在首次启动时用设备内 Go 重建"
fi

# ── 4. 首次配置（.env / config.json / 管理员密码）──────
rand_hex() {
  n=${1:-12}
  o=$(od -An -tx1 -N "$n" /dev/urandom 2>/dev/null | tr -d ' \n')
  if [ -z "$o" ]; then o="$(date +%s)$RANDOM"; fi
  echo "$o"
}

if [ ! -f "$DATA/app/.env" ]; then
  ui_print "- 生成首次运行配置…"
  pw=$(rand_hex 12)
  cat > "$DATA/app/.env" <<EOF
# WorkBuddy Manager on Android
# 修改后执行：sh $DATA/bin/wbm-ctl restart

# 面板监听地址：默认只监听本机；如需局域网访问改成 0.0.0.0（先确认风险）
WB_MANAGER_HOST=127.0.0.1
WB_MANAGER_PORT=7864
WB_ADMIN_PASSWORD=$pw
WB_SECURE_COOKIE=auto
WB_SESSION_DAYS=1
WB_SESSION_IDLE_HOURS=12
WB_TRUST_PROXY=0
WB_TRUSTED_PROXY_CIDRS=127.0.0.0/8,::1/128

# 更新相关（可选）
# WB_UPDATE_PROXY=http://127.0.0.1:7890
# WB_HTTP_PROXY=
# WB_GITHUB_MIRROR=https://gh-proxy.com/
# PIP_INDEX_URL=https://pypi.tuna.tsinghua.edu.cn/simple
# WB_GOPROXY=https://goproxy.cn,direct
# 设备上编译上游时 Go 使用的 HTTP 代理（Go 只认 HTTPS_PROXY/HTTP_PROXY）
# HTTPS_PROXY=http://127.0.0.1:7890

# 对外网关
WB_GATEWAY_RATE_PER_MIN=120
WB_GATEWAY_MAX_BODY_MB=32
EOF
  chmod 600 "$DATA/app/.env"
  printf '%s\n' "面板：http://127.0.0.1:7864/    管理员密码：$pw" > "$DATA/webui.txt"
  chmod 600 "$DATA/webui.txt"
  INIT_PW=$pw
else
  # 已有配置：管理员密码可能已经在面板里改过，不再从 .env 回显
  INIT_PW=""
fi

if [ ! -f "$DATA/app/upstream/config.json" ]; then
  ui_print "- 生成上游配置…"
  if [ -f "$DATA/app/upstream/config.example.json" ]; then
    cp -f "$DATA/app/upstream/config.example.json" "$DATA/app/upstream/config.json"
  else
    printf '{"listen":"127.0.0.1:7863","api_key":"%s"}\n' "$(rand_hex 16)" \
      > "$DATA/app/upstream/config.json"
  fi
  sed -i 's#"listen"[[:space:]]*:[[:space:]]*":7863"#"listen": "127.0.0.1:7863"#' \
    "$DATA/app/upstream/config.json" 2>/dev/null || true
  sed -i "s#\"api_key\"[[:space:]]*:[[:space:]]*\"test_key\"#\"api_key\": \"$(rand_hex 16)\"#" \
    "$DATA/app/upstream/config.json" 2>/dev/null || true
  chmod 600 "$DATA/app/upstream/config.json"
fi

# ── 5. 离线安装 Python 依赖 ─────────────────────────────
# 只在两种情况下安装：
#   · 本次确实换上了包内的管理端代码（依赖要与代码匹配）；
#   · 保留的是更新过的代码，但 rootfs 的 Python 版本变了（旧 pylibs 的
#     编译扩展会失效）。
# 其余情况不动 pylibs —— 否则旧模块包里的 wheel 可能把用户已经在线升级过的
# 依赖降级。
root_py=$(basename "$(ls -d "$ROOTFS"/usr/lib/python3.* 2>/dev/null | tail -n 1)" 2>/dev/null)
marker_py=""
[ -f "$DATA/pylibs/.wbm-python" ] && marker_py=$(cat "$DATA/pylibs/.wbm-python" 2>/dev/null)

need_deps=0
[ "$PAYLOAD_INSTALLED" = "1" ] && need_deps=1
[ -n "$root_py" ] && [ "$marker_py" != "$root_py" ] && need_deps=1

if [ "$need_deps" = "1" ]; then
  ui_print "- 安装 Python 依赖（离线 wheel）…"
  if wbm_setup_mounts; then
    if [ "$PAYLOAD_INSTALLED" = "1" ]; then
      req=/workbuddy/app/server/requirements.txt
      wbm_chroot /bin/sh -c "
        . /opt/wbm/bin/wbm-env.sh
        python3 -m pip install -q --break-system-packages --no-index \
          --find-links /opt/wbm/wheels -r $req
      " >>"$DATA/logs/setup.log" 2>&1
      rc=$?
    else
      # 保留了更新过的代码、但 Python 版本变了：包内 wheel 未必满足新代码。
      # 先试本地 wheel，再（可选地）用网络补齐 —— 安装本身不依赖网络。
      req=/workbuddy/app/server/requirements.txt
      wbm_chroot /bin/sh -c "
        . /opt/wbm/bin/wbm-env.sh
        python3 -m pip install -q --break-system-packages --no-index \
          --find-links /opt/wbm/wheels -r $req \
        || python3 -m pip install -q --break-system-packages -r $req
      " >>"$DATA/logs/setup.log" 2>&1
      rc=$?
    fi
    wbm_umount_all
    if [ "$rc" -eq 0 ]; then
      [ -n "$root_py" ] && printf '%s\n' "$root_py" > "$DATA/pylibs/.wbm-python"
      ui_print "  依赖已安装"
    else
      ui_print "! 离线依赖安装未完成（首次启动会自动重试）"
      ui_print "! 详情：$DATA/logs/setup.log"
    fi
  else
    ui_print "! 无法建立临时挂载；首次启动时会自动安装依赖"
  fi
else
  ui_print "- Python 依赖已存在（$marker_py），跳过"
fi

# ── 6. 收尾 ─────────────────────────────────────────────
chmod 700 "$DATA" "$DATA/app" "$DATA/data" 2>/dev/null || true
chmod -R 700 "$DATA/app/upstream/auths" 2>/dev/null || true

# 大文件已解压/复制到持久化目录，删除安装临时内容以节省 /data 空间
rm -rf "$MODPATH/payload" 2>/dev/null
rm -f "$MODPATH/assets/rootfs-arm64.tar.gz" 2>/dev/null
rmdir "$MODPATH/assets" 2>/dev/null || true

ui_print ""
ui_print "安装完成。"
ui_print "重启后在手机浏览器打开：http://127.0.0.1:7864/"
if [ -n "${INIT_PW:-}" ]; then
  ui_print "管理员密码：$INIT_PW"
  ui_print "（也保存在 $DATA/webui.txt）"
fi
ui_print ""
ui_print "命令行：sh $DATA/bin/wbm-ctl status|logs|restart"
ui_print "首次启动若显示未运行，请执行：sh $DATA/bin/wbm-ctl start"
ui_print ""

# 尝试安装后立即启动（等模块目录就位）；失败也不影响，重启后 service.sh 会拉起。
_bb=$(wbm_busybox)
if [ -n "$_bb" ] && "$_bb" setsid true >/dev/null 2>&1; then
  "$_bb" setsid sh -c "sleep 12; [ -d $MODDIR_FINAL/rootfs ] && sh $DATA/bin/wbm-ctl start" \
    >/dev/null 2>&1 </dev/null &
elif command -v setsid >/dev/null 2>&1; then
  setsid sh -c "sleep 12; [ -d $MODDIR_FINAL/rootfs ] && sh $DATA/bin/wbm-ctl start" \
    >/dev/null 2>&1 </dev/null &
else
  ( sleep 12; [ -d "$MODDIR_FINAL/rootfs" ] && sh "$DATA/bin/wbm-ctl" start ) \
    >/dev/null 2>&1 </dev/null &
fi
