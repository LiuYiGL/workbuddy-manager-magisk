#!/system/bin/sh
# Magisk / KernelSU 模块页「操作」按钮。
# 作用：启动/确认服务，等待面板就绪后尝试在浏览器打开面板。
# 注意：这里运行在 Android shell（不是 chroot），用 /system/bin 下的工具。
set -u

DATA=/data/adb/workbuddy-manager
CTL=$DATA/bin/wbm-ctl
ENV=$DATA/app/.env

echo "== WorkBuddy Manager =="

if [ ! -x "$CTL" ]; then
  echo "未找到 $CTL，请先安装模块。"
  exit 1
fi

port=$(sed -n 's/^[[:space:]]*WB_MANAGER_PORT[[:space:]]*=[[:space:]]*//p' "$ENV" 2>/dev/null \
  | tail -n 1 | sed 's/^"//; s/"$//' | tr -d '\r')
[ -n "$port" ] || port=7864

echo "- 启动服务…"
sh "$CTL" start || true

echo "- 等待面板就绪…"
i=0
code=000
while [ "$i" -lt 15 ]; do
  if [ -x /system/bin/curl ]; then
    code=$(/system/bin/curl -s -o /dev/null -w '%{http_code}' --max-time 2 \
      "http://127.0.0.1:$port/api/healthz" 2>/dev/null)
  else
    code=200
  fi
  [ "$code" = 200 ] && break
  i=$((i + 1))
  sleep 1
done

echo "- 面板：http://127.0.0.1:$port/"

if [ -x /system/bin/am ]; then
  /system/bin/am start --user 0 -a android.intent.action.VIEW \
    -d "http://127.0.0.1:$port/" >/dev/null 2>&1 \
  || /system/bin/am start -a android.intent.action.VIEW \
    -d "http://127.0.0.1:$port/" >/dev/null 2>&1 \
  || echo "! 无法自动打开浏览器，请手动访问上面的地址"
else
  echo "! 未找到 am 命令，请手动访问上面的地址"
fi

echo "完成。"
exit 0
