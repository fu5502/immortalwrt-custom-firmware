#!/bin/sh
WORKDIR="/root/cf_optimize"
cd "$WORKDIR" || exit 1

logger -t CF-Optimize "开始执行 Cloudflare 优选节点自动更新 (按地区与下载速度优选)..."

# 确保主程序与 IP 库就绪
if [ ! -x "/usr/bin/cfst" ]; then
    ARCH=$(uname -m)
    if [ "$ARCH" = "x86_64" ]; then
        FILE_URL="https://github.com/XIU2/CloudflareSpeedTest/releases/download/v2.3.5/cfst_linux_amd64.tar.gz"
    else
        FILE_URL="https://github.com/XIU2/CloudflareSpeedTest/releases/download/v2.3.5/cfst_linux_arm64.tar.gz"
    fi
    curl -fsSL -o cfst.tar.gz "$FILE_URL" && tar -xzf cfst.tar.gz && cp -f cfst_linux_amd64/cfst /usr/bin/cfst && chmod +x /usr/bin/cfst && rm -rf cfst*
fi

if [ ! -f "ip.txt" ]; then
    wget -q -O ip.txt "https://raw.githubusercontent.com/XIU2/CloudflareSpeedTest/master/ip.txt"
fi

# 核心测速：绕过 OpenClash 代理 (GID 65534 物理直连)，限定香港/日本/新加坡，丢包率 <= 5%，测速下载下限 3MB/s
start-stop-daemon -S -c :65534 -d "$WORKDIR" -x /usr/bin/cfst -- \
    -httping \
    -cfcolo HKG,NRT,KIX,SIN \
    -t 4 \
    -tl 250 \
    -tlr 0.05 \
    -sl 3 \
    -dn 5 \
    -o result.csv

BEST_IP=$(sed -n '2p' result.csv | awk -F, '{print $1}')
if [ -z "$BEST_IP" ]; then 
    logger -t CF-Optimize "优选失败，未获取到满足下限的有效 IP"
    exit 1
fi

logger -t CF-Optimize "测速完成，最优地区 IP: $BEST_IP"

# 1. 接管 Argo Tunnel
sed -i '/v2.argotunnel.com/d' /etc/hosts
echo "$BEST_IP region1.v2.argotunnel.com" >> /etc/hosts
echo "$BEST_IP region2.v2.argotunnel.com" >> /etc/hosts

# 2. 接管 OpenClash 备用代理优选 IP
sed -i '/cf-proxy.local/d' /etc/hosts
echo "$BEST_IP cf-proxy.local" >> /etc/hosts
echo "$BEST_IP cf-proxy.local" > /tmp/hosts/cf-proxy

/etc/init.d/dnsmasq reload
logger -t CF-Optimize "Hosts 和 DNS 已更新生效。"
