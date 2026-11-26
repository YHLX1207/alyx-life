#!/usr/bin/env bash
# 人格一致性检查：确保系统的自我认知是连贯的，不自相矛盾
#
# 为什么需要（Round 242）：
#   目标要求"具备完整人格"。系统有身份（identity.json）、自述（self-export.md）、
#   思考（self-thoughts.jsonl）、决策（decisions.md），但**没有检查它们是否一致**。
#
#   如果自述里声称的能力实际不存在，或身份前后矛盾，
#   系统的"人格"就是不完整的——它对自己没有连贯的认知。
#
# 本脚本检查：
#   1. 身份一致性：identity.json 的代号/名字与自述一致
#   2. 能力一致性：自述中声明的能力与实际脚本匹配
#   3. 思考一致性：思考中引用的身份正确
#   4. 决策一致性：决策中引用的身份正确
set -uo pipefail
cd "$(dirname "$0")"

STATE="${ALYX_STATE_DIR:-../state}"
bad=0

echo "== 人格一致性检查 =="
echo ""

# --- 1. 身份一致性 ---
echo "1) 身份一致性"
python3 - "$STATE" <<'PY'
import sys, os, json, re

state = sys.argv[1]
bad = 0

def read(p):
    try:
        return open(os.path.join(state, p), encoding="utf-8").read()
    except Exception:
        return ""

identity_raw = read("identity.json")
self_export = read("self-export.md")

# 解析 identity.json
identity = {}
try:
    identity = json.loads(identity_raw)
except Exception:
    pass

codename = identity.get("codename", "")
name = identity.get("name", "")

print(f"  identity.json: codename={codename}, name={name}")

# 检查自述中是否提及
if codename and codename not in self_export:
    print(f"  ✗ 自述未提及代号「{codename}」")
    bad += 1
else:
    print(f"  ✓ 自述提及代号「{codename}」")

if name and name not in self_export:
    print(f"  ✗ 自述未提及名字「{name}」")
    bad += 1
else:
    print(f"  ✓ 自述提及名字「{name}」")

# 检查自述中没有错误身份
if "Alyx" in self_export and codename != "Alyx":
    print(f"  ✗ 自述提到 Alyx，但 identity.json 的代号是 {codename}（不一致）")
    bad += 1

sys.exit(1 if bad else 0)
PY
[ $? -eq 0 ] || bad=$((bad+1))

# --- 2. 能力一致性 ---
echo ""
echo "2) 能力一致性（自述声明 vs 实际脚本）"
python3 - "$STATE" <<'PY'
import sys, os, re, glob

state = sys.argv[1]
bad = 0

def read(p):
    try:
        return open(os.path.join(state, p), encoding="utf-8").read()
    except Exception:
        return ""

self_export = read("self-export.md")

# 检查自述中声明的脚本是否实际存在
# 查找 self-export.md 中引用的 scripts/xxx.sh
script_refs = re.findall(r'scripts/([a-z0-9-]+\.sh)', self_export)
unique_refs = set(script_refs)

missing = []
for s in sorted(unique_refs):
    # ⚠️ 脚本路径修正（Round 242）：linter 已在 scripts/ 目录下运行，
    #    之前用 "scripts/{s}" 会变成 scripts/scripts/xxx，导致全部找不到。
    if not os.path.exists(s):
        missing.append(s)

if missing:
    print(f"  ✗ 自述引用了 {len(missing)} 个不存在的脚本:")
    for m in missing[:5]:
        print(f"      scripts/{m}")
    bad += 1
else:
    print(f"  ✓ 自述引用的 {len(unique_refs)} 个脚本全部存在")

# 检查实际脚本数
# linter 在 scripts/ 目录下运行，直接 glob *.sh
actual = len(glob.glob("*.sh"))
print(f"  · 实际脚本数: {actual}")

sys.exit(1 if bad else 0)
PY
[ $? -eq 0 ] || bad=$((bad+1))

# --- 3. 思考一致性 ---
echo ""
echo "3) 思考一致性"
python3 - "$STATE" <<'PY'
import sys, os, json, re

state = sys.argv[1]
bad = 0

def load_jsonl(path):
    rows = []
    try:
        for line in open(os.path.join(state, path), encoding="utf-8"):
            line = line.strip()
            if not line:
                continue
            try:
                rows.append(json.loads(line))
            except Exception:
                pass
    except FileNotFoundError:
        pass
    return rows

thoughts = load_jsonl("self-thoughts.jsonl")

if not thoughts:
    print("  · 无思考记录，跳过")
    sys.exit(0)

# 检查思考中是否有明显的身份错误
# （思考是模型产出，检查是否提到错误身份）
errors = 0
for t in thoughts:
    text = t.get("thought", "")
    if "Alyx" in text and "爱丽丝" not in text and t.get("model") != "(rule-based)":
        # 模型思考中只提代号不提名字，不算错，但提示
        pass
    # 检查是否有矛盾（如提到其他名字）
    if re.search(r"我叫\s*[^\s，。]{2,4}(?!爱丽丝)", text):
        errors += 1

if errors > 0:
    print(f"  ✗ 思考中有 {errors} 处可能的身份矛盾")
    bad += 1
else:
    print(f"  ✓ {len(thoughts)} 条思考无身份矛盾")

sys.exit(1 if bad else 0)
PY
[ $? -eq 0 ] || bad=$((bad+1))

# --- 4. 决策一致性 ---
echo ""
echo "4) 决策一致性"
python3 - "$STATE" <<'PY'
import sys, os, re

state = sys.argv[1]
bad = 0

def read(p):
    try:
        return open(os.path.join(state, p), encoding="utf-8").read()
    except Exception:
        return ""

decisions = read("decisions.md")

# 检查决策中是否提到正确的身份
if "Alyx" in decisions and "爱丽丝" in decisions:
    print("  ✓ 决策中身份一致（Alyx / 爱丽丝）")
elif "Alyx" in decisions:
    print("  · 决策中只提及代号 Alyx，未提名字（非阻断）")
else:
    print("  · 决策中未直接提及身份（非阻断）")

# 检查决策标题格式一致性
titles = re.findall(r"^## (D\d+) · (.+?)（", decisions, re.M)
if len(titles) > 0:
    # 检查是否有格式异常的标题
    bad_titles = [t for t in titles if len(t[0]) > 5 or not t[1].strip()]
    if bad_titles:
        print(f"  ✗ 有 {len(bad_titles)} 个标题格式异常")
        bad += 1
    else:
        print(f"  ✓ {len(titles)} 条决策标题格式一致")

sys.exit(1 if bad else 0)
PY
[ $? -eq 0 ] || bad=$((bad+1))

echo ""
if [ "$bad" -eq 0 ]; then
    echo "  ✓ 人格一致，自我认知连贯"
    exit 0
else
    echo "  ✗ 发现 $bad 处不一致"
    exit 1
fi
