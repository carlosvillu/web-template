#!/usr/bin/env bash
# Redeploy a producción. Detecta solo dónde corre (ver _lib.sh):
#
#   · Modo LOCAL  — el agente YA está en el VPS de producción: actualiza main,
#     reconstruye las imágenes, levanta, conecta al Caddy central y verifica.
#   · Modo REMOTE — el agente está en una máquina de desarrollo: sincroniza el
#     código con el VPS (git push + pull, o rsync) y ejecuta ESTE MISMO script
#     allí en modo local. Un solo camino de deploy, dos puntos de entrada.
#
# Si la verificación final falla, el script falla — un deploy no está hecho
# porque los contenedores arranquen, sino porque la app responda desde fuera.
#
# Uso:  ./redeploy.sh                # autodetecta el modo
#       ./redeploy.sh --rsync       # (remote) envía el árbol local tal cual, sin git
#       ./redeploy.sh --local|--remote   # fuerza el modo
#       ./redeploy.sh --no-sync     # (local) no toques git: despliega lo que hay
#       ./redeploy.sh --allow-dirty # (local) permite desplegar con el árbol SUCIO
#
# Cuándo --rsync: cuando quieres probar en producción algo que aún no está
# pusheado (legítimo, pero deja huella "+sin-commitear" en .deployed para que
# verify.sh delate la deriva). El camino canónico es git: el bucle SÍ hace push.
set -euo pipefail

SYNC="git"; NO_SYNC=0; ALLOW_DIRTY=0
for arg in "$@"; do
  case "$arg" in
    --local)  export DEPLOY_MODE=local ;;
    --remote) export DEPLOY_MODE=remote ;;
    --rsync)  SYNC="rsync" ;;
    --no-sync) NO_SYNC=1 ;;
    --allow-dirty) ALLOW_DIRTY=1 ;;
    *) echo "flag desconocida: $arg" >&2; exit 1 ;;
  esac
done

. "$(cd "$(dirname "$0")" && pwd)/_lib.sh"
cd "$ROOT"

write_footprint() { # $1 = sha a registrar
  write_vps "$REMOTE_DIR/.deployed" <<EOF
sha=$1
at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
by=$(git config user.email 2>/dev/null || echo desconocido)
EOF
}

# ═══ MODO REMOTE: sincronizar y delegar en el VPS ═════════════════════════════
if [ "$MODE" = "remote" ]; then
  step "Modo REMOTE (máquina de desarrollo → $VPS_SSH)"

  if [ "$SYNC" = "git" ]; then
    [ -n "$(git status --porcelain)" ] && \
      warn "hay cambios sin commitear que NO viajarán por git (usa --rsync si quieres desplegarlos)"
    step "1/2 · git push y actualización del checkout del VPS"
    git push origin main
    run_vps "cd $REMOTE_DIR && git fetch origin && git checkout main && git pull --ff-only"
    step "2/2 · Ejecutando el deploy EN el VPS (modo local)"
    exec ssh -o BatchMode=yes "$VPS_SSH" \
      "cd $REMOTE_DIR && DEPLOY_MODE=local .claude/skills/deploy/scripts/redeploy.sh --no-sync"
  else
    # rsync: el remoto queda idéntico al árbol local. Se excluye lo que no debe
    # viajar: dependencias y builds (se reconstruyen en la imagen), el .git, y
    # CRÍTICAMENTE el .env — los secretos de producción viven SOLO en el VPS y
    # un rsync los machacaría con los de desarrollo.
    if [ -n "$(git status --porcelain)" ]; then
      warn "cambios sin commitear: se desplegarán igualmente (rsync envía el árbol tal cual)"
      git status --short | head -10
    fi
    step "1/2 · rsync del árbol local al VPS"
    rsync -az --delete \
      --exclude '.git' --exclude 'node_modules' --exclude '.next' --exclude 'dist' \
      --exclude '.env' --exclude '.env.*' \
      --exclude 'test-results' --exclude 'playwright-report' \
      ./ "$VPS_SSH:$REMOTE_DIR/"
    DIRTY=$([ -n "$(git status --porcelain)" ] && echo '+sin-commitear' || echo '')
    write_footprint "$(git rev-parse --short HEAD)$DIRTY"
    step "2/2 · Ejecutando el deploy EN el VPS (modo local, sin tocar git)"
    # `--allow-dirty` es OBLIGATORIO aquí: rsync acaba de dejar el árbol del VPS
    # idéntico al local (posiblemente sucio) — desplegar trabajo sin commitear es
    # SU propósito, y sin la flag la guarda de árbol limpio abortaría siempre.
    exec ssh -o BatchMode=yes "$VPS_SSH" \
      "cd $REMOTE_DIR && DEPLOY_MODE=local .claude/skills/deploy/scripts/redeploy.sh --no-sync --allow-dirty"
  fi
fi

# ═══ MODO LOCAL: estamos EN el VPS ════════════════════════════════════════════
step "Modo LOCAL (este host ES producción: $REMOTE_DIR)"

# Guarda de árbol limpio: la imagen se construye desde el ÁRBOL (COPY . .), no
# desde HEAD. Con el árbol sucio se despliega trabajo sin commitear ni verificar,
# y el único rastro sería un '+sin-commitear' en .deployed, que se lee DESPUÉS
# del deploy y no lo impide. Ya mordió en un proyecto real: un deploy se llevó a
# producción una tarea a medio revisar. Con un humano lanzando el script es
# recuperable; con el bucle desplegando solo, es cómo se cuela código sin
# verificar. Va ANTES del `if NO_SYNC` a propósito: `--no-sync` («despliega lo
# que hay») es justo el caso más expuesto.
if [ "$ALLOW_DIRTY" = "0" ] && [ -n "$(git status --porcelain)" ]; then
  echo "" >&2
  echo "  ✗ ABORTADO: el árbol de trabajo tiene cambios sin commitear." >&2
  echo "" >&2
  echo "  Este script construye la imagen desde el ÁRBOL (COPY . .), no desde HEAD:" >&2
  echo "  desplegaría código que nadie ha revisado ni verificado, y .deployed solo" >&2
  echo "  lo delataría a posteriori con '+sin-commitear'." >&2
  echo "" >&2
  git status --short | head -10 >&2
  echo "" >&2
  echo "  Commitea (o stashea) y repite. Si el árbol sucio es DELIBERADO:" >&2
  echo "      .claude/skills/deploy/scripts/redeploy.sh --allow-dirty" >&2
  exit 1
fi

if [ "$NO_SYNC" = "0" ]; then
  step "1/5 · Actualizando main"
  if git remote get-url origin >/dev/null 2>&1; then
    git fetch origin
    branch=$(git rev-parse --abbrev-ref HEAD)
    [ "$branch" = "main" ] || { warn "HEAD está en '$branch', no en main — checkout a main"; git checkout main; }
    git pull --ff-only
  else
    warn "sin remote 'origin': se despliega el árbol tal cual"
  fi
  DIRTY=$([ -n "$(git status --porcelain)" ] && echo '+sin-commitear' || echo '')
  write_footprint "$(git rev-parse --short HEAD)$DIRTY"
fi

step "2/4 · Reconstruyendo imágenes y levantando servicios"
# --build reconstruye; up -d recrea solo lo que cambió. Las migraciones se
# aplican solas al arrancar web (con lock) — por eso el healthcheck da margen.
$(compose) up -d --build

step "3/4 · Esperando a que $WEB_SERVICE esté 'healthy'"
web_container="${COMPOSE_PROJECT}-${WEB_SERVICE}-1"
for i in $(seq 1 30); do
  state=$(docker inspect --format '{{.State.Health.Status}}' "$web_container" 2>/dev/null || echo "starting")
  case "$state" in
    healthy)   ok "$WEB_SERVICE: healthy (tras $((i * 5))s)"; break ;;
    unhealthy) bad "$WEB_SERVICE: UNHEALTHY — abortando"
               $(compose) logs --tail 40 "$WEB_SERVICE"; exit 1 ;;
    *)         printf '  %s: %s… (%ss)\n' "$WEB_SERVICE" "$state" "$((i * 5))"; sleep 5 ;;
  esac
  [ "$i" = "30" ] && { bad "timeout esperando healthy"; exit 1; }
done

step "4/4 · Bloque del dominio en el Caddy central"
site_file="$CADDY_DIR/sites/$DOMAIN.caddy"
if [ ! -f "$site_file" ]; then
  # Primera vez: crea el site block. El Caddyfile central debe hacer
  # `import sites/*.caddy`. TLS lo gestiona Caddy (o Cloudflare por delante).
  #
  # header_up X-Forwarded-For {client_ip}: SOBRESCRIBE el header con la IP del
  # socket en vez de añadirla a lo que mandara el cliente — deja de ser
  # client-controllable. Es un control de seguridad, no una casualidad de
  # defaults, y por eso es explícito. OJO: si hay Cloudflare delante, esa IP es
  # la de Cloudflare, NO la del visitante: la real va en CF-Connecting-IP y es
  # la que debe usar cualquier rate-limit (SKILL.md §Topología).
  #
  # Si el proyecto tiene SSE, este bloque NO basta: la ruta de eventos necesita
  # su propio handle con flush_interval -1 y sin encode. Se edita a mano.
  mkdir -p "$CADDY_DIR/sites"
  cat > "$site_file" <<EOF
$DOMAIN {
	reverse_proxy $CADDY_UPSTREAM {
		header_up X-Forwarded-For {client_ip}
	}
}
EOF
  ok "creado $site_file → $CADDY_UPSTREAM"
fi
# Un cambio en el site file no surte efecto hasta recargar. Valida SIEMPRE antes.
docker exec "$CADDY_CONTAINER" caddy validate --config /etc/caddy/Caddyfile \
  && docker exec "$CADDY_CONTAINER" caddy reload --config /etc/caddy/Caddyfile \
  || { bad "el Caddyfile no valida o no recarga — el dominio puede no estar enrutado"; exit 1; }

step "Verificando desde fuera"
# La única prueba que vale: ¿responde la app en internet? Si esto falla, el
# deploy NO está hecho, por muy verdes que estén los contenedores.
exec "$ROOT/.claude/skills/deploy/scripts/verify.sh"
