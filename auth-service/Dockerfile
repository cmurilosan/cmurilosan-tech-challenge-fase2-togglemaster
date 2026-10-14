# syntax=docker/dockerfile:1

# ---------- Stage 1: build ----------
FROM golang:1.21-alpine AS builder

WORKDIR /src

# Dependencias primeiro: aproveita o cache de camadas quando so o codigo muda
COPY go.mod go.su[m] ./
RUN go mod download

COPY . .

# Binario estatico (CGO desabilitado), sem simbolos de debug nem paths absolutos
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/auth-service .

# ---------- Stage 2: runtime ----------
FROM alpine:3.20

# ca-certificates: chamadas HTTPS para a AWS (SQS).
# wget ja vem no busybox e e usado pelo healthcheck do compose.
RUN apk add --no-cache ca-certificates \
 && adduser -D -u 10001 appuser

COPY --from=builder /out/auth-service /usr/local/bin/auth-service

USER appuser
EXPOSE 8001

ENTRYPOINT ["/usr/local/bin/auth-service"]
