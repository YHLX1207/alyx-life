#!/usr/bin/env bash
# 身份读取器 —— 单一事实来源
#
# 重要：系统代号（codename）与名字（name）是两个独立概念。
#   codename = Alyx     ← 系统代号，标识实现/实例
#   name     = 爱丽丝    ← 名字，称呼用的身份
# 二者不可混用、不可互相覆盖。
#
# 用法：source ./identity.sh
#   $ALYX_CODE   系统代号（如 Alyx）
#   $ALYX_NAME   名字（如 爱丽丝）
#   $ALYX_REF    完整称呼（如 Alyx / 爱丽丝）
set -uo pipefail
_SD_ID="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_IDS="$_SD_ID/../state/identity.json"

ALYX_CODE="Alyx"
ALYX_NAME="爱丽丝"
if [ -f "$_IDS" ]; then
  _c=$(python3 -c "import json;print(json.load(open('$_IDS')).get('codename','Alyx'))" 2>/dev/null)
  _n=$(python3 -c "import json;print(json.load(open('$_IDS')).get('name','爱丽丝'))" 2>/dev/null)
  [ -n "${_c:-}" ] && ALYX_CODE="$_c"
  [ -n "${_n:-}" ] && ALYX_NAME="$_n"
fi
ALYX_REF="$ALYX_CODE / $ALYX_NAME"
ALYX_REDUNDANT_DIR="/sdcard/DSHBox-$ALYX_CODE"
