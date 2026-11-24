#!/usr/bin/env bash
# 确保 Shizuku 服务运行；未运行则通过 adb starter 拉起
set -uo pipefail
export PATH=/opt/elevation/bin:$PATH
A="adb -s 127.0.0.1:5555"

alive=$(timeout 10 $A shell "ps -A -o NAME 2>/dev/null | grep -c '^shizuku_server$'" 2>/dev/null | tr -d '\r')
if [ "${alive:-0}" -ge 1 ]; then
  echo "shizuku: already running (pid $(timeout 8 $A shell "pidof shizuku_server" 2>/dev/null | tr -d '\r'))"
  exit 0
fi

# 动态解析 starter 路径（安装哈希会随应用更新变化）
SO=$(timeout 10 $A shell "pm path moe.shizuku.privileged.api 2>/dev/null" 2>/dev/null | tr -d '\r' | sed 's|package:||; s|/base.apk$||')
if [ -z "$SO" ]; then echo "ERROR: shizuku apk not found"; exit 1; fi
STARTER="$SO/lib/arm64/libshizuku.so"

echo "starting via: $STARTER"
timeout 30 $A shell "$STARTER" 2>&1 | tr -d '\r' | sed 's/^/  /'
sleep 3

alive=$(timeout 10 $A shell "ps -A -o NAME 2>/dev/null | grep -c '^shizuku_server$'" 2>/dev/null | tr -d '\r')
if [ "${alive:-0}" -ge 1 ]; then
  echo "shizuku: started OK (pid $(timeout 8 $A shell "pidof shizuku_server" 2>/dev/null | tr -d '\r'))"
  exit 0
else
  echo "shizuku: FAILED to start"
  exit 1
fi
