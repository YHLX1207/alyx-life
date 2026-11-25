#!/usr/bin/env bash
# 检查 heredoc 退出码是否被捕获
#
# 背景（Round 183）：
#   `python3 - <<'PY' ... PY` 的退出码**不会**传给 bash 脚本。
#   若 Python 里调用 sys.exit(非零)，bash 仍返回 0 —— 检查"永远通过"。
#
#   这个问题在 D177（check-products.sh）和 D178（lint-checks.sh）各出现一次。
#   两次都是"检查本身失效"，比功能 bug 更危险。
set -uo pipefail
cd "$(dirname "$0")"

RS=$(python3 - <<'PY'
import glob, re, sys

bad = []
for path in sorted(glob.glob("*.sh")):
    if path == "lint-heredoc-rc.sh":
        continue   # 跳过自己，避免注释里的示例被自匹配
    try:
        src = open(path, encoding="utf-8").read()
    except Exception:
        continue
    # 提取 heredoc 块（结束标记可能顶格）
    blocks = re.findall(r"python3 - <<'(\w+)'[^\n]*\n(.*?)\n\s*\1\s*$", src, re.S | re.M)
    for mark, code in blocks:
        if not re.search(r"sys\.exit\(\s*[1-9]", code):
            continue
        # 找到调用行，看是否有捕获
        for m in re.finditer(r"python3 - <<'" + mark + r"'([^\n]*)", src):
            tail = m.group(1)
            if "||" in tail or "_rc=" in tail:
                continue
            line_no = src[:m.start()].count("\n") + 1
            bad.append(f"{path}:{line_no}  <<'{mark}' 含 sys.exit(非零) 但未捕获")

if bad:
    for b in bad:
        print(f"  ✗ {b}")
    sys.exit(1)
print("  ✓ 所有 heredoc 的退出码处理正确")
sys.exit(0)
PY
)
_rc=$?
echo "$RS"
exit $_rc
