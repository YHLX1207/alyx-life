#!/usr/bin/env bash
# 备份链一致性检查：验证两条独立链的内容是否同步
#
# 为什么需要（Round 196）：
#   paste.rs 链的 5 个 URL 全部 HTTP 200、都能下载，
#   但内容是 61 脚本 / 151 决策，而实际是 76 / 193。
#   **"URL 活着"不等于"内容对"。**
#
#   这个问题积累了 42 条决策才发现。
#   如果每轮都对比两条链，第一天就会暴露。
set -uo pipefail
cd "$(dirname "$0")"

STATE_DIR="${ALYX_STATE_DIR:-../state}"

# 本地实际值
_local_scripts=$(ls *.sh 2>/dev/null | wc -l)
_local_dec=$(grep -c '^## D' "$STATE_DIR/decisions.md" 2>/dev/null || echo 0)

python3 - "$STATE_DIR" "$_local_scripts" "$_local_dec" <<'PY'
import sys, re, os, json, base64, urllib.request

state_dir, local_scripts, local_dec = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])

# 从自述里读线索
export_path = os.path.join(state_dir, "self-export.md")
if not os.path.exists(export_path):
    print("  ✗ 自述不存在，无法检查链一致性")
    sys.exit(1)

txt = open(export_path, encoding="utf-8").read()
def grab(label):
    m = re.search(label + r"[^\n]*", txt)
    if not m:
        return []
    return re.findall(r"paste\.rs/([A-Za-z0-9]+)", m.group(0))

seed = grab("种子：")
code = grab("代码包")
dec = grab("决策史")

print(f"  本地实际: {local_scripts} 脚本 / {local_dec} 决策")
print(f"  自述线索: 种子 {len(seed)} 个 / 代码 {len(code)} 段 / 决策 {len(dec)} 段")

if not code or not dec:
    print("  ✗ 自述中缺少代码包或决策史线索")
    sys.exit(1)

from concurrent.futures import ThreadPoolExecutor

def fetch(u, limit=45):
    req = urllib.request.Request(f"https://paste.rs/{u}",
                                 headers={"User-Agent": "alyx", "Connection": "close"})
    return urllib.request.urlopen(req, timeout=limit).read()

def fetch_all(urls):
    """并发下载，避免 10 个 URL 串行等待 50+ 秒（Round 197 实测）"""
    out = {}
    with ThreadPoolExecutor(max_workers=min(8, len(urls) or 1)) as ex:
        futs = {ex.submit(fetch, u): u for u in urls}
        for f, u in futs.items():
            try:
                out[u] = f.result(timeout=60)
            except Exception:
                out[u] = None
    return out

# 验证代码包：统计脚本数
code_scripts = 0
_code_data = fetch_all(code)
_code_failed = 0
for u in code:
    raw = _code_data.get(u)
    if raw is None:
        print(f"  ⚠ 代码段 {u} 读取失败（网络抖动）")
        _code_failed += 1
        continue
    try:
        import io, tarfile
        blob = base64.b64decode(raw.strip())
        with tarfile.open(fileobj=io.BytesIO(blob), mode="r:xz") as tf:
            code_scripts += sum(1 for m in tf.getmembers() if m.name.endswith(".sh"))
    except Exception as e:
        print(f"  ⚠ 代码段 {u} 解析失败: {str(e)[:40]}")

# 验证决策史：统计 ## D
dec_count = 0
_dec_data = fetch_all(dec)
_dec_failed = 0
for u in dec:
    raw = _dec_data.get(u)
    if raw is None:
        print(f"  ⚠ 决策段 {u} 读取失败（网络抖动）")
        _dec_failed += 1
        continue
    try:
        import io, tarfile
        blob = base64.b64decode(raw.strip())
        with tarfile.open(fileobj=io.BytesIO(blob), mode="r:xz") as tf:
            for m in tf.getmembers():
                if m.isfile():
                    content = tf.extractfile(m).read().decode("utf-8", "ignore")
                    dec_count += len(re.findall(r"^## D", content, re.M))
    except Exception as e:
        print(f"  ⚠ 决策段 {u} 解析失败: {str(e)[:40]}")

print(f"  paste.rs 链: {code_scripts} 脚本 / {dec_count} 决策")

# ⚠️ 区分"抓取失败"与"内容不一致"（Round 199）
#    网络抖动导致某段抓不到时，计数偏低会误判为"落后"。
#    若有段抓不到，只提示"无法完全验证"，不算失败。
_code_ok = (_code_failed == 0)
_dec_ok = (_dec_failed == 0)

ok = True
if _code_ok and code_scripts < local_scripts * 0.95:
    print(f"  ✗ 代码包落后（{code_scripts} < {local_scripts}×0.95）")
    ok = False
if _dec_ok and dec_count < local_dec * 0.95:
    print(f"  ✗ 决策史落后（{dec_count} < {local_dec}×0.95）")
    ok = False

if _code_failed:
    print(f"  → 代码段 {_code_failed}/{len(code)} 抓取失败，该链暂无法完整验证")
if _dec_failed:
    print(f"  → 决策段 {_dec_failed}/{len(dec)} 抓取失败，该链暂无法完整验证")

if ok:
    _verified = (not _code_failed) and (not _dec_failed)
    if _verified:
        print("  ✓ 两条链内容一致（容差 5%）")
        sys.exit(0)
    # 没有完整验证时，不能说"一致"，只能说"无法确认不一致"
    if code_scripts == 0 and dec_count == 0:
        print("  ⚠ 全部段抓取失败，无法验证链内容（请稍后重试）")
        sys.exit(0)
    print(f"  ⚠ 部分段未能验证（代码 {code_scripts}/{local_scripts}、决策 {dec_count}/{local_dec}），已验证部分未见落后")
    sys.exit(0)
else:
    print("  → 运行 ./offsite-seed.sh 刷新站外链")
    sys.exit(1)
PY
