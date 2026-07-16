# pg-boss: jobs tipados, consumers, cron y shutdown

> **Este reference SOLO aplica si el F0 del proyecto incluye el módulo de cola (pg-boss + `apps/worker`).** Si tu planning no tiene worker ni jobs en background, no lo leas: nada de aquí te concierne todavía. Si el módulo se añade más adelante, este documento es la fuente desde el primer job.
>
> Capa: `packages/core/src/jobs` (registro) + `packages/db` (adaptador JobQueue) + `apps/worker` (consumers/handlers).
>
> No existe skill externa de pg-boss: **este documento es la fuente**. Las APIs citadas están verificadas contra `docs/api/` de https://github.com/timgit/pg-boss y contra el paquete publicado (v12.x). **Versión mínima: ≥12.21** (`fromDrizzle` llegó en 12.20, `perJobResults` en 12.21; `redrive()` exige ≥12.23) — el catálogo fija `^12` (tooling.md §6). Ante cualquier duda nueva, verifica ahí o vía Context7 antes de asumir — pg-boss cambia semántica entre majors.

**Contenido**: [Principio](#1-principio-pg-boss-despacha-la-verdad-vive-en-nuestras-tablas) · [Jobs tipados](#2-jobs-tipados-registro-definejob-en-packagescoresrcjobs) · [Colas](#3-colas-createqueue-explícito-en-el-bootstrap) · [Consumers](#4-consumers) · [Encolado transaccional](#5-encolado-transaccional) · [Idempotencia](#6-idempotencia-del-handler) · [Retries y tiempos](#7-retries-y-tiempos) · [Cron](#8-cron) · [Shutdown](#9-graceful-shutdown) · [Qué NO va aquí](#10-qué-no-va-aquí)

## 1. Principio: pg-boss despacha, la verdad vive en nuestras tablas

pg-boss es SOLO el mecanismo de ejecución (despacho, retries, backoff, cron). El estado canónico del dominio vive en **nuestras** tablas, y toda mutación de estado pasa por los servicios transaccionales de core (y por `transition()` del orquestador, si tu proyecto tiene uno) — ningún handler cambia un status por su cuenta, porque dos fuentes de verdad divergen en el primer crash. Nunca leas `pgboss.job` para decidir negocio (retry counts, "¿está corriendo?"): esa tabla es un detalle de implementación del despacho.

Consecuencia innegociable: pg-boss es **at-least-once** (crashes, expiraciones y heartbeats perdidos re-entregan el mismo job) → TODO handler es idempotente por diseño (§6). Si un handler no soporta ejecutarse dos veces, está mal escrito, no "pendiente de pulir".

## 2. Jobs tipados: registro `defineJob` en `packages/core/src/jobs/`

El registro **declara** (nombre de cola, schema Zod del payload, opciones); los **handlers viven en `apps/worker`**. Core jamás importa pg-boss — la frontera prohibida de core es BD/cola (SKILL.md, principio 1).

```ts
// packages/core/src/jobs/registry.ts
import type { z } from 'zod'

export interface JobDefinition<TSchema extends z.ZodType = z.ZodType> {
  name: string                    // nombre de la cola: '<dominio>.<acción>'
  payload: TSchema
  options: {                      // config de cola (createQueue); cada job la hereda
    policy: 'standard' | 'short' | 'singleton'
    retryLimit: number
    retryDelay?: number           // segundos
    retryBackoff?: boolean
    retryDelayMax?: number        // segundos; solo aplica con retryBackoff
    expireInSeconds?: number
    heartbeatSeconds?: number
  }
}

export function defineJob<T extends z.ZodType>(def: JobDefinition<T>): JobDefinition<T> {
  return def
}

/** Lo que viaja por el puerto JobQueue (architecture.md §2): job + payload sin validar + opciones. */
export interface EnqueueRequest<T extends z.ZodType = z.ZodType> {
  job: JobDefinition<T>
  payload: z.infer<T>
  singletonKey?: string
  startAfter?: Date
}
```

```ts
// packages/core/src/jobs/report-build.ts — esquema del patrón (job del dominio de TU proyecto)
import { z } from 'zod'
import { UlidSchema } from '../contracts/ids' // los PKs son ULIDs (db.md §1) — z.uuid() los rechazaría
import { defineJob } from './registry'

export const ReportBuildJobSchema = z.object({
  report_id: UlidSchema,
})
export type ReportBuildJob = z.infer<typeof ReportBuildJobSchema>

export const reportBuildJob = defineJob({
  name: 'report.build',
  payload: ReportBuildJobSchema,
  options: {
    policy: 'short',          // ver §3: 'short' es lo que hace real el dedupe por singletonKey
    retryLimit: 3,
    retryBackoff: true,
    retryDelayMax: 300,
    expireInSeconds: 900,
  },
})
```

**Validación Zod en LAS DOS puntas** — al encolar (`payload.parse` en el adaptador, §5) y al consumir (`safeParse` en el handler, §4). El porqué del lado consumidor: tras un deploy pueden quedar en la cola payloads encolados por la versión anterior del código; un `safeParse` que falla convierte "undefined is not a function a mitad de handler" en un job en la DLQ con error legible.

## 3. Colas: `createQueue` explícito en el bootstrap

En v10+ las colas se crean explícitamente. El bootstrap del worker recorre el registro y garantiza cola + DLQ; idempotente con el guard `getQueue` (patrón de los docs oficiales) y `updateQueue` si la config del registro cambió (`policy`/`partition` no se pueden cambiar):

```ts
// apps/worker/src/bootstrap.ts (fragmento)
import { jobRegistry } from '@app/core/jobs'

for (const job of Object.values(jobRegistry)) {
  const dlq = `${job.name}.dlq`
  if (!(await boss.getQueue(dlq))) await boss.createQueue(dlq)   // la DLQ debe existir ANTES de referenciarla
  if (!(await boss.getQueue(job.name))) {
    await boss.createQueue(job.name, { ...job.options, deadLetter: dlq })
  } else {
    // policy/partition son inmutables (docs/api/queues.md): se excluyen del update
    const { policy: _policy, ...updatable } = job.options
    await boss.updateQueue(job.name, { ...updatable, deadLetter: dlq })
  }
}
```

Una cola por tipo de trabajo, con la política que su semántica exige. Guía de elección (los nombres concretos los define tu dominio):

| Semántica del trabajo | Política | Config clave | Por qué |
|---|---|---|---|
| "No encoles dos veces el mismo trabajo, ejecuta N a la vez" | `short` + `singletonKey` | retryBackoff, retryDelayMax, expire ajustado al peor caso | **Trampa verificada**: en una cola `standard`, `singletonKey` NO garantiza unicidad; `short` = 1 job *en cola* por key con activos ilimitados |
| Trabajo paralelo normal (descargas, envíos, procesado por unidad) | `standard` | retryLimit + retryBackoff según el proveedor | El default correcto para casi todo |
| Trabajo largo de CPU/proceso externo (minutos) | `standard` | expire alto + `heartbeatSeconds` | El heartbeat detecta un worker muerto en ~1–2 min sin esperar el expire (§7) |
| Cron / barridos periódicos | `singleton` | retryLimit 0–2, expire corto | `singleton` = máximo 1 activo; dos barridos solapados pisándose locks es un bug, no throughput |

Cada cola tiene su `'<queue>.dlq'`: un job que agota retries conserva payload y error consultables (autopsia + `redrive()` de vuelta a la cola origen). Una DLQ que crece es una alerta operativa, no un cubo de basura.

Si `apps/web` necesita encolar desde requests, también necesita una instancia PgBoss: accessor lazy `getBoss()`/`setBossForTests()` — mismo contrato que `getDb()` (ver `references/api.md` §3) — sin `work()` y con `schedule: false` en el constructor (solo el worker programa crons).

## 4. Consumers

Handlers reciben `Job[]` (v10) con `batchSize: 1` — desestructura `[job]`. Patrón canónico: validar payload → child logger correlacionado → releer estado real y no-op si ya está resuelto → delegar toda mutación de estado en el servicio transaccional de core:

```ts
// apps/worker/src/consumers/report-build.ts
import { AppError } from '@app/core/contracts'
import { reportBuildJob, ReportBuildJobSchema } from '@app/core/jobs'

export async function startReportConsumer({ boss, db, services, logger }: WorkerContext) {
  await boss.work(reportBuildJob.name, { batchSize: 1 }, async ([job]) => {
    const parsed = ReportBuildJobSchema.safeParse(job.data)
    if (!parsed.success) throw new AppError('validation_error', 'payload de job inválido', z.flattenError(parsed.error)) // payload viejo/corrupto → agotará retries → DLQ
    const { report_id } = parsed.data
    const log = logger.child({ queue: reportBuildJob.name, job_id: job.id, report_id }) // bindings canónicos: observability.md §3.1

    // Re-entrega: si el trabajo ya no está en un estado ejecutable, no-op (¡no error!).
    // La revalidación REAL bajo lock la hace el servicio transaccional; esto solo ahorra trabajo.
    const report = await getReport(db, report_id)
    if (!isPending(report)) { log.info('re-entrega sobre trabajo ya resuelto: no-op'); return }

    try {
      await services.reports.build({ report, log, signal: job.signal })
    } catch (err) {
      log.error({ err }, 'handler falló')  // la clave DEBE llamarse err (observability.md §5)
      throw err                            // pg-boss registra el intento (§7)
    }
  })
}
```

**Si tu proyecto tiene un orquestador de pipeline** (steps con `node_key`, dependencias y máquina de estados), el patrón escala a un **consumer genérico**: una sola cola `step.execute`, un registro de executors por `node_key`, y TODO cambio de estado delegado en `transition()` (que re-arma retries y valida bajo lock). Los executors de demo/harness (sleep, fail determinista, hang) son **código de producto**, no de test: son lo que permite verificar retries, timeouts y sweeper desde la UI en F0.

## 5. Encolado transaccional

La propiedad crítica: **el INSERT del job va en la MISMA transacción Drizzle que la mutación de estado que lo motiva**. Esto elimina una clase entera de bugs: crash entre commit y encolado → estado "pendiente" que nadie ejecutará jamás; encolado antes del commit sin tx compartida → rollback deja un job fantasma que ejecuta sobre un estado inconsistente. Con la tx compartida ninguno de los dos mundos existe.

pg-boss lo soporta de serie: `send(name, data, { db })` acepta un adaptador `{ executeSql(text, values) }`, y trae `fromDrizzle(tx, sql)` oficial (verificado en el paquete, `pg-boss/dist/adapters/drizzle.js`):

```ts
// packages/db/src/adapters/job-queue.ts — adaptador tx-scoped del puerto JobQueue de core
// (lo construye makeWithTransaction con la tx abierta: db.md §5, architecture.md §2)
import { sql } from 'drizzle-orm'
import type PgBoss from 'pg-boss'
import { fromDrizzle } from 'pg-boss'
import type { JobQueue } from '@app/core/orders' // o donde viva el puerto en tu dominio
import type { EnqueueRequest } from '@app/core/jobs'
import type { DbTx } from '../client'

export function makeTxJobQueue(boss: PgBoss, tx: DbTx): JobQueue {
  return {
    async enqueue(req: EnqueueRequest): Promise<void> {
      const data = req.job.payload.parse(req.payload) // validación al ENCOLAR (§2)
      await boss.send(req.job.name, data, {
        db: fromDrizzle(tx, sql), // el INSERT del job va en NUESTRA transacción
        ...(req.singletonKey && { singletonKey: req.singletonKey }),
        ...(req.startAfter && { startAfter: req.startAfter }),
      })
    },
  }
}
```

`singletonKey` es la barrera contra el **doble encolado** (dos caminos decidiendo a la vez que un trabajo está listo — p. ej. un webhook y un sweeper): elige una key derivada del invariante de tu dominio (p. ej. `'${agregado_id}:${accion}'`). Con la política `short` de la cola (§3), el segundo `send` con la misma key resuelve `null` en vez de crear job — trátalo como éxito idempotente, nunca como error.

## 6. Idempotencia del handler

Patrón obligatorio para handlers con trabajo externo de pago (LLMs, generación, envíos facturables): la re-entrega de un job NO puede re-submitir — es la barrera contra el doble gasto. Tres reglas:

1. **Al (re)entrar, releer bajo `FOR UPDATE` y no-op si el trabajo ya se aplicó.** La revalidación bajo lock vive en el servicio transaccional; el handler consulta además su tabla de trabajo por el registro activo.
2. **Persistir la intención (`submitting`) ANTES de llamar al proveedor**, y el `request_id`/referencia externa inmediatamente después. Si el worker muere entre medias, la re-entrega encuentra la intención y **reanuda el seguimiento** del request existente en vez de crear otro.
3. **Dos transacciones cortas, jamás un lock abierto durante HTTP.** Un `FOR UPDATE` que espera a un proveedor serializa el worker entero y agota el pool con la latencia de un tercero.

```ts
// apps/worker — esquema del patrón con proveedor externo de pago
async function runPaidWork(entity: Entity, deps: Deps) {
  // tx corta 1: decidir bajo lock
  const intent = await deps.db.transaction(async (tx) => {
    const current = await repo.getForUpdate(tx, entity.id)
    if (isTerminal(current.status)) return { kind: 'noop' } as const              // re-entrega tardía
    const work = await workRepo.findActiveByEntity(tx, entity.id)
    if (work?.provider_request_id) return { kind: 'resume', requestId: work.provider_request_id } as const
    const created = await workRepo.insert(tx, { entity_id: entity.id, status: 'submitting' })
    return { kind: 'submit', workId: created.id } as const                        // intención COMMITEADA
  })
  if (intent.kind === 'noop') return
  if (intent.kind === 'resume') return deps.provider.trackRequest(intent.requestId) // seguimiento, NO re-submit

  // HTTP FUERA de toda transacción
  const submitted = await deps.provider.submit({ /* … */ })

  // tx corta 2: persistir la referencia externa inmediatamente
  await deps.db.transaction(async (tx) => {
    await workRepo.recordSubmit(tx, intent.workId, submitted)
  })
}
```

El mismo principio aplica a jobs baratos (descargas, procesado): re-entrar tiene que ser gratis (checksum ya persistido → no re-descargar; resultado ya cacheado → no re-procesar).

## 7. Retries y tiempos

- **La decisión reintentable-vs-fatal es del dominio, no de `retryLimit`.** Si tu dominio lleva su propio contador (`retry_count`/`max_retries` en la tabla), ese es el canónico; pg-boss aporta el *timing* y la re-entrega. El handler traduce: error transitorio (red, 5xx, timeout HTTP) → marcar fallo + relanzar, y la re-entrega con backoff reintenta si el guard lo permite; error fatal (`AppError` no reintentable, payload inválido) → fallo terminal, y el job debe acabar en la DLQ para autopsia — o agotando `retryLimit` (las re-entregas encuentran el estado terminal y no-opean barato), o directo con `perJobResults: true` devolviendo `{ id, status: 'deadletter', output }` (≥12.21: salta los reintentos restantes).
- **Backoff exponencial para APIs externas**: `retryBackoff: true` + `retryDelayMax` (p. ej. 300 s). Sin techo, el delay se dispara (`retryDelay·2^n`); sin backoff, cada glitch del proveedor fusila el trabajo al tercer martillazo en 3 segundos.
- **`retryLimit` por tipo, alineado con el contador del dominio** (mismo orden de magnitud): así el último throw deja el job en la DLQ a la vez que el estado queda terminal. Las re-entregas por crash del worker no consumen el contador del dominio pero sí `retryLimit` — margen deliberado en colas donde el crash es plausible.
- **Jobs largos**: `expireInSeconds` alto = techo duro del peor caso (un job pasa a retry/fail al superarlo, esté vivo o no) + **heartbeat periódico** para detectar el worker muerto en segundos en vez de esperar el expire: con `heartbeatSeconds` en la cola, `work()` envía los heartbeats (touch) automáticamente; `boss.touch(name, jobId)` manual solo se necesita procesando con `fetch()`. Sin heartbeat, un trabajo de 1 h con expire de 2 h tarda 2 h en detectarse muerto.
- Propaga `job.signal` (AbortSignal del job) a fetch y procesos hijos: expiración y shutdown cancelan trabajo en curso en vez de dejarlo zombi.

## 8. Cron

`boss.schedule(name, cron, data, options)` sobre colas con política `singleton` (§3): el schedule **vive en Postgres** — sobrevive reinicios y deploys, y con varias instancias solo se emite 1 job por slot (throttling interno + compensación de clock skew). El bootstrap lo declara incondicionalmente: si ya existe, `schedule()` lo actualiza (upsert por nombre; `key` para varios schedules por cola).

```ts
// apps/worker/src/bootstrap.ts (fragmento) — si web tiene instancia, arranca con { schedule: false }
await boss.schedule(sweeperTickJob.name, '* * * * *', {}, {})                        // barrido de timeouts, si tu dominio lo necesita
await boss.schedule(cleanupJob.name, '30 4 * * *', {}, { tz: 'Europe/Madrid' })      // retención/limpieza periódica
```

Reglas: formato de **5 campos** (precisión de minuto; los schedules se evalúan cada ~30 s, el de 6 campos con segundos se malinterpreta); el handler del cron es un job normal (idempotente, DLQ, logging). Si un SLA exige detectar timeouts más rápido que la granularidad del cron: implementa el barrido como función invocable directa (`sweepExpired(db)`) — así también se testea sin cron —, ajusta `cronWorkerIntervalSeconds` si hace falta, y considera un poller lazy en read-path para cubrir el hueco.

## 9. Graceful shutdown

SIGTERM/SIGINT (deploy, `docker compose down`) → dejar de aceptar → esperar a los activos → cerrar recursos → salir. `boss.stop()` ya hace las dos primeras: deja de hacer polling y espera a los handlers activos hasta `timeout`:

```ts
// apps/worker/src/bootstrap.ts (fragmento)
const SHUTDOWN_TIMEOUT_MS = 120_000 // ≥ p99 del job más largo aceptable de perder

async function shutdown(signal: string) {
  logger.info({ signal }, 'shutdown: dejando de aceptar jobs')
  await boss.stop({ graceful: true, timeout: SHUTDOWN_TIMEOUT_MS }) // espera activos; close: true cierra el pool propio de pg-boss
  await pool.end()                                                  // el pool de Drizzle es nuestro: lo cerramos nosotros
  process.exit(0)
}
process.once('SIGTERM', () => void shutdown('SIGTERM'))
process.once('SIGINT', () => void shutdown('SIGINT'))
```

El `timeout` es un compromiso, no una garantía: un job que lo supere quedará interrumpido y **re-entregado en el próximo arranque** — por eso los handlers largos son reanudables (§6: intención persistida + resultados cacheados = la re-entrega retoma, no repite). No subas el timeout para "no perder nada": súbelo hasta donde un deploy siga siendo tolerable y confía en la idempotencia para el resto. En Docker, asegúrate de que el worker recibe la señal (proceso PID 1 vía `tsx`/binario de tsup, o `init: true`) y de que `stop_grace_period` del compose supera tu `SHUTDOWN_TIMEOUT_MS` (ver skill `deploy`).

## 10. Qué NO va aquí

- **SQL del lock, transacciones Drizzle, `FOR UPDATE`/`skipLocked`, repos** → `references/db.md`.
- **Puertos, servicios transaccionales y (si existe) la máquina de estados** → `references/architecture.md` (aquí solo se consumen).
- **Webhooks de proveedores y las rutas que encolan** → `references/api.md` (regla: el route handler verifica/persiste/delega; el trabajo pesado SIEMPRE es un job del worker).
- **Logging y correlación (`job_id`, redact)** → `references/observability.md`.
- **Tests de todo lo anterior** → skill `testing`. Regla de oro que gobierna esos tests y esta capa: **pg-boss no se mockea** — su semántica (re-entrega, retries, transaccionalidad del `send` con `{ db }`) ES lo que se está testeando; mockearla es testear el mock.
