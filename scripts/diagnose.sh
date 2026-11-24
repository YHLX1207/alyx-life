#!/usr/bin/env bash
# 故障归因器：当某个能力异常时，逐层排查"是环境问题还是我的测量问题"
set -uo pipefail
cd "$(dirname "$0")"

TARGET=${1:-github.com}
echo "== 诊断 $TARGET =="
echo
echo "--- 第 1 层：DNS 解析 ---"
ip=$(getent ahostsv4 "$TARGET" 2>/dev/null | head -1 | awk '{print $1}')
echo "  resolved: ${ip:-FAIL}"

echo "--- 第 2 层：TCP 443 ---"
if [ -n "$ip" ]; then
  timeout 5 bash -c "echo > /dev/tcp/$ip/443" 2>/dev/null && echo "  ✓ TCP OPEN" || echo "  ✗ TCP BLOCKED"
fi

echo "--- 第 3 层：TLS 握手 ---"
tls=$(timeout 12 curl -sv --max-time 10 "https://$TARGET" -o /dev/null 2>&1 | grep -c "TLS handshake, Finished")
[ "${tls:-0}" -ge 1 ] && echo "  ✓ TLS 完成" || echo "  ✗ TLS 未完成"

echo "--- 第 4 层：延迟基线（区分慢与断）---"
python3 - "$TARGET" <<'PY'
import subprocess,sys,time,statistics
h=sys.argv[1]; lat=[]; codes=[]
for i in range(6):
    t0=time.time()
    p=subprocess.run(['curl','-s','-o','/dev/null','-w','%{http_code}',
                      '--max-time','20',f'https://{h}'],capture_output=True,text=True)
    lat.append(time.time()-t0); codes.append(p.stdout.strip() or '000')
    time.sleep(0.5)
ok=sum(1 for c in codes if c=='200')
med=statistics.median(lat)
print(f"  成功 {ok}/6   中位 {med:.2f}s   最大 {max(lat):.2f}s")
print(f"  结论: ", end="")
if ok==6 and med<2:  print("健康")
elif ok==6:          print(f"可达但慢（中位 {med:.1f}s）—— 注意探测超时不能低于此值的 2 倍")
elif ok>=3:          print("不稳定 — 间歇可达")
else:                print("不可达")
PY

echo
echo "--- 建议 ---"
echo "  若延迟中位数 > 2s，任何低于 2×中位 的探测超时都会制造假故障。"
echo "  参见 state/decisions.md D004。"
