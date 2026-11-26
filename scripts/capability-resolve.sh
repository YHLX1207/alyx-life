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

# 凭据来源映射：环境变量名 → 本机文件路径
# ⚠️ 只看环境变量会误判（Round 219 实测）：
#    publish 在设备节点被判"缺 GH_TOKEN"，但本机 token 文件存在，
#    且 snapshot-release.sh 实际已成功发布多次。
#    **能力判定要以"实际可否完成"为准，不是"环境变量是否被 export"。**
ENV_FILE_FALLBACK = {
    "GH_TOKEN": os.path.join(state, "secrets", "github.token"),
}

def check_env(spec):
    missing = []
    for env in spec.get("requires_env") or []:
        if os.environ.get(env):
            continue
        # 环境变量缺失 ⇒ 看是否有本机文件等价来源
        fb = ENV_FILE_FALLBACK.get(env)
        if fb and os.path.exists(fb) and os.path.getsize(fb) > 20:
            continue
        missing.append(env)
    return missing

PROBE_HISTORY = os.path.join(state, "capability-probe.jsonl")
PROBE_FAIL_THRESHOLD = 3   # 连续失败 N 次才判定不可用

def _record_probe(cap, ok):
    """记录一次探测结果（只保留最近 50 条）"""
    try:
        rec = {"ts": now, "cap": cap, "ok": bool(ok)}
        with open(PROBE_HISTORY, "a", encoding="utf-8") as f:
            f.write(json.dumps(rec) + "\n")
        lines = [l for l in open(PROBE_HISTORY, encoding="utf-8") if l.strip()]
        if len(lines) > 50:
            open(PROBE_HISTORY, "w", encoding="utf-8").writelines(lines[-50:])
    except Exception:
        pass

def _consecutive_failures(cap):
    """该能力最近连续失败次数"""
    try:
        rows = []
        for line in open(PROBE_HISTORY, encoding="utf-8"):
            line = line.strip()
            if not line:
                continue
            try:
                r = json.loads(line)
            except Exception:
                continue
            if r.get("cap") == cap:
                rows.append(r)
        n = 0
        for r in reversed(rows):
            if r.get("ok"):
                break
            n += 1
        return n
    except Exception:
        return 0

def check_gateway():
    """推理能力专用：网关是否可达
    ⚠️ 抗瞬时抖动（Round 218）：单次失败不降级，
       连续 PROBE_FAIL_THRESHOLD 次失败才判不可用。
       实测：网关偶发抖动会让单次探测失败，而它其实是通的。"""
    import urllib.request
    key = os.environ.get("ALYX_GATEWAY_KEY") or ""
    if not key:
        kf = "/root/projects/.dsh/openai-gateway/api-key"
        if os.path.exists(kf):
            key = open(kf, encoding="utf-8").read().strip()
    if not key:
        _record_probe("think", False)
        return False
    gw = os.environ.get("ALYX_GATEWAY_URL") or "http://127.0.0.1:8326/v1"
    # 单次探测内重试 2 次（快速重试，消除瞬时抖动）
    for _ in range(2):
        try:
            req = urllib.request.Request(gw + "/models",
                                         headers={"Authorization": f"Bearer {key}", "User-Agent": "alyx"})
            urllib.request.urlopen(req, timeout=8).read(32)
            _record_probe("think", True)
            return True
        except Exception:
            continue
    # 两次都失败：看历史，连续失败够多才降级
    _record_probe("think", False)
    fails = _consecutive_failures("think")
    if fails >= PROBE_FAIL_THRESHOLD:
        return False
    # 未达阈值：保守地认为仍可用（上一次是通的）
    return True

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
