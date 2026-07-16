# API de `apps/web` — route handlers, SSE, webhooks y auth

Cómo se escribe la capa API del proyecto. La superficie (rutas, verbos, semántica) la define el **PRD** — este documento no la redefine, define CÓMO se implementa cada handler. Sus tests los gobierna la skill `testing` (handler-level con `setDbForTests`, server-level para auth/SSE): todo patrón de aquí existe para que ese harness funcione sin fricción. Las secciones de SSE, webhooks, auth y download aplican **solo si el F0 del proyecto incluye el módulo correspondiente**.

## Tabla de contenidos

1. [Handler fino y HOFs componibles](#1-handler-fino-y-hofs-componibles)
2. [Envelope de errores](#2-envelope-de-errores)
3. [Accessors lazy y composition root](#3-accessors-lazy-y-composition-root)
4. [SSE (solo si módulo SSE)](#4-sse-solo-si-módulo-sse)
5. [Webhooks de proveedores (solo si el proyecto los recibe)](#5-webhooks-de-proveedores-solo-si-el-proyecto-los-recibe)
6. [Auth single-user (solo si módulo auth)](#6-auth-single-user-solo-si-módulo-auth)
7. [Download proxificado (solo si módulo storage)](#7-download-proxificado-solo-si-módulo-storage)
8. [Qué NO va aquí](#8-qué-no-va-aquí)

---

## 1. Handler fino y HOFs componibles

Un route handler hace exactamente cuatro cosas: **parsear → validar → delegar en core → serializar**. Si un `route.ts` contiene lógica de negocio (decidir transiciones, calcular importes, componer resultados), esa lógica está en el paquete equivocado: muévela a `@app/core` — es lo que permite testearla como unit puro y reutilizarla desde el worker (si existe).

La repetición (leer JSON, `safeParse`, mapear errores, exigir sesión) se factoriza en dos HOFs componibles en `apps/web/src/server/`. **`JSON.parse`/`schema.parse` a pelo sobre la ENTRADA (body/params) está prohibido**: siempre `safeParse` vía `withRoute`, porque un body malformado es un 400 tipado, no un 500 con stack trace. La **salida** sí se serializa con `Schema.parse` (un fallo ahí es drift servidor↔contrato — bug nuestro): que acabe en el 500 opaco es correcto; lo que NUNCA debe pasar es que un parse de salida se disfrace de `validation_error` 400.

```ts
// apps/web/src/server/with-route.ts
import { z } from 'zod'
import { AppError } from '@app/core/contracts'
import { toErrorResponse } from './errors'

type Ctx = { params: Promise<Record<string, string>> } // params asíncrono en Next 16

export function withRoute<B = undefined, P = Record<string, string>>(
  handler: (input: { req: Request; body: B; params: P }) => Promise<Response>,
  schemas: { body?: z.ZodType<B>; params?: z.ZodType<P> } = {},
) {
  return async (req: Request, ctx: Ctx): Promise<Response> => {
    try {
      const raw = await ctx.params
      const params = (schemas.params ? parseOrThrow(schemas.params, raw) : raw) as P
      const body = (schemas.body ? parseOrThrow(schemas.body, await readJson(req)) : undefined) as B
      return await handler({ req, body, params })
    } catch (err) {
      return toErrorResponse(err) // TODO error sale por aquí: envelope único, nunca un throw sin formato
    }
  }
}

// export: también lo usan los webhooks (§5), que no pasan por withRoute
export function parseOrThrow<T>(schema: z.ZodType<T>, value: unknown): T {
  const r = schema.safeParse(value)
  if (!r.success) throw new AppError('validation_error', 'payload inválido', z.flattenError(r.error))
  return r.data
}

async function readJson(req: Request): Promise<unknown> {
  try { return await req.json() } catch { throw new AppError('validation_error', 'el body no es JSON') }
}
```

```ts
// apps/web/src/server/with-auth.ts (solo si módulo auth) — defensa en profundidad: el handler
// se protege a sí mismo aunque proxy.ts proteja las páginas (§6). Así el 401 es testeable a nivel handler.
import { AppError } from '@app/core/contracts'
import { requireSession } from './session'
import { toErrorResponse } from './errors'

export function withAuth<A extends unknown[]>(handler: (req: Request, ...rest: A) => Promise<Response>) {
  return async (req: Request, ...rest: A): Promise<Response> => {
    if (!requireSession(req)) return toErrorResponse(new AppError('unauthorized', 'sesión requerida'))
    return handler(req, ...rest)
  }
}
```

Composición canónica — auth por fuera (un 401 no debe ni parsear el body):

```ts
// apps/web/src/app/api/orders/[id]/confirm/route.ts — esquema del patrón
import { z } from 'zod'
import { OrderSchema, UlidSchema } from '@app/core/contracts'
// `withRoute`/`getContext` salen del barrel `@/server`; `withAuth` se importa de su
// path directo `@/server/with-auth` — knip veta reexportar por el barrel un símbolo
// que nadie consume a través de él, y `withAuth` es la única superficie que compone
// por fuera. Es intencional, no drift.
import { withRoute, getContext } from '@/server'
import { withAuth } from '@/server/with-auth'

export const POST = withAuth(withRoute(async ({ params }) => {
  const { orders } = getContext()
  const order = await orders.confirm(params.id) // toda la lógica en core, transaccional
  return Response.json(OrderSchema.parse(order)) // serializar = contrato Zod de core, el mismo que valida el api-client
}, { params: z.object({ id: UlidSchema }) })) // los PKs son ULIDs (db.md §1) — z.uuid() los rechazaría
```

La respuesta siempre se serializa con el schema de `@app/core` que el `api-client` del frontend usa para validar (skill `frontend`): un drift entre lo que devuelve el handler y el contrato revienta en test, no en producción.

## 2. Envelope de errores

El formato `{code, message, details?}` es contrato Zod en core — el frontend hace `switch` sobre `code`; el wording de `message` **nunca** es contrato.

```ts
// packages/core/src/contracts/errors.ts
import { z } from 'zod'

export const ErrorCodeSchema = z.enum(APP_ERROR_CODES)
// La unión canónica (APP_ERROR_CODES) vive junto a AppError en architecture.md §5.
// Unión cerrada: añadir un código es una decisión de contrato, no un string ad hoc.

export const ErrorEnvelopeSchema = z.object({
  code: ErrorCodeSchema,
  message: z.string(),
  details: z.unknown().optional(),   // p. ej. z.flattenError() en validation_error
  request_id: z.string().optional(), // correlación: el mismo id que aparece en los logs pino
})
export type ErrorEnvelope = z.infer<typeof ErrorEnvelopeSchema>
```

La tabla code→status vive en core (`AppError` deriva su `status` de ella — architecture.md §5). El mapeo a `Response` está en UN sitio:

```ts
// apps/web/src/server/errors.ts
import { ZodError, z } from 'zod'
import { AppError, type ErrorEnvelope } from '@app/core/contracts'
import { getRequestId, getRequestLogger } from './request-context' // AsyncLocalStorage — ver observability.md

export function toErrorResponse(err: unknown): Response {
  const request_id = getRequestId() // del header entrante o randomUUID; viaja en logs Y en el envelope
  if (err instanceof AppError) {
    return Response.json(
      { code: err.code, message: err.message, details: err.details, request_id } satisfies ErrorEnvelope,
      { status: err.status },
    )
  }
  if (err instanceof ZodError) {
    // La entrada ya llega convertida a AppError por withRoute (parseOrThrow): un ZodError crudo
    // aquí es drift de SALIDA o de datos internos — bug nuestro, no culpa del cliente. 500 opaco.
    getRequestLogger().error({ err, request_id }, 'zod_contract_drift')
    return Response.json(
      { code: 'internal', message: 'error interno', request_id } satisfies ErrorEnvelope,
      { status: 500 },
    )
  }
  getRequestLogger().error({ err, request_id }, 'unhandled_route_error') // clave err: serializer de pino
  return Response.json( // 500 SIEMPRE opaco: el mensaje interno puede contener rutas, SQL o keys
    { code: 'internal', message: 'error interno', request_id } satisfies ErrorEnvelope,
    { status: 500 },
  )
}
```

## 3. Accessors lazy y composition root

Contrato con la skill `testing`: importar un módulo **jamás** abre una conexión ni lee env — si `route.ts` conectara en module scope, el test no podría redirigirla al test database. El par canónico es `getDb()`/`setDbForTests()` en `apps/web/src/server/db.ts` (la skill `testing` fija su forma exacta — cópiala de ahí tal cual, no la "mejores": los tests dependen de esa forma). Lo que este documento añade es la regla de extensión — mismo molde, mismo nombre de par (`getX`/`setXForTests`), para **toda** dependencia de proceso (pg-boss si hay cola, storage si hay módulo storage):

```ts
// apps/web/src/server/storage.ts (solo si módulo storage) — mismo molde; boss.ts (getBoss/setBossForTests) es idéntico
let override: StorageAdapter | undefined
let fromEnv: StorageAdapter | undefined
export function setStorageForTests(s: StorageAdapter | undefined) { override = s }
export function getStorage(): StorageAdapter {
  return override ?? (fromEnv ??= makeFsStorageAdapter({ root: process.env.ASSETS_ROOT ?? '/data/assets' }))
}
```

`apps/web/src/server/context.ts` es el **composition root** de web: cablea los servicios de core con los adaptadores de db. Se construye **en cada llamada** sobre los accessors — los factories de core son objetos con closures, baratos; memoizar instancias capturaría la BD y rompería `setDbForTests`:

```ts
// apps/web/src/server/context.ts — el wiring canónico está en architecture.md §6; aquí el esqueleto
import { makeOrderService } from '@app/core/orders'
import { makeWithTransaction } from '@app/db'

export function getContext() {
  const deps = { logger: getRequestLogger(), clock: systemClock }
  return { orders: makeOrderService({ withTransaction: makeWithTransaction(getDb()), ...deps }) }
}
```

## 4. SSE (solo si módulo SSE)

Contrato canónico de un endpoint de eventos: `snapshot` al conectar → deltas → `heartbeat`; `id:` monotónico; `Last-Event-ID` ⇒ **re-snapshot** (nunca replay de deltas — el estado actual es la verdad, no la historia). Los tipos de evento son un discriminated union Zod en core (architecture.md §4), el mismo que consume el hook del frontend (skill `frontend`).

```ts
// apps/web/src/app/api/<recurso>/[id]/events/route.ts — esquema del patrón
import { Client } from 'pg'
import { withAuth } from '@/server/with-auth'
import { getDb } from '@/server/db'

export const runtime = 'nodejs'          // streaming + pg: jamás edge
export const dynamic = 'force-dynamic'   // ruta dinámica: la respuesta es un stream vivo, sin caché

export const GET = withAuth(async (req: Request, ctx: { params: Promise<{ id: string }> }) => {
  const { id } = await ctx.params
  const db = getDb()
  const heartbeatMs = Number(process.env.SSE_HEARTBEAT_MS ?? 25_000) // inyectable por env: el test server-level usa valores bajos
  let eventId = Number(req.headers.get('last-event-id') ?? 0) // seed desde Last-Event-ID: ids monotónicos entre reconexiones

  const encoder = new TextEncoder()
  // Conexión pg DEDICADA (connectionString): una conexión en LISTEN no sirve para queries y el pool no debe prestarla
  const listener = new Client({ connectionString: process.env.DATABASE_URL })
  let heartbeat: ReturnType<typeof setInterval> | undefined
  let closed = false

  const stream = new ReadableStream<Uint8Array>({
    async start(controller) {
      const send = (event: string, data: unknown) => {
        if (closed) return
        controller.enqueue(encoder.encode(`id: ${++eventId}\nevent: ${event}\ndata: ${JSON.stringify(data)}\n\n`))
      }
      const close = () => {
        if (closed) return
        closed = true
        clearInterval(heartbeat)
        void listener.end()      // sin esto, cada reconexión filtra una conexión pg hasta agotar Postgres
        controller.close()
      }
      req.signal.addEventListener('abort', close, { once: true }) // Next dispara abort al desconectar el cliente

      // 1) LISTEN ANTES del snapshot: ningún cambio entre la foto y la suscripción se pierde
      await listener.connect()
      listener.on('notification', (msg) => {
        if (msg.payload !== id) return
        // El NOTIFY solo transporta el id: la verdad se RELEE de las tablas, nunca viaja en el payload
        void readChanges(db, id).then((deltas) => { for (const d of deltas) send('changed', d) })
      })
      await listener.query('LISTEN app_events')

      // 2) snapshot SIEMPRE primero — también con Last-Event-ID (re-snapshot con el estado ACTUAL)
      send('snapshot', await readSnapshot(db, id))

      // 3) heartbeat: mantiene vivo el paso por proxies y permite al cliente detectar streams zombis
      heartbeat = setInterval(() => send('heartbeat', { ts: Date.now() }), heartbeatMs)
    },
    cancel() { closed = true; clearInterval(heartbeat); void listener.end() }, // red de seguridad del runtime
  })

  return new Response(stream, {
    headers: {
      'content-type': 'text/event-stream',
      'cache-control': 'no-cache, no-transform', // no-transform: que ningún intermediario comprima/bufferice
      'x-accel-buffering': 'no',
    },
  })
})
```

En producción, si el stream atraviesa un reverse proxy (Caddy/nginx), la ruta SSE necesita desactivar el buffering (p. ej. `flush_interval -1` en Caddy — ver skill `deploy`) o los eventos llegan en ráfagas bufferizadas. Eso solo es observable desplegado — lo cubre la verificación real de la tarea, no la suite.

## 5. Webhooks de proveedores (solo si el proyecto los recibe)

`POST /api/webhooks/<proveedor>`. No lleva `withAuth`: su autenticación ES la firma (HMAC, ED25519… lo que el proveedor use). Reglas duras:

1. **Verificar antes de tocar nada**: cabeceras de firma completas, timestamp dentro de una ventana acotada (los proveedores reintentan durante horas: el rechazo debe ser determinista), firma válida contra la clave/JWKS del proveedor — si es un JWKS remoto, **cacheado en memoria con TTL** (accessor inyectable en tests: 1 fetch para N webhooks).
2. **El handler SOLO persiste el evento y delega en el servicio de core** (idempotencia por el id de request del proveedor: releer estado + UNIQUE sobre `provider_request_id` como red — db.md §8). La mutación de estado es transaccional.
3. **El trabajo pesado (descargas, procesado) SIEMPRE se encola como job del worker** (si el módulo de cola existe; si no, el diseño debe evitar trabajo pesado en el webhook). Un payload puede pesar cientos de MB y el proveedor corta la entrega en segundos: procesar en el route handler garantiza timeouts y reentregas duplicadas.
4. **El builder del mensaje firmado vive en core** y lo comparten verificador y tests — dos implementaciones del layout es la receta para validar una y romper la otra. Que el layout coincida con el proveedor real lo demuestra la verificación real de la tarea, no la suite.

```ts
// apps/web/src/app/api/webhooks/<proveedor>/route.ts — esquema del patrón
export const runtime = 'nodejs'

export const POST = async (req: Request): Promise<Response> => {
  try {
    const body = await req.text() // texto CRUDO: la firma cubre los bytes exactos, no un JSON re-serializado
    const headers = WebhookHeadersSchema.safeParse(Object.fromEntries(req.headers))
    if (!headers.success) throw new AppError('invalid_signature', 'cabeceras de webhook incompletas')

    const valid = await verifyWebhook({ ...headers.data, body }, { getKeys, now: Date.now }) // verificador en core
    if (!valid) throw new AppError('invalid_signature', 'firma o timestamp inválidos') // 401 sin tocar la BD

    let json: unknown
    try { json = JSON.parse(body) } catch { throw new AppError('validation_error', 'el body no es JSON') } // misma regla que readJson (§1)
    const event = parseOrThrow(WebhookPayloadSchema, json)
    await getContext().suModulo.handleWebhookEvent(event) // idempotente: persiste + mutación transaccional + encola lo pesado
    return Response.json({ ok: true })
  } catch (err) {
    return toErrorResponse(err)
  }
}
```

## 6. Auth single-user (solo si módulo auth)

El patrón canónico del template para auth single-user (si tu PRD exige multi-usuario u OAuth, lo define el PRD; estas piezas siguen siendo la referencia de cookies/sesión):

- **Password**: hash scrypt (`node:crypto`, cero dependencias), sembrado desde env solo en el primer arranque. Comparación con `timingSafeEqual` — la comparación de strings filtra timing.
- **Sesión**: cookie con `HttpOnly; Secure; SameSite=Lax; Path=/` y valor `exp.hmac` firmado con clave derivada del secreto maestro del proyecto (una única credencial en env). Stateless: sobrevive a reinicios del contenedor sin tabla de sesiones — single-user no necesita revocación por sesión.
- **`requireSession(req)`** lee la cookie **del propio `Request`** (no de `cookies()` de next/headers): así el 401 es testeable a nivel handler pasando o no el header `cookie`.
- **Rate limit de login**: contador en memoria por IP con ventana deslizante → `AppError('rate_limited')` 429. En memoria del proceso es suficiente con un solo proceso web.
- **`proxy.ts`** (Next 16 — sustituye a `middleware.ts`) protege las **páginas**: sin cookie válida → redirect a `/login`. Hace solo el check barato (presencia + expiración de la cookie); la verificación criptográfica completa la hace `requireSession` en cada handler — por eso `withAuth` no es opcional: es la barrera real de la API, el proxy es UX.
- **Excepciones** (allowlist, nunca denylist): `/login` + `POST /api/login`, `/api/health` (monitores), `/api/webhooks/*` (su auth es la firma, §5).

```ts
// apps/web/src/server/session.ts (esqueleto; createSessionCookie emite el mismo formato exp.hmac)
import { createHmac, timingSafeEqual } from 'node:crypto'

const COOKIE = 'app_session' // fija el nombre en F0 y no lo cambies: invalida todas las sesiones

export function requireSession(req: Request): boolean {
  const value = parseCookieHeader(req.headers.get('cookie'))[COOKIE]
  if (!value) return false
  const [exp, sig] = value.split('.')
  if (!exp || !sig || Number(exp) < Date.now()) return false
  const expected = createHmac('sha256', sessionKey()).update(exp).digest()
  const given = Buffer.from(sig, 'base64url')
  return given.length === expected.length && timingSafeEqual(given, expected)
}
```

## 7. Download proxificado (solo si módulo storage)

`GET /api/assets/:id/download`: la ÚNICA vía de salida de un fichero almacenado. Nunca se expone `storage_key` ni una ruta del filesystem — las URLs con semántica permiten auth, auditoría y migrar el storage a S3/R2 sin romper nada.

```ts
// apps/web/src/app/api/assets/[id]/download/route.ts
export const GET = withAuth(withRoute(async ({ params }) => {
  const asset = await getAssetRepo(getDb()).byId(params.id)
  if (!asset) throw new AppError('not_found', 'asset inexistente')

  const stream = await getStorage().get(asset.storageKey) // ReadableStream<Uint8Array>: JAMÁS buffer completo
  return new Response(stream, {
    headers: {
      'content-type': asset.mime,
      'content-length': String(asset.bytes),          // el cliente ve progreso real de descarga
      'content-disposition': `attachment; filename="${asset.id}.${extensionFor(asset.mime)}"`,
    },
  })
}, { params: z.object({ id: UlidSchema }) }))
```

Reglas: streaming siempre (un fichero puede pesar cientos de MB — bufferizarlo tumba el proceso web); `content-length` desde la fila de BD (la BD es la verdad del tamaño); `withAuth` obligatorio si el módulo auth existe.

**Excepción deliberada al "delegar en core" de §1**: el download llama al repo de lectura y al StorageAdapter directamente — es streaming puro sin ninguna decisión de negocio, y meter un servicio de core en medio solo añadiría un passthrough. Es la ÚNICA ruta con este privilegio; si algún día gana lógica (permisos por asset, transformaciones), se muda a core como todo lo demás.

## 8. Qué NO va aquí

- **Consumo de esta API desde componentes/hooks** (api-client, formularios, hooks de SSE) → skill `frontend`.
- **`AppError`, contratos Zod y fronteras de paquetes en detalle** → `references/architecture.md` (aquí solo su uso desde handlers).
- **Repos, transacciones y el lado SQL** → `references/db.md`; los handlers solo los invocan vía core.
- **Jobs, consumers y el worker** (si el módulo existe) → `references/jobs.md`.
- **Logging, AsyncLocalStorage y `request_id` en detalle** → `references/observability.md`.
- **Reverse proxy, TLS, compose y todo lo de producción** → skill `deploy`.
- **Tests de todo lo anterior** (handler-level, server-level, contrato SSE, firma de webhooks) → skill `testing` — fuente de verdad; este documento solo garantiza que el código sea testeable con sus patrones.
