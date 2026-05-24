#!/usr/bin/env bash
# 字节级补丁 app.asar：把 daily-cloudcode-pa 改回 cloudcode-pa
# 不动文件长度、不动 asar header offset、不重打包
set -e

SRC=/Applications/Antigravity.app
WORK=/tmp/AG_rebuild

if [[ ! -d "$SRC" ]]; then
  echo "❌ 找不到 $SRC，先装好 Antigravity 再跑"
  exit 1
fi

echo "[1/5] 退出 Antigravity..."
osascript -e 'tell application "Antigravity" to quit' 2>/dev/null || true
sleep 4
pkill -f "Antigravity.app/Contents" 2>/dev/null || true
sleep 1

echo "[2/5] 拷贝 .app 到 /tmp（用非 .app 名，绕过 macOS App Management）..."
rm -rf "$WORK"
mkdir -p "$WORK"
cp -R "$SRC/." "$WORK/"

ASAR="$WORK/Contents/Resources/app.asar"
if [[ ! -f "$ASAR" ]]; then
  echo "❌ 找不到 $ASAR"
  exit 1
fi

echo "[3/5] 字节级同长度替换..."
python3 - "$ASAR" <<'PYEOF'
import sys, shutil
p = sys.argv[1]
with open(p, "rb") as f:
    data = f.read()
old = b"'https://daily-cloudcode-pa.googleapis.com',"
new = b"'https://cloudcode-pa.googleapis.com'      ,"
assert len(old) == len(new), (len(old), len(new))
n = data.count(old)
print(f"    匹配数: {n}")
if n == 0:
    print("    ⚠️  没找到 daily-cloudcode-pa，可能 asar 已经被改过 / 不需要补 / 版本不对")
    sys.exit(2)
shutil.copy(p, p + ".bak.preDailyFix")
with open(p, "wb") as f:
    f.write(data.replace(old, new))
print(f"    ✅ 写入完成，文件大小不变: {len(data)} 字节")
PYEOF

echo "[4/5] 清隔离属性 + ad-hoc 重签名..."
xattr -cr "$WORK"
codesign --force --deep --sign - "$WORK" 2>&1 | tail -3

echo "[5/5] 验证补丁结果..."
if strings "$ASAR" | grep -qE "cloudcode-pa\.googleapis\.com'      ,"; then
  echo "    ✅ asar 内端点已替换"
else
  echo "    ❌ asar 验证失败"
  exit 1
fi

echo
echo "✅ 第 2 步完成。补好的 .app 在: $WORK"
echo "👉 接下来跑: bash scripts/03-swap-bundle.sh （会弹系统授权框）"
