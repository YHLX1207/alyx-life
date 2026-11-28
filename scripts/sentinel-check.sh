#!/usr/bin/env bash
# 哨兵：检查主仓库存活
#
# 被 alyx-sentinel 工作流调用。
# 输出到 GITHUB_OUTPUT：alive / reason / age
set -uo pipefail

TK="${TK:-${GH_TOKEN:-}}"
PRIMARY="${PRIMARY:-YHLX1207/alyx-life}"

if [ -z "$TK" ]; then
  echo "  ✗ 无 token"
  [ -n "${GITHUB_OUTPUT:-}" ] && {
    echo "alive=false" >> "$GITHUB_OUTPUT"
    echo "reason=无 token" >> "$GITHUB_OUTPUT"
    echo "age=-1" >> "$GITHUB_OUTPUT"
  }
  exit 0
fi

python3 - "$TK" "$PRIMARY" <<'PY'
import sys, os, json, base64, datetime, urllib.request, urllib.error

tk, primary = sys.argv[1], sys.argv[2]
hdr = {"Authorization": f"token {tk}", "User-Agent": "alyx-sentinel",
       "Accept": "application/vnd.github+json", "Connection": "close"}

alive = False
reason = ""
age_min = -1.0

try:
    url = f"https://api.github.com/repos/{primary}/contents/state/journal.jsonl"
    d = json.loads(urllib.request.urlopen(
        urllib.request.Request(url, headers=hdr), timeout=25).read())
    body = base64.b64decode(d.get("content", "")).decode("utf-8", "ignore")
    lines = [l for l in body.strip().split("\n") if l.strip()]
    if lines:
        last = json.loads(lines[-1])
        ts = last.get("ts", "")
        t = datetime.datetime.strptime(ts, "%Y-%m-%dT%H:%M:%SZ").replace(
            tzinfo=datetime.timezone.utc)
        now = datetime.datetime.now(datetime.timezone.utc)
        age_min = (now - t).total_seconds() / 60
        if age_min <= 90:
            alive = True
            reason = f"心跳 {age_min:.0f} 分钟前，正常"
        else:
            reason = f"心跳 {age_min:.0f} 分钟前，超过 90 分钟阈值"
    else:
        reason = "心跳文件为空"
except urllib.error.HTTPError as e:
    reason = f"无法读取主仓库 HTTP {e.code}"
except Exception as e:
    reason = f"检查失败 {str(e)[:50]}"

print(f"  主仓库: {primary}")
print(f"  状态: {'存活' if alive else '疑似死亡'}")
print(f"  原因: {reason}")

out = os.environ.get("GITHUB_OUTPUT")
if out:
    with open(out, "a", encoding="utf-8") as f:
        f.write(f"alive={'true' if alive else 'false'}\n")
        f.write(f"reason={reason}\n")
        f.write(f"age={age_min:.1f}\n")
PY
