#!/usr/bin/env bash
# 产物检查：验证"每轮必变的数据"是否真的在更新
#
# 为什么需要（Round 179）：
#   我在 D159/D164/D165/D167/D174 五次遇到"步骤 success 但产物没变"。
#   每次都是靠人工翻日志才发现。这个脚本把那个排查过程自动化。
#
# 与 verify.sh 的区别：
#   verify.sh 检查"系统功能是否正常"（脚本能跑、依赖齐全）
#   check-products.sh 检查"数据是否真的在流动"（产物是否新鲜）
set -uo pipefail
cd "$(dirname "$0")"

TOKEN="${GH_TOKEN:-}"
[ -n "$TOKEN" ] || TOKEN=$(cat ../state/secrets/github.token 2>/dev/null || echo "")
REPO="${GITHUB_REPOSITORY:-YHLX1207/alyx-life}"

# 每个产物的最大容忍年龄（分钟）
MAX_AGE_JOURNAL=45       # 心跳：设计 30 分钟一轮
MAX_AGE_REFLECTIONS=45
MAX_AGE_DECISIONS=45
MAX_AGE_WATCHLOG=120     # 互监：每 20 轮 ≈1h

_rc=0
python3 - "$TOKEN" "$REPO" <<'PY' || _rc=$?
import sys, json, base64, urllib.request, urllib.error, datetime, os, time

token, repo = sys.argv[1], sys.argv[2]
now = datetime.datetime.now(datetime.timezone.utc)

# ⚠️ 阈值依据（Round 194 实测）：
#    心跳 23 分钟 / 自省 33 分钟 / 决策 34 分钟 / 互监 24 分钟。
#    原阈值 45 分钟对"决策"只有 1.3x 余量，正常波动就会误报。
#    统一提到 90 分钟（约 2.6x），既能容忍波动，又能发现真断更。
CHECKS = [
    ("journal",         "state/journal.jsonl",         "心跳",   90),
    ("reflections",     "state/reflections.jsonl",     "自省",   90),
    ("chain-decisions", "state/chain-decisions.jsonl", "决策",   90),
    ("watch-log",       "state/watch-log.jsonl",       "互监",  120),
    ("nodes",           "state/nodes.json",            "节点",  120),
    # ⚠️ 自述曾静默过时 20 小时（Round 188）。它虽不是"每轮必变"，
    #    但一旦过时就会误导接手者，必须纳入检查。
    ("self-export",     "state/self-export.md",        "自述",  120),
    # decisions.md 是最重要的成长记录（185 条）。虽靠 git 写回目前正常，
    # 但一旦被 rebase 丢弃不会有任何信号（Round 189）。
    ("decisions",       "state/decisions.md",          "决策史", 4320),
    # ⚠️ 站外种子（paste.rs）是独立备份链。CI 中的 offsite-seed 曾持续失败
    #    （重试未能解决，属非瞬时原因），而步骤是 continue-on-error，失败不可见。
    #    纳入检查：记录陈旧即说明 CI 的刷新没成功（Round 208）。
    ("offsite-seed",    "state/offsite-seed.jsonl",    "站外种子", 180),
]

def fetch(remote_path):
    if token:
        # ⚠️ 重试 2 次（Round 203）：GitHub API 偶发抖动会让抓取失败，
        #    而失败会被判为"产物不存在"⇒ 假失败。重试能消除这类噪音。
        for _attempt in range(2):
            try:
                req = urllib.request.Request(
                    f"https://api.github.com/repos/{repo}/contents/{remote_path}",
                    headers={"Authorization": f"token {token}", "User-Agent": "alyx",
                             "Accept": "application/vnd.github+json", "Connection": "close"})
                d = json.loads(urllib.request.urlopen(req, timeout=25).read())
                raw = base64.b64decode(d.get("content", "")).decode("utf-8", "ignore")
                return raw, "remote"
            except Exception:
                if _attempt == 0:
                    time.sleep(1.5)
                continue
    local = os.path.join("..", remote_path)
    if os.path.exists(local):
        return open(local, encoding="utf-8").read(), "local"
    return None, None

def newest_ts(raw, name):
    """从 jsonl / json / markdown 中取最新时间戳"""
    if name == "decisions":
        # ⚠️ 标题只有日期（YYYY-MM-DD），构造 00:00Z 会让当天新写的决策
        #    显示成"18 小时前"，判据失真（Round 193）。
        #    改用 GitHub API 的**最后提交时间**，精确到秒。
        import urllib.request as _ur, json as _json, os as _os
        # ⚠️ 隔离测试时（设置了 ALYX_STATE_DIR）不查远端，否则模拟数据被真实数据覆盖
        if _os.environ.get("ALYX_STATE_DIR"):
            import re as _re2
            ms = _re2.findall(r"^## D\d+ · .+?（(\d{4}-\d{2}-\d{2})", raw, _re2.M)
            return f"{ms[-1]}T00:00:00Z" if ms else None
        try:
            req = _ur.Request(
                "https://api.github.com/repos/YHLX1207/alyx-life/commits?path=state/decisions.md&per_page=1",
                headers={"Authorization": f"token {token}" if token else "",
                         "User-Agent": "alyx",
                         "Accept": "application/vnd.github+json",
                         "Connection": "close"})
            d = _json.loads(_ur.urlopen(req, timeout=15).read())
            if isinstance(d, list) and d:
                return d[0]["commit"]["committer"]["date"]
        except Exception:
            pass
        # 回退：标题日期
        import re as _re
        ms = _re.findall(r"^## D\d+ · .+?（(\d{4}-\d{2}-\d{2})", raw, _re.M)
        return f"{ms[-1]}T00:00:00Z" if ms else None
    if name == "self-export":
        # markdown 里找 "导出时间：YYYY-MM-DDTHH:MM:SSZ"
        import re as _re
        m = _re.search(r"导出时间[：:]\s*(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z)", raw)
        return m.group(1) if m else None
    if name == "nodes":
        try:
            d = json.loads(raw)
            stamps = []
            for k, v in d.items():
                if k == "_summary" or not isinstance(v, dict):
                    continue
                ls = v.get("last_seen")
                if ls:
                    stamps.append(ls)
            return max(stamps) if stamps else None
        except Exception:
            return None
    best = None
    for line in raw.strip().split("\n"):
        line = line.strip()
        if not line:
            continue
        try:
            ts = json.loads(line).get("ts")
        except Exception:
            continue
        if ts and (best is None or ts > best):
            best = ts
    return best

bad, ok = [], []
print(f"  {'产物':<10}{'条数':>6}  {'最新':<22}{'年龄':>8}  来源")
print("  " + "-" * 62)

for name, path, label, maxage in CHECKS:
    raw, src = fetch(path)
    if raw is None:
        print(f"  {label:<10}{'—':>6}  {'不存在':<22}{'—':>8}  ✗")
        bad.append((label, "产物不存在"))
        continue

    if name == "decisions":
        count = len(__import__("re").findall(r"^## D", raw, __import__("re").M))
    elif name == "self-export":
        count = len(raw.splitlines())
    elif name == "nodes":
        count = len([k for k in json.loads(raw) if k != "_summary"])
    else:
        count = len([l for l in raw.strip().split("\n") if l.strip()])

    ts = newest_ts(raw, name)
    if not ts:
        print(f"  {label:<10}{count:>6}  {'无时间戳':<22}{'—':>8}  {src}")
        bad.append((label, "无时间戳"))
        continue

    try:
        t = datetime.datetime.strptime(ts, "%Y-%m-%dT%H:%M:%SZ").replace(
            tzinfo=datetime.timezone.utc)
        age = (now - t).total_seconds() / 60
    except Exception:
        bad.append((label, "时间戳格式错"))
        continue

    fresh = age <= maxage
    mark = "✓" if fresh else "✗"
    print(f"  {label:<10}{count:>6}  {ts:<22}{age:>7.0f}m  {src} {mark}")
    if not fresh:
        bad.append((label, f"{age:.0f} 分钟未更新（上限 {maxage}）"))
    else:
        ok.append(label)

print()
if bad:
    print(f"  ✗ {len(bad)} 项异常:")
    for label, why in bad:
        print(f"      {label}: {why}")
    print()
    print("  排查顺序：")
    print("    1. 这个数据走 API 还是 git？（走 git 会被 rebase 丢弃）")
    print("    2. 最近一次运行用的是哪个版本的工作流？（版本时间差）")
    print("    3. 该运行里对应步骤结论是什么？（success 不代表产物更新）")
    print("    4. 手动执行写入脚本，看是否成功（区分逻辑问题 vs 环境问题）")
    sys.exit(1)
else:
    print(f"  ✓ 全部 {len(ok)} 项产物正常")
    sys.exit(0)
PY

exit "${_rc:-0}"
