#!/usr/bin/env bash
# ============================================================
# Entrypoint: генерирует секреты, рендерит конфиги Caddy/XRay
# и запускает XRay, Flask и Caddy в одном контейнере.
# ============================================================
set -euo pipefail

log() { printf '\033[1;36m[entrypoint]\033[0m %s\n' "$*" >&2; }
err() { printf '\033[1;31m[entrypoint]\033[0m %s\n' "$*" >&2; }

# ---------- 1. Публичный домен ----------
if [[ -z "${PUBLIC_HOST:-}" ]]; then
  if [[ -n "${RAILWAY_PUBLIC_DOMAIN:-}" ]]; then
    PUBLIC_HOST="${RAILWAY_PUBLIC_DOMAIN}"
  elif [[ -n "${RAILWAY_STATIC_URL:-}" ]]; then
    PUBLIC_HOST="${RAILWAY_STATIC_URL#http://}"
    PUBLIC_HOST="${PUBLIC_HOST#https://}"
    PUBLIC_HOST="${PUBLIC_HOST%%/*}"
  else
    PUBLIC_HOST="localhost"
    err "RAILWAY_PUBLIC_DOMAIN не определён — использую '${PUBLIC_HOST}'."
    err "После первого деплоя в Railway → Settings → Networking → Generate Domain,"
    err "затем сделайте Redeploy."
  fi
fi
export PUBLIC_HOST

# ---------- 2. Секреты ----------
gen_uuid() {
  if command -v uuidgen >/dev/null 2>&1; then uuidgen
  elif [[ -r /proc/sys/kernel/random/uuid ]]; then cat /proc/sys/kernel/random/uuid
  else python3 -c 'import uuid; print(uuid.uuid4())'
  fi
}
gen_token() {
  python3 -c 'import secrets; print(secrets.token_urlsafe(16))'
}

: "${VLESS_UUID:=$(gen_uuid)}"
: "${WS_PATH:=/$(gen_token)}"
: "${SUB_PATH:=/$(gen_token)}"
: "${BASIC_AUTH_USER:=admin}"
: "${BASIC_AUTH_PASS:=$(gen_token)}"
: "${PROFILE_NAME:=Railway-VPN}"
: "${PORT:=8080}"

# Внутренние порты для XRay/Flask. Сдвигаем, если Railway вдруг
# назначит $PORT == один из них (маловероятно, но всякое бывает).
XRAY_PORT=10000
FLASK_PORT=10001
[[ "${PORT}" == "${XRAY_PORT}"  ]] && XRAY_PORT=20000
[[ "${PORT}" == "${FLASK_PORT}" ]] && FLASK_PORT=20001

# нормализуем пути (должны начинаться с /, без хвостового /)
[[ "${WS_PATH}"  != /* ]] && WS_PATH="/${WS_PATH}"
[[ "${SUB_PATH}" != /* ]] && SUB_PATH="/${SUB_PATH}"
WS_PATH="${WS_PATH%/}"
SUB_PATH="${SUB_PATH%/}"

export VLESS_UUID WS_PATH SUB_PATH BASIC_AUTH_USER BASIC_AUTH_PASS \
       PROFILE_NAME PORT XRAY_PORT FLASK_PORT

# ---------- 3. Рендерим конфиги ----------
RUNTIME=/tmp/runtime
mkdir -p "${RUNTIME}"

envsubst '${VLESS_UUID} ${WS_PATH} ${XRAY_PORT}' \
  < /app/xray-config.template.json \
  > "${RUNTIME}/xray-config.json"

envsubst '${PORT} ${WS_PATH} ${SUB_PATH} ${XRAY_PORT} ${FLASK_PORT}' \
  < /app/Caddyfile.template \
  > "${RUNTIME}/Caddyfile"

# ---------- 4. Краткий отчёт в логи ----------
cat <<EOF
=============================================================
  Railway VPN deployed
-------------------------------------------------------------
  Public host        : ${PUBLIC_HOST}
  Public port        : 443 (HTTPS, через Railway edge)
  Internal port      : ${PORT}
  WS path (secret)   : ${WS_PATH}
  Dashboard URL      : https://${PUBLIC_HOST}${SUB_PATH}/
  Basic-Auth user    : ${BASIC_AUTH_USER}
  Basic-Auth pass    : ${BASIC_AUTH_PASS}
  VLESS UUID         : ${VLESS_UUID}
  Profile name       : ${PROFILE_NAME}
-------------------------------------------------------------
  ВАЖНО: чтобы UUID/пути не менялись при следующем deploy,
  скопируйте значения выше в Railway → Variables.
=============================================================
EOF

# ---------- 5. Запуск процессов ----------
shutdown() {
  log "shutting down…"
  [[ -n "${XRAY_PID:-}"  ]] && kill -TERM "${XRAY_PID}"  2>/dev/null || true
  [[ -n "${FLASK_PID:-}" ]] && kill -TERM "${FLASK_PID}" 2>/dev/null || true
  [[ -n "${CADDY_PID:-}" ]] && kill -TERM "${CADDY_PID}" 2>/dev/null || true
  wait
}
trap shutdown TERM INT

log "starting xray…"
xray run -config "${RUNTIME}/xray-config.json" &
XRAY_PID=$!

log "starting flask…"
python -m web.app &
FLASK_PID=$!

log "starting caddy on :${PORT}…"
caddy run --config "${RUNTIME}/Caddyfile" --adapter caddyfile &
CADDY_PID=$!

# Если любой из процессов умер — валим контейнер, Railway перезапустит.
wait -n "${XRAY_PID}" "${FLASK_PID}" "${CADDY_PID}"
EXIT_CODE=$?
err "one of the services exited with code ${EXIT_CODE}"
shutdown
exit "${EXIT_CODE}"
