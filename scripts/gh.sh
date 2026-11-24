#!/usr/bin/env bash
# GitHub 访问降级工具：主站不通时改走 api.github.com（实测稳定）
# 用法: gh.sh repo <owner/name>   |  gh.sh releases <owner/name>  |  gh.sh search <query>
set -uo pipefail

api() { timeout 15 curl -s --max-time 12 -H "Accept: application/vnd.github+json" "$1" 2>/dev/null; }

case "${1:-}" in
  repo)
    api "https://api.github.com/repos/$2" | python3 -c "
import sys,json
d=json.load(sys.stdin)
if 'full_name' in d:
    print(f\"{d['full_name']}  ★{d.get('stargazers_count',0)}\")
    print(f\"  {d.get('description') or '(no description)'}\")
    print(f\"  updated: {d.get('updated_at')}  lang: {d.get('language')}\")
else: print('error:', d.get('message'))
"
    ;;
  releases)
    api "https://api.github.com/repos/$2/releases?per_page=3" | python3 -c "
import sys,json
d=json.load(sys.stdin)
if isinstance(d,list):
    for r in d:
        print(f\"{r.get('tag_name')}  {r.get('published_at')}  {r.get('name') or ''}\")
else: print('error:', d.get('message'))
"
    ;;
  search)
    api "https://api.github.com/search/repositories?q=$2&per_page=5" | python3 -c "
import sys,json
d=json.load(sys.stdin)
for it in d.get('items',[])[:5]:
    print(f\"{it['full_name']:<45} ★{it['stargazers_count']:<6} {it.get('description','')[:60]}\")
"
    ;;
  *) echo "usage: gh.sh {repo|releases|search} <arg>"; exit 1;;
esac
