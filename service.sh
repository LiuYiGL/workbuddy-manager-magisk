#!/system/bin/sh
# 开机启动脚本（Magisk late_start / KernelSU 对应阶段）。
# 等待系统启动完成后再拉起监督进程，避免早期网络/存储未就绪。
MODDIR=${0%/*}
DATA=/data/adb/workbuddy-manager
LOG=$DATA/logs/supervisor.log

mkdir -p "$DATA/logs" 2>/dev/null

i=0
while [ "$(getprop sys.boot_completed 2>/dev/null)" != "1" ] && [ "$i" -lt 180 ]; do
  i=$((i + 1))
  sleep 2
done

if [ ! -x "$DATA/bin/wbm-ctl" ]; then
  echo "[service] wbm-ctl 不存在，安装可能未完成" >> "$LOG" 2>/dev/null
  exit 0
fi

# wbm-ctl start 会自行 setsid 后台化，并处理上次开机遗留的 PID。
sh "$DATA/bin/wbm-ctl" start >> "$LOG" 2>&1
exit 0
