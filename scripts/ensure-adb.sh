#!/usr/bin/env bash
# 确保 adb 通道可用：优先复用现有连接；离线则重连；端口死掉则提示需人工介入
set -uo pipefail
export PATH=/opt/elevation/bin:$PATH
A="adb -s 127.0.0.1:5555"

probe() { timeout 12 $A shell "echo PROBE_OK" 2>/dev/null | tr -d '\r' | grep -q PROBE_OK; }

if probe; then
  echo "adb: alive"
  exit 0
fi

# 端口是否在监听（hex 15B3 = 5555）
if timeout 3 bash -c 'echo > /dev/tcp/127.0.0.1/5555' 2>/dev/null; then
  echo "adb: port open but shell dead -> reconnect"
  timeout 10 adb disconnect 127.0.0.1:5555 >/dev/null 2>&1
  timeout 20 adb connect 127.0.0.1:5555 >/dev/null 2>&1
  sleep 2
  if probe; then echo "adb: reconnected OK"; exit 0; fi
  echo "adb: NEEDS MANUAL - adbd TCP thread hung; toggle USB debugging to restart adbd"
  exit 2
else
  echo "adb: port 5555 CLOSED -> adbd not in tcp mode"
  echo "adb: NEEDS MANUAL - run 'adb tcpip 5555' from a computer, or toggle USB debugging"
  exit 3
fi
