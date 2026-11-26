#!/usr/bin/env bash
# 离线暂存：GitHub 不可用时，把新产生的状态先存本地，恢复后自动补推
#
# 为什么需要（Round 228）：
#   死亡条件分析发现一个真实缺口——
#   GitHub 不可用时，设备节点仍能推理、能自检，
#   **但无法持久化任何新状态**。断网期间产生的思考会全部丢失。
#
#   现存通道：
#     · /sdcard 备份 —— 需 adb（当前断开）
#     · paste.rs    —— 只用于定期快照，不是实时写入
#     · 本地磁盘     —— 可用，但没被用于"暂存待推"
#
# 本脚本补上这个缺口：
#   · 每次要同步前，先写本地 WAL（write-ahead log）
#   · 同步成功 → 清空 WAL
#   · 同步失败 → WAL 保留，下次启动时自动补推
set -uo pipefail
cd "$(dirname "$0")"

STATE="${ALYX_STATE_DIR:-../state}"
WAL="$STATE/pending-sync.jsonl"

say(){ printf "  %s\n" "$*"; }

case "${1:-status}" in
  stage)
    # 暂存一条待推记录
    shift
    [ $# -ge 2 ] || { say "用法: $0 stage <file> <note>"; exit 1; }
    python3 - "$STATE" "$WAL" "$1" "$2" <<'PY'
import sys, os, json, datetime
state, wal, f, note = sys.argv[1:5]
rec = {
    "ts": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "file": f,
    "note": note,
}
os.makedirs(state, exist_ok=True)
with open(wal, "a", encoding="utf-8") as fh:
    fh.write(json.dumps(rec, ensure_ascii=False) + "\n")
print(f"  ✓ 已暂存: {f} ({note})")
PY
    ;;

  flush)
    # 尝试补推所有暂存项
    if [ ! -s "$WAL" ]; then
      say "无需补推（WAL 为空）"
      exit 0
    fi
    python3 - "$STATE" "$WAL" <<'PY'
import sys, os, json, subprocess

state, wal = sys.argv[1:3]
rows = []
try:
    for line in open(wal, encoding="utf-8"):
        line = line.strip()
        if line:
            try:
                rows.append(json.loads(line))
            except Exception:
                pass
except FileNotFoundError:
    print("  无 WAL"); sys.exit(0)

print(f"  待补推 {len(rows)} 项")
ok, fail = 0, 0
remaining = []
for r in rows:
    f = r.get("file", "")
    # 只处理 state/ 下的 jsonl / md
    if not f.startswith("state/"):
        continue
    local = os.path.join("..", f)
    if not os.path.exists(local):
        continue
    try:
        p = subprocess.run(["./sync-jsonl.sh", f, "500"],
                           capture_output=True, timeout=120)
        if p.returncode == 0:
            ok += 1
        else:
            fail += 1
            remaining.append(r)
    except Exception:
        fail += 1
        remaining.append(r)

# 重写 WAL：只保留失败的
with open(wal, "w", encoding="utf-8") as fh:
    for r in remaining:
        fh.write(json.dumps(r, ensure_ascii=False) + "\n")

print(f"  ✓ 补推成功 {ok} 项，仍待推 {fail} 项")
sys.exit(0 if fail == 0 else 1)
PY
    ;;

  status)
    if [ -s "$WAL" ]; then
      n=$(wc -l < "$WAL")
      say "WAL 有待推记录: $n 项"
      tail -3 "$WAL" | python3 -c "
import sys,json
for l in sys.stdin:
    if l.strip():
        r=json.loads(l)
        print(f\"    {r.get('ts','?')[:19]}  {r.get('file','?')}\")
" 2>/dev/null
    else
      say "WAL 为空（无待推数据）"
    fi
    ;;

  *)
    say "用法: $0 {status|stage <file> <note>|flush}"
    exit 1
    ;;
esac
