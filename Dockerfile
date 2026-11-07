# ══════════════════════════════════════════════════════════════════
# STAGE 1: BadVPN builder
# ══════════════════════════════════════════════════════════════════
FROM ubuntu:22.04 AS badvpn-builder
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y cmake make gcc g++ curl tar \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /src
RUN curl -fsSL https://github.com/ambrop72/badvpn/archive/refs/tags/1.999.130.tar.gz | tar -xz \
 && cd badvpn-1.999.130 && mkdir build && cd build \
 && cmake .. -DBUILD_NOTHING_BY_DEFAULT=1 -DBUILD_UDPGW=1 \
 && make badvpn-udpgw

# ══════════════════════════════════════════════════════════════════
# STAGE 2: Go builder (ws-proxy)
# ══════════════════════════════════════════════════════════════════
FROM golang:1.22-bookworm AS go-builder
WORKDIR /build
COPY go.mod ./
COPY ws-proxy.go ./
RUN CGO_ENABLED=0 GOOS=linux go build -ldflags="-s -w" -o /out/ws-proxy ws-proxy.go

# ══════════════════════════════════════════════════════════════════
# STAGE 3: Runtime (Ubuntu 22.04)
# ══════════════════════════════════════════════════════════════════
FROM ubuntu:22.04 AS runtime
ENV DEBIAN_FRONTEND=noninteractive
WORKDIR /app

RUN apt-get update && apt-get install -y \
    openssh-server \
    openssh-client \
    nginx-full \
    libnginx-mod-stream \
    openssl \
    ca-certificates \
    procps psmisc net-tools iproute2 \
    bash jq sudo \
    curl wget \
    libstdc++6 \
    && rm -rf /var/lib/apt/lists/*

# ── Cloudflared ──
RUN curl -fsSL -o /usr/local/bin/cloudflared \
    https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 \
 && chmod +x /usr/local/bin/cloudflared

# ── Binary dari builder ──
COPY --from=badvpn-builder \
     /src/badvpn-1.999.130/build/udpgw/badvpn-udpgw \
     /usr/local/bin/badvpn-udpgw
RUN chmod +x /usr/local/bin/badvpn-udpgw

COPY --from=go-builder /out/ws-proxy /usr/local/bin/ws-proxy
RUN chmod +x /usr/local/bin/ws-proxy

# ── Nginx config + entrypoint ──
COPY nginx.conf    /etc/nginx/nginx.conf
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# ── Bersihkan config default nginx + module auto-load ──
RUN rm -f /etc/nginx/sites-enabled/default \
          /etc/nginx/conf.d/*.conf \
          /etc/nginx/modules-enabled/*.conf

# ── Direktori runtime wajib ──
RUN mkdir -p /run/sshd /var/run /var/log/nginx /etc/nginx/ssl \
             /var/lib/nginx/body /var/lib/nginx/proxy \
             /var/lib/nginx/fastcgi /var/lib/nginx/scgi /var/lib/nginx/uwsgi

# ── Log nginx ke stdout/stderr ──
RUN ln -sf /dev/stdout /var/log/nginx/access.log \
 && ln -sf /dev/stderr /var/log/nginx/error.log \
 && ln -sf /dev/stdout /var/log/nginx/stream_access.log \
 && ln -sf /dev/stderr /var/log/nginx/stream_error.log

# ── Validasi fail-fast ──
RUN nginx -t -c /etc/nginx/nginx.conf 2>&1 || \
    (echo "❌ nginx.conf tidak valid!" && exit 1)

EXPOSE 8080 8443
ENTRYPOINT ["/entrypoint.sh"]
