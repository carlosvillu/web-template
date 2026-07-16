#!/usr/bin/env bash
# Verifica el despliegue DESDE FUERA (como lo ve un usuario real) y, por
# separado, el ORIGEN saltándose el CDN/proxy (Cloudflare o similar).
#
# Por qué las dos capas por separado: un bucle de redirecciones o un 502 en el
# borde NO significa que el origen esté roto (caso clásico: zona de Cloudflare
# en SSL «Flexible» — CF habla HTTP contra un origen que redirige a HTTPS y el
# bucle lo crea el borde). Si solo pruebas el dominio público no sabes CUÁL de
# las dos capas falla; probando ambas, el diagnóstico es inmediato.
#
# Funciona igual desde el VPS (modo local: docker directo) que desde una máquina
# de desarrollo (modo remote: ssh) — _lib.sh decide.
#
# Uso:  ./verify.sh              # verificación completa (5 capas)
#       ./verify.sh --quick      # solo el dominio público (tras un redeploy)
#       ./verify.sh --local|--remote   # fuerza el modo
#
# Salida: exit 0 si todo pasa; 1 si algo falla (imprime QUÉ capa y QUÉ hacer).
set -uo pipefail

QUICK=0
for arg in "$@"; do
  case "$arg" in
    --quick)  QUICK=1 ;;
    --local)  export DEPLOY_MODE=local ;;
    --remote) export DEPLOY_MODE=remote ;;
  esac
done

. "$(cd "$(dirname "$0")" && pwd)/_lib.sh"
set +e  # cada comprobación gestiona su propio fallo

fails=0
okc()  { ok "$1"; }
badc() { bad "$1"; fails=$((fails + 1)); }
head_() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# ── Capa 1: el dominio público (CDN/proxy → Caddy → app) ─────────────────────
head_ "Dominio público — https://$DOMAIN"

# -L NO: queremos ver la redirección cruda, no seguirla. Un bucle se delata aquí
# (código 3xx apuntándose a sí mismo).
root_code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 "https://$DOMAIN/" 2>/dev/null)
root_loc=$(curl -sS -o /dev/null -w '%{redirect_url}' --max-time 15 "https://$DOMAIN/" 2>/dev/null)

# VERIFY_ROOT_EXPECT (deploy.env): "200", o "307:/login" si la raíz exige sesión.
exp_code="${VERIFY_ROOT_EXPECT%%:*}"
exp_loc="${VERIFY_ROOT_EXPECT#*:}"; [ "$exp_loc" = "$VERIFY_ROOT_EXPECT" ] && exp_loc=""
if [[ "$root_loc" == "https://$DOMAIN/" ]]; then
  badc "BUCLE DE REDIRECCIONES: / → sí mismo (HTTP $root_code)"
  echo "     → Causa casi segura: la zona del CDN está en SSL «Flexible»."
  echo "       ARREGLO (solo el humano, en el dashboard): SSL/TLS → «Full (strict)»."
elif [ "$root_code" = "$exp_code" ] && { [ -z "$exp_loc" ] || [[ "$root_loc" == *"$exp_loc"* ]]; }; then
  okc "GET / → $root_code${exp_loc:+ → $exp_loc} (esperado)"
else
  badc "GET / → HTTP $root_code${root_loc:+ → $root_loc} (esperado $VERIFY_ROOT_EXPECT)"
fi

health=$(curl -sS --max-time 15 "https://$DOMAIN$HEALTH_PATH" 2>/dev/null)
if [ "$health" = '{"ok":true,"db":true}' ]; then
  okc "GET $HEALTH_PATH → ok:true, db:true (la BD responde end-to-end)"
else
  badc "GET $HEALTH_PATH → ${health:-<sin respuesta>}"
  echo "     → db:false ⇒ la app vive pero NO habla con Postgres (mira los logs de $WEB_SERVICE)."
fi

if [ "$QUICK" = "1" ]; then
  head_ "Resultado"
  [ "$fails" -eq 0 ] && { okc "deploy OK"; exit 0; } || { badc "$fails fallo(s)"; exit 1; }
fi

# ── Capa 2: el ORIGEN, saltándose el CDN ─────────────────────────────────────
# --resolve fuerza a curl a ir a la IP del VPS manteniendo el SNI del dominio,
# así el certificado sigue validando. Si esto pasa y la capa 1 falla, el
# problema es del CDN y NO del servidor.
head_ "Origen directo (sin CDN) — https://$VPS_IP"
origin_code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 \
  --resolve "$DOMAIN:443:$VPS_IP" "https://$DOMAIN/" 2>/dev/null)
tls_ok=$(curl -sS -o /dev/null -w '%{ssl_verify_result}' --max-time 15 \
  --resolve "$DOMAIN:443:$VPS_IP" "https://$DOMAIN/" 2>/dev/null)
[ "$tls_ok" = "0" ] && okc "certificado TLS del origen: VÁLIDO" \
                    || badc "certificado TLS del origen inválido (código ${tls_ok:-?})"
[ "$origin_code" = "$exp_code" ] && okc "origen responde $origin_code (Caddy y la app, vivos)" \
                                 || badc "origen responde HTTP $origin_code (esperado $exp_code)"

# ── Capa 3: los contenedores ─────────────────────────────────────────────────
head_ "Contenedores en el VPS ($MODE)"
ps_out=$(run_vps 'docker ps --format "{{.Names}}|{{.Status}}"' 2>/dev/null)
if [ -z "$ps_out" ]; then
  badc "no se pudo consultar Docker ($([ "$MODE" = remote ] && echo "ssh $VPS_SSH" || echo local))"
else
  for svc in $SERVICES; do
    c="${COMPOSE_PROJECT}-${svc}-1"
    line=$(printf '%s\n' "$ps_out" | grep "^$c|" || true)
    if [ -z "$line" ]; then badc "$c NO está corriendo"
    else
      status="${line#*|}"
      case "$status" in
        *unhealthy*) badc "$c → $status" ;;
        Up*)         okc "$c → $status" ;;
        *)           badc "$c → $status" ;;
      esac
    fi
  done
  printf '%s\n' "$ps_out" | grep -q "^$CADDY_CONTAINER|" \
    && okc "$CADDY_CONTAINER → corriendo" || badc "$CADDY_CONTAINER NO está corriendo (nadie termina TLS)"
fi

# ── Capa 4: ¿qué código corre ahí? ───────────────────────────────────────────
# "¿Lo que está en producción es lo que tengo delante?" redeploy.sh deja la
# huella en .deployed; sin ella verías contenedores verdes sin poder afirmar
# qué contienen.
head_ "Código desplegado"
deployed=$(run_vps "cat $REMOTE_DIR/.deployed 2>/dev/null" 2>/dev/null || true)
if [ -z "$deployed" ]; then
  warn "sin huella (.deployed): el último deploy no la dejó — no se puede saber qué corre"
else
  dep_sha=$(printf '%s\n' "$deployed" | sed -n 's/^sha=//p')
  dep_at=$(printf '%s\n' "$deployed" | sed -n 's/^at=//p')
  local_sha=$(git rev-parse --short HEAD 2>/dev/null || echo '?')
  if [ "${dep_sha%%+*}" = "$local_sha" ]; then
    okc "producción = tu HEAD ($dep_sha, desplegado $dep_at)"
  else
    warn "producción corre $dep_sha y tu HEAD es $local_sha (desplegado $dep_at)"
    echo "     → hay deriva: lo que ves aquí NO es lo que sirve el servidor."
  fi
fi

# ── Capa 5: salud, no solo «responde» ────────────────────────────────────────
# "¿Está bien?" y "¿responde?" no son la misma pregunta. Un contenedor healthy
# puede estar escupiendo errores, con el disco lleno o con backups parados.
head_ "Salud"
errs=$(run_vps "cd $REMOTE_DIR && docker compose -p $COMPOSE_PROJECT -f $COMPOSE_FILE logs --tail 200 $SERVICES 2>/dev/null \
  | grep -icE '\"level\":(50|60)|FATAL' || true" 2>/dev/null)
if [ "${errs:-0}" -eq 0 ]; then
  okc "sin errores en los últimos 200 registros de $SERVICES"
else
  badc "$errs línea(s) de error/fatal en los logs recientes (pino level 50/60)"
  echo "     → míralos: docker compose -f $COMPOSE_FILE logs --tail 50 $WEB_SERVICE"
fi

disk=$(run_vps "df -h / | awk 'NR==2{print \$5}' | tr -d '%'" 2>/dev/null)
if [ -n "${disk:-}" ] && [ "$disk" -lt 85 ]; then
  okc "disco al ${disk}%"
else
  badc "disco al ${disk:-?}% — Postgres y los assets se quedan sin sitio"
fi

# El backup más reciente: un cron que dejó de correr es invisible hasta que lo
# necesitas. Aviso si el último dump tiene más de 48 h (el cron es diario).
age=$(run_vps "find $BACKUP_DIR -name '*.dump' -mtime -2 2>/dev/null | wc -l" 2>/dev/null)
if [ "${age:-0}" -gt 0 ]; then
  okc "hay backup de las últimas 48 h"
else
  badc "NINGÚN backup en las últimas 48 h — ¿ha dejado de correr el cron?"
  echo "     → fuerza uno: .claude/skills/deploy/scripts/backup.sh"
fi

head_ "Resultado"
if [ "$fails" -eq 0 ]; then
  printf '  \033[32m✓ deploy verificado: la app responde en https://%s\033[0m\n' "$DOMAIN"
  exit 0
fi
printf '  \033[31m✗ %s comprobación(es) fallaron\033[0m\n' "$fails"
echo "  Pista: si el ORIGEN pasa y el DOMINIO PÚBLICO falla, el problema es del"
echo "  CDN (no toques el servidor). Si falla el origen, mira los logs de $WEB_SERVICE."
exit 1
