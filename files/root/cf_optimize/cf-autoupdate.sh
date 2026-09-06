#!/bin/sh
WORKDIR="/root/cf_optimize"
cd "$WORKDIR" || exit 1

logger -t CF-Optimize "开始执行 Cloudflare 优选节点自动更新..."

# 每次执行前清理旧版，强制拉取最新 release
rm -f CloudflareST CloudflareST.tar.gz

ARCH=$(uname -m)
if [ "$ARCH" = "x86_64" ]; then
    FILE_URL="https://ghproxy.net/https://github.com/XIU2/CloudflareSpeedTest/releases/latest/download/CloudflareST_linux_amd64.tar.gz"
else
    FILE_URL="https://ghproxy.net/https://github.com/XIU2/CloudflareSpeedTest/releases/latest/download/CloudflareST_linux_arm64.tar.gz"
fi

wget -O CloudflareST.tar.gz "$FILE_URL"
tar -xzf CloudflareST.tar.gz CloudflareST
chmod +x CloudflareST
rm -f CloudflareST.tar.gz

if [ ! -f "ip.txt" ]; then
    wget -O ip.txt "https://ghproxy.net/https://raw.githubusercontent.com/XIU2/CloudflareSpeedTest/master/ip.txt"
fi

./CloudflareST -sl 1 -dn 10 -o result.csv
BEST_IP=$(sed -n '2p' result.csv | awk -F, '{print $1}')
if [ -z "$BEST_IP" ]; then 
    logger -t CF-Optimize "优选失败，未获取到有效 IP"
    exit 1
fi

logger -t CF-Optimize "测速完成，最优 IP: $BEST_IP"

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
