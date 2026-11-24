#!/usr/bin/env bash
# 在**没有设备、没有 adb、没有 pilot** 的环境下自检。
#
# 用途：GitHub Actions 上每周期运行一次，证明"我的核心逻辑仍然有效"。
# 明确只跑**纯本地**的检查，不做任何设备操作。
set -uo pipefail
cd "$(dirname "$0")"
pass=0; fail=0
ok(){ printf "  ✓ %s\n" "$*"; pass=$((pass+1)); }
bad(){ printf "  ✗ %s\n" "$*"; fail=$((fail+1)); }

# 1. 内嵌 Python 语法
./lint-embedded-py.sh >/dev/null 2>&1 && ok "内嵌 Python 语法" || bad "内嵌 Python 语法"
# 2. 裸路径
./lint-paths.sh >/dev/null 2>&1 && ok "无裸相对路径" || bad "无裸相对路径"
# 3. 数据源
./lint-datasource.sh >/dev/null 2>&1 && ok "未依赖不可靠数据源" || bad "未依赖不可靠数据源"
# 4. 探针质量
./lint-probe.sh >/dev/null 2>&1 && ok "探针质量" || bad "探针质量"
# 5. README 覆盖
./lint-readme.sh >/dev/null 2>&1 && ok "README 覆盖全部脚本" || bad "README 覆盖全部脚本"
# 6. 策略单元测试
./test-policy.sh >/dev/null 2>&1 && ok "调度策略 9 项" || bad "调度策略 9 项"
# 7. 入口一致
./lint-entrypoints.sh >/dev/null 2>&1 && ok "入口一致" || bad "入口一致"
# 8. 兜底文本
./lint-fallback.sh >/dev/null 2>&1 && ok "兜底文本无漂移" || bad "兜底文本无漂移"
# 9. 自述可生成
ALYX_NO_REDUNDANT=1 ./export-self.sh /tmp/p.md >/dev/null 2>&1 && [ -s /tmp/p.md ] \
  && ok "自我导出可生成" || bad "自我导出可生成"
[ -f /tmp/p.md ] && rm -f /tmp/p.md

echo
echo "  可移植检查: $pass 通过 / $fail 失败"
[ $fail -eq 0 ]
