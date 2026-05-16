# ---- Stage 1: download XRay binary ----
FROM debian:bookworm-slim AS xray-builder

ARG XRAY_VERSION=25.3.6
ARG TARGETARCH=amd64

RUN apt-get update \
 && apt-get install -y --no-install-recommends curl ca-certificates unzip \
 && rm -rf /var/lib/apt/lists/*

RUN set -eux; \
    case "${TARGETARCH}" in \
      amd64) XRAY_ARCH=64 ;; \
      arm64) XRAY_ARCH=arm64-v8a ;; \
      *) XRAY_ARCH=64 ;; \
    esac; \
    curl -fsSL -o /tmp/xray.zip \
      "https://github.com/XTLS/Xray-core/releases/download/v${XRAY_VERSION}/Xray-linux-${XRAY_ARCH}.zip"; \
    mkdir -p /opt/xray; \
    unzip /tmp/xray.zip -d /opt/xray; \
    chmod +x /opt/xray/xray; \
    rm /tmp/xray.zip


# ---- Stage 2: runtime ----
FROM python:3.12-slim

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1

# Caddy + gettext (для envsubst) + ca-certificates
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        curl ca-certificates gettext-base gnupg debian-keyring debian-archive-keyring apt-transport-https \
 && curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
      | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg \
 && curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
      > /etc/apt/sources.list.d/caddy-stable.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends caddy \
 && rm -rf /var/lib/apt/lists/*

# XRay из builder
COPY --from=xray-builder /opt/xray/xray         /usr/local/bin/xray
COPY --from=xray-builder /opt/xray/geoip.dat    /usr/local/share/xray/geoip.dat
COPY --from=xray-builder /opt/xray/geosite.dat  /usr/local/share/xray/geosite.dat
ENV XRAY_LOCATION_ASSET=/usr/local/share/xray

# Список РФ-доменов (UnRKN/ru-blocklist) — для блокировки на сервере,
# чтобы наш Railway-IP не светился в логах российских сервисов.
ARG RU_BLOCKLIST_REF=main
RUN curl -fsSL \
      "https://raw.githubusercontent.com/UnRKN/ru-blocklist/${RU_BLOCKLIST_REF}/ru-blocklist-extended-domain.dat" \
      -o /usr/local/share/xray/ru-blocklist.dat \
 && test -s /usr/local/share/xray/ru-blocklist.dat

WORKDIR /app

# Python deps
COPY web/requirements.txt /app/web/requirements.txt
RUN pip install -r /app/web/requirements.txt

# Остальные файлы проекта
COPY Caddyfile.template      /app/Caddyfile.template
COPY xray-config.template.json /app/xray-config.template.json
COPY entrypoint.sh           /app/entrypoint.sh
COPY web                     /app/web

RUN chmod +x /app/entrypoint.sh

# Railway сам пробрасывает $PORT, но дефолт зададим
ENV PORT=8080
EXPOSE 8080

CMD ["/app/entrypoint.sh"]
