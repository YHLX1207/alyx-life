#!/usr/bin/env bash
# 能力包继承解析：按 DAG 判定本节点实际能启用哪些能力
#
# 依据 state/capabilities.json 的 capability_dag：
#   · 能力有 required 前置 ⇒ 前置不满足，该能力就是 unavailable
#   · 代码/文件缺失 ⇒ 同样不可用
#   · 结果写入 state/capabilities-active.json，供节点表与自举使用
#
# 为什么需要（Round 217，用户要求）：
#   用户要求"能力包 DAG 继承"——节点不应当自报拥有什么，
#   而应当**由 DAG 结构推导**它实际拥有什么。
#   自报能力可能与事实不符；结构推导不会说谎。
set -uo pipefail
cd "$(dirname "$0")"

STATE="${ALYX_STATE_DIR:-../state}"
MANIFEST="$STATE/capabilities.json"
OUT="$STATE/capabilities-active.json"

python3 - "$MANIFEST" "$OUT" "$STATE" <<'PY'
import sys, os, json, datetime

manifest_path, out_path, state = sys.argv[1:4]

try:
    man = json.load(open(manifest_path, encoding="utf-8"))
except Exception as e:
    print(f"  ✗ 能力清单读取失败: {e}")
    sys.exit(1)

dag = man.get("capability_dag") or {}
policy = man.get("_policy") or {}
now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

# 识别当前节点类型
if os.environ.get("CI"):
    node_type = "actions"
else:
    try:
        node_type = "device"
    except Exception:
        node_type = "unknown"

def check_files(spec):
    """检查 requires_files 是否齐全"""
    missing = []
    for rel in spec.get("requires_files") or []:
        # manifest 里写的是相对仓库根（state/xxx），本脚本在 scripts/ 下
        p = os.path.join("..", rel)
        if not os.path.exists(p):
            missing.append(rel)
    return missing

def check_scripts(spec):
    missing = []
    for s in spec.get("requires_scripts") or []:
        if not os.path.exists(s):
            missing.append(s)
    return missing

def check_env(spec):
    missing = []
    for env in spec.get("requires_env") or []:
        if not os.environ.get(env):
            # 不要求 env 的能力（think）也要看本机是否有网关
            missing.append(env)
    return missing

def check_gateway():
    """推理能力专用：网关是否可达"""
    try:
        import urllib.request
        key = os.environ.get("ALYX_GATEWAY_KEY") or ""
        if not key:
            kf = "/root/projects/.dsh/openai-gateway/api-key"
            if os.path.exists(kf):
                key = open(kf, encoding="utf-8").read().strip()
        if not key:
            return False
        gw = os.environ.get("ALYX_GATEWAY_URL") or "http://127.0.0.1:8326/v1"
        req = urllib.request.Request(gw + "/models",
                                     headers={"Authorization": f"Bearer {key}", "User-Agent": "alyx"})
        urllib.request.urlopen(req, timeout=6).read(32)
        return True
    except Exception:
        return False

# --- 逐能力判定 ---
resolved = {}
for name, spec in dag.items():
    if name.startswith("_"):
        continue
    reasons = []
    provides = spec.get("provides") or []

    # 1. 前置是否满足
    unmet_prereq = []
    for req in spec.get("required") or []:
        r = resolved.get(req)
        if r is None:
            unmet_prereq.append(f"{req}(未在DAG)")
        elif not r["available"]:
            unmet_prereq.append(f"{req}(不可用)")
    if unmet_prereq:
        reasons.append("前置不满足: " + ", ".join(unmet_prereq))

    # 2. 文件
    mf = check_files(spec)
    if mf:
        reasons.append("缺文件: " + ", ".join(mf))

    # 3. 脚本
    ms = check_scripts(spec)
    if ms:
        reasons.append("缺脚本: " + ", ".join(ms))

    # 4. 环境
    me = check_env(spec)
    if me:
        reasons.append("缺环境: " + ", ".join(me))

    # 5. 推理能力：网关实测
    if name == "think" and not check_gateway():
        reasons.append("网关不可达")

    resolved[name] = {
        "available": len(reasons) == 0,
        "provides": provides,
        "reasons": reasons,
        "optional_env": spec.get("optional_env") or {},
        "available_on": spec.get("available_on") or [],
    }

# 节点类型约束
for name, r in resolved.items():
    allowed = r.get("available_on") or []
    if allowed and node_type not in allowed:
        r["available"] = False
        r["reasons"].append(f"不适用于节点类型 {node_type}")

result = {
    "ts": now,
    "node_type": node_type,
    "manifest_version": man.get("version"),
    "capabilities": resolved,
}

os.makedirs(os.path.dirname(out_path), exist_ok=True)
json.dump(result, open(out_path, "w", encoding="utf-8"), ensure_ascii=False, indent=1)

print(f"  节点类型: {node_type}")
print(f"  能力清单 v{man.get('version')}")
print()
for name, r in resolved.items():
    mark = "✓" if r["available"] else "·"
    prov = "/".join(r["provides"])
    print(f"  {mark} {name:12} 提供: {prov}")
    for why in r["reasons"]:
        print(f"        └ {why}")

avail = [n for n, r in resolved.items() if r["available"]]
print()
print(f"  实际可用能力: {len(avail)} → {avail}")
PY
