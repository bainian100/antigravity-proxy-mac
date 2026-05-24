#!/usr/bin/env bash
# 一键回滚：把 Antigravity.app 还原成原 daily 版
set -e

DEST=/Applications/Antigravity.app
BAK=/Applications/Antigravity.app.dailybak

if [[ ! -d "$BAK" ]]; then
  echo "❌ 找不到备份 $BAK，无法回滚"
  echo "    可能是没用 03-swap-bundle.sh 替换过，或者备份被删了"
  echo "    可以从 https://antigravity.google/ 重新下载 Antigravity 安装"
  exit 1
fi

echo "👉 即将弹出系统授权框，请输入开机密码"
osascript -e 'tell application "Antigravity" to quit' 2>/dev/null || true
sleep 3

osascript <<EOF
do shell script "rm -rf '$DEST' && mv '$BAK' '$DEST'" \\
  with administrator privileges \\
  with prompt "回滚 Antigravity 到原 daily 版"
EOF

echo "✅ 回滚完成"
