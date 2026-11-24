#!/usr/bin/env bash
# 检查 shell 脚本里**内嵌 Python** 的语法
#
# 缘起 Round 120：`bash -n` 通过，但内嵌 Python 有重复行导致语法错误，
# 脚本静默失败（错误被 2>/dev/null 吞掉），工具输出为空却"看起来正常"。
# ⇒ bash -n 不检查 heredoc 里的 Python，必须有专门检查。
set -uo pipefail
cd "$(dirname "$0")"
bad=0
for f in *.sh; do
  out=$(python3 - "$f" <<'PY'
import re,sys
path=sys.argv[1]
try: src=open(path,encoding='utf-8').read()
except Exception: sys.exit(0)
blocks=re.findall(r"<<'PY'\n(.*?)\nPY\b", src, re.S)+re.findall(r"<<PY\n(.*?)\nPY\b", src, re.S)
errs=0
for i,b in enumerate(blocks,1):
    try: compile(b,f"<{path}#{i}>",'exec')
    except SyntaxError as e:
        print(f"  ✗ {path} 内嵌 Python 块#{i}: 行 {e.lineno}: {str(e.text).strip()[:60]}")
        errs+=1
sys.exit(1 if errs else 0)
PY
) || { echo "$out"; bad=$((bad+1)); }
done
if [ "$bad" -eq 0 ]; then
  echo "  ✓ 所有内嵌 Python 语法正确"; exit 0
else
  echo "  ✗ $bad 个脚本的内嵌 Python 有语法错误"; exit 1
fi
