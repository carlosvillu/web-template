# Testing del worker, colas pg-boss y lógica transaccional de estado

> **Solo aplica si tu F0 incluye el módulo worker/colas (pg-boss) o una máquina de estados transaccional.** Si tu proyecto es solo web+BD, ignora este reference entero.

Capa: la lógica de orquestación de `packages/core` (si existe) + consumers de `apps/worker`. Los patrones de aquí sirven para cualquier sistema de jobs sobre Postgres: máquinas de estado, encolado transaccional, retries, timeouts, idempotencia y deduplicación.

**Contenido**: [Por qué máximo rigor](#por-qué-esta-capa-exige-el-máximo-rigor) · [Ubicación y setup](#ubicación-y-setup) · [Tabla de transiciones](#1-la-tabla-de-transiciones-legales-end-to-end-ilegales-por-muestra) · [Carreras](#2-carreras-select--for-update) · [NOTIFY](#3-assertions-de-notify) · [Encolado transaccional](#4-encolado-transaccional-en-pg-boss) · [Retries](#5-pg-boss-retries-y-backoff) · [Invalidación con supersedes](#6-invalidación-con-supersedes_id) · [Timeouts y sweeper](#7-timeouts-y-cron-de-barrido) · [Idempotencia](#8-idempotencia-de-executors) · [Dedup](#9-deduplicación-por-content-hash)

## Por qué esta capa exige el máximo rigor

Si tu producto tiene un orquestador, es **la única fuente de mutación de estado**: toda transición pasa por `transition(id, event, { db })`, que en UNA transacción actualiza el estado, resuelve dependencias, encola en pg-boss y emite `NOTIFY`. Un bug aquí no rompe una feature: **corrompe todos los flujos** — jobs huérfanos que nunca arrancan, doble encolado que duplica gasto real si hay APIs de pago, invalidaciones que pierden linaje. Y sus garantías son propiedades de Postgres (`SELECT … FOR UPDATE`, atomicidad de transacción, NOTIFY-que-solo-dispara-en-COMMIT) que **no existen en ningún mock**. De ahí las tres reglas de esta capa:

1. **Cero mocks de BD.** Todo test de comportamiento corre contra Postgres 16 real vía Testcontainers (setup en `db-integration.md`). Un `transition()` unit-testeado con un fake de Drizzle prueba exactamente nada: el valor está en el lock, la transacción y el NOTIFY.
2. **Cero fake timers.** pg-boss hace polling con conexiones propias y el sweeper compara `timeout_at` contra el reloj de Postgres; `vi.useFakeTimers()` solo congela el proceso de test, no la BD ni el worker. Usa timeouts reales cortos (1–2 s) y un helper `waitFor(predicate, { timeoutMs })` por polling.
3. **Determinismo en los fallos.** Si tienes executors de demo con un flag de fallo aleatorio (`fail_rate`), resérvalo para los scripts de verificación manual; en tests automatizados usa `fail_times: N` (falla exactamente los N primeros intentos) — un test flaky en el módulo más crítico es peor que no tener test.

Lo único que SÍ se mockea es la frontera HTTP con APIs externas (msw + fixtures de `packages/test-utils/fixtures/http/`): el worker debe ser verificable sin gastar un céntimo.

## Ubicación y setup

```
packages/core/src/orchestrator/*.test.ts                 # unit: cartesiano exhaustivo sobre la función pura (unit-core.md §4)
packages/core/test/integration/orchestrator/*.test.ts    # transition, carreras, NOTIFY, encolado transaccional
apps/worker/test/integration/*.test.ts                   # consumers reales, retries, sweeper, idempotencia, dedup
```

Cada archivo de suite pide su database aislada (clonada de la template en milisegundos, sin interferencias entre suites paralelas):

```ts
import { beforeAll, afterAll } from 'vitest'
import { createTestDatabase, insertJob } from '@app/test-utils'

let db: DrizzleDb, connectionString: string, close: () => Promise<void>
beforeAll(async () => ({ db, connectionString, close } = await createTestDatabase()))
afterAll(() => close())
```

Las filas de prueba se crean con las factories **insertadoras** `insertX` (async: insertan vía `makeX` + Drizzle y devuelven la fila con id); las `makeX` puras y síncronas quedan para unit (ver `stack-setup.md` §4.3).

## 1. La tabla de transiciones: legales end-to-end, ilegales por muestra

El reparto entre capas es explícito y no se duplica: el **producto cartesiano exhaustivo** estados × eventos es **unit** sobre la función pura de la tabla en `packages/core` — milisegundos, ver `unit-core.md` §4. Esta capa de integración **NO repite el cartesiano**: cubre todas las transiciones LEGALES end-to-end contra Postgres real, una muestra representativa de ilegales verificando el rollback, y los efectos transaccionales que solo existen aquí (`SELECT … FOR UPDATE`, encolado en pg-boss en la misma tx, `NOTIFY`, `supersedes_id` si existe invalidación).

La máquina de estados vive en el código como **dato** (una constante `TRANSITIONS`), pero el test **NO la importa**: duplica a mano la lista de transiciones legales copiada del PRD. Si el test derivara sus expectativas de la misma constante que valida, no probaría nada; así, cualquier cambio en la máquina de estados rompe el test a propósito y obliga a decidir conscientemente.

```ts
// packages/core/test/integration/orchestrator/transition-table.test.ts
import { describe, it, expect } from 'vitest'
import { createTestDatabase, insertRun, insertStep } from '@app/test-utils'
import { transition, IllegalTransitionError } from '@app/core/orchestrator'

// Copia MANUAL del PRD — mantén este espejo 1:1 (junto al cartesiano unit
// de unit-core.md) en la misma sesión en que cambie la máquina.
const LEGAL: Array<[from: string, event: string, to: string]> = [
  ['pending', 'enqueue', 'queued'],
  ['queued', 'start', 'running'],
  ['running', 'succeed', 'succeeded'],
  ['running', 'fail', 'failed'],
  ['failed', 'retry', 'queued'], // guard: retry_count < max_retries (test aparte)
  // …completar 1:1 con la tabla del PRD
]

describe('transition(): todas las transiciones legales, end-to-end', () => {
  for (const [from, event, to] of LEGAL) {
    it(`${from} --${event}--> ${to}`, async () => {
      const run = await insertRun(db)
      const step = await insertStep(db, { runId: run.id, status: from })
      await transition(step.id, { type: event }, { db })
      expect((await getStep(db, step.id)).status).toBe(to)
    })
  }
})

describe('transition(): muestra de ilegales — el rollback se verifica', () => {
  const ILLEGAL: Array<[from: string, event: string]> = [
    ['succeeded', 'start'],    // terminal no revive
    ['pending', 'succeed'],    // salto de estados
  ]
  for (const [from, event] of ILLEGAL) {
    it(`${from} --${event}--> ILEGAL: la BD queda intacta`, async () => {
      const run = await insertRun(db)
      const step = await insertStep(db, { runId: run.id, status: from })
      const before = await getStepRaw(db, step.id) // SELECT * completo, tal cual
      await expect(transition(step.id, { type: event }, { db }))
        .rejects.toThrow(IllegalTransitionError)
      expect(await getStepRaw(db, step.id)).toEqual(before) // ni updated_at cambia
    })
  }
})
```

**El rollback se verifica, no se supone.** Para cada ilegal de la muestra: (a) la fila queda *byte a byte* idéntica (compara el `SELECT *` completo, incluido `updated_at` — detecta el bug clásico de "validar después de escribir"); (b) no aparece ningún job nuevo en `pgboss.job` (cuenta antes/después); (c) un cliente con `LISTEN` no recibe nada (test representativo en §3). Baratos porque comparten database y solo crean una fila por caso — la exhaustividad ya la garantiza el cartesiano unit.

Añade también los tests de guards con contexto: `failed --retry-->` con `retry_count >= max_retries` rechaza. Y la derivación de estado agregado si existe (el estado de un run derivado de sus steps).

## 2. Carreras: SELECT … FOR UPDATE

El diseño que el test protege: `transition()` adquiere el lock **y revalida el estado leído bajo el lock** (no el leído antes). El perdedor de la carrera no debe aplicar su transición dos veces ni corromper nada: debe fallar limpio con `IllegalTransitionError` cuando, al desbloquearse, el estado ya no admite su evento. Este es exactamente el escenario real webhook (web) vs consumer (worker) llegando a la vez.

```ts
it('dos transiciones concurrentes sobre el mismo step: una gana, la otra falla limpio', async () => {
  const step = await insertStep(db, { status: 'queued' })
  // Dos pools independientes: la serialización debe venir del FOR UPDATE,
  // no de compartir conexión.
  const dbA = createDb(connectionString), dbB = createDb(connectionString)
  const results = await Promise.allSettled([
    transition(step.id, { type: 'start' }, { db: dbA }),
    transition(step.id, { type: 'start' }, { db: dbB }),
  ])
  expect(results.filter((r) => r.status === 'fulfilled')).toHaveLength(1)
  const [ko] = results.filter((r) => r.status === 'rejected') as PromiseRejectedResult[]
  expect(ko.reason).toBeInstanceOf(IllegalTransitionError)
  const final = await getStep(db, step.id)
  expect(final.status).toBe('running')     // exactamente UNA aplicación
  expect(final.started_at).not.toBeNull()  // y una sola marca temporal
})
```

**Estrés de concurrencia**: crea N runs (p. ej. 20) del DAG de demo, arranca el consumer real y espera con `waitFor` (timeout global generoso, p. ej. 30 s) a que todos lleguen a `succeeded`. Un deadlock aflora como error de Postgres (`40P01`) o como timeout del test. La regla de diseño que este test vigila: cuando `transition()` bloquea varias filas (step + dependientes), **siempre en orden determinista por id** — el interbloqueo nace de órdenes de lock distintos en transacciones cruzadas.

## 3. Assertions de NOTIFY

> Solo si el módulo SSE/eventos existe (LISTEN/NOTIFY como bus de eventos).

`NOTIFY` solo se entrega en COMMIT: el mismo test prueba el evento y la transaccionalidad. Usa un `pg.Client` **dedicado** (LISTEN fija la conexión; nunca el pool de la app):

```ts
import { Client } from 'pg'

it('toda transición legal emite NOTIFY con el id; las ilegales, silencio', async () => {
  const listener = new Client({ connectionString })
  await listener.connect()
  const payloads: string[] = []
  listener.on('notification', (n) => payloads.push(n.payload ?? ''))
  await listener.query('LISTEN app_events')

  const run = await insertRun(db)
  const step = await insertStep(db, { runId: run.id, status: 'pending' })
  await transition(step.id, { type: 'enqueue' }, { db })
  await waitFor(() => payloads.includes(run.id))          // llega tras el COMMIT

  await expect(transition(step.id, { type: 'succeed' }, { db })).rejects.toThrow()
  await sleep(300)                                        // ventana de gracia real
  expect(payloads).toHaveLength(1)                        // el rollback no notifica
  await listener.end()
})
```

Esto es además la base del contrato SSE: el endpoint de eventos se testea aparte (api.md §3.3), pero la garantía "un NOTIFY por transición confirmada, cero por transición fallida" se cierra aquí.

## 4. Encolado transaccional en pg-boss

La propiedad crítica: **el job aparece en pg-boss en la misma transacción que la mutación de estado, o no aparece**. Si el encolado fuera post-commit, un crash entre ambos dejaría filas `queued` que nadie ejecuta jamás; si fuera pre-commit sin transacción compartida, un rollback dejaría jobs fantasma que ejecutan estado inconsistente. pg-boss permite ejecutar el INSERT del job con tu propia transacción (revisa la opción de executor/`db` de tu versión; si no la expone, INSERT directo en `pgboss.job` — lo innegociable es la atomicidad, no el mecanismo):

```ts
it('rollback de la transición ⇒ el job NO existe en pg-boss', async () => {
  const step = await insertStep(db, { status: 'pending' })
  await db.transaction(async (tx) => {
    await enqueueStepJob(tx, step)      // mismo tx que la mutación de estado
    throw new Error('boom')             // simula fallo post-encolado, pre-commit
  }).catch(() => {})
  const [{ count }] = await rawSql(db, `SELECT count(*)::int AS count FROM pgboss.job WHERE name = 'step.execute'`)
  expect(count).toBe(0)
})
```

Y el camino feliz completo, con resolución de dependencias si existen: DAG `a → b`; llevar `a` a `succeeded` debe, en una sola llamada a `transition()`, dejar `b` en `queued` Y su job visible en `pgboss.job` Y emitir el NOTIFY. Arranca después el consumer real y verifica que `b` se ejecuta — cierra el ciclo entero encolado→despacho.

## 5. pg-boss: retries y backoff

En `apps/worker/test/integration/`, con el boss real apuntando a la database del test: registra un executor de demo con `fail_times: 2` y `retryLimit: 3` (retryDelay corto, 1 s), encola 10 jobs y espera a que todos acaben `completed`. Asserts: la tabla de pg-boss muestra los reintentos (`retry_count = 2` en los que fallaron), ningún job en `failed`, y el executor fue invocado exactamente `10 + 2×fallidos` veces (cuenta con un spy propio, no confíes solo en logs). El porqué: los retries de pg-boss son la red de seguridad de todo el pipeline; si el backoff no funciona, cada glitch de un proveedor externo se convierte en un job muerto.

## 6. Invalidación con supersedes_id

> Solo si tu diseño incluye checkpoints/ediciones que invalidan trabajo aguas abajo.

La regla de oro: **la invalidación nunca resetea filas** — crea filas nuevas con `supersedes_id` y marca las antiguas `superseded`, conservando histórico y linaje (de costes, si existe spend ledger). El test que la protege:

```ts
it('edit: la fila antigua queda superseded, NUNCA se resetea', async () => {
  const oldA = await getStepRaw(db, aId)
  await orchestrator.edit(cp.id, { patch: edited }, { db })

  const afterA = await getStepRaw(db, aId)
  expect(afterA.status).toBe('superseded')
  expect(afterA.output_refs).toEqual(oldA.output_refs)   // histórico intacto
  expect(afterA.cost_actual).toEqual(oldA.cost_actual)   // linaje intacto
  expect(afterA.retry_count).toEqual(oldA.retry_count)   // NADA se resetea

  const newA = await findStep(db, { runId, nodeKey: 'a', supersedesId: aId })
  expect(newA.status).toBe('queued')                     // fila NUEVA + job en pg-boss (misma tx)
})
```

Completa la matriz con las demás acciones de tu diseño (approve/reject/skip/cancel): `cancel` de un flujo en curso pasa todos los estados no terminales a `cancelled` y los jobs pendientes se vuelven no-op (el consumer, al despertar, encuentra el estado `cancelled` y NO ejecuta — assert con spy); un estado ya `succeeded` no se toca — cancelar no reescribe historia. El cierre transitivo del sub-grafo invalidado se unit-testea además en puro (grafo en memoria, sin BD): nodos aguas *arriba* jamás se invalidan, y los diamantes (`a→b`, `a→c`, `b,c→d`) invalidan `d` una sola vez.

## 7. Timeouts y cron de barrido

Los executors de demo (`sleep_ms`, `fail_times`, `hang`) existen precisamente para esto — trátalos como código de producto: son el harness de test de todo F0. Timeouts reales cortos, sweeper invocado como función:

```ts
it('executor colgado + timeout_at corto ⇒ expired', async () => {
  const step = await insertStep(db, {
    nodeKey: 'demo.hang', input: { hang: true },
    timeoutAt: new Date(Date.now() + 1_000),   // 1 s real, no fake timers
  })
  await enqueueAndStartWorker()
  await waitFor(async () => (await getStep(db, step.id)).status === 'running')
  await waitFor(() => Date.now() > step.timeoutAt.getTime())
  await sweepExpiredSteps(db)                  // la función del cron, directa
  expect((await getStep(db, step.id)).status).toBe('expired')
})
```

Testea el sweep como función (rápido, determinista) y, aparte, que el **schedule queda registrado** en pg-boss al arrancar el worker (query a la tabla de schedules) — la granularidad de cron de pg-boss es de minutos y esperar al disparo real en un test sería lento y flaky; el disparo real se observa en la verificación de gate de la tarea. Si el sweeper también reconcilia trabajos colgados contra una API externa (polling fallback), móntalo con msw devolviendo el estado final para un request "olvidado".

## 8. Idempotencia de executors

Para cualquier executor que hace submit a una API externa de pago: la intención se persiste ANTES del submit, y el `request_id` inmediatamente después; un executor re-entregado **reanuda el seguimiento, no re-submite**. Es la barrera contra el doble gasto:

```ts
// apps/worker/test/integration/executor-idempotency.test.ts
import { useHttpMocks, server } from '@app/test-utils'
useHttpMocks()                                 // handlers por defecto; server.use = override puntual
let submits = 0
server.use(
  http.post('https://api.provider.example/submit', () => {
    submits++
    return HttpResponse.json({ request_id: 'req_1', status_url: STATUS })
  }),
  http.get(STATUS, () => HttpResponse.json({ status: 'IN_PROGRESS' })),
)
await startWorker(boss1)
await waitFor(async () => (await getJobRow(db, step.id))?.status === 'submitted')
await boss1.stop(/* sin gracia: simula el crash del worker */)

server.use(http.get(STATUS, () => HttpResponse.json({ status: 'COMPLETED' })))
await startWorker(boss2)                       // pg-boss re-entrega el job
await waitFor(async () => (await getJobRow(db, step.id))?.status === 'completed')

expect(submits).toBe(1)                        // UN solo submit al proveedor
```

La verificación de gate de la tarea correspondiente repite esto en el mundo real (matar el proceso del worker durante una ejecución real; el billing del proveedor muestra 1 solo job) — esa evidencia es manual/live y se persiste en `docs/verifications/<TASK-ID>/`; el test automatizado con msw es la regresión permanente.

## 9. Deduplicación por content-hash

> Solo si tu diseño deduplica trabajo idéntico (mismo input ⇒ una sola ejecución cara).

Test de integración en el worker, con msw contando submits por input: N unidades de trabajo con inputs idénticos deben producir UNA sola ejecución externa y compartir el resultado. Añade el caso negativo (un carácter distinto en el input ⇒ hash distinto ⇒ nueva ejecución) y el de carrera: dos consumers que buscan el mismo hash a la vez no deben submitir dos veces — misma disciplina FOR UPDATE / unique constraint sobre `content_hash` + estado, verificada con dos consumers concurrentes.

---

Regla final: cuando toques la máquina de estados, el orden es (1) actualizar el PRD, (2) actualizar `TRANSITIONS` en el código, (3) actualizar los espejos de los tests (el cartesiano unit de `unit-core.md` y el `LEGAL` de §1) — en la misma sesión. Si el cartesiano unit y las legales de §1 están en verde y los tests de carrera/atomicidad pasan contra Postgres real, el resto del sistema puede confiar ciegamente en esta capa; esa confianza es su objetivo.
