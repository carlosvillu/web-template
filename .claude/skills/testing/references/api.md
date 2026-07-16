# Testing de API routes contra BD real

Cómo testear la superficie API interna de `apps/web` contra un Postgres real de Testcontainers. Aquí no hay mocks de BD: las mutaciones de la API **son** transacciones sobre Postgres, y mockear la BD sería testear el mock. La mecánica del contenedor, el template database y `createTestDatabase()` están en `db-integration.md`; lo que se ve desde un navegador está en `e2e.md`.

## Tabla de contenidos

1. [Estrategia en dos niveles](#1-estrategia-en-dos-niveles)
2. [Nivel 1 — handler-level](#2-nivel-1--handler-level)
   - 2.1 Requisito de diseño: BD inyectable
   - 2.2 Helper `callRoute`
   - 2.3 Ejemplo: mutaciones transaccionales
   - 2.4 Errores tipados `{code, message, details}`
   - 2.5 Download proxificado *(solo si el módulo storage existe)*
   - 2.6 Webhooks firmados *(solo si un proveedor externo entrega webhooks)*
3. [Nivel 2 — server-level](#3-nivel-2--server-level)
   - 3.1 Arranque del servidor real
   - 3.2 Auth, cookies httpOnly y rate limit *(solo si el módulo auth existe)*
   - 3.3 Contrato SSE *(solo si el módulo SSE existe)*
4. [Qué NO se testea aquí](#4-qué-no-se-testea-aquí)

---

## 1. Estrategia en dos niveles

| | Nivel 1 · handler-level | Nivel 2 · server-level |
|---|---|---|
| Qué se ejecuta | El route handler exportado (`GET`/`POST` de `route.ts`), invocado en el proceso del test con `new Request()` | Un servidor Next real (`next start`) en otro proceso, atacado con `fetch` |
| BD | `createTestDatabase()` inyectada | `DATABASE_URL` del test database pasada al proceso del servidor |
| Middleware de Next | **NO se ejecuta** | Sí (auth completo, cookies, redirects) |
| msw | Funciona (mismo proceso) | **No intercepta** (otro proceso) — evita endpoints que llamen fuera, o apunta el server a `startFakeExternalApis()` (`@app/test-utils/fake-apis`) vía env |
| Velocidad | ms por test | segundos de arranque por suite (+ `next build` previo) |
| Ubicación | `apps/web/test/integration/api/**/*.test.ts` | `apps/web/test/integration/server/**/*.test.ts` |

**El nivel 1 es el default.** Cubre CRUD, todas las mutaciones transaccionales, webhooks y contratos de download. Es rápido, depurable y el fallo señala directamente al handler. Usa el nivel 2 **solo** para lo que el nivel 1 no puede reproducir con fidelidad: el middleware de auth completo, atributos reales de cookies httpOnly, rate limits y el streaming SSE — donde el valor está precisamente en que la respuesta atraviese el runtime HTTP real de Next sin buffering.

Ambos niveles corren bajo `pnpm test:integration` (necesitan el testcontainer). Nada de esto gasta dinero: las APIs externas van con msw + fixtures de `packages/test-utils/fixtures/http/`; los webhooks usan claves generadas en el test.

## 2. Nivel 1 — handler-level

### 2.1 Requisito de diseño: BD inyectable

Importar `route.ts` ejecuta su module scope. Si el handler creara la conexión al importarse (leyendo env en top-level), el test no podría redirigirla al test database. Regla: **ninguna conexión en module scope**; los handlers obtienen la BD de un accessor lazy con override para tests.

```ts
// apps/web/src/server/db.ts
import { createDb, type Db } from '@app/db'

let override: Db | undefined
let fromEnv: Db | undefined

/** Solo para tests. En producción nunca se llama. */
export function setDbForTests(db: Db | undefined) { override = db }

export function getDb(): Db {
  if (override) return override
  fromEnv ??= createDb(process.env.DATABASE_URL!)
  return fromEnv
}
```

El mismo criterio aplica a cualquier dependencia de proceso (StorageAdapter con su directorio raíz por env, cliente pg-boss): lazy + override. El camino de producción no cambia (primera llamada crea desde env); el de test es explícito.

### 2.2 Helper `callRoute`

En App Router el handler recibe `(request, ctx)` donde `ctx.params` es asíncrono en las versiones actuales de Next. Centraliza esa forma en UN helper: si Next cambia la firma, se toca un solo fichero.

```ts
// apps/web/test/helpers/call-route.ts
type Handler = (req: Request, ctx: { params: Promise<Record<string, string>> }) => Promise<Response>

export async function callRoute(
  handler: Handler,
  path: string,
  { params = {}, json, ...init }: RequestInit & { params?: Record<string, string>; json?: unknown } = {},
): Promise<Response> {
  const req = new Request(`http://test.local${path}`, {
    ...init,
    ...(json !== undefined && {
      body: JSON.stringify(json),
      headers: { 'content-type': 'application/json', ...init.headers },
    }),
  })
  return handler(req, { params: Promise.resolve(params) })
}
```

`new Request()` estándar basta casi siempre (`NextRequest` lo extiende); si un handler usa helpers de cookies de `NextRequest`, construye un `NextRequest` en ese test concreto. **Ojo (principio 9 de SKILL.md)**: un `Request` construido a mano **no lleva `content-length`** — lo pone la capa de fetch al enviar. Si el handler tiene lógica sobre ese header (límite de tamaño), un test handler-level solo ejercita la rama sin header; cubre la rama real a nivel 2 o con un `fetch` real.

### 2.3 Ejemplo: mutaciones transaccionales

El patrón es siempre el mismo: **sembrar el estado con factories → llamar al handler → assertar la respuesta Y las filas**. El contrato real de estas rutas es el efecto transaccional en la BD, no el 200.

```ts
// apps/web/test/integration/api/steps-approve.test.ts
import { beforeAll, afterAll, expect, test } from 'vitest'
import { eq, sql } from 'drizzle-orm'
import { stepRun } from '@app/db/schema'
import { createTestDatabase, insertRun, insertStep } from '@app/test-utils'
import { setDbForTests } from '@/server/db'
import { POST as approve } from '@/app/api/steps/[id]/approve/route'
import { callRoute } from '../../helpers/call-route'
import { expectApiError } from '../../helpers/expect-api-error'

let ctx: Awaited<ReturnType<typeof createTestDatabase>>
beforeAll(async () => { ctx = await createTestDatabase(); setDbForTests(ctx.db) })
afterAll(async () => { setDbForTests(undefined); await ctx.close() })

const getStep = (id: string) =>
  ctx.db.select().from(stepRun).where(eq(stepRun.id, id)).then(r => r[0])

test('approve: waiting_approval → succeeded, desbloquea deps y encola', async () => {
  const run = await insertRun(ctx.db)
  const cp = await insertStep(ctx.db, { runId: run.id, status: 'waiting_approval' })
  const next = await insertStep(ctx.db, { runId: run.id, status: 'awaiting_deps', dependsOn: [cp.id] })

  const res = await callRoute(approve, `/api/steps/${cp.id}/approve`, { method: 'POST', params: { id: cp.id } })

  expect(res.status).toBe(200)
  expect((await getStep(cp.id)).status).toBe('succeeded')
  expect((await getStep(next.id)).status).toBe('queued')
  // Si hay pg-boss: el encolado ocurre en la MISMA transacción que la transición (queued ⇔ hay job).
  const jobs = await ctx.db.execute(sql`select 1 from pgboss.job where data->>'stepId' = ${next.id}`)
  expect(jobs.rows).toHaveLength(1)
})

test('approve sobre un estado que no lo admite: 409 tipado sin tocar la BD', async () => {
  const run = await insertRun(ctx.db)
  const step = await insertStep(ctx.db, { runId: run.id, status: 'running' })
  const res = await callRoute(approve, `/api/steps/${step.id}/approve`, { method: 'POST', params: { id: step.id } })
  await expectApiError(res, 409, 'invalid_transition')
  expect((await getStep(step.id)).status).toBe('running')
})
```

Con el mismo molde: cualquier mutación asserta el efecto completo en filas (una edición con `supersedes_id` asserta la fila nueva Y que la vieja no se resetea; un retry asserta el contador y el re-encolado). Que pg-boss tenga su schema en el test database es responsabilidad del template (ver `db-integration.md`).

### 2.4 Errores tipados `{code, message, details}`

El formato de error es superficie de API: la UI hace `switch` sobre `code`. Asserta **status + code + presencia de message**, jamás el texto (el wording cambia sin ser breaking change).

```ts
// apps/web/test/helpers/expect-api-error.ts
import { expect } from 'vitest'

export async function expectApiError(res: Response, status: number, code: string) {
  expect(res.status).toBe(status)
  const body = await res.json()
  expect(body).toMatchObject({ code, message: expect.any(String) })
  return body // para assertar details cuando aporte (p. ej. issues de Zod)
}
```

Mínimos por ruta nueva: body inválido → `400` `validation_error` con `details` derivado de Zod; recurso inexistente → `404` `not_found`; estado que no admite la acción → `409`. Estos tres casos son baratos a nivel 1 y son exactamente lo que la UI necesita para mostrar errores accionables.

### 2.5 Download proxificado

> **Solo si el módulo storage existe en tu F0.**

El contrato: streaming byte-exacto (checksum), headers correctos y nunca exponer la ruta cruda de storage.

```ts
import { createHash, randomBytes } from 'node:crypto'
import { GET as download } from '@/app/api/assets/[id]/download/route'

test('descarga con checksum idéntico al asset', async () => {
  const bytes = randomBytes(1024 * 1024)
  const asset = await seedAssetFile(ctx, { bytes })   // escribe vía StorageAdapter (dir temporal) + fila en asset

  const res = await callRoute(download, `/api/assets/${asset.id}/download`, { params: { id: asset.id } })

  expect(res.status).toBe(200)
  const body = Buffer.from(await res.arrayBuffer())
  expect(createHash('sha256').update(body).digest('hex')).toBe(asset.checksum)
  expect(res.headers.get('content-length')).toBe(String(asset.bytes))
})
```

El **401 sin sesión** (si hay auth) depende de dónde viva el check: el middleware NO corre a nivel 1. Recomendado (defensa en profundidad): el handler valida sesión él mismo con un `requireSession(req)` que lee la cookie del `Request` — entonces el 401 se testea a nivel 1 pasando (o no) el header `cookie`. El paso por el middleware real se cubre una vez, a nivel 2 (§3.2); no dupliques cada caso en ambos niveles.

### 2.6 Webhooks firmados

> **Solo si un proveedor externo entrega webhooks firmados a tu app.**

No necesitas al proveedor para testear el verificador: genera un par de claves de test y sirve su JWKS (o secreto) con msw. Regla de oro: el test **firma con el mismo builder de mensaje que usa el verificador de producción** (`@app/core`) — no reimplementes el layout del mensaje en el test o acabarás validando dos implementaciones distintas. Que el layout coincida con el del proveedor real lo demuestra la verificación de la tarea (webhook real), no esta suite.

```ts
// packages/test-utils/src/webhook.ts
import { generateKeyPairSync, sign } from 'node:crypto'
import { buildWebhookMessage } from '@app/core' // el MISMO que usa el verificador

export function makeWebhookKeypair() {
  const { publicKey, privateKey } = generateKeyPairSync('ed25519')
  return { privateKey, jwk: publicKey.export({ format: 'jwk' }) }
}

export function signWebhook(privateKey: any, p: { requestId: string; timestamp: number; body: string }) {
  const message = buildWebhookMessage(p)
  return {
    'x-webhook-request-id': p.requestId,
    'x-webhook-timestamp': String(p.timestamp),
    'x-webhook-signature': sign(null, message, privateKey).toString('hex'),
  }
}
```

Casos obligatorios de la suite del handler:

- **Firma válida**: persiste el evento, delega el efecto en el código de producción, y cualquier trabajo pesado derivado (descarga de outputs) se encola como job — NUNCA se hace en el handler.
- **Firma forjada** (otra clave criptográficamente válida pero NO en el JWKS): 401 tipado y **la BD queda intacta** (snapshot de counts antes/después).
- **Replay del mismo `request_id`**: idempotente — 200 ambas veces, sin duplicar nada; la unique constraint en BD es la red de seguridad, el handler el primer filtro.
- **Timestamp fuera de ventana (±5 min)**: rechazado sin tocar la BD, de forma determinista (los proveedores reintentan; el rechazo no puede depender de estado).
- **Caché del JWKS**: un contador en el handler de msw debe registrar 1 sola petición tras N webhooks.

## 3. Nivel 2 — server-level

### 3.1 Arranque del servidor real

Un servidor por suite (fichero de test), con su propio database del template: aislamiento total y compatible con la paralelización de Vitest. Requiere `next build` previo (el script `test:integration` de `apps/web` lo garantiza; en CI se construye una vez). Mantén POCAS suites de nivel 2 — es la razón de que el nivel 1 sea el default.

```ts
// apps/web/test/helpers/server.ts
import { spawn } from 'node:child_process'

export async function startWebServer(env: Record<string, string>) {
  const port = 3100 + Math.floor(Math.random() * 500)
  const proc = spawn('pnpm', ['--filter', '@app/web', 'exec', 'next', 'start', '-p', String(port)], {
    env: { ...process.env, SSE_HEARTBEAT_MS: '250', ...env }, // intervalos inyectables por env (ver 3.3)
    stdio: 'pipe',
  })
  await waitFor(async () => (await fetch(`http://127.0.0.1:${port}/api/health`)).ok, { timeoutMs: 30_000 })
  return { baseUrl: `http://127.0.0.1:${port}`, stop: () => proc.kill('SIGTERM') }
}
```

```ts
const ctx = await createTestDatabase()
const server = await startWebServer({ DATABASE_URL: ctx.connectionString })
// El test siembra y muta por ctx.db; el servidor ve los mismos datos: es el MISMO Postgres.
```

### 3.2 Auth, cookies httpOnly y rate limit

> **Solo si el módulo auth existe en tu F0.**

```ts
test('API sin sesión → 401; login deja cookie httpOnly que abre el paso', async () => {
  expect((await fetch(`${server.baseUrl}/api/items`, { method: 'POST' })).status).toBe(401)

  const res = await fetch(`${server.baseUrl}/api/login`, {
    method: 'POST', headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ password: TEST_PASSWORD }),
  })
  const setCookie = res.headers.get('set-cookie')!
  expect(setCookie).toMatch(/httponly/i) // el atributo se asserta parseando el header:
  // que el navegador lo respete no es nuestro test (eso es E2E)

  const cookie = setCookie.split(';')[0]
  expect((await fetch(`${server.baseUrl}/api/items/${id}`, { headers: { cookie } })).status).toBe(200)
})

test('rate limit de login: N fallos → 429 tipado', async () => {
  let last: Response
  for (let i = 0; i < 6; i++) last = await postLogin(server.baseUrl, 'wrong-password')
  await expectApiError(last!, 429, 'rate_limited')
})
```

El estado del rate limiter vive en el proceso del servidor: por eso cada suite arranca servidor propio (sin orden entre tests que se contaminan). El redirect a `/login` de las páginas HTML y el flujo visual de login pertenecen a `e2e.md`.

### 3.3 Contrato SSE

> **Solo si el módulo SSE existe en tu F0.**

Se testea con `fetch` streaming + `AbortController` — no con `EventSource` (en Node no permite header `cookie` y su auto-reconexión esconde justo lo que queremos assertar). Dos reglas de diseño que este test impone al producto: (a) el **intervalo de heartbeat es inyectable por env** (`SSE_HEARTBEAT_MS`) — no hay fake timers a través de procesos y esperar 25 s reales es inaceptable; (b) el delta se provoca con una **mutación real** vía el código de `@app/core` contra el mismo Postgres — así el test cubre el camino completo `mutación → NOTIFY → LISTEN → frame SSE` cruzando procesos.

```ts
// apps/web/test/helpers/sse.ts
export type SseEvent = { id?: string; event: string; data: any }

export async function collectSse(url: string, opts: {
  headers?: Record<string, string>
  onEvent?: (e: SseEvent) => void
  until: (events: SseEvent[]) => boolean
  timeoutMs?: number
}): Promise<SseEvent[]> {
  const ac = new AbortController()
  const timer = setTimeout(() => ac.abort(), opts.timeoutMs ?? 10_000)
  const events: SseEvent[] = []
  try {
    const res = await fetch(url, { headers: { accept: 'text/event-stream', ...opts.headers }, signal: ac.signal })
    if (!res.headers.get('content-type')?.includes('text/event-stream')) throw new Error('no es un stream SSE')
    const decoder = new TextDecoder()
    let buf = ''
    for await (const chunk of res.body! as any) {
      buf += decoder.decode(chunk, { stream: true })
      let sep: number
      while ((sep = buf.indexOf('\n\n')) !== -1) {
        const ev = parseSseFrame(buf.slice(0, sep)) // líneas id:/event:/data: → JSON.parse(data)
        buf = buf.slice(sep + 2)
        events.push(ev); opts.onEvent?.(ev)
      }
      if (opts.until(events)) { ac.abort(); break }
    }
  } catch (err) { if (!ac.signal.aborted) throw err } // el abort propio no es un fallo
  finally { clearTimeout(timer) }
  return events
}
```

```ts
// apps/web/test/integration/server/sse-contract.test.ts
test('snapshot al conectar → delta por mutación real → heartbeat → reconexión con Last-Event-ID', async () => {
  const seeded = await seedLiveEntity(ctx.db)
  const url = `${server.baseUrl}/api/…/events`

  // Conectar; disparar la mutación SOLO tras recibir el snapshot (evita la carrera conexión/NOTIFY)
  const events = await collectSse(url, {
    headers: { cookie },
    onEvent: e => { if (e.event === 'snapshot') void mutateEntity(seeded.id, { db: ctx.db }) },
    until: evs => evs.some(e => e.event === 'changed') && evs.some(e => e.event === 'heartbeat'),
  })

  expect(events[0].event).toBe('snapshot')                    // SIEMPRE lo primero al conectar
  const ids = events.map(e => Number(e.id))
  expect([...ids].sort((a, b) => a - b)).toEqual(ids)         // id: monotónico

  // Reconexión: Last-Event-ID → re-snapshot que refleja el estado ACTUAL (no repite deltas perdidos)
  const again = await collectSse(url, {
    headers: { cookie, 'last-event-id': String(ids.at(-1)) },
    until: evs => evs.length >= 1,
  })
  expect(again[0].event).toBe('snapshot')
})
```

El heartbeat se asserta implícitamente en el `until` (con `SSE_HEARTBEAT_MS=250` llega en <1 s). Si el stream se cuelga sin heartbeats, el `timeoutMs` del helper falla el test: eso ES el bug que el heartbeat existe para detectar.

## 4. Qué NO se testea aquí

- **Todo lo que implica un navegador** → `e2e.md` (Playwright en `apps/web/e2e/`): UI en vivo, redirect visual a login, que el navegador respete `httpOnly`, la auto-reconexión de `EventSource`, descargas por click.
- **SSE a través del reverse proxy** (Caddy/nginx con su config de buffering): solo observable en despliegue real; se cubre en el gate CUA de la tarea de deploy con evidencia en `docs/verifications/<TASK-ID>/`.
- **Que el proveedor firme como asumimos**: la suite valida nuestro verificador contra nuestro builder; el emparejamiento con el mundo real lo prueba la verificación de tarea (webhook real) y, si hiciera falta repetirlo, un `*.live.test.ts` opt-in.
- **UI de las páginas** que consumen estas APIs: aquí solo el contrato HTTP; la integración visual es de `e2e.md`.
