# ══════════════════════════════════════════════════════════════════
# Stage 1: Build Go WS-proxy + BadVPN UDPGW
# ══════════════════════════════════════════════════════════════════
FROM golang:1.22-alpine AS builder

RUN apk add --no-cache cmake make gcc g++ musl-dev linux-headers curl

WORKDIR /app
COPY ws-proxy.go .
RUN CGO_ENABLED=0 GOOS=linux go build -ldflags="-s -w" -o ws-proxy ws-proxy.go

WORKDIR /src
RUN curl -fsSL https://github.com/ambrop72/badvpn/archive/refs/tags/1.999.130.tar.gz | tar -xz \
    && cd badvpn-1.999.130 \
    && mkdir build && cd build \
    && cmake .. -DBUILD_NOTHING_BY_DEFAULT=1 -DBUILD_UDPGW=1 \
    && make badvpn-udpgw

# ══════════════════════════════════════════════════════════════════
# Stage 2: Runtime Alpine (nginx + sshd + tunnel)
# ══════════════════════════════════════════════════════════════════
FROM alpine:3.20

RUN apk add --no-cache \
    nginx \
    nginx-mod-stream \
    openssl \
    sudo \
    curl \
    bash \
    openssh-server \
    openssh-client \
    gcompat \
    libstdc++

COPY --from=builder /app/ws-proxy                                   /usr/local/bin/ws-proxy
COPY --from=builder /src/badvpn-1.999.130/build/udpgw/badvpn-udpgw  /usr/local/bin/badvpn-udpgw

# Cloudflared (opsional, hanya jika pakai CF Tunnel)
RUN curl -fsSL -o /usr/local/bin/cloudflared \
    https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 \
    && chmod +x /usr/local/bin/cloudflared

COPY nginx.conf     /etc/nginx/nginx.conf
COPY entrypoint.sh  /entrypoint.sh
RUN chmod +x /entrypoint.sh

RUN mkdir -p /var/run/sshd /var/run/nginx /etc/nginx/ssl /var/log/nginx \
    && chown -R nginx:nginx /var/log/nginx

EXPOSE 8080 8443

ENTRYPOINT ["/entrypoint.sh"]
