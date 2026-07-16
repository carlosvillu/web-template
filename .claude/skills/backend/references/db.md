# Drizzle: schema, migraciones, repos y transacciones

> Capa: `packages/db` — la implementación con Drizzle + Postgres de los puertos de persistencia que define `packages/core`. Los tests de todo lo de aquí los define la skill `testing` (harness de Testcontainers, tests de migraciones/constraints, transaccionalidad); este documento NO los duplica.

**Drizzle evoluciona rápido (0.x → 1.0 cambia relations y drizzle-kit).** Si dudas de una API exacta, verifica con Context7 (`.mcp.json`) o docs oficiales antes de asumirla; la skill instalada `postgres-drizzle` complementa con la distinción 0.x vs 1.0. Los snippets de este documento son esquemas de patrón, con las APIs de Drizzle 0.x verificadas a fecha de escritura.

**Contenido**: [1. Schema por dominio](#1-schema-por-dominio) · [2. Tipos](#2-tipos-inferselectinferinsert-nunca-shapes-a-mano) · [3. Migraciones](#3-migraciones) · [4. Repos](#4-repos-funciones-por-agregado-executor-como-primer-argumento) · [5. Adaptadores de puertos](#5-adaptadores-de-puertos) · [6. Mutaciones transaccionales vistas desde SQL](#6-mutaciones-transaccionales-vistas-desde-sql) · [7. Read models con relational queries](#7-relational-queries-para-read-models) · [8. Índices y constraints con intención](#8-índices-y-constraints-con-intención) · [9. Qué NO va aquí](#9-qué-no-va-aquí)

## 1. Schema por dominio

Un fichero por grupo de tablas en `packages/db/src/schema/` (los dominios los define el PRD del proyecto: `users.ts`, `orders.ts`, `ops.ts`…), re-exportados en `schema/index.ts`. Por qué: los diffs de una feature tocan UN fichero coherente, y `drizzle(pool, { schema })` recibe el barrel completo sin listas manuales.

`drizzle.config.ts` apunta a la carpeta (glob), no a ficheros sueltos — añadir un dominio nuevo no toca la config:

```ts
// packages/db/drizzle.config.ts
import { defineConfig } from 'drizzle-kit';

export default defineConfig({
  dialect: 'postgresql',
  schema: './src/schema/*.ts',
  out: './drizzle', // SQL committeado: la historia de migraciones es parte del repo
});
```

**Helpers compartidos** en `schema/columns.helpers.ts`. Los PKs son ULIDs **generados en la app** (util de `@app/core`): ordenables por tiempo y disponibles ANTES del INSERT — logs, `singletonKey` de pg-boss (si hay cola) y payloads de NOTIFY (si hay SSE) pueden referenciar la fila que aún no existe.

```ts
// packages/db/src/schema/columns.helpers.ts
import { text, timestamp } from 'drizzle-orm/pg-core';
import { newUlid } from '@app/core/contracts'; // vive en contracts/ids.ts junto a UlidSchema

export const ulidPk = () => text('id').primaryKey().$defaultFn(() => newUlid());

export const timestamps = {
  createdAt: timestamp('created_at', { withTimezone: true }).notNull().defaultNow(),
  updatedAt: timestamp('updated_at', { withTimezone: true }).notNull().defaultNow()
    .$onUpdateFn(() => new Date()),
};
```

**Enums `pgEnum` junto a su tabla**, con los valores EXACTOS que fije el PRD — el enum es parte del contrato de la tabla y el diff de migración los muestra juntos. Copia bien la lista la primera vez: añadir un valor a un pgEnum es un `ALTER TYPE … ADD VALUE` trivial, pero renombrar o quitar uno es migración manual delicada.

```ts
// packages/db/src/schema/orders.ts — esquema del patrón (entidad y estados de TU dominio)
import { sql } from 'drizzle-orm';
import { index, pgEnum, pgTable, text, timestamp } from 'drizzle-orm/pg-core';
import { ulidPk, timestamps } from './columns.helpers';
import { user } from './users';

// Si el PRD define una máquina de estados, este enum ES esa máquina: NO reordenar ni renombrar a la ligera.
export const orderStatus = pgEnum('order_status', ['draft', 'confirmed', 'shipped', 'cancelled']);

export const order = pgTable('order', {
  id: ulidPk(),
  userId: text('user_id').notNull().references(() => user.id, { onDelete: 'cascade' }),
  status: orderStatus('status').notNull().default('draft'),
  ...timestamps,
}, (t) => [
  index('order_user_id_idx').on(t.userId), // cada índice existe para una query con nombre (§8)
]);
```

Toda FK declara `onDelete` **explícito**: la política de borrado es una decisión de producto, no un default heredado — y su test la fija (skill `testing`, integración de BD).

## 2. Tipos: `$inferSelect`/`$inferInsert`, nunca shapes a mano

```ts
// al final de cada fichero de schema
export type Order = typeof order.$inferSelect;
export type NewOrder = typeof order.$inferInsert;
```

- **NUNCA dupliques a mano** un shape de fila: dos fuentes de verdad divergen en silencio; `$infer*` mantiene el tipo pegado al schema y una migración que cambia una columna rompe el typecheck en todos los consumidores.
- **Los contratos Zod de `@app/core` son la vista pública** (API, SSE, payloads de jobs) y se escriben a mano: pueden renombrar, omitir o reagrupar campos — no son un espejo de la tabla. Los tipos `$infer*` son el shape de persistencia, interno a db y sus adaptadores.
- **`drizzle-zod` solo para validaciones internas de db** si hacen falta (p. ej. validar un `jsonb` antes de insertar). Jamás se exporta un schema de drizzle-zod como contrato público: acoplaría la API a la tabla y un `ALTER TABLE` se convertiría en breaking change del frontend.

## 3. Migraciones

Flujo único: editar schema → `drizzle-kit generate` → SQL committeado en `packages/db/drizzle/` → `migrate()` con lock en el arranque de web. El SQL committeado ES la historia: se revisa como cualquier código.

```ts
// apps/web/src/server/migrate.ts — se invoca UNA vez en el arranque
import path from 'node:path';
import { createRequire } from 'node:module';
import { Client } from 'pg';
import { drizzle } from 'drizzle-orm/node-postgres';
import { migrate } from 'drizzle-orm/node-postgres/migrator';

const MIGRATION_LOCK_KEY = 724_100; // constante propia del proyecto; distinta de la del harness de tests

export async function runMigrations(connectionString: string): Promise<void> {
  const client = new Client({ connectionString });
  await client.connect();
  try {
    // Advisory lock de sesión: si dos procesos arrancan a la vez (deploy,
    // restart de compose), solo uno migra; el otro espera y encuentra el
    // schema ya al día. Sin lock: migraciones concurrentes = corrupción.
    await client.query('SELECT pg_advisory_lock($1)', [MIGRATION_LOCK_KEY]);
    const require = createRequire(import.meta.url);
    await migrate(drizzle(client), {
      // Resuelta respecto al paquete, NUNCA process.cwd() (mismo criterio que el harness de testing)
      migrationsFolder: path.join(path.dirname(require.resolve('@app/db/package.json')), 'drizzle'),
    });
  } finally {
    await client.query('SELECT pg_advisory_unlock($1)', [MIGRATION_LOCK_KEY]);
    await client.end();
  }
}
```

Reglas no negociables:

- **`drizzle-kit push` PROHIBIDO** fuera de prototipado local sin datos: aplica el schema sin dejar historia y puede dropear columnas para "cuadrar" — en un entorno desplegado eso es pérdida de datos sin rastro.
- **Conflicto de ramas → regenerar limpia**: borra tu migración no mergeada, rebasa sobre main y vuelve a `drizzle-kit generate`. NUNCA edites a mano el journal ni renumeres SQLs ya aplicados en algún entorno.
- **`drizzle-kit check` como paso del gate** cuando pueda haber migraciones generadas en paralelo: detecta colisiones antes de que lleguen a una BD.
- **Cada migración se prueba contra el testcontainer**: el globalSetup de la skill `testing` aplica TODAS las migraciones a la template database en cada run — una migración rota aborta la suite entera, rápido y en un solo sitio. Lo que la migración *promete* (UNIQUE parciales, enums, `ON DELETE`) lleva además su test explícito.

## 4. Repos: funciones por agregado, executor como primer argumento

Un fichero por agregado (`orders.repo.ts`, `users.repo.ts`…) con funciones que reciben el executor como PRIMER argumento. Así la misma función corre sobre la conexión o dentro de una transacción — es lo que permite componer repos bajo un solo `db.transaction`.

El alias `Db` (conexión | transacción) se exporta UNA vez desde db; el tipo de la tx se **deriva** del callback de `transaction()` para no depender de los generics internos de `PgTransaction`, que cambian entre versiones de Drizzle:

```ts
// packages/db/src/client.ts
import { drizzle, type NodePgDatabase } from 'drizzle-orm/node-postgres';
import { Pool } from 'pg';
import * as schema from './schema'; // el barrel incluye schema/relations.ts (§7)

export type DbClient = NodePgDatabase<typeof schema>;
export type DbTx = Parameters<Parameters<DbClient['transaction']>[0]>[0];
export type Db = DbClient | DbTx;

/** Bajo nivel: quien posee el pool (el worker, si existe) lo pasa y lo cierra él en el shutdown. */
export function makeDb(pool: Pool): DbClient {
  return drizzle(pool, { schema });
}

/** Conveniencia: pool interno. Es lo que usan el accessor getDb() de web y los tests que abren conexiones propias. */
export function createDb(connectionString: string): DbClient {
  return makeDb(new Pool({ connectionString }));
}
```

```ts
// packages/db/src/repos/orders.repo.ts
import { and, asc, eq, inArray, lte, sql } from 'drizzle-orm';
import type { Db } from '../client';
import { order, type Order, type NewOrder } from '../schema/orders';

// Mutación serializada bajo lock de fila (patrón withTransaction, architecture.md §2).
export async function findOrderForUpdate(tx: Db, id: string): Promise<Order | undefined> {
  const [row] = await tx.select().from(order).where(eq(order.id, id)).for('update');
  return row;
}

export async function updateOrder(tx: Db, id: string, patch: Partial<NewOrder>): Promise<Order> {
  const [row] = await tx.update(order).set(patch).where(eq(order.id, id)).returning();
  if (!row) throw new Error(`order ${id} no existe`); // el servicio de core lo mapea a AppError
  return row;
}

// Patrón de barrido por lotes (crons/sweepers): skipLocked evita bloquearse con
// mutaciones en vuelo — la fila lockeada se procesa en la siguiente pasada.
export async function claimExpirable(tx: Db, limit = 50): Promise<Order[]> {
  return tx.select().from(order)
    .where(and(inArray(order.status, ['draft']), lte(order.updatedAt, sql`now() - interval '30 days'`)))
    .orderBy(asc(order.id)) // orden determinista de locks: previene deadlocks
    .limit(limit)
    .for('update', { skipLocked: true });
}
```

**Nada de generic repository ni active record.** Cada query es explícita y existe para un caso de uso con nombre: los `findAll/save` genéricos esconden justo el SQL que importa aquí (`FOR UPDATE`, `RETURNING`, `ON CONFLICT`, `skipLocked`) e invitan a N+1. Un repo nuevo empieza con la query que necesitas hoy, no con un CRUD por si acaso. Tests: roundtrip real contra el clon de Testcontainers (skill `testing`).

## 5. Adaptadores de puertos

`packages/core` define los puertos (`OrderStore`, `WithTransaction`, `JobQueue` si hay cola…); db los implementa envolviendo repos. La dirección manda: **el adaptador habla los tipos de los contratos de core**, no expone filas Drizzle — a menudo el mapeo es identidad estructural, pero cuando diverjan se convierte aquí, nunca en core.

```ts
// packages/db/src/adapters/order-store.ts
import type { OrderStore } from '@app/core/orders';
import type { Db } from '../client';
import * as orders from '../repos/orders.repo';

// Implementa EXACTAMENTE el puerto de architecture.md §2 (se amplía cuando el puerto crezca).
// Funciona igual con conexión o tx: los repos aceptan la unión Db.
export function makeOrderStore(db: Db): OrderStore {
  return {
    findForUpdate: async (id) => (await orders.findOrderForUpdate(db, id)) ?? null, // el puerto habla null, no undefined
    update: (id, patch) => orders.updateOrder(db, id, patch),
  };
}
```

`makeWithTransaction` implementa el puerto `WithTransaction` de core: abre la tx de Drizzle y entrega los stores **tx-scoped** — core compone la transacción sin saber que Drizzle existe:

```ts
// packages/db/src/adapters/with-transaction.ts
import { sql } from 'drizzle-orm';
import type { WithTransaction } from '@app/core/orders';
import type { DbClient } from '../client';
import { makeOrderStore } from './order-store';

export function makeWithTransaction(db: DbClient /*, boss: PgBoss — solo si módulo cola */): WithTransaction {
  return (fn) =>
    db.transaction(async (tx) => fn({
      orders: makeOrderStore(tx),
      // solo si módulo cola: jobs: makeTxJobQueue(boss, tx) — INSERT del job dentro de ESTA tx (jobs.md §5)
      // solo si módulo SSE:
      // events: { notify: async (id) => { await tx.execute(sql`SELECT pg_notify('app_events', ${id})`) } },
      //   → pg_notify (no NOTIFY a pelo): acepta el payload parametrizado; se ENTREGA al commit, nunca antes.
      // TxStores crece con el dominio: se añade el store al puerto y aquí, en el mismo PR.
    }));
}
```

Las apps cablean esto en su composition root (`apps/web/src/server/context.ts`; `apps/worker/src/bootstrap.ts` si existe); los tests de integración cablean lo mismo contra el clon de Testcontainers — idéntico código, distinta conexión.

## 6. Mutaciones transaccionales vistas desde SQL

Lo que una mutación con invariantes de concurrencia (y en particular el `transition()` de un orquestador, si tu proyecto tiene uno) ejecuta contra Postgres, en UNA transacción:

```sql
BEGIN;
SELECT * FROM "order" WHERE id = $1 FOR UPDATE;       -- 1) lock de fila; el estado se revalida BAJO el lock
-- 2) validar la mutación: lógica PURA de core; ilegal ⇒ throw ⇒ ROLLBACK
UPDATE "order" SET status = $next, updated_at = … WHERE id = $1;
INSERT INTO pgboss.job (name, data, …) VALUES (…);    -- 3) solo si módulo cola: MISMA tx (adaptador {db}: jobs.md)
SELECT pg_notify('app_events', $id);                   -- 4) solo si módulo SSE: se ENTREGA en COMMIT
COMMIT;
```

Por qué cada pieza:

- **FOR UPDATE + revalidación bajo el lock**: dos procesos (dos requests, o un webhook y un consumer) llegan a la vez; el perdedor, al desbloquearse, ve el estado ya cambiado y falla limpio con un `AppError` tipado — exactamente una aplicación de la mutación.
- **Job en la MISMA tx** (si hay cola): post-commit, un crash entre UPDATE y encolado deja trabajo pendiente que nadie ejecuta; pre-commit sin tx compartida, un rollback deja jobs fantasma. La atomicidad es lo innegociable.
- **`pg_notify` transaccional** (si hay SSE): NOTIFY solo se entrega en COMMIT — un rollback silencia el evento automáticamente, sin código de compensación.
- **Rollback total en ilegal**: la fila queda byte a byte idéntica (ni `updated_at`), cero jobs, cero NOTIFY — el orden validar-antes-de-escribir lo garantiza y su test lo verifica.
- **NUNCA un FOR UPDATE abierto durante una llamada HTTP externa.** Trabajo externo = **dos transacciones cortas**: tx1 persiste la intención y commitea; la llamada HTTP corre SIN transacción; tx2 persiste el resultado. Un lock abierto durante segundos de red serializa el sistema entero contra la latencia de un proveedor.
- **Locks múltiples siempre en orden determinista por id**: órdenes distintos en transacciones cruzadas = deadlock `40P01`.

## 7. Relational queries para read models

Las lecturas compuestas (un agregado con sus hijos para la API o para el evento `snapshot` del SSE) usan las relational queries — una query, shape anidado, sin joins a mano:

```ts
// packages/db/src/repos/orders.repo.ts
export async function getOrderSnapshot(db: Db, orderId: string) {
  return db.query.order.findFirst({
    where: eq(order.id, orderId),
    with: {
      items: { orderBy: (i, { asc }) => [asc(i.createdAt)] },
    },
  });
}
```

- **Escrituras: SIEMPRE query builder + tx.** Las relational queries son de lectura y no expresan `FOR UPDATE`, `RETURNING` ni `ON CONFLICT` — todo lo que las mutaciones necesitan.
- **Nota de barrel**: `schema/relations.ts` se re-exporta también en `schema/index.ts` — es lo que hace que `drizzle(pool, { schema })` conozca las relaciones y `db.query.*` funcione con el mismo barrel.
- **Nota de versión**: en Drizzle 0.x las relaciones se declaran con `relations()` (en `schema/relations.ts`); Drizzle 1.0 las sustituye por `defineRelations` con otra API de filtros. Por eso el RQB queda **encapsulado en repos**: los consumidores llaman `getOrderSnapshot(db, id)` y un upgrade de Drizzle se paga en un solo fichero, no filtrado por core y las apps. Ante la duda de sintaxis exacta: skill `postgres-drizzle` o Context7.

## 8. Índices y constraints con intención

Regla: cada índice existe para una query o invariante con nombre — un índice "por si acaso" es coste de escritura sin retorno. Cada uno lleva su test de integración (skill `testing`). Patrones canónicos (los casos concretos los define tu PRD):

| Patrón | Cuándo lo necesitas | Test |
|---|---|---|
| UNIQUE sobre el id externo del proveedor (p. ej. `provider_request_id`) | Idempotencia de webhooks: el proveedor reintenta la entrega; el segundo INSERT choca (23505) y el handler hace no-op en vez de duplicar | Insert duplicado rechaza |
| UNIQUE **parcial** (`WHERE col IS NOT NULL` o por estados activos) | Invariante que solo aplica a un subconjunto: "un X activo por Y", "único cuando existe" — NULL no colisiona; dos procesos concurrentes chocan con la constraint, no con la suerte | Ambos casos, explícitos |
| GIN sobre columnas `text[]`/`jsonb` facetadas | Búsqueda facetada con `@>`; sin GIN es seq scan en cuanto la tabla crece | EXPLAIN con volumen sintético + corrección del resultado |
| UNIQUE compuesto para upserts periódicos (`(entity_id, date)`) | Un sync/cron que upsertea (`ON CONFLICT`) — re-ejecutarlo no duplica filas | Upsert idempotente contra el clon |
| Índice sobre la columna de la query caliente (rango de fechas, FK muy leída) | La query existe y se ejecuta a menudo; el índice tiene dueño | Lookup del repo |

Declaración en el schema (mismo fichero que la tabla):

```ts
// esquema del patrón UNIQUE parcial
export const account = pgTable('account', {
  id: ulidPk(),
  domain: text('domain'), // nullable: el invariante solo aplica cuando existe
  // …
}, (t) => [
  uniqueIndex('account_domain_uq').on(t.domain).where(sql`${t.domain} IS NOT NULL`),
]);
```

Los UNIQUE parciales y los `ON DELETE` son exactamente lo que puede divergir entre el schema TS y el SQL migrado — por eso su comportamiento observable se fija con tests de integración, no se supone.

## 9. Qué NO va aquí

- **Harness de Testcontainers** (template database, pitfalls de pools) y los patrones de test de migraciones/repos/índices → skill `testing` (fuente de verdad; no dupliques ni un snippet).
- **Colas pg-boss** (si el módulo existe): `defineJob`, creación de colas, el adaptador `{ db }` del encolado transaccional, consumers, retries, cron, shutdown → `references/jobs.md`.
- **Dónde vive una pieza** (puertos, módulos de core, contratos Zod públicos, composition roots) → `references/architecture.md`.
- **Accessors `getDb()`/`setDbForTests()` de apps/web**, route handlers y envelope de errores → `references/api.md`.
- **SQL genérico de Postgres** (diseño de queries, locking avanzado) → skill `supabase-postgres-best-practices`; dudas de API Drizzle 0.x vs 1.0 → skill `postgres-drizzle` + Context7.
