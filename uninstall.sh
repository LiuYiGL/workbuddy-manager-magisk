#!/system/bin/sh
# 模块卸载：停止进程、卸载 chroot 挂载。
#
# 默认**保留** /data/adb/workbuddy-manager（账号凭据、数据库、日志、离线依赖）。
# 这些是不可再生的用户数据，静默删除风险太高。确认不再需要时手动执行：
#   rm -rf /data/adb/workbuddy-manager
DATA=/data/adb/workbuddy-manager

if [ -x "$DATA/bin/wbm-ctl" ]; then
  sh "$DATA/bin/wbm-ctl" stop >/dev/null 2>&1
fi

# 兜底卸载（进程被杀后挂载点可能仍存在）
ROOTFS=/data/adb/modules/workbuddy_manager/rootfs
if [ -d "$ROOTFS" ]; then
  for d in workbuddy sys dev/pts dev proc; do
    umount "$ROOTFS/$d" 2>/dev/null || true
  done
fi

echo "[wbm] 已卸载模块。用户数据保留在 $DATA"
echo "[wbm] 如需彻底清理：rm -rf $DATA"
exit 0
