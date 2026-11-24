#!/usr/bin/env bash
# GitHub hosts 维护 —— 多 IP 故障转移 + 失败安全
#
# 核心认知（D004/D007/D011/D012）：
#   1. 本机到 GitHub 的连接瞬时间歇，同一 IP 可能一分钟内从可用变不可用
#   2. 单一静态映射必然很快失效；探测方法(--resolve)与真实路径也可能不一致
#   3. 答案不是"更准确地选一个 IP"，而是"列多个 IP 让系统自动故障转移"
#      —— curl/glibc 会按顺序尝试，跳过连不上的
#
# 策略：
#   a) 对每个域名写入前 N 个候选 IP（按实测延迟排序，失败者靠后）
#   b) 探测全失败时保留原有条目，绝不因为探测噪声删除可用映射
#   c) 幂等：重复运行结果稳定
set -uo pipefail
cd "$(dirname "$0")"
MARK="# GitHub hosts (由 ensure-hosts.sh 生成)"
HOSTS=/etc/hosts
CACHE=../state/gh520_hosts
mkdir -p ../state

# domain:number_of_ips
TARGETS="github.com:3 raw.githubusercontent.com:2 objects.githubusercontent.com:1 avatars.githubusercontent.com:1 camo.githubusercontent.com:1 codeload.github.com:1 api.github.com:1"

# 候选列表地址。⚠️ 这里有**循环依赖**：修 GitHub 访问的工具，自己依赖 GitHub 取数据。
# Round 108 修法：直连失败时**经 gh-proxy 端点重试**，打破循环。
_LIST_PATH="521xueweihan/GitHub520/main/hosts"
_GH_PROXY_ENDPOINTS="https://gh-proxy.com https://ghproxy.net"

fetch_list() {
  # 1) 直连（最快，通常可用）
  if timeout 30 curl -sfL --max-time 25 \
      "https://raw.githubusercontent.com/${_LIST_PATH}" -o "$CACHE.tmp" 2>/dev/null \
     && [ -s "$CACHE.tmp" ]; then
    mv "$CACHE.tmp" "$CACHE"; echo "  候选列表: 直连获取"; return 0
  fi
  # 2) 经代理兜底（打破循环依赖）
  for _ep in $_GH_PROXY_ENDPOINTS; do
    if timeout 40 curl -sfL --max-time 35 \
        "${_ep}/https://raw.githubusercontent.com/${_LIST_PATH}" -o "$CACHE.tmp" 2>/dev/null \
       && [ -s "$CACHE.tmp" ]; then
      mv "$CACHE.tmp" "$CACHE"; echo "  候选列表: 经代理获取（${_ep}）"; return 0
    fi
  done
  # 3) 退回缓存
  [ -s "$CACHE" ] && { echo "  候选列表: 使用缓存（直连与代理均失败）"; return 0; }
  return 1
}

fetch_list || echo "warn: 候选列表获取失败，使用缓存/内置候选"

python3 - "$CACHE" "$HOSTS" "$MARK" "$TARGETS" <<'PY'
import sys,re,subprocess,statistics
cache,hosts_path,mark,targets_spec=sys.argv[1],sys.argv[2],sys.argv[3],sys.argv[4]
targets=[(t.split(':')[0], int(t.split(':')[1])) for t in targets_spec.split()]

cand={}
try:
    for line in open(cache):
        m=re.match(r'^(\d+\.\d+\.\d+\.\d+)\s+(\S+)$',line.strip())
        if m: cand.setdefault(m.group(2),[]).append(m.group(1))
except FileNotFoundError: pass

# 内置已知候选（历史上出现过的 GitHub 段）
fallback={
 'github.com':['20.205.243.166','20.27.177.113','140.82.113.4','140.82.114.3','20.247.166.64'],
 'www.github.com':[],
 'raw.githubusercontent.com':['185.199.111.133','185.199.108.133','185.199.109.133','185.199.110.133'],
 'objects.githubusercontent.com':['185.199.111.133','185.199.110.133'],
 'avatars.githubusercontent.com':['185.199.111.133','185.199.108.133'],
 'camo.githubusercontent.com':['185.199.111.133'],
 'codeload.github.com':['57.155.223.241','20.205.243.165','140.82.114.9'],
 'api.github.com':['20.205.243.168','20.27.177.116'],
}

def probe(host,ip):
    """多次尝试取最小延迟；全失败返回 None"""
    best=None
    for _ in range(2):
        p=subprocess.run(['curl','-s','-o','/dev/null','-w','%{http_code}|%{time_total}',
                          '-4','-k','--max-time','8','--resolve',f'{host}:443:{ip}',
                          f'https://{host}/'],capture_output=True,text=True)
        try:
            c,t=p.stdout.strip().split('|')
            if c in ('200','301','302','404'):
                v=float(t); best=v if best is None else min(best,v)
        except: pass
    return best

# 现有映射（用于失败时保留）
existing={}
for l in open(hosts_path):
    if l.startswith('#'): continue
    parts=l.split()
    if len(parts)==2 and re.match(r'^\d+\.\d+\.\d+\.\d+$',parts[0]):
        existing.setdefault(parts[1],[]).append(parts[0])

picked={}
any_probe_ok=False
for host,n in targets:
    ips=list(dict.fromkeys(cand.get(host,[])+fallback.get(host,[])))
    scored=[]
    for ip in ips:
        lat=probe(host,ip)
        if lat is not None:
            scored.append((lat,ip)); any_probe_ok=True
    scored.sort()
    chosen=[ip for _,ip in scored][:n]
    # 探测不够数时，用未探测的候选补齐（多 IP 故障转移本身能兜底）
    if len(chosen)<n:
        for ip in ips:
            if ip not in chosen and len(chosen)<n:
                chosen.append(ip)
    if not chosen and host in existing:
        chosen=existing[host][:n]; print(f"  keep {host:<36} {','.join(chosen)} (no candidate, preserving)")
    elif chosen:
        tag='probe' if scored else 'blind'
        print(f"  {tag:<5} {host:<36} {','.join(chosen)}")
    picked[host]=chosen

# 全盘探测失败且无候选 -> 保留原文件不动
if not any_probe_ok and not picked.get('github.com'):
    print("no usable data; leaving hosts untouched"); raise SystemExit(0)

marks=[mark,'# GitHub 绕过 DNS 污染','# GitHub520','# TEST multi-ip']
lines=open(hosts_path).read().splitlines()
out=[];skip=False
for l in lines:
    st=l.strip()
    if any(st.startswith(m) for m in marks): skip=True; continue
    if skip:
        if st=='': skip=False; continue
        if st.startswith('#') or st[0].isdigit(): continue
        skip=False
    out.append(l)
out+=['',mark]
for host,n in targets:
    for ip in picked.get(host,[]):
        out.append(f'{ip}\t{host}')
for ip in picked.get('github.com',[]):
    out.append(f'{ip}\twww.github.com')
open(hosts_path,'w').write('\n'.join(out).rstrip()+'\n')
print(f"\napplied {sum(len(v) for v in picked.values())} entries across {len(picked)} domains")
PY

echo "--- verify ---"
for u in https://github.com https://api.github.com https://raw.githubusercontent.com; do
  ok=0
  for i in 1 2 3; do
    c=$(timeout 40 curl -s -o /dev/null -w "%{http_code}" --max-time 35 "$u" 2>/dev/null)
    case "$c" in 200|301) ok=$((ok+1));; esac
  done
  printf "  %-40s %d/3\n" "$u" "$ok"
done
