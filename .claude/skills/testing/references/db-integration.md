# Integración con Postgres real (Testcontainers)

Esta capa cubre los tests de integración de `packages/db` — migraciones Drizzle, constraints, repos tipados, índices — y provee el harness de BD que reutiliza cualquier otro paquete que necesite Postgres de verdad (los tests transaccionales del worker con `SELECT … FOR UPDATE` y `LISTEN/NOTIFY`, si el módulo existe, se montan sobre este mismo harness).

La decisión es vinculante y no se reabre: **nada de mocks de BD ni SQLite**. El producto depende de comportamiento específico de Postgres 16 — `FOR UPDATE`, `NOTIFY`, enums nativos, índices UNIQUE parciales, GIN, JSONB, `ON DELETE` — y un doble de test no falla donde Postgres falla. Un test que pasa aquí se comporta igual en el VPS, porque es el mismo motor.

## Tabla de contenidos

1. [Diseño: un contenedor, una template, N clones](#diseño)
2. [globalSetup: un contenedor por run (singleton con refcount)](#globalsetup)
3. [`createTestDatabase()`: un clon aislado por suite](#createtestdatabase)
4. [Uso en una suite](#uso)
5. [Tests de migraciones](#migraciones)
6. [Tests de repos tipados](#repos)
7. [Índices con EXPLAIN](#indices)
8. [Pitfalls](#pitfalls)
9. [Checklist](#checklist)

<a name="diseño"></a>
## 1. Diseño: un contenedor, una template, N clones

```
globalSetup (singleton con refcount: 1 contenedor por run)
  └─ postgres:16 (Testcontainer)
       ├─ app_template  ← migraciones Drizzle aplicadas; datallowconn=false
       └─ test_a1b2c3, test_d4e5f6, …  ← CREATE DATABASE … TEMPLATE app_template
            (uno por suite, creado por createTestDatabase() en beforeAll)
```

**Por qué template database y no TRUNCATE entre tests:**

- **Paralelismo**: vitest ejecuta los ficheros de test en workers paralelos. Con una única BD compartida + TRUNCATE, los workers se pisan (o te obligan a `maxWorkers=1`, que multiplica el tiempo de CI). Con un clon por suite, el aislamiento es por construcción y el paralelismo es gratis.
- **Velocidad**: `CREATE DATABASE … TEMPLATE` es una copia a nivel de ficheros (decenas de ms). Re-ejecutar migraciones por suite costaría segundos; TRUNCATE exige mantener la lista de tablas al día y resetear secuencias a mano.
- **Fidelidad**: cada clon nace exactamente en el estado "post-migraciones sobre BD limpia". Eso re-verifica implícitamente la verificación de la tarea de migraciones en cada run: si una migración se rompe, el globalSetup falla y el run entero aborta con el error de Drizzle, rápido y en un solo sitio.

<a name="globalsetup"></a>
## 2. globalSetup: un contenedor por run (singleton con refcount)

El globalSetup vive en `packages/test-utils/src/global-setup.ts` (subpath `@app/test-utils/global-setup`) y se declara **en cada `vitest.config.integration.ts`** — los proyectos unit NO lo declaran, así que jamás arrancan el contenedor. Vitest ejecuta todos los globalSetup en el proceso principal (misma caché de módulos), de modo que el módulo mantiene un **singleton con refcount**: el primer setup arranca el contenedor, los siguientes lo reutilizan, cada teardown decrementa y el último llama a `stop()` — un solo contenedor por run aunque varios proyectos tengan tests de integración. Expone la connection string vía `provide`/`inject` (nunca vía env: así es imposible que un test apunte por accidente a la BD de desarrollo).

```ts
// packages/db/vitest.config.integration.ts (mismo patrón en cada paquete con integración)
import { defineConfig } from 'vitest/config';

export default defineConfig({
  test: {
    name: 'db:integration',
    include: ['test/integration/**/*.test.ts'],
    exclude: ['**/*.live.test.ts'],
    globalSetup: ['@app/test-utils/global-setup'],
  },
});
```

```ts
// packages/test-utils/src/postgres-container.ts
import { createRequire } from 'node:module';
import path from 'node:path';
import { PostgreSqlContainer } from '@testcontainers/postgresql';
import { Client } from 'pg';
import { drizzle } from 'drizzle-orm/node-postgres';
import { migrate } from 'drizzle-orm/node-postgres/migrator';

export const TEMPLATE_DB = 'app_template';

export async function startPostgresContainer(): Promise<{
  serverUri: string;  // conexión al servidor (BD de mantenimiento `postgres`)
  templateDb: string; // template ya migrada
  stop: () => Promise<void>;
}> {
  const container = await new PostgreSqlContainer('postgres:16')
    .withDatabase('postgres') // la conexión admin va a la BD de mantenimiento
    .withEnvironment({ TZ: 'UTC', PGTZ: 'UTC' })
    // Datos desechables: sin fsync todo el run va notablemente más rápido.
    .withCommand([
      'postgres',
      '-c', 'fsync=off',
      '-c', 'synchronous_commit=off',
      '-c', 'full_page_writes=off',
    ])
    .start();

  const serverUri = container.getConnectionUri();

  // 1) Crear la template y aplicarle las migraciones reales del producto.
  const admin = new Client({ connectionString: serverUri });
  await admin.connect();
  await admin.query(`CREATE DATABASE ${TEMPLATE_DB}`);

  const migrator = new Client({
    connectionString: withDatabaseName(serverUri, TEMPLATE_DB),
  });
  await migrator.connect();
  // Ruta resuelta respecto al paquete @app/db, NUNCA process.cwd(): los
  // scripts por paquete ejecutan vitest desde el directorio del paquete.
  const require = createRequire(import.meta.url);
  await migrate(drizzle(migrator), {
    migrationsFolder: path.join(
      path.dirname(require.resolve('@app/db/package.json')),
      'drizzle',
    ),
  });
  // 2) CERRAR la conexión: CREATE DATABASE … TEMPLATE exige CERO conexiones
  //    activas a la BD origen. Un pool abierto aquí rompe todos los clones.
  await migrator.end();

  // 3) Blindaje contra conexiones accidentales (el mismo truco que template0):
  //    una BD con datallowconn=false sigue siendo clonable como template.
  await admin.query(
    `UPDATE pg_database SET datallowconn = false WHERE datname = '${TEMPLATE_DB}'`,
  );
  await admin.end();

  return {
    serverUri,
    templateDb: TEMPLATE_DB,
    stop: async () => {
      await container.stop();
    },
  };
}

export function withDatabaseName(uri: string, dbName: string): string {
  const url = new URL(uri);
  url.pathname = `/${dbName}`;
  return url.toString();
}
```

```ts
// packages/test-utils/src/global-setup.ts
// Compartido por TODOS los vitest.config.integration.ts. Vitest ejecuta los
// globalSetup en el proceso principal (misma caché de módulos), así que el
// singleton con refcount de este módulo funciona entre proyectos.
// Nota: según la versión de Vitest el tipo del argumento se llama
// GlobalSetupContext o TestProject; ambos exponen provide(). Ajusta el import
// al actualizar Vitest en vez de copiar esta firma a ciegas.
import type { GlobalSetupContext } from 'vitest/node';
import { startPostgresContainer } from './postgres-container';

let harnessPromise: ReturnType<typeof startPostgresContainer> | undefined;
let refs = 0;

export default async function globalSetup({ provide }: GlobalSetupContext) {
  harnessPromise ??= startPostgresContainer(); // el primero arranca; el resto reutiliza
  refs += 1;
  const harness = await harnessPromise;
  provide('pgServerUri', harness.serverUri);
  provide('pgTemplateDb', harness.templateDb);
  // El teardown devuelto se ejecuta al terminar cada proyecto: el último
  // refcount es quien para el contenedor.
  return async () => {
    refs -= 1;
    if (refs === 0) {
      await harness.stop();
      harnessPromise = undefined;
    }
  };
}

declare module 'vitest' {
  export interface ProvidedContext {
    pgServerUri: string;
    pgTemplateDb: string;
  }
}
```

<a name="createtestdatabase"></a>
## 3. `createTestDatabase()`: un clon aislado por suite

```ts
// packages/test-utils/src/create-test-database.ts
import { randomBytes } from 'node:crypto';
import { inject } from 'vitest';
import { Client, Pool } from 'pg';
import { drizzle, type NodePgDatabase } from 'drizzle-orm/node-postgres';
import * as schema from '@app/db/schema';
import { withDatabaseName } from './postgres-container';

export type DrizzleDb = NodePgDatabase<typeof schema>;

export interface TestDatabase {
  db: DrizzleDb;
  pool: Pool;
  connectionString: string;
  close: () => Promise<void>;
}

// Clave arbitraria pero fija: serializa los CREATE DATABASE … TEMPLATE.
const CLONE_LOCK_KEY = 724_001;

/**
 * Clona la template en una BD nueva y aislada (~decenas de ms: copia de
 * ficheros, no re-migración). Dentro de vitest no pases serverUri/templateDb:
 * se leen vía inject(), nunca de env. Los overrides existen para scripts
 * FUERA de vitest (p. ej. apps/web/scripts/e2e-stack.ts).
 */
export async function createTestDatabase(opts?: {
  label?: string;      // opcional: visible en pg_stat_activity (debugging)
  serverUri?: string;  // override para scripts fuera de vitest
  templateDb?: string;
}): Promise<TestDatabase> {
  const serverUri = opts?.serverUri ?? inject('pgServerUri');
  const templateDb = opts?.templateDb ?? inject('pgTemplateDb');
  const name = `test_${randomBytes(6).toString('hex')}`;

  const admin = new Client({ connectionString: serverUri });
  await admin.connect();
  // Postgres no permite clonar una template mientras otra clonación la tiene
  // abierta, y los workers paralelos de vitest clonan a la vez: el advisory
  // lock serializa el CREATE y el retry cubre sesiones rezagadas (55006).
  await admin.query(`SELECT pg_advisory_lock(${CLONE_LOCK_KEY})`);
  try {
    for (let attempt = 1; ; attempt++) {
      try {
        // Identificadores generados aquí mismo (hex), jamás input externo:
        // la interpolación en el DDL es segura (CREATE DATABASE no acepta $1).
        await admin.query(`CREATE DATABASE ${name} TEMPLATE ${templateDb}`);
        break;
      } catch (err) {
        if ((err as { code?: string }).code !== '55006' || attempt >= 5) throw err;
        await new Promise((r) => setTimeout(r, 100 * attempt));
      }
    }
  } finally {
    await admin.query(`SELECT pg_advisory_unlock(${CLONE_LOCK_KEY})`);
  }

  const connectionString = withDatabaseName(serverUri, name);
  const pool = new Pool({
    connectionString,
    max: 5,
    // Visible en pg_stat_activity: es la pista nº1 para cazar la suite
    // que filtró una conexión (ver pitfalls).
    application_name: opts?.label ?? 'app-test-db',
  });
  const db = drizzle(pool, { schema });

  return {
    db,
    pool,
    connectionString,
    close: async () => {
      await pool.end(); // 1) soltar nuestras conexiones
      // 2) WITH (FORCE) (PG13+) mata sesiones filtradas: un leak dentro de la
      //    suite no bloquea la limpieza ni deja BDs zombis en el contenedor.
      await admin.query(`DROP DATABASE IF EXISTS ${name} WITH (FORCE)`);
      await admin.end();
    },
  };
}
```

<a name="uso"></a>
## 4. Uso en una suite

Ubicación: `test/integration/**/*.test.ts` dentro de cada paquete; se ejecutan con `pnpm test:integration` (y dentro de `pnpm test`). Granularidad por defecto: **una BD por fichero** (`beforeAll`) — dentro de un fichero los tests corren en serie y controlas el estado. Baja a una BD por test (`beforeEach`) solo cuando los tests se destruyen datos entre sí o usas `describe.concurrent`; cuesta ~decenas de ms por clon, así que no lo hagas por inercia.

```ts
// packages/db/test/integration/example.test.ts
import { beforeAll, afterAll, describe, it, expect } from 'vitest';
import { createTestDatabase, type TestDatabase } from '@app/test-utils';

let tdb: TestDatabase;

beforeAll(async () => {
  tdb = await createTestDatabase({ label: 'example.test.ts' });
});

afterAll(async () => {
  await tdb.close(); // OBLIGATORIO: sin esto el proceso de vitest no termina
});
```

<a name="migraciones"></a>
## 5. Tests de migraciones

Que la migración *aplique* ya lo garantiza el globalSetup. Lo que hay que testear explícitamente es lo que la migración **promete**: constraints, enums y política de borrado. Por qué: el schema Drizzle (TypeScript) y el SQL migrado pueden divergir — los índices UNIQUE parciales y los `ON DELETE` se declaran a mano — y un test fija el comportamiento observable para que un cambio accidental rompa un test, no producción.

```ts
// packages/db/test/integration/account.constraints.test.ts
import { beforeAll, afterAll, describe, it, expect } from 'vitest';
import { createTestDatabase, makeAccount, type TestDatabase } from '@app/test-utils';
import { account } from '@app/db/schema';

let tdb: TestDatabase;
beforeAll(async () => { tdb = await createTestDatabase({ label: 'account' }); });
afterAll(async () => { await tdb.close(); });

describe('account: UNIQUE parcial sobre domain', () => {
  it('admite N filas con domain NULL', async () => {
    // Fija el comportamiento, no la implementación: da igual si mañana el
    // índice pasa de parcial a UNIQUE NULLS DISTINCT — esto debe seguir pasando.
    await tdb.db.insert(account).values([
      makeAccount({ domain: null }),
      makeAccount({ domain: null }),
    ]);
  });

  it('rechaza la segunda fila con el mismo domain', async () => {
    await tdb.db.insert(account).values(makeAccount({ domain: 'acme.com' }));
    await expect(
      tdb.db.insert(account).values(makeAccount({ domain: 'acme.com' })),
    ).rejects.toThrow(/duplicate key value/); // SQLSTATE 23505
  });

  it('rechaza un valor fuera del enum', async () => {
    await expect(
      tdb.db.insert(account).values(makeAccount({ source: 'nope' as never })),
    ).rejects.toThrow(/invalid input value for enum/);
  });
});
```

Para las FKs, asserta **la política elegida en la migración** (exige `ON DELETE` explícito en todas):

```ts
it('borrar el padre se comporta como declara la migración', async () => {
  const [parent] = await tdb.db.insert(parentTable).values(makeParent()).returning();
  await tdb.db.insert(childTable).values(makeChild({ parentId: parent.id }));

  // Si la migración declara CASCADE:
  await tdb.db.delete(parentTable).where(eq(parentTable.id, parent.id));
  expect(await tdb.db.select().from(childTable)).toHaveLength(0);
  // Si declara RESTRICT, invierte el assert: el delete debe rechazar (23503).
});
```

<a name="repos"></a>
## 6. Tests de repos tipados

Los repos concentran el SQL real: `RETURNING`, `ON CONFLICT` (upserts), round-trip de JSONB, defaults y enums. El sistema de tipos no detecta un mapeo camelCase↔snake_case roto ni un default que solo existe en la BD — por eso el roundtrip se hace contra Postgres, no contra un stub.

```ts
// packages/db/test/integration/project-repo.test.ts
describe('projectRepo', () => {
  it('create/get hace roundtrip completo (defaults, enums, timestamps)', async () => {
    const repo = createProjectRepo(tdb.db);
    const created = await repo.create(makeProject({ name: 'Demo' }));
    const fetched = await repo.getById(created.id);
    // RETURNING y SELECT deben devolver exactamente la misma forma:
    expect(fetched).toEqual(created);
    expect(fetched?.locale).toBe('es'); // default aplicado por la BD
  });
});
```

Regla: los repos reciben `db` inyectado (el del harness) y **nunca** abren su propio pool — un pool propio es una conexión que el harness no puede cerrar (ver pitfalls).

<a name="indices"></a>
## 7. Índices con EXPLAIN

Cuando una tarea promete que una query caliente usa un índice (GIN, parcial, compuesto), hay dos estrategias, y conviene entender qué prueba cada una:

- **Volumen sintético (preferida)**: con ≥1.000 filas y estadísticas frescas, el planner elige el índice por coste — pruebas que el índice se usa *en condiciones realistas*.
- **`SET LOCAL enable_seqscan = off`**: fuerza al planner. Solo prueba que el índice *existe y es utilizable* con el operador (p. ej. `@>` casa con la operator class del GIN). Útil como test barato de humo; más débil.

```ts
it('usa Bitmap Index Scan sobre el GIN y devuelve exactamente lo esperado', async () => {
  const N = 1500;
  // seedRow(i) determinista: el test puede calcular cuántas filas espera el filtro
  await tdb.db.insert(items).values(Array.from({ length: N }, (_, i) => seedRow(i)));
  // Sin ANALYZE el planner decide con estadísticas vacías: falso negativo típico.
  await tdb.db.execute(sql`ANALYZE items`);

  const plan = await tdb.db.execute(sql`
    EXPLAIN (FORMAT JSON)
    SELECT id FROM items WHERE tags @> ARRAY['hot']
  `);
  expect(JSON.stringify(plan.rows)).toMatch(/Bitmap Index Scan/);

  // El plan no basta: asserta también la corrección del resultado.
  const hits = await tdb.db.execute(sql`SELECT id FROM items WHERE tags @> ARRAY['hot']`);
  const expected = Array.from({ length: N }, (_, i) => seedRow(i))
    .filter((r) => r.tags.includes('hot')).length;
  expect(hits.rows).toHaveLength(expected);
});

it('variante barata: el índice es utilizable (enable_seqscan=off)', async () => {
  // SET LOCAL dentro de una transacción: con un Pool, dos execute() sueltos
  // pueden ir por conexiones distintas y el SET no aplicaría al EXPLAIN.
  await tdb.db.transaction(async (tx) => {
    await tx.execute(sql`SET LOCAL enable_seqscan = off`);
    const plan = await tx.execute(sql`EXPLAIN (FORMAT JSON) SELECT id FROM items WHERE tags @> ARRAY['hot']`);
    expect(JSON.stringify(plan.rows)).toMatch(/Bitmap Index Scan/);
  });
});
```

<a name="pitfalls"></a>
## 8. Pitfalls

**Pools sin cerrar → run que no termina.** Cualquier `Pool`/`Client` abierto mantiene vivo el proceso de Node: los tests pasan, y vitest se queda colgado al final (o avisa de "close timed out"). Regla mecánica: cada `createTestDatabase()` en `beforeAll` tiene su `await tdb.close()` en `afterAll`, sin excepciones; y nadie fuera del harness abre conexiones (repos y helpers reciben `db` inyectado).

**Cómo debuggear un test colgado por conexión abierta.** En orden:
1. `pnpm vitest run --reporter=hanging-process` — reporter oficial de Vitest que lista los handles que impiden salir (verás los sockets de pg).
2. Con el contenedor aún vivo, conéctate con la `serverUri` y pregunta a Postgres quién sigue ahí:
   ```sql
   SELECT datname, application_name, state,
          now() - state_change AS idle_for, left(query, 60) AS last_query
   FROM pg_stat_activity
   WHERE datname LIKE 'test_%';
   ```
   El `application_name` (el `label` que pasaste a `createTestDatabase`) te dice **qué suite** filtró la conexión — por eso, aunque el `label` es opcional en la firma, en la práctica conviene ponerlo siempre.
3. El `DROP … WITH (FORCE)` del `close()` ya mata sesiones filtradas dentro de la propia suite; si aun así cuelga, busca un pool creado fuera del harness (el sospechoso habitual: un módulo que instancia su propio `Pool` a nivel de import).

**Paralelismo de workers.** Vitest paraleliza *ficheros*. No compartas jamás estado de BD entre ficheros (singletons a nivel de módulo en test-utils, caches de conexión): cada fichero debe poder correr en cualquier worker, en cualquier orden. Si aparece flakiness, la respuesta es aislar mejor (BD por test), nunca `maxWorkers=1` — eso esconde el bug de estado compartido y multiplica el tiempo de CI. Dentro de un fichero, `describe.concurrent` + una sola BD = tests que se pisan: usa BD por test ahí.

**Timezone y locale del contenedor.** El harness fija `TZ=UTC`; la locale es la de la imagen oficial (no la de tu máquina ni la del VPS). Consecuencias prácticas: usa siempre `timestamptz` y compara instantes (ISO/epoch), nunca strings formateados con la zona local; no escribas asserts de `ORDER BY` sobre texto con acentos/ñ — la collation por defecto ordena distinto que `es_ES` — salvo que la migración fije la collation explícitamente (`COLLATE`), en cuyo caso testéala aquí precisamente por eso.

**`source database "app_template" is being accessed by other users`.** Significa que alguien está conectado a la template en el momento de clonar. Causas típicas: el pool de migraciones del globalSetup no se cerró, alguien apuntó una connection string a la template, o dos workers paralelos intentaron clonar la template a la vez (Postgres tampoco permite clonaciones concurrentes). El harness lo previene con el orden migrar → **cerrar** → `datallowconn=false` y serializando el `CREATE DATABASE` con `pg_advisory_lock` + retry en `createTestDatabase()`; si tocas cualquiera de las dos piezas, conserva ese diseño.

**Los tests ignoran `DATABASE_URL` por diseño.** Dentro de vitest, `createTestDatabase()` lee de `inject()`; los overrides `serverUri`/`templateDb` existen solo para scripts fuera de vitest (el stack de E2E). No añadas fallbacks a env "por comodidad": ese fallback es exactamente cómo una suite acaba truncando tu BD de desarrollo.

**CI.** Los runners de GitHub Actions (ubuntu) traen Docker: el job de integración ejecuta `pnpm test:integration` tal cual, sin `services:` — Testcontainers gestiona el ciclo de vida del contenedor. El coste fijo (~segundos de arranque + pull de `postgres:16` cacheado) se paga una vez por run gracias al singleton con refcount del globalSetup compartido.

<a name="checklist"></a>
## 9. Checklist

- [ ] ¿Nueva tabla o migración? → test de constraints en `packages/db/test/integration/` que fije UNIQUE (incl. parciales), enums y `ON DELETE` observables.
- [ ] ¿Nuevo repo? → roundtrip real create/get/update + casos de conflicto (`ON CONFLICT`, violaciones UNIQUE) contra el clon.
- [ ] ¿Nuevo índice para una query caliente? → test EXPLAIN con volumen sintético + assert de corrección del resultado.
- [ ] Toda suite: `beforeAll` con `createTestDatabase({ label })` y `afterAll` con `close()` — el `label` es opcional en la firma, pero ponlo siempre (es la pista nº1 de debugging).
- [ ] Datos de prueba vía factories (`makeX()`/`insertX()`) y `seedFixtures(db)` de `@app/test-utils`, nunca literales repetidos: cuando el schema evolucione, se arregla la factory, no cincuenta tests.
