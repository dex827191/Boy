#!/bin/bash
set -e

# ══════════════════════════════════════════════════════════════════
# Kernel tuning
# ══════════════════════════════════════════════════════════════════
ulimit -n 65535
ulimit -s unlimited 2>/dev/null || true

sysctl -w net.core.default_qdisc=fq 2>/dev/null || true
sysctl -w net.ipv4.tcp_congestion_control=bbr 2>/dev/null || true
sysctl -w net.ipv4.tcp_rmem="4096 8388608 16777216" 2>/dev/null || true
sysctl -w net.ipv4.tcp_wmem="4096 8388608 16777216" 2>/dev/null || true
sysctl -w net.core.rmem_max=16777216 2>/dev/null || true
sysctl -w net.core.wmem_max=16777216 2>/dev/null || true
sysctl -w net.core.netdev_max_backlog=50000 2>/dev/null || true
sysctl -w net.ipv4.tcp_max_syn_backlog=8192 2>/dev/null || true

# ══════════════════════════════════════════════════════════════════
# 🔑 UUID — Auto-generate kalau belum ada (persist antar restart)
# ══════════════════════════════════════════════════════════════════
if [ ! -f /tmp/uuid.txt ] || [ ! -s /tmp/uuid.txt ]; then
    if [ -f /proc/sys/kernel/random/uuid ]; then
        cat /proc/sys/kernel/random/uuid > /tmp/uuid.txt
    else
        openssl rand -hex 16 | sed 's/\(.\{8\}\)\(.\{4\}\)\(.\{4\}\)\(.\{4\}\)\(.\{12\}\)/\1-\2-4\3-8\4-\5/' > /tmp/uuid.txt
    fi
    echo "[✓] UUID baru di-generate: $(cat /tmp/uuid.txt)"
else
    echo "[✓] UUID tersimpan: $(cat /tmp/uuid.txt)"
fi
export UUID="$(cat /tmp/uuid.txt)"

# ══════════════════════════════════════════════════════════════════
# SSH — opsional: hanya buat user kalau SSH_USER di-set
#         (kalau tidak di-set, buat user via panel UI)
# ══════════════════════════════════════════════════════════════════
if [ -n "$SSH_USER" ] && [ -n "$SSH_PASSWORD" ]; then
    if ! id "$SSH_USER" &>/dev/null; then
        useradd -m -s /bin/bash "$SSH_USER"
        echo "$SSH_USER ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers
    fi
    echo "$SSH_USER:$SSH_PASSWORD" | chpasswd
    echo "[✓] Default SSH user dibuat: $SSH_USER"
else
    echo "[i] SSH_USER tidak diset — buat akun via panel web (/)"
fi

# ══════════════════════════════════════════════════════════════════
# Banner OpenSSH
# ══════════════════════════════════════════════════════════════════
cat << 'EOF' > /etc/ssh/ssh_banner
<p style="text-align:center;"><b>
    <font color="#800080">▬</font><font color="#8A2BE2">▬</font><font color="#9370DB">▬</font><font color="#7B68EE">▬ஜ۩۞۩ஜ▬</font><font color="#7B68EE">▬</font><font color="#9370DB">▬</font><font color="#8A2BE2">▬</font><font color="#800080">▬</font><br>
    <font color="#800080">─── SERVER PREMIUM ───</font><br>
    <font color="#8A2BE2">NO MULTI LOGIN / NO TORRENT</font><br>
    <font color="#9370DB">NO SPAM / NO DDOS / NO HACKING</font><br>
    <font color="#800080">▬</font><font color="#8A2BE2">▬</font><font color="#9370DB">▬</font><font color="#7B68EE">▬ஜ۩۞۩ஜ▬</font><font color="#7B68EE">▬</font><font color="#9370DB">▬</font><font color="#8A2BE2">▬</font><font color="#800080">▬</font><br></b>
</p>
EOF

ssh-keygen -A
mkdir -p /run/sshd

cat << 'EOF' > /etc/ssh/sshd_config
Port 22
ListenAddress 127.0.0.1
PermitRootLogin yes
PasswordAuthentication yes
PermitEmptyPasswords no
KbdInteractiveAuthentication no
UsePAM no
X11Forwarding no
PrintMotd no
AcceptEnv LANG LC_*
Subsystem sftp /usr/lib/openssh/sftp-server
Banner /etc/ssh/ssh_banner
UseDNS no
ClientAliveInterval 20
ClientAliveCountMax 3
EOF

/usr/sbin/sshd
echo "[✓] sshd di 127.0.0.1:22"

# ══════════════════════════════════════════════════════════════════
# TLS cert
# ══════════════════════════════════════════════════════════════════
mkdir -p /etc/nginx/ssl
openssl req -new -newkey rsa:2048 -days 3650 -nodes -x509 \
    -subj "/C=ID/ST=Jakarta/L=Jakarta/O=SSHServer/CN=localhost" \
    -keyout /etc/nginx/ssl/server.key \
    -out    /etc/nginx/ssl/server.crt 2>/dev/null

# ══════════════════════════════════════════════════════════════════
# ws-proxy + admin
# ══════════════════════════════════════════════════════════════════
export WS_PORT=8880
ws-proxy &
echo "[✓] ws-proxy di 127.0.0.1:8880"

admin &
echo "[✓] admin panel di 127.0.0.1:8081"

# ══════════════════════════════════════════════════════════════════
# Xray — VLESS/VMess/Trojan (UUID dari /tmp/uuid.txt)
# ══════════════════════════════════════════════════════════════════
cat > /tmp/xray-config.json <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "port": 8001, "listen": "127.0.0.1", "protocol": "vless",
      "settings": {
        "clients": [{ "id": "$UUID" }],
        "decryption": "none",
        "fallbacks": [
          { "path": "/vless-argo",  "dest": 3100 },
          { "path": "/vmess-argo",  "dest": 3101 },
          { "path": "/trojan-argo", "dest": 3102 },
          { "path": "/ssh-ws",      "dest": 8880 },
          { "dest": 22 }
        ]
      },
      "streamSettings": { "network": "tcp", "security": "none" }
    },
    {
      "port": 3100, "listen": "127.0.0.1", "protocol": "vless",
      "settings": { "clients": [{ "id": "$UUID" }], "decryption": "none" },
      "streamSettings": { "network": "ws", "wsSettings": { "path": "/vless-argo" } }
    },
    {
      "port": 3101, "listen": "127.0.0.1", "protocol": "vmess",
      "settings": { "clients": [{ "id": "$UUID", "alterId": 0 }] },
      "streamSettings": { "network": "ws", "wsSettings": { "path": "/vmess-argo" } }
    },
    {
      "port": 3102, "listen": "127.0.0.1", "protocol": "trojan",
      "settings": { "clients": [{ "password": "$UUID" }] },
      "streamSettings": { "network": "ws", "wsSettings": { "path": "/trojan-argo" } }
    }
  ],
  "outbounds": [{ "protocol": "freedom", "tag": "direct" }]
}
EOF

xray run -c /tmp/xray-config.json &
echo "[✓] Xray :8001 (VLESS/VMess/Trojan)"

# ══════════════════════════════════════════════════════════════════
# BadVPN UDPGW
# ══════════════════════════════════════════════════════════════════
if [ -x /usr/local/bin/badvpn-udpgw ]; then
    /usr/local/bin/badvpn-udpgw \
        --listen-addr 127.0.0.1:7300 \
        --max-clients 500 \
        --max-connections-for-client 20 &
    echo "[✓] badvpn-udpgw di 127.0.0.1:7300"
fi

# ══════════════════════════════════════════════════════════════════
# Cloudflare Tunnel — selalu start, log ke /tmp/tunnel.log
#   - Kalau CF_TUNNEL_TOKEN di-set → named tunnel (domain fixed)
#   - Kalau tidak → quick tunnel (domain auto dari log)
# ══════════════════════════════════════════════════════════════════
if [ -n "$CF_TUNNEL_TOKEN" ]; then
    cloudflared tunnel run --protocol http2 --token "$CF_TUNNEL_TOKEN" \
        > /tmp/tunnel.log 2>&1 &
    echo "[✓] cloudflared (named tunnel) → log /tmp/tunnel.log"
else
    cloudflared tunnel --url http://127.0.0.1:8080 --protocol http2 \
        > /tmp/tunnel.log 2>&1 &
    echo "[✓] cloudflared (quick tunnel) → log /tmp/tunnel.log"
fi

# ══════════════════════════════════════════════════════════════════
# Background: auto-detect domain dari cloudflared log
# ══════════════════════════════════════════════════════════════════
(
    for i in $(seq 1 60); do
        sleep 2
        if [ -f /tmp/tunnel.log ]; then
            # Quick tunnel pattern
            DOMAIN=$(grep -oE '[a-zA-Z0-9][a-zA-Z0-9-]*\.trycloudflare\.com' /tmp/tunnel.log | head -1)
            if [ -n "$DOMAIN" ]; then
                echo "$DOMAIN" > /tmp/domain.txt
                echo "[✓] Auto-detect domain (quick): $DOMAIN"
                exit 0
            fi
            # Named tunnel pattern (dari ingress config)
            DOMAIN=$(grep -oE '"hostname":"[^"]+"' /tmp/tunnel.log | head -1 | sed 's/"hostname":"//;s/"$//')
            if [ -n "$DOMAIN" ]; then
                echo "$DOMAIN" > /tmp/domain.txt
                echo "[✓] Auto-detect domain (named): $DOMAIN"
                exit 0
            fi
        fi
    done
    echo "[!] Domain tidak terdeteksi dari log — fallback ke /api/info"
) &

# ══════════════════════════════════════════════════════════════════
# Nginx
# ══════════════════════════════════════════════════════════════════
echo "[✓] Nginx :8080 (HTTP) & :8443 (Stream)"
exec nginx -g 'daemon off;'
