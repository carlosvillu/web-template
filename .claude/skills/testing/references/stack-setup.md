# Stack setup — bootstrap de la infraestructura de testing

Este reference define **cómo se monta la infraestructura de testing del monorepo**: configs, `packages/test-utils` (y su API pública, que todos los demás references consumen), scripts, carpetas, variables de entorno y el orden de bootstrap en F0. Se ejecuta por primera vez en las primeras tareas de F0 y se amplía tarea a tarea. Léelo entero antes de crear el workspace; después, consulta el reference específico de la capa que estés tocando.

**Regla de oro**: la suite estándar (`pnpm test`) es hermética — sin red real (msw con `onUnhandledRequest: 'error'`), sin BD compartida (Testcontainers), sin gastar dinero. Todo lo que rompa esa hermeticidad vive en suites etiquetadas y opt-in (`test:live`, tiers de dominio, gate CUA).

> El scope de paquetes de los ejemplos es `@app/*`; la skill `bootstrap` fija el scope real del proyecto al crearlo.

## Tabla de contenidos

1. [Mapa: tipo de código → tipo de test](#1-mapa-tipo-de-código--tipo-de-test)
2. [Estructura de carpetas](#2-estructura-de-carpetas)
3. [Configs de Vitest y tsconfig](#3-configs-de-vitest-y-tsconfig)
4. [`packages/test-utils`: API pública](#4-packagestest-utils-api-pública)
5. [Playwright y msw](#5-playwright-y-msw)
6. [Scripts pnpm](#6-scripts-pnpm)
7. [Variables de entorno de test](#7-variables-de-entorno-de-test)
8. [Convención `docs/verifications/`](#8-convención-docsverifications)
9. [Orden de bootstrap en F0](#9-orden-de-bootstrap-en-f0)

---

## 1. Mapa: tipo de código → tipo de test

Usa esta tabla como router antes de escribir cualquier test. El criterio de fondo: **el tipo de test lo decide la dependencia más cara que el código necesita de verdad** (nada → unit; Postgres real → integración; binarios de dominio → tier de dominio; navegador → E2E; dinero → live).

| Tipo de código | Tipo de test | Dónde vive | Reference |
|---|---|---|---|
| Lógica pura de `packages/core`: contratos Zod, validadores, transformadores, parsers, cálculos | Unit (Vitest, sin I/O) | co-locado `src/**/*.test.ts` | unit-core.md |
| Outputs deterministas grandes: prompts resueltos, payloads serializados, ficheros de texto generados | Unit + golden files (`UPDATE_GOLDEN=1` regenera) | `test/golden/` junto a la suite que los usa | unit-core.md |
| Repos Drizzle, migraciones, lógica transaccional (`FOR UPDATE`, `NOTIFY`), pg-boss si existe | Integración (Testcontainers, Postgres 16 real) | `test/integration/**/*.test.ts` por paquete | db-integration.md / worker-jobs.md |
| Clientes de APIs externas, webhook handlers, polling fallback | Integración con msw + fixtures grabados | `test/integration/**` + fixtures en `packages/test-utils/fixtures/http/` | external-apis.md |
| Contratos reales contra APIs de pago (deudas `[verificar]`, smoke de modelos) | Live opt-in, presupuesto acotado | `**/*.live.test.ts` | external-apis.md (tier live) |
| UI: páginas, editores, formularios, paneles | E2E Playwright | `apps/web/e2e/**/*.spec.ts` | e2e.md |
| Código que exige binarios/entorno propio (solo si tu dominio lo necesita) | Tier de dominio (Vitest + binarios reales) | carpeta propia, p. ej. `apps/worker/test/<dominio>/` | domain-tier.md |
| Verificación de cierre de cada tarea del planning | Gate CUA (`npx -y agent-browser`) o script/curl observable | evidencia en `docs/verifications/<TASK-ID>/` | cua.md |

**Por qué unit co-locado e integración en carpeta aparte**: el unit test es documentación del módulo (vive a su lado y se ejecuta en milisegundos); el de integración tiene coste de arranque (contenedor, database) y agrupa flujos que cruzan módulos — separarlos por ruta es lo que permite seleccionarlos por proyecto de Vitest sin etiquetas frágiles.

## 2. Estructura de carpetas

```
<repo>/
├── vitest.config.ts                 # raíz: test.projects enumera todos los proyectos de test
├── tsconfig.base.json
├── .env.test                        # committeado: claves falsas, defaults
├── .env.test.local                  # gitignored: claves reales SOLO para test:live
├── docs/verifications/<TASK-ID>/    # evidencia del gate de cada tarea
├── .github/workflows/ci.yml         # lint+typecheck · unit · integration · e2e (ver ci.md)
├── packages/
│   ├── core/
│   │   ├── src/**/*.test.ts         # unit co-locado
│   │   ├── test/integration/        # (cuando lo necesite)
│   │   ├── test/golden/             # golden files
│   │   ├── vitest.config.ts
│   │   └── vitest.config.integration.ts
│   ├── db/
│   │   ├── test/integration/
│   │   └── vitest.config.integration.ts
│   └── test-utils/                  # @app/test-utils — ver §4
└── apps/
    ├── web/
    │   ├── src/**/*.test.ts
    │   ├── test/integration/        # route handlers, SSE, webhooks
    │   ├── e2e/**/*.spec.ts         # Playwright
    │   ├── scripts/e2e-stack.ts     # stack E2E autosuficiente, ejecutado con tsx (ver §5 y e2e.md)
    │   └── playwright.config.ts
    └── worker/                      # SOLO si el módulo worker existe en tu F0
        ├── src/**/*.test.ts
        └── test/integration/        # consumers pg-boss, executors
```

## 3. Configs de Vitest y tsconfig

### 3.1 `vitest.config.ts` (raíz)

Cada paquete aporta un proyecto **unit** (`vitest.config.ts`) y, si toca Postgres, otro **integration** (`vitest.config.integration.ts`). Los proyectos transversales (`live`, tiers de dominio) se definen inline y quedan **vacíos salvo opt-in por env** — así `vitest run` a secas nunca los arrastra. **Ojo**: `vitest.workspace.ts`/`defineWorkspace` está deprecado desde Vitest 3.2 y **eliminado en Vitest 4** — la forma canónica es `test.projects` en la config raíz.

```ts
// vitest.config.ts (raíz del monorepo)
import { defineConfig } from 'vitest/config';

export default defineConfig({
  test: {
    projects: [
      '{packages,apps}/*/vitest.config.ts',
      '{packages,apps}/*/vitest.config.integration.ts',
      // SOLO si el proyecto consume APIs de pago:
      {
        test: {
          name: 'live',
          include: process.env.RUN_LIVE ? ['**/*.live.test.ts'] : [],
          exclude: ['**/node_modules/**'],
          setupFiles: ['@app/test-utils/setup-env'],
          // default export de live-budget: globalSetup que crea el ledger LIVE_BUDGET_LEDGER (§7, external-apis.md)
          globalSetup: ['@app/test-utils/live-budget'],
          testTimeout: 300_000,
        },
      },
      // SOLO si tu dominio necesita un tier propio (ver domain-tier.md):
      // { test: { name: 'worker:media', root: './apps/worker',
      //   include: process.env.RUN_MEDIA ? ['test/media/**/*.test.ts'] : [], … } },
    ],
  },
});
```

### 3.2 Config unit por paquete

```ts
// packages/core/vitest.config.ts
import { defineConfig } from 'vitest/config';

export default defineConfig({
  test: {
    name: 'core:unit',
    include: ['src/**/*.test.ts'],
    // CRÍTICO: *.live.test.ts matchea *.test.ts — exclúyelo SIEMPRE
    // o un `vitest run` normal ejecutará tests que gastan dinero.
    exclude: ['**/*.live.test.ts', '**/node_modules/**'],
    environment: 'node',
    setupFiles: ['@app/test-utils/setup-env'],
  },
});
```

Convención de nombres de proyecto: `<paquete>:unit`, `<paquete>:integration` (`core:unit`, `db:integration`, `web:unit`, `web:integration`…) + los transversales opt-in. Los scripts raíz filtran por wildcard `--project '*:unit'` / `--project '*:integration'`.

**Sin `globals: true`**: importa siempre `describe/it/expect` de `'vitest'`. Un agente que escribe código nuevo se beneficia de imports explícitos (el archivo declara sus dependencias; no hay tipos mágicos que configurar por tsconfig).

### 3.3 Config integration por paquete

```ts
// packages/db/vitest.config.integration.ts
import { defineConfig } from 'vitest/config';

export default defineConfig({
  test: {
    name: 'db:integration',
    include: ['test/integration/**/*.test.ts'],
    exclude: ['**/*.live.test.ts', '**/node_modules/**'],
    environment: 'node',
    setupFiles: ['@app/test-utils/setup-env'],
    globalSetup: ['@app/test-utils/global-setup'],
    testTimeout: 30_000, // crear una database desde template tarda más que un unit
    pool: 'forks',       // proceso por archivo: clientes pg y LISTEN/NOTIFY sin fugas entre suites
  },
});
```

Solo los proyectos integration declaran este `globalSetup` — los unit jamás arrancan el contenedor (velocidad y hermeticidad). Vitest ejecuta el `globalSetup` una vez **por proyecto** que lo declare, pero todos corren en el proceso principal con la **misma caché de módulos**: `global-setup.ts` mantiene un singleton con refcount en scope de módulo (§4.1), así que el contenedor físico arranca **una sola vez por run** — el primer setup lo arranca, los siguientes lo reutilizan y el último teardown llama a `stop()`.

### 3.4 tsconfig de tests

- `tsconfig.base.json` en la raíz (strict, `moduleResolution: bundler`; SIN `paths` entre paquetes — `@app/*` se resuelve por exports map + `workspace:*`, ver skill backend `.claude/skills/backend/`).
- Por paquete: `tsconfig.json` (desarrollo, **incluye** `src/**` y `test/**` — así `pnpm typecheck` cubre los tests y un contrato roto en `packages/core` rompe también las suites que lo usan, que es exactamente la señal que quieres) y `tsconfig.build.json` (`extends` del anterior, **excluye** `**/*.test.ts`, `test/**`, `e2e/**` — los tests nunca se publican en `dist`).

## 4. `packages/test-utils`: API pública

Paquete privado `@app/test-utils`. **Este es el contrato que consumen todos los demás references** — no renombres estos exports.

```
packages/test-utils/
├── package.json
├── src/
│   ├── index.ts                 # re-exporta la API pública
│   ├── setup-env.ts             # carga .env.test(.local) — setupFile universal
│   ├── global-setup.ts          # globalSetup Vitest: contenedor (refcount) + provide
│   ├── postgres-container.ts    # startPostgresContainer()
│   ├── database.ts              # createTestDatabase()
│   ├── factories/               # makeX() puras + insertX(db, …) que insertan (§4.3)
│   ├── seed.ts                  # seedFixtures()
│   ├── msw/                     # useHttpMocks() + server + handlers por proveedor
│   ├── golden.ts                # expectGolden()
│   ├── live-budget.ts           # spendBudget() + globalSetup del ledger live (solo si hay APIs de pago)
│   └── fake-apis.ts             # startFakeExternalApis() para el stack E2E (solo si hay APIs externas)
└── fixtures/
    └── http/                    # respuestas reales grabadas, por proveedor
```

```jsonc
// packages/test-utils/package.json (lo esencial)
{
  "name": "@app/test-utils",
  "private": true,
  "exports": {
    ".": "./src/index.ts",
    "./global-setup": "./src/global-setup.ts",
    "./setup-env": "./src/setup-env.ts",
    "./live-budget": "./src/live-budget.ts",
    "./fake-apis": "./src/fake-apis.ts",
    "./fixtures/*": "./fixtures/*"
  },
  "dependencies": { "@testcontainers/postgresql": "…", "msw": "…", "@app/db": "workspace:*", "@app/core": "workspace:*" }
}
```

Se consume como TypeScript directo (sin build): Vitest lo transpila al vuelo; los scripts fuera de Vitest que lo importan (p. ej. `e2e-stack.ts`, §5) se ejecutan con `tsx`. Depende de `@app/db` (schema + migraciones) y `@app/core` (contratos) — nunca al revés.

### 4.1 `startPostgresContainer()` — globalSetup

```ts
// src/postgres-container.ts
export interface PostgresTestContainer {
  serverUri: string;            // p. ej. postgres://test:test@localhost:54321 — SIN database
  templateDb: string;           // 'app_template': migrada con drizzle, lista para clonar
  stop(): Promise<void>;        // para el contenedor
}
export async function startPostgresContainer(): Promise<PostgresTestContainer>;
```

Implementación (detalle en db-integration.md): arranca `postgres:16` con `@testcontainers/postgresql`, aplica **todas las migraciones de `packages/db`** sobre una database `app_template` y la marca como template. Las rutas de migraciones se resuelven **respecto al paquete `@app/db`** (p. ej. `createRequire(import.meta.url).resolve('@app/db/package.json')` + join a `drizzle/`), **nunca con `process.cwd()`** — los scripts por paquete ejecutan vitest desde el directorio del paquete. **Por qué template database**: aplicar migraciones cuesta segundos; `CREATE DATABASE … TEMPLATE app_template` cuesta milisegundos — cada suite obtiene aislamiento total sin pagar las migraciones.

```ts
// src/global-setup.ts — lo declara CADA vitest.config.integration.ts
import type { GlobalSetupContext } from 'vitest/node';
import { startPostgresContainer, type PostgresTestContainer } from './postgres-container';

declare module 'vitest' {
  interface ProvidedContext { pgServerUri: string; pgTemplateDb: string }
}

// Singleton con refcount en scope de módulo: todos los globalSetup corren en el
// proceso principal (misma caché de módulos), así que el contenedor arranca una
// sola vez por run aunque lo declaren varios proyectos.
let container: Promise<PostgresTestContainer> | undefined;
let refs = 0;

export default async function setup({ provide }: GlobalSetupContext) {
  refs += 1;
  container ??= startPostgresContainer();
  const pg = await container;
  provide('pgServerUri', pg.serverUri);
  provide('pgTemplateDb', pg.templateDb);
  return async () => {
    refs -= 1;
    if (refs === 0) await pg.stop();   // el último teardown apaga el contenedor
  };
}
```

### 4.2 `createTestDatabase()` — una database aislada por suite

```ts
// src/database.ts
export interface TestDatabase {
  db: DrizzleDb;               // drizzle tipado con el schema completo de @app/db
  pool: pg.Pool;               // pool subyacente, para SQL crudo
  connectionString: string;    // para código que abre su propia conexión: pg-boss, LISTEN/NOTIFY, la app entera
  close(): Promise<void>;      // cierra el pool y DROPea la database
}
export async function createTestDatabase(opts?: {
  label?: string;              // opcional: para debugging del nombre de la BD
  serverUri?: string;          // override para scripts FUERA de vitest (p. ej. e2e-stack)
  templateDb?: string;
}): Promise<TestDatabase>;
```

Sin argumentos lee `inject('pgServerUri')`/`inject('pgTemplateDb')` (contexto del globalSetup); los overrides `serverUri`/`templateDb` existen para scripts fuera de Vitest (el stack E2E, §5). Crea `test_<random>` desde la template (serializando el `CREATE DATABASE` con `pg_advisory_lock` sobre la conexión admin + retry: Postgres no permite copias concurrentes de la misma template y los workers paralelos de Vitest chocan sin el lock). **Patrón por defecto: una database por archivo de test** (`beforeAll`/`afterAll`) — aislamiento real que permite paralelismo sin `TRUNCATE` frágiles. Ejemplo canónico:

```ts
import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import { createTestDatabase, makeUser, type TestDatabase } from '@app/test-utils';
import { user } from '@app/db/schema';

describe('user repo', () => {
  let tdb: TestDatabase;
  beforeAll(async () => { tdb = await createTestDatabase(); });
  afterAll(async () => { await tdb.close(); });

  it('inserta y lee un user', async () => {
    await tdb.db.insert(user).values(makeUser({ name: 'Demo' }));
    const rows = await tdb.db.select().from(user);
    expect(rows[0]?.name).toBe('Demo');
  });
});
```

### 4.3 Factories de dominio

Dos familias con nombres distintos — la regla es transversal a todos los references:

- **`makeX(overrides?)`** — puras, síncronas, sin I/O: devuelven un objeto insertable (tipo insert de Drizzle) con defaults válidos, ID nuevo y `Partial<T>` de overrides. No insertan ni resuelven FKs. Sirven igual para un unit (validar un contrato Zod, props de componentes, payloads) que para construir la fila que el test inserta, y su coste es cero. El frontend usa SIEMPRE `makeX`.
- **`insertX(db, overrides?)`** — async: insertan vía `makeX` + Drizzle y devuelven la fila con id. Para integración y seeds de E2E.

Si un ejemplo pasa `db` a una factory e inserta, se llama `insertX`; si construye en memoria, `makeX`.

**Regla de bootstrap**: cada tabla del schema tiene su par `makeX`/`insertX`, creados **en la misma tarea que crea la tabla** (§9). Mantén un índice de factories como tabla en el propio `factories/index.ts` o en un comentario de cabecera: cuando el contrato de una entidad evoluciona, se actualiza la factory una vez y no cincuenta JSON copiados.

### 4.4 `seedFixtures()`

```ts
// src/seed.ts
export interface SeedResult { /* las filas creadas, tipadas por entidad */ }
export async function seedFixtures(db: DrizzleDb, opts?: SeedOptions): Promise<SeedResult>;
```

Inserta un **grafo mínimo coherente** de tu dominio (FKs válidas entre las entidades núcleo, vía las `insertX`) y devuelve las filas creadas. Úsalo cuando el test necesite "un mundo plausible" y no le importe cómo se construyó; si el test ES sobre la construcción, inserta a mano con factories. Define `SeedOptions`/`SeedResult` con las entidades de TU dominio en la tarea de F0 que lo estrene.

### 4.5 msw y golden (exports auxiliares)

```ts
// src/msw/index.ts — detalle completo en external-apis.md
export function useHttpMocks(...overrides: HttpHandler[]): void;
export const server: SetupServerApi; // export secundario: overrides puntuales con server.use(...) dentro de un test
```

Registra `beforeAll/afterEach/afterAll` con un server msw (node) cargado con los handlers por defecto de TODOS los proveedores externos del proyecto, que reproducen fixtures grabados de `fixtures/http/`. `onUnhandledRequest: 'error'` **siempre**: cualquier petición no mockeada en la suite normal es un bug que podría gastar dinero. Los ejemplos usan `useHttpMocks()`; `server` solo aparece para overrides puntuales.

```ts
// src/golden.ts — uso en unit-core.md
export async function expectGolden(actual: string, goldenPath: string | URL): Promise<void>; // async SIEMPRE
// El caller pasa una URL relativa al fichero de test:
// expectGolden(payload, new URL('./golden/caso.json', import.meta.url))
// Internamente se convierte con fileURLToPath — JAMÁS `.pathname` (percent-encoda
// espacios/no-ASCII del path y produce ENOENT falsos; lección aprendida).
// Falla con diff si difiere; solo ENOENT se reporta como "golden ausente" (el resto
// de errores se relanza); regeneración SOLO con UPDATE_GOLDEN=1 (reescribe y pasa).
```

## 5. Playwright y msw

**Playwright** (solo en `apps/web`):

```bash
pnpm --filter @app/web add -D @playwright/test
pnpm --filter @app/web exec playwright install chromium   # solo chromium salvo que el PRD exija cross-browser
```

```ts
// apps/web/playwright.config.ts
import { defineConfig, devices } from '@playwright/test';

export default defineConfig({
  testDir: './e2e',
  // 3100 para no chocar con el dev server de 3000
  use: { baseURL: process.env.E2E_BASE_URL ?? 'http://localhost:3100', trace: 'retain-on-failure' },
  projects: [{ name: 'chromium', use: { ...devices['Desktop Chrome'] } }],
  webServer: {
    command: 'pnpm exec tsx scripts/e2e-stack.ts',
    port: 3100,
    reuseExistingServer: !process.env.CI,
    timeout: 180_000,
  },
});
```

El stack E2E es **autosuficiente**: `scripts/e2e-stack.ts` (TypeScript ejecutado con `tsx` — Node plano no puede importar los `.ts` de `@app/test-utils`; `tsx` es devDependency) arranca su propio testcontainer Postgres vía `startPostgresContainer()`, migra + siembra (`seedFixtures`), arranca `startFakeExternalApis()` si el proyecto tiene APIs externas (`@app/test-utils/fake-apis`: servidor HTTP local que sirve los mismos fixtures grabados que msw — msw no puede interceptar procesos ajenos al runner) y levanta next (3100) — y el worker, si existe — con env apuntando a la BD del contenedor y a los fakes (`<PROVIDER>_BASE_URL`). Detalles y patrones de spec en e2e.md.

**msw** vive como dependencia de `@app/test-utils` (`pnpm --filter @app/test-utils add msw`) — ningún otro paquete lo instala directamente; consumen `useHttpMocks()`. Los fixtures grabados se versionan en `packages/test-utils/fixtures/http/<provider>/<caso>.json` (cómo grabarlos: external-apis.md).

## 6. Scripts pnpm

Raíz (`package.json`):

```jsonc
{
  "scripts": {
    "test":             "vitest run --project '*:unit' --project '*:integration'",
    "test:unit":        "vitest run --project '*:unit'",
    "test:integration": "vitest run --project '*:integration'",
    "test:e2e":         "pnpm --filter @app/web test:e2e",
    "test:live":        "RUN_LIVE=1 vitest run --project live",
    "test:watch":       "vitest --project '*:unit'"
    // + el script del tier de dominio si existe (ver domain-tier.md)
  }
}
```

`pnpm test` es la última pieza de `pnpm gate` (lint && typecheck && format:check && knip && readme:status:check && test) — el gate lo define la skill backend; esta skill define lo que `test` significa.

Por paquete: `"test": "vitest run"` (usa su config unit local) y, si aplica, `"test:integration": "vitest run -c vitest.config.integration.ts"` — útiles para iterar dentro de un paquete sin arrancar el workspace entero. En `apps/web`: `"test:e2e": "playwright test"` y `"e2e:stack": "tsx scripts/e2e-stack.ts"` — el mismo script que ejecuta el `webServer` de Playwright; lánzalo a mano en otra terminal si quieres que `reuseExistingServer` lo reutilice (Playwright siempre apaga los servidores que arrancó él mismo).

CI (`.github/workflows/ci.yml`, desde la primera tarea): jobs `lint+typecheck` → `unit` → `integration` (Testcontainers funciona en runners de GitHub: traen Docker) → `e2e` (Playwright). **CUA y `test:live` no corren jamás en CI** — el gate CUA requiere juicio y evidencia por tarea, y live gasta dinero con credenciales reales. Detalle en ci.md.

## 7. Variables de entorno de test

`.env.test` (committeado — no contiene ningún secreto real):

```bash
NODE_ENV=test
LOG_LEVEL=silent                  # pino en silencio; sube a debug al depurar un test concreto
# Claves FALSAS para cada proveedor externo del proyecto: la suite normal nunca
# toca la red (msw intercepta y falla lo no mockeado)
# <PROVIDER>_API_KEY=test-key
# Solo si hay APIs de pago:
# LIVE_BUDGET_USD=0.50            # techo por run del tier live (guard spendBudget() en @app/test-utils/live-budget)
# UPDATE_GOLDEN=1                 # nunca committeado activado: regenera golden files
```

`.env.test.local` (gitignored): claves **reales** exclusivamente para `pnpm test:live`. `setup-env.ts` carga primero `.env.test.local` y después `.env.test` sin override (lo local gana).

**`DATABASE_URL` está deliberadamente ausente**: la connection string la fabrica Testcontainers y viaja por `provide/inject`. Así es *imposible* que una suite apunte por accidente a la BD de desarrollo o del VPS.

## 8. Convención `docs/verifications/`

Toda tarea del planning termina con su verificación real ejecutada (gate CUA si hay superficie UI; script/curl observable si es solo backend) y la **evidencia se persiste ANTES de marcar la tarea** — es la materialización de la regla de trabajo del planning ("verificación ejecutada y anotada").

```
docs/verifications/T0.3/
├── report.md          # obligatorio
├── psql-dt.txt        # outputs crudos de los comandos de verificación
└── smoke.json
```

`report.md` mínimo:

```markdown
# T0.3 · Drizzle + primera migración
- **Fecha**: YYYY-MM-DD
- **Qué se verificó**: migración sobre BD vacía + roundtrip create/get de la entidad núcleo
- **Cómo**: `pnpm db:migrate` contra compose dev; `psql \dt`; script de smoke
- **Resultado observado**: N tablas creadas; entidad leída con los mismos datos (ver adjuntos)
- **Coste real**: $0 (sin APIs de pago)
- **Evidencia**: psql-dt.txt, smoke.json
```

Con superficie UI, la evidencia incluye screenshots/output del flujo con `npx -y agent-browser` reproduciendo el flujo humano de la "Verificación" de la tarea (ver cua.md). Con coste de APIs, el report anota el coste real observado (recalibrar si difiere >25 % del estimado).

## 9. Orden de bootstrap en F0

Cada pieza de testing se monta **en la tarea que crea la superficie que testea** — nunca antes (no hay nada que verificar) ni después (la tarea no puede cerrar su gate). El mapa exacto tarea→pieza lo fija el `planning.md` generado por la skill `bootstrap`; el patrón canónico es:

| Momento de F0 | Pieza de testing que se monta |
|---|---|
| Primera tarea (esqueleto del monorepo) | Vitest raíz (`vitest.config.ts` con `test.projects`) + configs unit por paquete + tsconfigs (§3). Esqueleto de `@app/test-utils` (`setup-env`, `golden`, carpeta `fixtures/http/` vacía, msw instalado). Primer unit test: un schema Zod trivial de `packages/core` (valida el import cruzado entre apps). `.github/workflows/ci.yml` con lint+typecheck+unit. Se inaugura `docs/verifications/` con la evidencia de la propia tarea. |
| App levantable (compose + `/api/health`) | `.env.test` (§7). Sin framework nuevo: el gate es script/curl contra `/api/health` con compose arriba. |
| Primera migración Drizzle | **La pieza grande**: `startPostgresContainer()` + template database + `createTestDatabase()` + `global-setup.ts` (§4.1–4.2); primera factory `makeX`; primer test de integración (roundtrip del repo de la entidad núcleo) en `packages/db/test/integration/`; job `integration` en CI. A partir de aquí, **cada migración nueva se prueba con el contenedor real** (db-integration.md). |
| Primera superficie UI (login si hay auth; si no, la primera página) | Playwright instalado en `apps/web` (§5); primer spec E2E; job `e2e` en CI. Primer gate CUA con agent-browser. |
| *(solo si el módulo existe)* Storage | Factory del asset; integración del `StorageAdapter` (filesystem temporal) y del endpoint de download (401 sin sesión si hay auth, checksum idéntico). |
| *(solo si el módulo existe)* pg-boss/worker | Integración de pg-boss contra el testcontainer (retries/backoff observables en la tabla de pg-boss — no mockees pg-boss: su semántica de re-entrega ES lo que se está probando). Ver worker-jobs.md. |
| *(solo si el módulo existe)* SSE | Integración del SSE: fetch streaming contra el route handler con database de test — snapshot, deltas vía LISTEN/NOTIFY, reconexión con `Last-Event-ID` (api.md §3.3). |
| Despliegue al VPS | Sin suite nueva: verificación operativa en el VPS (TLS, backup/restore) → evidencia en `docs/verifications/`. |

**Después de F0** (se amplía, no se re-monta): la primera tarea que integre un proveedor externo graba sus primeros fixtures HTTP reales y estrena `useHttpMocks()`; la primera con coste real estrena el tier live (budget guard); la primera con output textual grande estrena los golden files. Cada paso está detallado en su reference.
