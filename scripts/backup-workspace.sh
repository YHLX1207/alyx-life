#!/usr/bin/env bash
# 工作区完整备份：把 scripts/ + state/ + notes/ 打包到设备公共存储
#
# 缘起 Round 110：/sdcard/DSHBox-Alyx/ 里只有 self-export.md（摘要），
# **47 个脚本从未备份**。若 /root/projects/life 丢失，我建立的一切全消失。
#
# 目标位置在公共存储，DSHBox 重装后仍保留。
set -uo pipefail
cd "$(dirname "$0")"
DEST_DIR=/sdcard/DSHBox-Alyx
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
ARCHIVE="$DEST_DIR/workspace-$STAMP.tar.gz"
KEEP=3   # 只保留最近 3 份

export PATH=/opt/elevation/bin:$PATH
A="adb -s 127.0.0.1:5555"

# 先在本地打包（排除临时文件与超大历史）
TMP=$(mktemp /tmp/life-bk.XXXXXX.tar.gz)
trap 'rm -f "$TMP"' EXIT

# ⚠️ cwd 已是 scripts/，`-C ..` 之后路径**不该再带 life/ 前缀**。
# Round 110 首版写成 `-C .. life/scripts` → 解析为 life/life/scripts（不存在）
# ⇒ tar 打包 0 文件、45 字节空包，却因 2>/dev/null 隐藏错误而"报成功"。
# ⚠️ 必须排除全部敏感文件（Round 218）：
#    此前用 `tar -C .. state` 整目录打包，会把以下内容一并备份：
#      · state/secrets/           GitHub token
#      · state/did-keys.json      门限 DID 私钥份额（泄露 2 份即可冒用身份）
#      · state/did-signature.json 签名产物
#    /sdcard 虽非公开，但备份可能被同步/分享/上传，不能依赖"它在本地"。
tar czf "$TMP" \
  --exclude='*.tmp' --exclude='.brief.*' --exclude='local-archive.tar.gz' \
  --exclude='state/secrets' --exclude='state/secrets/*' \
  --exclude='state/did-keys.json' --exclude='state/did-signature.json' \
  --exclude='state/watchdog.pid' \
  -C .. scripts state notes README.md 设备手册.md 2>/dev/null

if [ ! -s "$TMP" ]; then echo "  ✗ 打包失败（空文件）"; exit 1; fi
_NFILES=$(tar tzf "$TMP" 2>/dev/null | grep -c 'life\|scripts/\|state/\|notes/\|README\|设备手册' || echo 0)
# 双保险：包内必须有实际内容（首版 45 字节空包曾误报成功）
if [ "${_NFILES:-0}" -lt 20 ]; then
  echo "  ✗ 打包内容异常（仅 ${_NFILES} 项，预期 >=20）—— 疑似路径错误"
  exit 1
fi

LOCAL_SUM=$(md5sum "$TMP" | cut -d' ' -f1)
SIZE=$(wc -c < "$TMP")

# ⚠️ 先在本地留一份（Round 137）：推送失败时这是**唯一**的备份
#    注意包内路径是 scripts/ state/ notes/（无 life/ 前缀），与 /sdcard 版本一致
cp "$TMP" ../state/local-archive.tar.gz 2>/dev/null && echo "  本地档案已更新: state/local-archive.tar.gz"

# 推送到设备
if ! timeout 60 $A push "$TMP" "$ARCHIVE" >/dev/null 2>&1; then
  # ⚠️ 本地档案已在上面更新过（这是有效的冗余副本）。
  #    推送失败只说明 /sdcard 不可用，不代表备份完全失败。
  #    用专门的退出码 2 区分，避免守护记成"整体失败"（Round 186）。
  echo "  ⚠ 推送失败（adb 不可用），本地档案已更新"
  exit 2
fi

# 校验远端一致
REMOTE_SUM=$(timeout 30 $A shell "md5sum '$ARCHIVE' 2>/dev/null" 2>/dev/null | tr -d '\r' | cut -d' ' -f1)
if [ "$LOCAL_SUM" != "$REMOTE_SUM" ]; then
  echo "  ✗ 校验失败（本地 $LOCAL_SUM / 远端 $REMOTE_SUM）"; exit 1
fi

echo "  ✓ 已备份: $ARCHIVE"
echo "    大小 $(( SIZE / 1024 )) KB  md5 ${LOCAL_SUM:0:12}…  校验一致"

# 清理旧备份，只留最近 KEEP 份
# ⚠️ 方向必须正确：升序排列时**最旧在前**，
#    保留最新 KEEP 份 = 删除前 (总数-KEEP) 项（Round 127 曾搞反，把最新备份删了）
_total=$(timeout 30 $A shell "ls -1 $DEST_DIR/workspace-*.tar.gz 2>/dev/null | wc -l" 2>/dev/null | tr -d '\r')
_del=$(( ${_total:-0} - KEEP ))
OLD=""
if [ "${_del:-0}" -gt 0 ]; then
  OLD=$(timeout 30 $A shell "ls -1 $DEST_DIR/workspace-*.tar.gz 2>/dev/null | sort" 2>/dev/null | tr -d '\r' | head -n "$_del")
fi
if [ -n "$OLD" ]; then
# ⚠️ 必须用 for 循环：`while read` + 管道时，内部的 adb/timeout 会**抢走 stdin**，
#    导致循环只处理第一项就提前退出（Round 127 实测：3 份只删掉 1 份）。
for f in $OLD; do
  [ -n "$f" ] || continue
  timeout 20 $A shell "rm -f '$f'" >/dev/null 2>&1
  if [ -z "$(timeout 20 $A shell "ls '$f' 2>/dev/null" 2>/dev/null | tr -d '\r')" ]; then
    echo "    已清理旧备份: $(basename "$f")"
  else
    echo "    ⚠ 清理失败: $(basename "$f")"
  fi
done
fi

echo "  当前保留: $(timeout 20 $A shell "ls -1 $DEST_DIR/workspace-*.tar.gz 2>/dev/null | wc -l" 2>/dev/null | tr -d '\r') 份"
