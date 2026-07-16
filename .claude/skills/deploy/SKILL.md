---
name: deploy
description: Despliegue y operación de {{PROJECT_NAME}} en el VPS de producción — redeploy, rollback, verificación end-to-end, backups, logs y troubleshooting. Úsala SIEMPRE que el usuario diga "despliega", "deploy", "sube esto a producción", "actualiza el servidor", "¿está caído?", "¿está bien producción?", "mira los logs del VPS", "haz un backup", "vuelve atrás", o pregunte por el estado de producción; también antes de tocar nada del VPS por SSH, del Caddy central o del docker-compose.prod.yml. No la uses para el docker-compose.dev.yml (desarrollo local).
---

# Deploy — {{PROJECT_NAME}} en producción

Ejecuta, no investigues: los scripts son la vía canónica. Toda la configuración
del despliegue vive en **`deploy.env`** (raíz del repo, sin secretos, committeado)
— si tiene placeholders `{{…}}` sin rellenar, el deploy aún no está aprovisionado:
rellenarlo es la primera tarea de deploy (o del bootstrap).

**Todas las rutas de abajo son literales desde la raíz del repo.** (Ojo: existe
también un `scripts/` en la raíz, que es otra cosa.)

| El usuario dice… | Ejecuta |
|---|---|
| "despliega", "sube esto a producción" | `.claude/skills/deploy/scripts/redeploy.sh` |
| "¿está bien?", "¿se ha caído?", "no me fío" | `.claude/skills/deploy/scripts/verify.sh` |
| "vuelve atrás", "deshaz el deploy", algo se rompió | `.claude/skills/deploy/scripts/rollback.sh` |
| "haz un backup" | `.claude/skills/deploy/scripts/backup.sh` |
| "¿qué hay desplegado?" | `.claude/skills/deploy/scripts/rollback.sh --status` |
| "mira los logs" | §Logs |

`redeploy.sh` y `rollback.sh` terminan llamando a `verify.sh`: **un deploy que no
se puede verificar falla**, en vez de aparentar éxito.

## Autodetección: ¿dónde estoy corriendo?

Los scripts detectan solos si el agente corre **EN el VPS de producción** o en una
**máquina de desarrollo**, y adaptan el flujo (la lógica vive en `scripts/_lib.sh`):

| Señal (por orden) | Modo |
|---|---|
| `DEPLOY_MODE` en deploy.env/entorno, o flag `--local`/`--remote` | el que digas |
| Existe `/etc/deploy-target` (marcador; lo crea la tarea que aprovisiona el VPS) | `local` |
| La raíz del repo == `REMOTE_DIR` de deploy.env | `local` |
| `hostname` == `VPS_HOSTNAME` (si está definido) | `local` |
| Nada de lo anterior | `remote` (el caso conservador) |

- **Modo `local`** (el agente YA está en el VPS): actualiza `main` (`git pull
  --ff-only`), reconstruye las imágenes del compose de prod, levanta, aplica
  migraciones (van solas al arrancar web, con lock), conecta el proyecto al
  **Caddy central** del VPS (red docker compartida `EDGE_NETWORK` + site block en
  `CADDY_DIR/sites/DOMAIN.caddy` con validate+reload) y verifica desde fuera.
- **Modo `remote`** (máquina de desarrollo): sincroniza el código con el VPS —
  por defecto `git push` + `git pull --ff-only` allí (el bucle SÍ puede hacer
  push); con `--rsync` envía el árbol local tal cual (para probar trabajo sin
  pushear; deja huella `+sin-commitear`) — y después ejecuta **este mismo script
  en el VPS en modo local**. Un solo camino de deploy, dos puntos de entrada.

## Topología

```
Internet → CDN/proxy opcional (Cloudflare, SSL Full strict)
         → Caddy central  (CADDY_CONTAINER, CADDY_DIR — COMPARTIDO por todos los proyectos del VPS)
         → red docker EDGE_NETWORK → web (Next standalone)
                                     ├── postgres:16  (sin puerto publicado)
                                     └── worker       (solo si el módulo cola existe)
```

- **El TLS no es de este proyecto**: lo termina el Caddy central. El
  `docker-compose.prod.yml` no lleva reverse proxy. El enrutado se toca en
  `CADDY_DIR/sites/DOMAIN.caddy` y hay que **recargar** (§Caddy) — `redeploy.sh`
  crea el bloque la primera vez y recarga siempre.
- **web NUNCA publica puertos en `0.0.0.0`.** O se une a la red `EDGE_NETWORK`
  (external en el compose) y Caddy le llega por nombre de servicio
  (`CADDY_UPSTREAM`), o como mucho publica en `127.0.0.1`. Un puerto abierto se
  salta UFW y saca la app de detrás de Caddy — que es lo único que sostiene el
  trust boundary (Caddy sobrescribe `x-forwarded-for` con la IP real; sin eso,
  cualquier rate-limit por IP se bombea rotando una cabecera).
- **Los secretos viven solo en el VPS** (`REMOTE_DIR/.env`, gitignored). El modo
  `--rsync` excluye `.env` a propósito; `deploy.env` (committeado) no lleva
  ninguno.

## Desplegar

```bash
.claude/skills/deploy/scripts/redeploy.sh            # autodetecta el modo; sync por git
.claude/skills/deploy/scripts/redeploy.sh --rsync    # (remote) el árbol local tal cual
.claude/skills/deploy/scripts/redeploy.sh --no-sync  # (local) no toques git: lo que hay
```

Qué hace, en orden: sincroniza el código → deja huella del commit desplegado en
`REMOTE_DIR/.deployed` → reconstruye las imágenes → espera a que web esté
`healthy` → asegura red + site block del Caddy central → **verifica desde fuera**.

**No corre `pnpm gate`.** Correr los tests es decisión tuya antes de desplegar.

**Las migraciones se aplican solas** al arrancar web (con lock). Por eso el deploy
puede tardar: el healthcheck ya lo contempla.

**Downtime**: unos segundos al recrear los contenedores. Si existe el módulo cola,
los jobs en curso sobreviven (su estado vive en Postgres; pg-boss re-entrega).

## Verificar

```bash
.claude/skills/deploy/scripts/verify.sh            # completo (5 capas)
.claude/skills/deploy/scripts/verify.sh --quick    # solo el dominio público
```

Comprueba cinco cosas **por separado**, y esa separación es lo que convierte un
síntoma en un diagnóstico: dominio público, **origen saltándose el CDN**,
contenedores, **qué commit corre** (vs. tu HEAD) y salud (errores en logs, disco,
antigüedad del último backup). Lo que espera de `GET /` se configura en
`VERIFY_ROOT_EXPECT` ( `"200"`, o `"307:/login"` si la raíz exige sesión).

### Cómo leer un fallo

| Falla… | y pasa… | Entonces |
|---|---|---|
| dominio público | el origen | **Es el CDN, no el servidor.** No toques el VPS. Bucle de redirecciones ⇒ zona en SSL «Flexible» ⇒ el humano la pone en **Full (strict)** |
| dominio público | nada más | Mira el Caddy central (§Caddy) y luego los contenedores |
| health con `db:false` | la app responde | web vive pero no habla con Postgres: logs de `web` + estado de `postgres` |
| web `unhealthy` | postgres `healthy` | Suele ser el arranque: web migra al boot. Logs de `web` |
| postgres `unhealthy` | — | La BD no arranca. Logs de `postgres`; mira el disco |
| "hay deriva" (SHA ≠ HEAD) | todo lo demás | Producción corre otro código. ¿Se desplegó con `--rsync` desde otro árbol, o alguien no pusheó? |
| "ningún backup en 48 h" | todo lo demás | El cron murió. Fuerza uno con `backup.sh` y revisa `crontab -l` en el VPS |

## Volver atrás

```bash
.claude/skills/deploy/scripts/rollback.sh          # al commit anterior al desplegado
.claude/skills/deploy/scripts/rollback.sh <sha>    # a uno concreto
.claude/skills/deploy/scripts/rollback.sh --status # qué hay desplegado ahora
```

Hace backup antes de tocar nada. En modo remote despliega el commit destino con
`git archive` (no mueve tu working tree); en modo local hace `git checkout
--detach` del destino (el siguiente redeploy vuelve a `main`).

**Lo crítico**: el rollback de código **no deshace la base de datos**. Las
migraciones son de ida. Volver atrás te deja código viejo contra un schema nuevo —
lo cual suele funcionar (una columna nueva es invisible para el código viejo),
pero **no** si la migración borró o renombró algo que el código viejo usa. El
script detecta si el tramo traía migraciones (`MIGRATIONS_DIR`) y exige
confirmación explícita (`SI` interactivo, o `--yes` si lo decide quien invoca).
Si la migración era destructiva, el rollback de código no basta: hay que restaurar.

## Backups y restauración

```bash
.claude/skills/deploy/scripts/backup.sh            # fuerza uno AHORA y prueba que es restaurable
.claude/skills/deploy/scripts/backup.sh --list     # lista los existentes
```

El cron del VPS debería hacer un `pg_dump` diario en `BACKUP_DIR` (retención ~14
días) — instalarlo es parte de la tarea de aprovisionamiento. `backup.sh` además
abre el dump con `pg_restore --list`: un backup que nadie ha probado a leer no es
un backup.

**Restaurar** (destructivo — se pierde todo lo ocurrido desde ese dump; confírmalo
con el humano antes). En el VPS, desde `REMOTE_DIR`:

```bash
docker compose -f docker-compose.prod.yml stop web worker   # que nadie escriba (worker solo si existe)
docker compose -f docker-compose.prod.yml exec -T postgres \
  pg_restore -U "$POSTGRES_USER" -d "$POSTGRES_DB" --clean --if-exists \
  < BACKUP_DIR/<el-dump>.dump
docker compose -f docker-compose.prod.yml start web worker
```

## Logs

```bash
# app (JSON de pino; correlaciona por request_id)
docker compose -f docker-compose.prod.yml logs --tail 50 web     # en el VPS
# desde desarrollo: ssh $VPS_SSH 'cd $REMOTE_DIR && docker compose -f docker-compose.prod.yml logs --tail 50 web'

# el borde (TLS, enrutado, certificados) — en el VPS
cd $CADDY_DIR && docker compose logs --tail 50 caddy
```

## Caddy

Un cambio en el site file (`CADDY_DIR/sites/DOMAIN.caddy`) no surte efecto hasta
recargarlo. Valida antes (en el VPS):

```bash
docker exec $CADDY_CONTAINER caddy validate --config /etc/caddy/Caddyfile && \
docker exec $CADDY_CONTAINER caddy reload   --config /etc/caddy/Caddyfile
```

El Caddyfile central debe tener `import sites/*.caddy`; cada proyecto del VPS
aporta su fichero. `redeploy.sh` lo crea si no existe (con `reverse_proxy
CADDY_UPSTREAM`) y recarga.

## Acceso

`ssh $VPS_SSH` (solo clave; `BatchMode` debe funcionar — los scripts lo asumen).

**`sudo` pide una contraseña que no tienes.** Normalmente no la necesitas: el
usuario del VPS está en el grupo `docker`. Si algo exige sudo de verdad (paquetes
del sistema, UFW, `/etc/deploy-target`), prepara el comando exacto y **pídeselo
al humano**; no intentes rodearlo.

## Trampas conocidas (genéricas, ya mordieron)

**`VAR: ${VAR:-}` en compose no significa "sin valor": significa cadena vacía.**
La variable se define igualmente aunque no esté en el `.env`, y el código que
distingue *ausente* de *vacío* se rompe (`Number('') === 0` ha sembrado ceros
donde tocaba un default). Las opcionales van por `env_file`, no interpoladas.

**Un `502` o un bucle de redirecciones en el borde no significa que el origen
esté roto.** Verifica el origen **por separado** (`verify.sh` lo hace) antes de
tocar el servidor.

**Volúmenes `ro` vs. `rw`**: si un servicio monta un volumen en solo-lectura y
otro código escribe ahí (uploads, exports), en producción dará `EROFS` aunque en
dev funcione. Antes de desplegar un cambio que escribe a disco, comprueba los
mounts del compose de prod. Es una decisión de producto, no un parche silencioso.
