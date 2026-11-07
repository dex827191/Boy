# Stage 1: Compile Script Golang + Build BadVPN UDPGW dari Source
FROM golang:1.22-alpine AS builder

# Install tools compile + curl
RUN apk update && apk add --no-cache cmake make gcc g++ musl-dev linux-headers curl

WORKDIR /app

# AMBIL SEMUA FILE dari repo GitHub lu ke dalam folder /app stage builder
COPY . .

# Proses build tetep lancar karena mux.go dan ws-proxy.go udah pasti ikut terbawa
RUN CGO_ENABLED=0 GOOS=linux go build -ldflags="-s -w" -o mux mux.go
RUN CGO_ENABLED=0 GOOS=linux go build -ldflags="-s -w" -o ws-proxy ws-proxy.go

# Download dan compile badvpn-udpgw langsung dari source resmi
WORKDIR /src
RUN curl -fsSL https://github.com/ambrop72/badvpn/archive/refs/tags/1.999.130.tar.gz | tar -xz \
    && cd badvpn-1.999.130 \
    && mkdir build && cd build \
    && cmake .. -DBUILD_NOTHING_BY_DEFAULT=1 -DBUILD_UDPGW=1 \
    && make badvpn-udpgw \
    && cp udpgw/badvpn-udpgw /app/badvpn-udpgw


# Stage 2: Runner Image Utama Alpine (Tetap Ringan)
FROM alpine:3.20

RUN apk update && apk add --no-cache \
    stunnel \
    openssl \
    sudo \
    curl \
    bash \
    openssh-server \
    openssh-client \
    gcompat

WORKDIR /app

# 1. Salin semua binary terkompilasi dari folder /app milik Stage 1
COPY --from=builder /app/mux /usr/local/bin/mux
COPY --from=builder /app/ws-proxy /usr/local/bin/ws-proxy
COPY --from=builder /app/badvpn-udpgw /usr/local/bin/badvpn-udpgw

# 2. FITUR TAMBAHAN: Salin juga semua file mentah (script, konfigurasi, dll) dari Stage 1 ke folder aktif /app di runner
COPY --from=builder /app /app

# Install cloudflared (Argo Tunnel) untuk Linux AMD64
RUN curl -fsSL -o /usr/local/bin/cloudflared \
    https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 \
    && chmod +x /usr/local/bin/cloudflared

RUN mkdir -p /var/run/sshd /var/run/stunnel /etc/stunnel

# Mengambil entrypoint yang sudah tercopy ke folder /app
RUN cp /app/entrypoint.sh /entrypoint.sh && chmod +x /entrypoint.sh

EXPOSE 8080

ENTRYPOINT ["/entrypoint.sh"]
