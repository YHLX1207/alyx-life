#!/usr/bin/env bash
# adb 客户端自愈：检测包装脚本是否完好，缺失则从备份重建
#
# 缘起 Round 109：/opt/elevation/bin/adb 是 790 字节 shim，
# 全系统唯一一份，是设备访问的**单点故障**。
# 已备份到 state/adb-backup/，本脚本负责检测与重建（不改动原件，除非它真的坏了）。
set -uo pipefail
cd "$(dirname "$0")"
WRAPPER=/opt/elevation/bin/adb
REAL=/opt/elevation/real/adb
BACKUP=../state/adb-backup/adb-wrapper.sh
SOCK=localfilesystem:/opt/elevation/adb.sock
HOME_D=/opt/elevation/home
KEYS=/opt/elevation/home/.android/keys

ok(){ echo "  ✓ $*"; }

# 1) 真二进制存在？
if [ ! -x "$REAL" ]; then
  echo "  ✗ 真二进制缺失: $REAL —— 无法自愈（需重装 DSHBox 开发者模式）"; exit 1
fi

# 2) wrapper 存在且可执行？
if [ -x "$WRAPPER" ]; then
  ok "wrapper 存在"
else
  echo "  ⚠ wrapper 缺失或不可执行，尝试从备份重建…"
  if [ -f "$BACKUP" ]; then
    mkdir -p /opt/elevation/bin 2>/dev/null || true
    cp "$BACKUP" "$WRAPPER" && chmod +x "$WRAPPER" && ok "已重建: $WRAPPER" \
      || { echo "  ✗ 重建失败（可能无写权限）"; exit 1; }
  else
    echo "  ✗ 备份也缺失: $BACKUP"; exit 1
  fi
fi

# 3) 实际可用性（最终判据）
if timeout 12 adb -s 127.0.0.1:5555 shell "echo ADB_OK" 2>/dev/null | grep -q ADB_OK; then
  ok "通道可用（经 wrapper）"
elif HOME="$HOME_D" ADB_VENDOR_KEYS="$KEYS" ADB_SERVER_SOCKET="$SOCK" \
     timeout 12 "$REAL" -s 127.0.0.1:5555 shell "echo ADB_OK" 2>/dev/null | grep -q ADB_OK; then
  echo "  ⚠ wrapper 失效但真二进制可用 —— 通道本身正常"
  echo "    （若需修复 wrapper，可手动 cp $BACKUP $WRAPPER）"
else
  echo "  ✗ 两条路径都不可用 —— 需人工介入（可能设备端 adbd 未开 tcp 模式）"
  exit 1
fi
