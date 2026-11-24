#!/usr/bin/env bash
# 采集 DSH 与设备资产清单，供长期跟踪变化
set -uo pipefail
cd "$(dirname "$0")"
OUT=../state/inventory.json
export PATH=/opt/elevation/bin:$PATH
A="adb -s 127.0.0.1:5555"

userapps=$(timeout 15 $A shell "pm list packages -3" 2>/dev/null | tr -d '\r' | sed 's/package://' | sort | tr '\n' ' ')
disabled=$(timeout 15 $A shell "pm list packages -d" 2>/dev/null | tr -d '\r' | sed 's/package://' | sort | tr '\n' ' ')
disk_phone=$(timeout 10 $A shell "df /data" 2>/dev/null | tr -d '\r' | awk 'NR==2{print $3"/"$2" ("$5")"}')
plugins=$(timeout 25 node -e "
const p=require('/root/projects/.dsh/profiles/web/package.json');
const deps=Object.keys(p.dependencies||{});
const bundles=(p.dsh&&p.dsh.profile&&p.dsh.profile.bundles)||[];
console.log(JSON.stringify({deps,bundles}));
" 2>/dev/null)

python3 -c "
import json
rec={
 'ts':'$(date -u +%Y-%m-%dT%H:%M:%SZ)',
 'phone_user_apps':'$userapps'.split(),
 'phone_disabled_packages':'$disabled'.split(),
 'phone_disk':'$disk_phone',
 'dsh_plugins':json.loads('''$plugins''') if '''$plugins''' else {}
}
json.dump(rec, open('$OUT','w'), ensure_ascii=False, indent=1)
print('plugins deps:', len(rec['dsh_plugins'].get('deps',[])))
print('bundles:', rec['dsh_plugins'].get('bundles',[]))
"
