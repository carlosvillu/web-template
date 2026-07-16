# Observabilidad: logging estructurado y correlación (pino)

Cómo se loguea en el proyecto: un único factory pino compartido en `@app/core/observability`, correlación (`request_id` siempre; `job_id` y los ids de tu dominio donde apliquen) en todo log desde F0, redaction declarativa de secretos y errores persistidos en BD cuando la UI los tiene que mostrar. Los tests del logging (nivel `silent`, override por env) los gobierna la skill `testing`.

## Tabla de contenidos

1. [Principio: los logs correlacionados deben bastar](#1-principio-los-logs-correlacionados-deben-bastar)
2. [Factory compartido en `@app/core/observability`](#2-factory-compartido-en-appcoreobservability)
3. [Correlación: child loggers por job y por request](#3-correlación-child-loggers-por-job-y-por-request)
4. [Redaction declarativa en el logger base](#4-redaction-declarativa-en-el-logger-base)
5. [Serializers](#5-serializers)
6. [Errores persistidos para la UI](#6-errores-persistidos-para-la-ui)
7. [Niveles y alertas operativas](#7-niveles-y-alertas-operativas)
8. [Qué NO va aquí](#8-qué-no-va-aquí)

---

## 1. Principio: los logs correlacionados deben bastar

Desde F0: **todo log es JSON estructurado (pino) con correlación**. La vara de calidad es operativa, no estética: cuando algo falla en producción, filtrar los logs por `request_id` (o por el id del agregado de tu dominio) más lo persistido en BD deben bastar para diagnosticarlo — sin SSH al servidor, sin grep de texto libre. Cada regla de este documento existe para sostener esa vara:

- **Estructurado siempre**: un log sin campos no es filtrable. `log.info({ order_id }, 'msg')`, jamás interpolar IDs en el string.
- **Correlación por child, no a mano**: los IDs se fijan UNA vez en un `logger.child()` en la frontera (request, job handler) y viajan implícitos; repetirlos a mano en cada línea garantiza que algún día falten.
- **Secretos redactados de forma declarativa** en el base (§4): la seguridad no depende de la disciplina de cada call site.

## 2. Factory compartido en `@app/core/observability`

El **puerto `Logger`** (lo que consume todo el resto del código) se define en `packages/core/src/ports.ts` junto a Clock — la definición canónica y su forma exacta viven en `references/architecture.md` §2. `packages/core/src/observability/` lo re-exporta y aporta lo demás: **`makeLogger(opts)`** (el factory pino que instancian los composition roots), `REDACT_PATHS`, los serializers y `sanitizeCausedBy`. Es **la excepción documentada** a "core sin I/O": el proyecto necesita UN logger compartido con serializers y redaction, y duplicarlo por app garantiza drift de redaction — el riesgo que no aceptamos. La frontera se mantiene estricta: **solo `observability/` importa pino**; cualquier otro módulo de core, db o apps consume el puerto.

```ts
// packages/core/src/observability/logger.ts
import pino from 'pino'
import type { Logger } from '../ports' // puerto canónico (architecture.md §2); aquí solo se implementa

export type { Logger }

export interface MakeLoggerOptions {
  name: 'web' | 'worker'   // 'worker' solo si el módulo existe
  level: string            // el composition root pasa process.env.LOG_LEVEL ?? 'info'
  pretty?: boolean         // SOLO dev: pino-pretty es transport de desarrollo, jamás en prod
}

export function makeLogger(opts: MakeLoggerOptions): Logger {
  return pino({
    name: opts.name,
    level: opts.level,
    redact: { paths: REDACT_PATHS, censor: '[REDACTED]' },   // §4
    serializers: { err: pino.stdSerializers.err, /* …los de dominio, §5 */ },
    transport: opts.pretty ? { target: 'pino-pretty', options: { colorize: true } } : undefined,
  })
}
```

Reglas:

- **El factory se invoca en el composition root** (`apps/web/src/server/logger.ts` vía accessor lazy; `apps/worker/src/bootstrap.ts` si existe), una vez por proceso. Importar el módulo no crea logger ni lee env (principio 5 de la skill: nada en module scope).
- **Nivel por env**: el root pasa `level: process.env.LOG_LEVEL ?? 'info'`. En tests `LOG_LEVEL=silent` — lo fija el `.env.test` según la skill `testing`; no lo re-decidas aquí.
- **`pretty` solo en dev** (`NODE_ENV === 'development'`): en producción el stdout JSON lo recoge Docker tal cual; pino-pretty en prod rompe el parseo estructurado.

## 3. Correlación: child loggers por job y por request

### 3.1 Worker: child por job, inyectado por deps (solo si módulo cola)

Al entrar en cada handler de pg-boss se crea UN child con `{queue, job_id, …ids del dominio}` y se pasa a los servicios **por deps** (los servicios de core son factories `makeXxxService(deps)` — ver `references/architecture.md`). Nada de loggers globales dentro de servicios: el mismo servicio corre para mil jobs y cada uno debe loguear su correlación.

```ts
// apps/worker/src/consumers/<job>.ts (fragmento — el consumer completo vive en jobs.md §4)
await boss.work(reportBuildJob.name, { batchSize: 1 }, async ([job]) => {
  const { report_id } = ReportBuildJobSchema.parse(job.data)
  const log = rootLogger.child({ queue: reportBuildJob.name, job_id: job.id, report_id })
  log.info('job started')
  await handler({ db, log, signal: job.signal })   // todo log interno sale ya correlacionado
  log.info('job finished')
})
```

### 3.2 Web: child por request + AsyncLocalStorage

En `apps/web`, el wrapper de rutas (`withRoute`, ver `references/api.md`) crea un child con `request_id` (header `x-request-id` entrante si existe — permite correlacionar con un proxy/cliente —, `crypto.randomUUID()` si no) y lo guarda en `AsyncLocalStorage`. Así **cualquier capa** (repo, servicio, accessor) loguea correlacionado sin prop drilling del logger a través de firmas que no lo necesitan.

```ts
// apps/web/src/server/request-context.ts
import { AsyncLocalStorage } from 'node:async_hooks'
import type { Logger } from '@app/core/observability'

interface RequestContext { log: Logger; requestId: string }
const als = new AsyncLocalStorage<RequestContext>()

export const runWithRequestContext = <T>(ctx: RequestContext, fn: () => T): T => als.run(ctx, fn)
export const getRequestLogger = (): Logger => als.getStore()?.log ?? getRootLogger()
export const getRequestId = (): string | undefined => als.getStore()?.requestId
```

`getRootLogger()` es el accessor lazy del logger base de web (`apps/web/src/server/logger.ts`): memoiza `makeLogger({ name: 'web', level: process.env.LOG_LEVEL ?? 'info' })` en el primer uso — mismo principio que `getDb()` (nada en module scope; `references/api.md` §3).

```ts
// dentro de withRoute (esqueleto — el wrapper completo vive en references/api.md)
const requestId = request.headers.get('x-request-id') ?? crypto.randomUUID()
const log = getRootLogger().child({ request_id: requestId, route: '/api/orders/[id]/confirm' })
return runWithRequestContext({ log, requestId }, async () => {
  // ... parse → auth → delegar en core → serializar
})
```

**El `request_id` se devuelve en el envelope de error** (`{code, message, details?, request_id}` — el contrato exacto lo define `references/api.md`): es el cruce cliente↔servidor. Cuando el frontend muestra "algo falló", el usuario copia el `request_id` y un filtro sobre los logs reconstruye la request completa. Los servicios de core siguen recibiendo `log` por deps (el composition root de web les pasa `getRequestLogger()`); el ALS es el mecanismo de web, no un patrón que core conozca.

## 4. Redaction declarativa en el logger base

La redaction vive en `REDACT_PATHS`, en el factory, **NUNCA ad hoc** en call sites (borrar campos a mano antes de loguear es el patrón que falla en el call site nuevo). Regla operativa: **si un secreto puede aparecer en un payload logueado, su path se añade aquí ANTES de escribir el log que lo incluye** — en el mismo commit. Al integrar un proveedor nuevo, su key entra en esta lista en la misma tarea.

```ts
// packages/core/src/observability/redact.ts
export const REDACT_PATHS = [
  // headers y credenciales de sesión
  'authorization', '*.authorization',
  'cookie', '*.cookie', 'set-cookie', '*["set-cookie"]',
  // claves de API en objetos de config / payloads
  '*.apiKey', '*.api_key', '*.token', '*.password', '*.secret',
  // las env keys de TUS proveedores, por nombre — p. ej.:
  // 'STRIPE_SECRET_KEY', '*.STRIPE_SECRET_KEY',
  // 'ANTHROPIC_API_KEY', '*.ANTHROPIC_API_KEY',
]
// censor: '[REDACTED]' — se configura en makeLogger (§2)
```

Gotcha verificado (fast-redact, el motor de pino): el wildcard `*` cubre **un nivel de anidamiento**, no recursión profunda — `*.apiKey` redacta `{ mail: { apiKey } }` pero no `{ a: { b: { apiKey } } }`. Si logueas un objeto profundo con secreto anidado, añade su path explícito… o mejor, no loguees ese objeto entero (§5). La redaction de pino **solo cubre logs**: lo que se persiste en BD (§6) se sanitiza aparte.

## 5. Serializers

Tres reglas:

1. **`err: pino.stdSerializers.err` SIEMPRE, y la clave DEBE llamarse `err`**: `log.error({ err }, 'provider call failed')`. El serializer solo se aplica a esa clave; `log.error({ error })` o `log.error(err)` pierden stack, `cause` y `type` en el JSON — el diagnóstico se queda ciego.
2. **Serializers de dominio para objetos ruidosos**: una fila entera con columnas jsonb en un log son KBs que entierran la señal. Se loguea la proyección mínima (id + status) y, si necesitas más, campos explícitos.

```ts
// packages/core/src/observability/serializers.ts — esquema del patrón con las entidades de TU dominio
export const orderSerializer = (o: Order) => ({ id: o.id, status: o.status })
// uso: log.info({ order }, 'state changed') — pino aplica el serializer por clave
```

3. **No se loguean bodies de request por defecto** (ni prompts completos, ni payloads de webhook enteros): son grandes, pueden contener secretos que ningún wildcard cubre y el dato canónico ya está en BD. En `debug` se loguean extractos redactados y tamaños (`{ body_bytes, keys }`), no el contenido.

## 6. Errores persistidos para la UI

Cuando un trabajo en background falla y la UI debe mostrarlo (solo aplica si tu proyecto tiene worker/pipeline con estados visibles), loguear no basta: **el handler persiste en la fila del agregado (columna `error` jsonb) un objeto estructurado** que la UI muestra como "caused by". El log es para el operador con contexto; la columna es lo que ve el usuario.

```ts
// packages/core/src/contracts/work-error.ts
export const WorkErrorSchema = z.object({
  message: z.string(),              // humano, accionable: 'el proveedor devolvió FAILED tras 3 reintentos'
  code: z.string(),                 // estable, para lógica: 'provider_failed' | 'timeout' | ...
  caused_by: z.unknown().optional() // payload del proveedor RECORTADO y sanitizado
})
export type WorkError = z.infer<typeof WorkErrorSchema>
```

```ts
// patrón en el handler (apps/worker) — la mutación transaccional lo persiste, el log lo cuenta
const workError: WorkError = {
  message: 'el proveedor devolvió estado FAILED',
  code: 'provider_failed',
  caused_by: sanitizeCausedBy(providerPayload),  // recorta (~2 KB) y elimina claves/URLs firmadas
}
log.error({ err, work_error_code: workError.code }, 'work failed')
await services.markFailed(entityId, workError)   // misma tx que el cambio de estado
```

`sanitizeCausedBy()` (helper en `observability/`) recorta el payload a un tamaño acotado y elimina secretos: la redaction del logger (§4) NO aplica a lo que se escribe en BD, y la columna `error` viaja al navegador vía la API. Ambas escrituras usan el mismo child correlacionado: el log y la fila cuentan la misma historia con el mismo id.

## 7. Niveles y alertas operativas

| Nivel | Cuándo | Ejemplos |
|---|---|---|
| `error` | Requiere acción humana u operativa | Trabajo agotó sus reintentos; webhook con firma inválida; migración fallida |
| `warn` | Degradación tolerada por diseño — el sistema siguió | Fallback a un proveedor secundario; retry programado tras fallo transitorio; SSE reconectado |
| `info` | Transiciones e hitos: la narrativa del sistema | `state changed`; `job started/finished`; proceso ready |
| `debug` | Detalle para depurar, redactado y acotado | Extractos de payloads (§5.3); decisión del rate limiter; timings internos |

Criterio rápido: si nadie debe hacer nada, no es `error`; si el sistema no se degradó, no es `warn`.

**Alertas operativas** (trabajo colgado > timeout, webhook con firma inválida, presupuesto superado si hay spend ledger…) se emiten como **log `error` + fila en BD** en el mismo punto de detección. El porqué: paneles y notificaciones in-app leen **tablas, no logs** — un log no es consultable por la UI ni sobrevive a la rotación. Mismo criterio para métricas internas (duraciones, tasas de fallo, costes): se derivan de las tablas, que ya contienen timestamps; los logs diagnostican, las tablas miden.

## 8. Qué NO va aquí

- **Métricas de negocio y paneles**: los define el PRD; este documento solo fija que sus fuentes son tablas, no logs.
- **Coste** (solo si módulo spend ledger): toda llamada facturable se registra en el ledger; loguear el coste está bien como traza, pero el log jamás es la fuente contable.
- **El envelope de error de la API** y el wrapper `withRoute`: `references/api.md` (aquí solo su relación con `request_id`).
- **Retries, DLQ y timeouts de jobs**: `references/jobs.md`; aquí solo cómo se loguean.
- **Testing**: `LOG_LEVEL=silent` y el `.env.test` los gobierna la skill `testing`.
