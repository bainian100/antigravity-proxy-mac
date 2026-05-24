#!/usr/bin/env bash
# 一键诊断：判断是 Bug 1 / Bug 2 / 还是别的问题
set +e

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "$@"; }
ok()  { log "${GREEN}✅ $*${NC}"; }
bad() { log "${RED}❌ $*${NC}"; }
warn(){ log "${YELLOW}⚠️  $*${NC}"; }
hr()  { log "${YELLOW}---- $* ----${NC}"; }

hr "0. 基础信息"
VER=$(defaults read /Applications/Antigravity.app/Contents/Info CFBundleShortVersionString 2>/dev/null)
log "Antigravity 版本: ${VER:-未安装}"
log "macOS 版本: $(sw_vers -productVersion)"
log "架构: $(uname -m)"

if [[ "$VER" != "2.0.6" ]]; then
  warn "本仓库专门修 2.0.6，你这个版本是 $VER，可能需要不同方法"
fi

hr "1. asar 端点检查（Bug 1）"
ASAR=/Applications/Antigravity.app/Contents/Resources/app.asar
if [[ -f "$ASAR" ]]; then
  ENDPOINT=$(strings "$ASAR" | grep -E "cloudcode-pa\.googleapis" | head -1)
  log "asar 内端点: $ENDPOINT"
  if echo "$ENDPOINT" | grep -q "daily-cloudcode-pa"; then
    bad "Bug 1 中招：端点是 daily-cloudcode-pa（写死在 asar 里）"
    BUG1=yes
  else
    ok "Bug 1 没中：端点是生产 cloudcode-pa"
    BUG1=no
  fi
  log "asar mtime: $(stat -f "%Sm" "$ASAR")"
else
  bad "找不到 $ASAR"
fi

hr "2. Antigravity 进程 + 网络连接（Bug 2）"
LS_PID=$(pgrep -f "language_server --standalone" | head -1)
if [[ -n "$LS_PID" ]]; then
  log "language_server PID: $LS_PID"
  CONNS=$(lsof -a -p "$LS_PID" -i 2>/dev/null | grep -v LISTEN | grep -v "^COMMAND")
  log "网络连接概览:"
  echo "$CONNS" | head -10
  echo

  PROXIED=$(echo "$CONNS" | grep -c "10808\|7890\|7891\|7897\|1080" || true)
  DIRECT=$(echo "$CONNS" | grep -c "1e100\|googleusercontent\|googleapi" || true)
  SYN=$(echo "$CONNS" | grep -c "SYN_SENT" || true)

  log "走代理的连接数: $PROXIED"
  log "直连 Google 的连接数: $DIRECT"
  log "SYN_SENT 卡死的连接数: $SYN"

  if [[ "$SYN" -gt 0 ]]; then
    bad "Bug 2 中招：有 $SYN 个直连请求被 GFW 截了（SYN_SENT）"
    BUG2=yes
  elif [[ "$DIRECT" -gt 0 ]]; then
    warn "有直连 Google 的请求，但暂时没卡死。可能 TUN 已经在工作了"
    BUG2=maybe
  else
    ok "Bug 2 没中：所有连接都走代理或 TUN"
    BUG2=no
  fi
else
  warn "Antigravity 没在跑，无法判断 Bug 2。先启动 Antigravity 再跑这个脚本"
fi

hr "3. 路由表 / TUN 状态"
ROUTES=$(netstat -rn -f inet 2>/dev/null | head -20)
echo "$ROUTES"
if echo "$ROUTES" | grep -qE "198\.18\..*utun"; then
  ok "TUN 在路由表里活跃（fake-IP 198.18.0.0/16）"
  TUN=yes
else
  warn "TUN 可能没启用（路由表里没看到 fake-IP）"
  TUN=no
fi

hr "4. 代理可用性"
for p in 10808 7897 7890 7891 1087 1080; do
  if nc -z 127.0.0.1 $p 2>/dev/null; then
    log "  127.0.0.1:$p 可连"
    if [[ -z "$PROXY_PORT" ]]; then PROXY_PORT=$p; fi
  fi
done
if [[ -n "$PROXY_PORT" ]]; then
  RES=$(curl -sS -m 5 -x http://127.0.0.1:$PROXY_PORT \
    -o /dev/null -w "%{http_code} t=%{time_total}" \
    https://cloudcode-pa.googleapis.com/ 2>&1)
  log "  via 127.0.0.1:$PROXY_PORT → cloudcode-pa.googleapis.com: $RES"
fi

hr "5. 最近一次 Antigravity 日志"
LATEST_LOG=~/Library/Logs/Antigravity/language_server.log
if [[ -f "$LATEST_LOG" ]]; then
  log "language_server.log（最后 10 行）:"
  tail -10 "$LATEST_LOG"
else
  warn "找不到 language_server.log，Antigravity 可能没启动过"
fi

hr "诊断结论"
if [[ "$BUG1" == "yes" && "$BUG2" == "yes" ]]; then
  bad "双重 bug 中招：需要补 asar + 启 TUN"
  log "下一步：bash scripts/02-patch-asar.sh && bash scripts/03-swap-bundle.sh"
  log "       然后开 Clash Verge → 启 TUN 模式"
elif [[ "$BUG1" == "yes" ]]; then
  bad "只中 Bug 1：补 asar 即可"
  log "下一步：bash scripts/02-patch-asar.sh && bash scripts/03-swap-bundle.sh"
elif [[ "$BUG2" == "yes" ]]; then
  bad "只中 Bug 2：启 TUN 即可"
  log "下一步：开 Clash Verge → 设置 → TUN 模式 → 打开"
else
  ok "Bug 1 / Bug 2 都没中。如果 Antigravity 还有问题，可能是别的原因"
fi
