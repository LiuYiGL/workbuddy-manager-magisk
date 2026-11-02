#!/usr/bin/env bash
# 本地静态检查（不需要 Docker / Go）。
# 检查：shell 语法、必要文件、module.prop 占位符、脚本执行位。
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"
fail=0

echo "== shell 语法 =="
while IFS= read -r f; do
  if bash -n "$f" 2>/tmp/wbm-syntax.err; then
    echo "ok   $f"
  else
    echo "FAIL $f"; cat /tmp/wbm-syntax.err; fail=1
  fi
done < <(find . -type f \( -name '*.sh' -o -path './bin/*' -o -path './rootfs-overlay/*' \) \
          ! -path './build/*' ! -path './.cache/*' ! -name '*.md')

echo
echo "== 必要文件 =="
for f in module.prop customize.sh service.sh uninstall.sh \
         META-INF/com/google/android/update-binary \
         bin/wbm-lib.sh bin/wbm-ctl bin/wbm-supervise \
         rootfs-overlay/opt/wbm/bin/wbm-env.sh \
         rootfs-overlay/opt/wbm/bin/start-manager \
         rootfs-overlay/opt/wbm/bin/start-upstream \
         rootfs-overlay/opt/wbm/bin/stop-upstream \
         rootfs-overlay/opt/wbm/bin/rebuild-upstream \
         rootfs-overlay/usr/local/bin/docker \
         rootfs-overlay/usr/local/bin/systemctl \
         tools/build.sh tools/rootfs.Dockerfile tools/build-upstream.sh; do
  [ -f "$f" ] && echo "ok   $f" || { echo "MISS $f"; fail=1; }
done

echo
echo "== module.prop =="
grep -q '^id=workbuddy_manager$' module.prop && echo "ok   id" || { echo "FAIL id"; fail=1; }
grep -q '@APP_VERSION@' module.prop && echo "ok   版本占位符由构建脚本替换" || echo "warn 没有版本占位符"

echo
echo "== 脚本 shebang =="
for f in customize.sh service.sh uninstall.sh bin/wbm-ctl bin/wbm-supervise; do
  head -n 1 "$f" | grep -q '^#!/system/bin/sh' && echo "ok   $f" || { echo "FAIL shebang $f"; fail=1; }
done
for f in rootfs-overlay/opt/wbm/bin/* rootfs-overlay/usr/local/bin/*; do
  head -n 1 "$f" | grep -q '^#!/bin/sh' && echo "ok   $f" || { echo "FAIL shebang $f"; fail=1; }
done

echo
[ "$fail" -eq 0 ] && echo "全部检查通过" || { echo "存在失败项"; exit 1; }
