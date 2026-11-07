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
# STAGE 2: Go builder (ws-proxy + admin)
# ══════════════════════════════════════════════════════════════════
FROM golang:1.22-bookworm AS go-builder
WORKDIR /build
COPY go.mod ./
COPY ws-proxy.go admin.go ./
RUN CGO_ENABLED=0 GOOS=linux go build -ldflags="-s -w" -o /out/ws-proxy ws-proxy.go \
 && CGO_ENABLED=0 GOOS=linux go build -ldflags="-s -w" -o /out/admin admin.go

# ══════════════════════════════════════════════════════════════════
# STAGE 3: Runtime
# ══════════════════════════════════════════════════════════════════
FROM ubuntu:22.04 AS runtime
ENV DEBIAN_FRONTEND=noninteractive
WORKDIR /app

RUN apt-get update && apt-get install -y \
    openssh-server openssh-client \
    nginx-full libnginx-mod-stream \
    openssl ca-certificates unzip \
    procps psmisc net-tools iproute2 \
    bash jq sudo curl wget libstdc++6 \
    && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL -o /usr/local/bin/cloudflared \
    https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 \
 && chmod +x /usr/local/bin/cloudflared

RUN curl -fsSL -o /tmp/xray.zip \
    https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip \
 && unzip -j /tmp/xray.zip xray -d /usr/local/bin/ \
 && chmod +x /usr/local/bin/xray && rm /tmp/xray.zip

COPY --from=badvpn-builder \
     /src/badvpn-1.999.130/build/udpgw/badvpn-udpgw \
     /usr/local/bin/badvpn-udpgw
COPY --from=go-builder /out/ws-proxy /usr/local/bin/ws-proxy
COPY --from=go-builder /out/admin    /usr/local/bin/admin
RUN chmod +x /usr/local/bin/badvpn-udpgw /usr/local/bin/ws-proxy /usr/local/bin/admin

COPY nginx.conf    /etc/nginx/nginx.conf
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

RUN rm -f /etc/nginx/sites-enabled/default /etc/nginx/conf.d/*.conf /etc/nginx/modules-enabled/*.conf

RUN mkdir -p /run/sshd /var/run /var/log/nginx /etc/nginx/ssl \
             /var/lib/nginx/body /var/lib/nginx/proxy \
             /var/lib/nginx/fastcgi /var/lib/nginx/scgi /var/lib/nginx/uwsgi

RUN openssl req -new -newkey rsa:2048 -days 3650 -nodes -x509 \
        -subj "/C=ID/ST=Jakarta/L=Jakarta/O=SSHServer/CN=localhost" \
        -keyout /etc/nginx/ssl/server.key \
        -out    /etc/nginx/ssl/server.crt 2>/dev/null

RUN ln -sf /dev/stdout /var/log/nginx/access.log \
 && ln -sf /dev/stderr /var/log/nginx/error.log \
 && ln -sf /dev/stdout /var/log/nginx/stream_access.log \
 && ln -sf /dev/stderr /var/log/nginx/stream_error.log

RUN nginx -t -c /etc/nginx/nginx.conf && echo "✅ nginx.conf valid"

EXPOSE 8080 8443
ENTRYPOINT ["/entrypoint.sh"]
