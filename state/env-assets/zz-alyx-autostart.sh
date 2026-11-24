# Alyx 自启钩子：确保守护在跑（幂等、静默、不阻塞）
# 由 D124 故障驱动：DSHBox 被系统回收时守护陪葬，无人重启。
# 仅在交互或登录 shell 首次进入时触发一次；失败不影响 shell。
if [ -x /root/projects/life/scripts/boot-hook.sh ]; then
    ( /root/projects/life/scripts/boot-hook.sh >/dev/null 2>&1 & ) 2>/dev/null || true
fi
