#!/usr/bin/env bash
# 把补好的 .app 替换回 /Applications，会弹系统授权框
set -e

WORK=/tmp/AG_rebuild
DEST=/Applications/Antigravity.app
BAK=/Applications/Antigravity.app.dailybak

if [[ ! -d "$WORK" ]]; then
  echo "❌ $WORK 不存在，请先跑 02-patch-asar.sh"
  exit 1
fi

if [[ -d "$BAK" ]]; then
  echo "⚠️  $BAK 已存在（之前的备份）"
  echo "    继续会覆盖旧备份。Ctrl+C 取消，回车继续："
  read -r
  rm -rf "$BAK"
fi

echo "👉 即将弹出系统授权框，请输入开机密码"
osascript <<EOF
do shell script "set -e; \\
  mv '$WORK' '/tmp/Antigravity.app' && \\
  mv '$DEST' '$BAK' && \\
  mv '/tmp/Antigravity.app' '$DEST' && \\
  echo SWAPPED" \\
  with administrator privileges \\
  with prompt "Antigravity 端点修复：替换 .app 包"
EOF

echo "[清理] 删除自动更新 pending 包，防止下次启动又把 daily 版打回来..."
rm -f ~/Library/Caches/antigravity-updater/pending/Antigravity.zip 2>/dev/null || true

echo
echo "[验证]"
if strings "$DEST/Contents/Resources/app.asar" | grep -qE "cloudcode-pa\.googleapis\.com'      ,"; then
  echo "    ✅ /Applications/Antigravity.app 已是补好的版本"
else
  echo "    ❌ 替换失败 / 验证失败"
  exit 1
fi

echo
echo "✅ 第 3 步完成。原版备份在: $BAK"
echo "👉 接下来开 Clash Verge → 启用 TUN 模式 → 重启 Antigravity"
echo "   要回滚跑: bash scripts/99-rollback.sh"
