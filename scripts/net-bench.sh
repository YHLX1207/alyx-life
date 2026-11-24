#!/usr/bin/env bash
# 网络延迟基线测量：区分「慢」与「断」，避免把超时当故障
set -uo pipefail
cd "$(dirname "$0")"
OUT=../state/netbench.jsonl
mkdir -p ../state

probe() {
  local url="$1" n="$2"
  python3 - "$url" "$n" <<'PY'
import subprocess,sys,json,time,statistics,datetime
url,n=sys.argv[1],int(sys.argv[2])
codes=[];lat=[]
for i in range(n):
    t0=time.time()
    p=subprocess.run(['curl','-s','-o','/dev/null','-w','%{http_code}|%{time_total}',
                      '--max-time','20',url],capture_output=True,text=True)
    dt=time.time()-t0
    try:
        c,t=p.stdout.strip().split('|'); codes.append(c); lat.append(float(t))
    except: codes.append('000'); lat.append(dt)
    time.sleep(0.6)
ok=sum(1 for c in codes if c=='200')
r={'url':url,'n':n,'ok':ok,'fail':n-ok,
   'med':round(statistics.median(lat),2) if lat else 0,
   'max':round(max(lat),2) if lat else 0,
   'ts':datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')}
print(json.dumps(r,ensure_ascii=False))
PY
}

for u in https://github.com https://api.github.com https://registry.npmjs.org; do
  r=$(probe "$u" 5)
  echo "$r" | tee -a "$OUT"
done
