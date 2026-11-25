#!/usr/bin/env bash
# 检查 shell 脚本里**内嵌 Python** 的语法
#
# 缘起 Round 120：`bash -n` 通过，但内嵌 Python 有重复行导致语法错误，
# 脚本静默失败（错误被 2>/dev/null 吞掉），工具输出为空却"看起来正常"。
# ⇒ bash -n 不检查 heredoc 里的 Python，必须有专门检查。
#
# Round 203 修正：正则 `<<'PY'\n` 太严（标记后带 `|| _rc=$?` 时不匹配），
# 后又太松（会匹配注释里的 `<<'PY'`）。改为**行级提取**：
#   · 只认**非注释行**里的 heredoc 标记
#   · 从标记行之后取内容，直到行首为 `PY` 的结束标记
set -uo pipefail
cd "$(dirname "$0")"
bad=0
for f in *.sh; do
  out=$(python3 - "$f" <<'PY'
import sys

path = sys.argv[1]
try:
    lines = open(path, encoding='utf-8').read().split('\n')
except Exception:
    sys.exit(0)

def is_comment(l):
    s = l.lstrip()
    return s.startswith('#')

def find_markers(line):
    """返回该行里所有 heredoc 标记（<<'PY' 或 <<PY），及其列位置"""
    out = []
    i = 0
    n = len(line)
    while i < n:
        j = line.find('<<', i)
        if j < 0:
            break
        rest = line[j+2:]
        for q in ('\'PY\'', 'PY'):
            if rest.startswith(q):
                out.append(j + 2 + len(q))
                i = j + 2 + len(q)
                break
        else:
            i = j + 2
    return out

blocks = []
i = 0
n = len(lines)
while i < n:
    line = lines[i]
    if not is_comment(line):
        for pos in find_markers(line):
            # 取标记后到下一个行首 PY 之间的内容
            j = i + 1
            while j < n and lines[j].strip() != 'PY':
                j += 1
            if j < n:
                blocks.append('\n'.join(lines[i+1:j]))
            i = j
            break
    i += 1

errs = 0
for k, b in enumerate(blocks, 1):
    try:
        compile(b, f"<{path}#{k}>", 'exec')
    except SyntaxError as e:
        txt = (e.text or '').strip()[:60]
        print(f"  ✗ {path} 内嵌 Python 块#{k}: 行 {e.lineno}: {txt}")
        errs += 1
sys.exit(1 if errs else 0)
PY
) || { echo "$out"; bad=$((bad+1)); }
done
if [ "$bad" -eq 0 ]; then
  echo "  ✓ 所有内嵌 Python 语法正确"; exit 0
else
  echo "  ✗ $bad 个脚本的内嵌 Python 有语法错误"; exit 1
fi
