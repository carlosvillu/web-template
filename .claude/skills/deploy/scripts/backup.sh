#!/usr/bin/env bash
# Fuerza un backup de la BD de producción AHORA y comprueba que el dump es
# restaurable. Lo segundo es el punto: un backup que nadie ha probado a leer no
# es un backup, es un fichero. `pg_restore --list` lo abre de verdad y enumera
# su contenido — si el dump está truncado o corrupto, falla aquí y no el día
# que lo necesites.
#
# El cron del VPS debería hacer esto a diario (verify.sh avisa si no hay dump
# reciente). Este script es para forzarlo a mano: antes de una migración
# arriesgada, antes de un rollback, o para verificar que el cron funciona.
#
# Funciona desde el VPS (local) y desde desarrollo (ssh) — _lib.sh decide.
#
# Uso:  ./backup.sh            # hace el backup y lo verifica
#       ./backup.sh --list     # solo lista los backups existentes
set -euo pipefail

for arg in "$@"; do
  case "$arg" in
    --local)  export DEPLOY_MODE=local ;;
    --remote) export DEPLOY_MODE=remote ;;
  esac
done

. "$(cd "$(dirname "$0")" && pwd)/_lib.sh"

if [ "${1:-}" = "--list" ]; then
  printf '\033[1mBackups en el VPS (%s)\033[0m\n' "$BACKUP_DIR"
  run_vps "ls -lh $BACKUP_DIR/*.dump 2>/dev/null || echo '  (todavía no hay ninguno)'"
  exit 0
fi

step "Volcando la BD de producción"
# pg_dump corre DENTRO del contenedor de postgres (el host no necesita tener las
# herramientas de Postgres instaladas). Formato custom (-Fc): comprimido y apto
# para pg_restore selectivo. Usuario y BD salen del entorno del contenedor.
run_vps "mkdir -p $BACKUP_DIR && \
  docker compose -p $COMPOSE_PROJECT -f $REMOTE_DIR/$COMPOSE_FILE exec -T postgres \
    sh -c 'pg_dump -U \"\$POSTGRES_USER\" -Fc \"\$POSTGRES_DB\"' \
  > $BACKUP_DIR/${PROJECT_NAME}-\$(date -u +%Y%m%dT%H%M%SZ).dump"

step "Verificando que el último dump es restaurable"
run_vps "bash -euo pipefail -c '
  latest=\$(ls -t $BACKUP_DIR/*.dump | head -1)
  echo \"  dump: \$latest (\$(du -h \"\$latest\" | cut -f1))\"
  tables=\$(docker compose -p $COMPOSE_PROJECT -f $REMOTE_DIR/$COMPOSE_FILE exec -T postgres \
             pg_restore --list < \"\$latest\" 2>/dev/null | grep -c \"TABLE DATA\" || true)
  if [ \"\${tables:-0}\" -gt 0 ]; then
    printf \"  \033[32m✓ pg_restore lo lee sin error — %s tablas con datos\033[0m\n\" \"\$tables\"
  else
    printf \"  \033[31m✗ pg_restore NO pudo leer el dump (corrupto o vacío)\033[0m\n\"
    exit 1
  fi
'"
