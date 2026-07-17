# Menú de módulos de F0

F0 no es una lista fija: es un menú. En la etapa 3 del bootstrap se cruza cada módulo con el PRD aprobado y se propone la selección justificada (módulo → señal del PRD que lo exige). Solo los módulos elegidos se convierten en tareas `T0.n` del planning, con el grafo de dependencias de abajo. Numera en el orden del grafo, no del menú.

Regla general: **si el PRD no lo exige, fuera** — un módulo de F0 sin consumidor en F1..Fn es esqueleto muerto que el gate mantiene para nadie. Y al revés: si una fase de features lo va a necesitar, entra en F0, no se improvisa a mitad de F2.

## Los módulos

### 1 · Esqueleto monorepo + gate — SIEMPRE (T0.1)
- **Cuándo**: siempre; no es opcional.
- **Entrega**: pnpm workspaces con `apps/web` (Next.js App Router + Tailwind v4 CSS-first), `packages/core` (contratos Zod compartidos), `packages/db` (aunque Postgres llegue después, el paquete nace aquí si el módulo 3 entra), `apps/worker` solo si el módulo 6 entra; tsconfig/eslint/prettier compartidos; pino con correlación (`request_id` y los ids del dominio) desde el día 1; `pnpm gate` completo (lint && typecheck && format:check && knip && readme:status:check && test); healthcheck `/api/health`.
- **Verificación típica**: `pnpm build && pnpm gate` verde; `curl /api/health` → `{ok:true}`; romper a propósito un tipo de `packages/core` rompe la compilación de las apps que lo importan.
- **Depende de**: —.

### 2 · Docker Compose de desarrollo con Postgres
- **Cuándo**: el PRD tiene modelo de datos (§ modelo de datos no vacío) — es decir, casi siempre.
- **Entrega**: `docker-compose.dev.yml` con `postgres:16` (volumen persistente) + `.env.example` documentado; web (y worker) se conectan al arrancar.
- **Verificación típica**: `docker compose up -d` → `/api/health` devuelve `{ok:true, db:true}`; parar Postgres → `db:false` sin tumbar la app.
- **Depende de**: 1 (y de TD.7 por orden, si la fase TD se intercala aquí).

### 3 · Drizzle + primera migración
- **Cuándo**: siempre que el módulo 2 entre.
- **Entrega**: Drizzle en `packages/db`, migración inicial con las 2-3 tablas nucleares del PRD, runner `db:migrate` (decidir aquí si migra on-boot con lock o como paso de deploy — la decisión afecta al módulo 13), repos tipados mínimos.
- **Verificación típica**: `pnpm db:migrate` sobre BD vacía crea las tablas (`psql \dt`); crear una fila vía script de smoke y leerla de vuelta.
- **Depende de**: 2.

### 4 · Auth (mono o multi-usuario)
- **Cuándo**: mono-usuario si el PRD declara herramienta personal self-hosted (decisión D tipo "sin billing ni multi-tenancy"); multi-usuario si hay monetización por cuentas. Solo se omite si la app es 100 % local sin superficie pública.
- **Entrega mono**: login con password (hash en settings), sesión cookie httpOnly, middleware que protege todo salvo login/health/webhooks, rate limit de login. Multi: signup/login + tabla users + sesiones.
- **Verificación típica**: en navegador, `/` sin sesión redirige a login; password incorrecto repetido → rate limit visible; con password correcto la cookie sobrevive a un refresh. Esta tarea suele **estrenar el harness Playwright** (`apps/web/e2e/auth.spec.ts`).
- **Depende de**: 3. Nota transversal al planning: desde que auth cierre, toda verificación con curl/scripts se autentica primero.

### 5 · StorageAdapter
- **Cuándo**: el PRD menciona ficheros del usuario o generados (uploads, imágenes, exports, media).
- **Entrega**: interfaz `StorageAdapter` (put/get/stat/delete) con implementación filesystem, tabla `asset` mínima (id, kind, storage_key, mime, bytes, checksum) y endpoint de descarga autenticado por streaming (nunca exponer la ruta cruda).
- **Verificación típica**: subir un fichero por script → aparece en disco con su fila en `asset` → descargarlo por el endpoint con checksum idéntico; sin sesión, 401.
- **Depende de**: 3, 4 (el 401 usa el middleware real de auth, no un check ad-hoc).

### 6 · Cola pg-boss (+ apps/worker)
- **Cuándo**: el PRD tiene trabajo asíncrono/larga duración (llamadas a APIs de media/LLM lentas, renders, crons, pipelines). Si todo cabe en request/response, fuera — y fuera también `apps/worker` de T0.1.
- **Entrega**: pg-boss inicializado en el worker; job de demo `noop` con retries/backoff; helper `enqueue()` tipado en `packages/core`.
- **Verificación típica**: encolar 10 jobs con 30 % de fallo configurado → el log muestra ejecuciones y reintentos; la tabla de pg-boss acaba con todos en `completed`.
- **Depende de**: 3.

### 7 · Máquina de estados + runs de demo con flags configurables
- **Cuándo**: el PRD describe un proceso multi-paso con estados observables (pipeline, DAG, workflow con aprobaciones). Es el módulo más caro: solo si es EL corazón del producto.
- **Entrega**: (a) migración de runs/steps con enums de estados y `transition(id, event)` transaccional (`SELECT … FOR UPDATE`, tabla de transiciones válidas, encolado dentro de la misma transacción, `NOTIFY`); (b) creación de run desde definición, consumer genérico y **executors de demo con flags configurables** (`sleep_ms`, `fail_rate`, `hang`) — imprescindibles para verificar los módulos 8 y 9 sin APIs reales. Suele dividirse en `T0.na`/`T0.nb`.
- **Verificación típica**: script contra BD real con transiciones legales e ilegales (las ilegales no tocan la BD); un run de demo completa `pending→…→succeeded` con timestamps coherentes; N runs concurrentes sin interbloqueos.
- **Depende de**: 6.

### 8 · Checkpoints y cancel
- **Cuándo**: el proceso del módulo 7 tiene pausas de aprobación humana o necesita cancelación/skip.
- **Entrega**: estado `waiting_approval` + endpoints approve/edit/reject, skip y cancel; invalidación de sub-grafo con `supersedes_id` (nunca reset de filas); modo autopilot con override por nodo si el PRD lo pide; audit log del diff editado.
- **Verificación típica**: run de demo con checkpoint se pausa; approve reanuda; edit crea la fila sucesora y el diff aparece en el audit log; cancel detiene un run en curso; autopilot completa sin pausas respetando el override.
- **Depende de**: 7.

### 9 · Timeouts, retries y sweeper
- **Cuándo**: siempre que el módulo 7 entre (un orquestador sin expiración deja runs zombis).
- **Entrega**: `timeout_at` por step, barrido periódico en el worker que expira colgados, retry manual y automático hasta `max_retries`. Ojo: el cron de pg-boss tiene precisión de ~minuto; si la verificación exige detectar cuelgues en segundos, el barrido va como timer del worker.
- **Verificación típica**: executor de demo con `hang=true` y timeout de 10 s → `expired` en <40 s sin intervención; retry sobre un step con `fail_rate` forzado a 0 re-ejecuta y completa.
- **Depende de**: 7.

### 10 · SSE realtime (LISTEN/NOTIFY)
- **Cuándo**: la UI debe reflejar progreso de servidor en vivo sin refresco (canvas de pipeline, barras de progreso, feeds). Si un refresh manual basta para v1, fuera.
- **Entrega**: endpoint SSE streaming con `snapshot` al conectar, deltas vía LISTEN/NOTIFY, heartbeat, `id:` monotónico + re-snapshot con `Last-Event-ID`; contrato de eventos en `packages/core`. En deploy, la ruta SSE necesita su ajuste de proxy (flush sin buffer).
- **Verificación típica**: `curl -N` durante un run de demo muestra snapshot, deltas y heartbeats; matar y reabrir el curl con `Last-Event-ID` re-sincroniza sin perder el estado final.
- **Depende de**: 7 (o de la fuente de eventos que exista).

### 11 · UI principal v1 desde mockup
- **Cuándo**: siempre que haya UI — es la primera pantalla real del producto (la del recorrido central del PRD), construida con las primitivas de la fase TD.
- **Entrega**: la página principal operable de punta a punta contra los módulos anteriores (con executors/datos de demo), partiendo de su mockup aprobado en `docs/mockups/`.
- **Verificación típica**: en el navegador (no vía API), operar el recorrido completo y VER el resultado en vivo; su spec Playwright permanente queda en `pnpm test:e2e`.
- **Depende de**: TD.7 + los módulos que la pantalla consuma (típicamente 8, 9, 10).

### 12 · Spend ledger
- **Cuándo**: el PRD consume APIs de pago por uso (LLM, generación de media, scraping) — señal directa: el PRD tiene sección de costes o precios `[verificar]`.
- **Entrega**: tablas `cost_entry` y `budget`, helper `recordCost()`, página `/spend` v1 con totales por día/proveedor y alerta al superar presupuesto.
- **Verificación típica**: tras N runs de demo con costes ficticios elegidos por el verifier (no los fixtures del implementer), `/spend` muestra la suma exacta; un presupuesto por debajo del gasto dispara la alerta.
- **Depende de**: 3 (y 7 si el coste se ancla a steps).

### 13 · Deploy inicial VPS (Docker + Caddy) ⚠
- **Cuándo**: el PRD declara self-hosted/producción en VPS. Lleva ⚠ SIEMPRE: VPS contratado y dominio con DNS son del usuario.
- **Entrega**: `docker-compose.prod.yml` (web standalone, worker si existe, postgres, volúmenes), `DEPLOY.md`, deploy por `git pull && docker compose up -d --build`, cron de `pg_dump` diario. TLS vía el **Caddy central** del VPS (nunca un reverse proxy propio del proyecto); la web publica **solo en `127.0.0.1:$WEB_PORT`**, con el puerto reservado en el registro de bloques de `~/AGENTS.md` del VPS. Si hay SSE, el site file necesita flush sin buffer y sin `encode`. **Resolver AQUÍ el trust boundary** — el rate limit de auth depende de ello: con Cloudflare en proxy naranja hay **dos** proxies delante, así que `x-forwarded-for` trae la IP de **Cloudflare** y la del visitante llega en **`CF-Connecting-IP`**; un rate-limit sobre XFF agrupa a todos los usuarios en un puñado de IPs de borde (castiga a inocentes y el atacante rota de borde). Detalle en la skill `deploy` §Topología. Gotcha conocido: `next start` no resuelve rutas como `next dev` — la verificación debe ejercitar `docker compose up` REAL, no solo dev.
- **Verificación típica**: desde fuera del VPS, `https://<dominio>` sirve la app con certificado válido; login funciona; el recorrido de demo completo corre en el VPS; forzar el backup produce un dump legible por `pg_restore --list`.
- **Depende de**: 11 (o la última pieza visible), 4.

### 14 · Credenciales cifradas + /settings
- **Cuándo**: el usuario debe aportar API keys de terceros en runtime (no como env vars fijas) — típico cuando hay módulo 12.
- **Entrega**: secretos cifrados at-rest (AEAD AES-256-GCM vía `node:crypto`, clave derivada de una master key por scrypt con salt propio), bootstrap desde env en el primer arranque, página `/settings` para editarlos enmascarados (+ apariencia tema/acento/densidad del DS si la fase TD lo dejó preparado).
- **Verificación típica**: guardar una key desde `/settings` → reiniciar Postgres y procesos → la key sigue funcionando; en `psql` el valor almacenado es un blob cifrado; borrar la env var tras el bootstrap no rompe nada.
- **Depende de**: 4 (y 3).

## Grafo resumido

```
1 ─► 2 ─► 3 ─┬► 4 ─┬► 5
             │      ├► 13 ⚠ (también ◄ 11)
             │      └► 14
             ├► 6 ─► 7 ─┬► 8 ─┐
             │           ├► 9 ─┤─► 11 (+ TD.7)
             │           └► 10 ┘
             └► 12
TD (design system) se intercala tras 1: T0.2 depende de TD.7 por orden.
```

La última tarea de F0 es su **E2E de fase**: el recorrido de demo completo sobre TODOS los módulos elegidos, operado desde la UI (y desde el VPS si el 13 entró).
