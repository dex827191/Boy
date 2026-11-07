#!/bin/bash
set -e

# ══════════════════════════════════════════════════════════════════
# 🔥 Anti-reconnect: naikkan limit
# ══════════════════════════════════════════════════════════════════
ulimit -n 65535
ulimit -s unlimited 2>/dev/null || true

# ══════════════════════════════════════════════════════════════════
# Kernel tuning (BBR + buffer raksasa)
# ══════════════════════════════════════════════════════════════════
sysctl -w net.core.default_qdisc=fq 2>/dev/null || true
sysctl -w net.ipv4.tcp_congestion_control=bbr 2>/dev/null || true
sysctl -w net.ipv4.tcp_rmem="4096 8388608 16777216" 2>/dev/null || true
sysctl -w net.ipv4.tcp_wmem="4096 8388608 16777216" 2>/dev/null || true
sysctl -w net.core.rmem_max=16777216 2>/dev/null || true
sysctl -w net.core.wmem_max=16777216 2>/dev/null || true
sysctl -w net.core.netdev_max_backlog=50000 2>/dev/null || true
sysctl -w net.ipv4.tcp_max_syn_backlog=8192 2>/dev/null || true

USER_NAME="${SSH_USER:-dd}"
USER_PASS="${SSH_PASSWORD:-dd}"

# ══════════════════════════════════════════════════════════════════
# User SSH — UBUNTU: useradd -m (bukan adduser -D)
# ══════════════════════════════════════════════════════════════════
if ! id "$USER_NAME" &>/dev/null; then
    useradd -m -s /bin/bash "$USER_NAME"
    echo "$USER_NAME ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers
fi
echo "$USER_NAME:$USER_PASS" | chpasswd

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

# ══════════════════════════════════════════════════════════════════
# Sertifikat TLS (fresh setiap deploy)
# ══════════════════════════════════════════════════════════════════
mkdir -p /etc/nginx/ssl
openssl req -new -newkey rsa:2048 -days 3650 -nodes -x509 \
    -subj "/C=ID/ST=Jakarta/L=Jakarta/O=SSHServer/CN=localhost" \
    -keyout /etc/nginx/ssl/server.key \
    -out    /etc/nginx/ssl/server.crt 2>/dev/null

# ══════════════════════════════════════════════════════════════════
# SSH host keys + direktori wajib Ubuntu
# ══════════════════════════════════════════════════════════════════
ssh-keygen -A
mkdir -p /run/sshd

# ══════════════════════════════════════════════════════════════════
# Konfigurasi sshd (Ubuntu — UsePAM SUPPORTED)
# ══════════════════════════════════════════════════════════════════
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
echo "[✓] sshd aktif di 127.0.0.1:22"

# ══════════════════════════════════════════════════════════════════
# BadVPN UDPGW (dukungan UDP / game)
# ══════════════════════════════════════════════════════════════════
if [ -x /usr/local/bin/badvpn-udpgw ]; then
    /usr/local/bin/badvpn-udpgw \
        --listen-addr 127.0.0.1:7300 \
        --max-clients 500 \
        --max-connections-for-client 20 &
    echo "[✓] badvpn-udpgw aktif di 127.0.0.1:7300"
fi

# ══════════════════════════════════════════════════════════════════
# WS-Proxy (SSH over WebSocket)
# ══════════════════════════════════════════════════════════════════
export WS_PORT="8880"
ws-proxy &
echo "[✓] ws-proxy aktif di 127.0.0.1:8880"

# ══════════════════════════════════════════════════════════════════
# Cloudflare Tunnel (--url sesuai kode awalmu)
# ══════════════════════════════════════════════════════════════════
if [ -n "$CF_TUNNEL_TOKEN" ]; then
    cloudflared tunnel run --protocol http2 \
        --url "http://127.0.0.1:8080" \
        --token "$CF_TUNNEL_TOKEN" &
    echo "[✓] cloudflared → http://127.0.0.1:8080"
fi

# ══════════════════════════════════════════════════════════════════
# Nginx (foreground)
# ══════════════════════════════════════════════════════════════════
echo "[✓] Nginx listen :8080 (HTTP) & :8443 (Stream/TCP)"
exec nginx -g 'daemon off;'
