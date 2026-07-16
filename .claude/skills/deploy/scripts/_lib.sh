#!/usr/bin/env bash
# _lib.sh — común a todos los scripts de deploy. NO se ejecuta directo: se sourcea.
#
# Hace tres cosas:
#   1. Carga deploy.env (raíz del repo) y valida que el bootstrap lo rellenó.
#   2. Detecta DÓNDE corre el agente: EN el VPS de producción (modo "local") o en
#      una máquina de desarrollo (modo "remote"). Toda la lógica de "¿ssh o bash?"
#      vive aquí, en run_vps / copy_to_vps — los scripts son idénticos en ambos modos.
#   3. Helpers de salida (step/ok/bad).
#
# Detección de modo, por orden de prioridad:
#   a) DEPLOY_MODE en deploy.env o en el entorno ("local"/"remote"), o flag
#      --local/--remote del script que nos sourcea (los scripts lo traducen).
#   b) Fichero marcador /etc/deploy-target en la máquina (lo crea la tarea que
#      aprovisiona el VPS: `echo "role=production" | sudo tee /etc/deploy-target`).
#   c) La raíz del repo actual ES $REMOTE_DIR → estamos dentro del checkout de prod.
#   d) hostname == $VPS_HOSTNAME (si está definido).
#   Si nada matchea → "remote" (el caso conservador: nunca tocamos contenedores
#   locales por accidente creyendo que son producción).

set -euo pipefail

ROOT=$(git rev-parse --show-toplevel)
DEPLOY_ENV="$ROOT/deploy.env"

step() { printf '\n\033[1m▶ %s\033[0m\n' "$1"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; }
warn() { printf '  \033[33m⚠\033[0m %s\n' "$1"; }

[ -f "$DEPLOY_ENV" ] || { bad "no existe $DEPLOY_ENV — el bootstrap (o la primera tarea de deploy) debe crearlo"; exit 1; }
# shellcheck disable=SC1090
. "$DEPLOY_ENV"

for var in PROJECT_NAME DOMAIN VPS_IP VPS_SSH REMOTE_DIR; do
  val="${!var:-}"
  if [ -z "$val" ] || [[ "$val" == *'{{'* ]]; then
    bad "deploy.env: $var sin rellenar (vale '${val:-<vacío>}')."
    echo "  Rellena deploy.env antes de desplegar — lo hace el bootstrap o la tarea de deploy."
    exit 1
  fi
done

# Defaults para lo opcional (deploy.env puede sobreescribirlos)
COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.prod.yml}"
COMPOSE_PROJECT="${COMPOSE_PROJECT:-$PROJECT_NAME}"
SERVICES="${SERVICES:-web postgres}"
WEB_SERVICE="${WEB_SERVICE:-web}"
HEALTH_PATH="${HEALTH_PATH:-/api/health}"
VERIFY_ROOT_EXPECT="${VERIFY_ROOT_EXPECT:-200}"
CADDY_DIR="${CADDY_DIR:-/home/developer/infra/caddy}"
CADDY_CONTAINER="${CADDY_CONTAINER:-edge-caddy}"
EDGE_NETWORK="${EDGE_NETWORK:-edge}"
CADDY_UPSTREAM="${CADDY_UPSTREAM:-web:3000}"
BACKUP_DIR="${BACKUP_DIR:-/home/developer/backups/$PROJECT_NAME}"
MIGRATIONS_DIR="${MIGRATIONS_DIR:-packages/db/drizzle}"

detect_mode() {
  if [ -n "${DEPLOY_MODE:-}" ]; then echo "$DEPLOY_MODE"; return; fi
  if [ -f /etc/deploy-target ]; then echo "local"; return; fi
  if [ "$ROOT" = "$REMOTE_DIR" ]; then echo "local"; return; fi
  if [ -n "${VPS_HOSTNAME:-}" ] && [ "$(hostname)" = "$VPS_HOSTNAME" ]; then echo "local"; return; fi
  echo "remote"
}
MODE=$(detect_mode)
case "$MODE" in local|remote) ;; *) bad "DEPLOY_MODE inválido: '$MODE' (local|remote)"; exit 1 ;; esac

# run_vps "comando…" — lo ejecuta en el VPS: bash local si YA estamos en él,
# ssh si no. Los scripts nunca llaman a ssh directamente.
run_vps() {
  if [ "$MODE" = "local" ]; then
    bash -c "$1"
  else
    ssh -o BatchMode=yes -o ConnectTimeout=10 "$VPS_SSH" "$1"
  fi
}

# write_vps <ruta-remota> — escribe stdin en un fichero del VPS.
write_vps() {
  if [ "$MODE" = "local" ]; then
    cat > "$1"
  else
    ssh -o BatchMode=yes "$VPS_SSH" "cat > $1"
  fi
}

compose() { echo "docker compose -p $COMPOSE_PROJECT -f $REMOTE_DIR/$COMPOSE_FILE"; }
