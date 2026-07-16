# Arquitectura — fronteras de paquetes, puertos, módulos y contratos

Cómo se decide DÓNDE vive cada pieza del backend y con qué forma: dirección de dependencias del monorepo, puertos e inyección por factory functions, estructura de módulos de `packages/core`, convención de contratos Zod, `AppError` y los composition roots. Si dudas de en qué paquete va algo, la respuesta está aquí; si ya sabes dónde va y necesitas el detalle de SQL, jobs o handlers, ve al reference correspondiente (§8).

## Índice

1. [Dirección de dependencias](#1-dirección-de-dependencias)
2. [Puertos y el patrón withTransaction](#2-puertos-y-el-patrón-withtransaction)
3. [Módulos de `packages/core`](#3-módulos-de-packagescore)
4. [Contratos Zod](#4-contratos-zod)
5. [AppError: errores tipados de extremo a extremo](#5-apperror)
6. [Composition roots](#6-composition-roots)
7. [Exports maps JIT y aliases `@app/*`](#7-exports-maps-jit-y-aliases-app)
8. [Qué NO va aquí](#8-qué-no-va-aquí)

## 1. Dirección de dependencias

El mapa (ver diagrama del SKILL.md) cabe en tres líneas y es innegociable:

- `packages/core` → solo `zod` y `pino` (pino ÚNICAMENTE para el factory de logging compartido; los módulos consumen el puerto `Logger`, jamás pino directo).
- `packages/db` → `core` (+ drizzle/pg). Implementa los puertos de persistencia (y cola, si existe) que core define.
- `apps/web` (y `apps/worker`, si el F0 incluye el módulo de cola) → todos los anteriores. Son composition roots: cablean, no contienen lógica de negocio. `packages/test-utils` → db+core (lo gobierna la skill `testing`).

### `packages/services` (opcional): cuándo introducirlo

Si una unidad de trabajo del dominio **combina red + persistencia** y la necesitan a la vez `apps/web` y `apps/worker`, no cabe en ningún paquete existente: en **core** no (escribe en BD = frontera prohibida), en **db** no (llama a proveedores por red y decide la secuencia), y en una app tampoco (web y worker son composition roots **hermanos** — ninguno importa del otro; lo compartido vive en un paquete). Ese es el momento de crear `packages/services` (dep: core + db), con firma canónica `run<Algo>(deps, input) → result`. Un servicio de ahí **cablea y ordena; no contiene la lógica de negocio**: el cliente HTTP, el mapeo y la validación viven en core; la escritura vive en db. Si una pieza nueva no llama a la red **o** no persiste nada, no es un servicio de este paquete — es lógica de core o un repo de db. No crees el paquete "por si acaso": hazlo cuando aparezca la primera pieza que lo exige.

**Si el F0 incluye el módulo de spend ledger**: toda llamada de pago va seguida SIEMPRE de su entrada en el ledger, en el propio servicio y antes de retornar (*record-first*) — el registro no puede quedar en manos del llamante, que puede fallar después de haber gastado.

**Matiz vinculante que confunde a todo el mundo**: los clientes HTTP de proveedores externos SÍ viven en `packages/core`. Usan `fetch` y reciben config/keys por deps — no importan nada de I/O de datos. La frontera prohibida de core es **BD y cola** (drizzle, pg, pg-boss), no la red. Por qué: sacar las llamadas a proveedores de core partiría cada módulo en dos mitades artificiales, mientras que la BD/cola sí tiene una implementación intercambiable (Testcontainers) que justifica el puerto.

Prohibido y vigilado: `core→db`, `core→drizzle/pg/pg-boss`, y cualquier ciclo entre paquetes o entre módulos de core — `import-x/no-cycle` (config en `tooling.md`) lo convierte en error de lint, porque un ciclo convierte dos módulos en uno sin decirlo.

## 2. Puertos y el patrón withTransaction

Un puerto es una interface de core que db (o una app) implementa. **Vive junto al módulo que lo consume** (p. ej. `orders/ports.ts` para lo que solo consume el módulo de pedidos); los transversales que consume todo core (`Logger`, `Clock`, y `StorageAdapter` si el F0 incluye el módulo de storage) viven en `packages/core/src/ports.ts`. Por qué: el puerto documenta lo que su consumidor necesita, no lo que el adaptador ofrece — colocarlo junto al consumidor evita interfaces gordas "por si acaso".

```ts
// packages/core/src/ports.ts — puertos transversales
export interface Logger {
  trace(obj: object, msg?: string): void;
  debug(obj: object, msg?: string): void;
  info(obj: object, msg?: string): void;
  warn(obj: object, msg?: string): void;
  error(obj: object, msg?: string): void;
  child(bindings: Record<string, unknown>): Logger; // correlación request_id/job_id (observability.md)
}

export interface Clock { now(): Date }               // inyectable ⇒ tests deterministas sin fake timers

// SOLO si el F0 incluye el módulo de storage:
export interface StorageAdapter {                    // implementación local hoy, s3 mañana
  put(key: string, data: Uint8Array | ReadableStream<Uint8Array>, opts?: { mime?: string }): Promise<{ bytes: number; checksum: string }>;
  get(key: string): Promise<ReadableStream<Uint8Array>>;
  stat(key: string): Promise<{ bytes: number; checksum: string } | null>;
  delete(key: string): Promise<void>;
}
```

**El patrón `withTransaction`**: core orquesta la transacción, db la ejecuta. Cuando un servicio de core necesita que varias escrituras (y, si hay cola, el encolado) sean atómicas, define un puerto `WithTransaction` cuyo callback recibe **stores ligados a UNA transacción abierta**; db lo implementa con `db.transaction((tx) => fn(makeTxStores(tx)))`, donde `makeTxStores` construye los stores pasando `tx` como executor a los repos (convención de repos en `db.md`). Core nunca ve drizzle: solo ve stores ya ligados a la transacción.

```ts
// packages/core/src/<módulo>/ports.ts — esquema del patrón (los nombres son del dominio de TU proyecto)
export interface TxStores {
  orders: OrderStore;          // los agregados que la operación muta
  jobs?: JobQueue;             // solo si módulo cola: el INSERT del job comparte tx (jobs.md)
  events?: ChangeNotifier;     // solo si módulo SSE: pg_notify — Postgres lo entrega al commit, nunca antes
}

export interface OrderStore {
  /** SELECT … FOR UPDATE — la fila queda bloqueada hasta el commit. */
  findForUpdate(id: string): Promise<Order | null>;
  update(id: string, patch: OrderPatch): Promise<void>;
}

export type WithTransaction = <T>(fn: (stores: TxStores) => Promise<T>) => Promise<T>;
```

```ts
// packages/core/src/<módulo>/service.ts — esquema del uso
export function makeOrderService(deps: { withTransaction: WithTransaction; logger: Logger; clock: Clock }) {
  return {
    async confirm(orderId: string): Promise<Order> {
      return deps.withTransaction(async ({ orders, jobs, events }) => {
        const order = await orders.findForUpdate(orderId);
        if (!order) throw new AppError("not_found", `order ${orderId} no existe`);
        const next = nextStatus(order.status, "confirm"); // lógica PURA; ilegal ⇒ throw ⇒ ROLLBACK total
        await orders.update(orderId, { status: next, updatedAt: deps.clock.now() });
        // encolado y NOTIFY, si aplican, EN LA MISMA transacción
        return { ...order, status: next };
      });
    },
  };
}
```

**Si tu proyecto tiene un orquestador de pipeline / máquina de estados** (steps con dependencias, checkpoints, invalidación), este patrón es su columna vertebral: la transición valida bajo `FOR UPDATE`, resuelve dependientes, encola y notifica en UNA transacción, y una transición ilegal lanza una subclase de `AppError` (`invalid_transition`) que provoca rollback total. El lado SQL del patrón está en `db.md` §6.

Regla dura: **nunca un lock abierto durante una llamada HTTP** (SKILL.md principio 3) — la llamada al proveedor ocurre FUERA del callback, entre dos transacciones cortas (persistir la intención antes, persistir el resultado después). Los tests de todo esto los define la skill `testing` (unit puro para la lógica de estados; transaccional real con Testcontainers para la atomicidad).

## 3. Módulos de `packages/core`

Carpeta por módulo de dominio del PRD. Estructura canónica:

```
packages/core/src/
├─ index.ts            # raíz: re-exporta contracts + AppError + ports (lo transversal mínimo)
├─ ports.ts            # Logger, Clock [, StorageAdapter]
├─ contracts/          # contratos transversales (entre módulos / con el frontend) + envelope de error
├─ <dominio-1>/ <dominio-2>/ …   # un módulo por dominio del PRD
├─ clients/            # clientes HTTP compartidos por >1 módulo; los de un solo módulo viven en él
├─ observability/      # puerto Logger re-exportado + makeLogger (pino) + redact + serializers (observability.md)
└─ jobs/               # SOLO si módulo cola: registro defineJob — nombres de cola + schemas Zod de payload (jobs.md)
```

Cada módulo contiene: `index.ts` (SU API pública — es lo único que expone el subpath export, §7), `contracts.ts` (schemas Zod locales del módulo), servicios y tests co-locados (`*.test.ts`). Los clientes de UN solo módulo viven en él; solo lo compartido por varios sube a `clients/`.

**Los servicios son factory functions con objeto de deps tipado.** Sin clases (la única excepción es `AppError`, §5), sin frameworks de DI, sin singletons de módulo:

```ts
// packages/core/src/notifications/notifier.ts — ejemplo del patrón
import type { Clock, Logger } from "../ports";
import type { MailerClient } from "../clients/mailer";
import { NotificationSchema, type Notification } from "./contracts";

interface NotifierDeps { mailer: MailerClient; logger: Logger; clock: Clock }

export function makeNotifier(deps: NotifierDeps) {
  return {
    async send(input: Notification): Promise<void> {
      const log = deps.logger.child({ module: "notifications", op: "send" });
      const parsed = NotificationSchema.safeParse(input); // frontera de entrada: safeParse
      if (!parsed.success) throw new AppError("validation_error", "notificación inválida", z.flattenError(parsed.error));
      await deps.mailer.deliver(parsed.data);
      log.info({ kind: parsed.data.kind }, "notification sent");
    },
  };
}
export type Notifier = ReturnType<typeof makeNotifier>;
```

Por qué factories y no clases/DI: las deps son visibles y tipadas en la firma (nada se resuelve "por arte de contenedor"), un test de Vitest pasa fakes sin mockear módulos (`makeNotifier({ mailer: fake, logger: noopLogger, clock: fixedClock })`), y el bundler puede tree-shakear lo no usado. `ReturnType<typeof makeX>` da el tipo del servicio gratis.

## 4. Contratos Zod

Convención única en TODO el proyecto: `export const XxxSchema = z.object({...})` + `export type Xxx = z.infer<typeof XxxSchema>`. Sufijo `Schema` siempre; el tipo nunca se escribe a mano. La skill externa `zod` complementa (composición, rendimiento); esto es lo estructural:

- **`contracts/` transversal**: los contratos que cruzan módulos o viajan al frontend (entidades públicas de la API, eventos SSE, envelope de error). Cruzan módulos: por eso no viven en ninguno.
- **`contracts.ts` por módulo**: lo local. Si otro módulo empieza a importarlo, muévelo a `contracts/` — es la señal de que dejó de ser local.
- **Discriminated unions** para todo canal que transporte varios tipos: payloads de jobs (registro `defineJob`, jobs.md) y eventos SSE. Por qué: `switch (ev.type)` exhaustivo con narrowing, y un evento desconocido falla en el `safeParse`, no en producción.

```ts
// packages/core/src/contracts/app-events.ts — esquema del patrón (SOLO si módulo SSE; nombres del dominio de TU proyecto)
// `type` = nombre del evento SSE (`event:`); `data` = el JSON de su línea `data:`.
export const AppEventSchema = z.discriminatedUnion("type", [
  z.object({ type: z.literal("snapshot"), data: SnapshotSchema }),        // estado completo al conectar
  z.object({ type: z.literal("changed"), data: ChangeSchema }),          // delta
  z.object({ type: z.literal("heartbeat"), data: z.looseObject({}) }),   // mantiene viva la conexión; el shape no es contrato
]);
export type AppEvent = z.infer<typeof AppEventSchema>;
```

- **IDs**: si el proyecto usa ULIDs como PK (recomendado, db.md §1), el contrato es `UlidSchema` propio en `contracts/ids.ts` — `z.uuid()` los rechazaría.
- **Si el proyecto llama a un LLM con structured outputs**: las cardinalidades (`min`/`max` de arrays, rangos numéricos) solo las garantiza el `safeParse` con el schema Zod tras la llamada — las APIs de structured outputs no las aplican. Si necesitas un espejo JSON Schema para el proveedor, genéralo con `z.toJSONSchema()` + un helper puro propio, expórtalo como artefacto y fija por test las divergencias deliberadas Zod↔espejo.
- **Errores de validación a `details`** con `z.flattenError(error)`: forma estable `{formErrors, fieldErrors}` que el frontend mapea a campos (ver skill `frontend`).

## 5. AppError

Una única clase de error en `packages/core`, con `code` de unión literal. Los servicios lanzan `AppError` con code semántico — JAMÁS `throw new Error("algo falló")` ni strings sueltos: el frontend hace switch sobre `code` y el wording de `message` no es contrato (SKILL.md principio 6).

```ts
// packages/core/src/contracts/app-error.ts — unión de PARTIDA; amplíala según el dominio del proyecto
export const APP_ERROR_CODES = [
  "validation_error", "not_found", "invalid_transition", "unauthorized", "invalid_signature",
  "rate_limited", "guardrail_blocked", "provider_error", "internal",
] as const;
export type AppErrorCode = (typeof APP_ERROR_CODES)[number];

const STATUS: Record<AppErrorCode, number> = {
  validation_error: 400, unauthorized: 401, invalid_signature: 401, not_found: 404,
  invalid_transition: 409, guardrail_blocked: 422, rate_limited: 429, internal: 500, provider_error: 502,
};

export class AppError extends Error {
  readonly code: AppErrorCode;
  readonly status: number;
  readonly details?: unknown;
  constructor(code: AppErrorCode, message: string, details?: unknown) {
    super(message);
    this.name = "AppError";
    this.code = code;
    this.status = STATUS[code]; // el status deriva del code: nadie elige un HTTP status a mano
    this.details = details;
  }
}
```

| Code | Status | Cuándo |
|---|---|---|
| `validation_error` | 400 | Input que no pasa el schema Zod de la frontera (el wrapper lo genera desde ZodError, api.md) |
| `unauthorized` | 401 | Sin sesión válida (solo si módulo auth) |
| `invalid_signature` | 401 | Webhook con firma/cabeceras/timestamp inválidos (solo si el proyecto recibe webhooks firmados) |
| `not_found` | 404 | Agregado inexistente |
| `invalid_transition` | 409 | Una máquina de estados rechaza el evento (solo si el proyecto tiene una) |
| `guardrail_blocked` | 422 | Un guardrail de negocio del dominio bloquea la operación |
| `rate_limited` | 429 | Rate limit propio o presupuesto agotado (si módulo spend ledger) |
| `internal` | 500 | Bug nuestro; el envelope sale opaco y el detalle va SOLO al log (api.md) |
| `provider_error` | 502 | Un proveedor externo falló de forma no recuperable u output fuera de contrato |

Añadir un code = ampliar la unión + la tabla `STATUS` + decidir su mapeo en el wrapper de api.md, en el mismo PR. Los codes que tu proyecto no necesite (sin webhooks → sin `invalid_signature`) se eliminan de la unión al arrancar — una unión con codes muertos también miente.

**Subclases semánticas**: cuando un módulo necesita un error atrapable por tipo, se subclasea AppError con el code fijado — la única familia de errores sigue siendo una:

```ts
// ejemplo canónico si el proyecto tiene máquina de estados
export class IllegalTransitionError extends AppError {
  constructor(from: string, event: string) {
    super("invalid_transition", `transición ilegal: ${from} + ${event}`);
    this.name = "IllegalTransitionError";
  }
}
```

Así `expect(...).toThrow(IllegalTransitionError)` funciona en los tests, y el wrapper de la API lo mapea vía `instanceof AppError` sin caso especial.

## 6. Composition roots

Los únicos sitios del monorepo donde se instancian adaptadores reales y se cablean con servicios de core. Si estás haciendo `new`/`create*` de un cliente o pool fuera de estos ficheros (o de los accessors que usan), está mal colocado.

**`apps/web/src/server/context.ts`** — cablea de forma **lazy**: en Next, importar un módulo no puede abrir conexiones ni leer env (la skill `testing` exige `getDb()`/`setDbForTests()`; mismo patrón para pg-boss y StorageAdapter si existen). Las factories de core son closures baratas: crear el servicio por request es gratis; lo único cacheado como singleton son las conexiones, y eso ya lo hacen los accessors.

```ts
// apps/web/src/server/context.ts
import { makeOrderService } from "@app/core/orders";
import { makeWithTransaction } from "@app/db";
import { getDb } from "./db";           // accessor lazy + setDbForTests (api.md §3)
import { getRequestLogger } from "./request-context"; // child por request vía AsyncLocalStorage (observability.md)
import { systemClock } from "./clock";

export function getContext() {
  const deps = { logger: getRequestLogger(), clock: systemClock };
  return {
    orders: makeOrderService({ withTransaction: makeWithTransaction(getDb()), ...deps }),
    // …un servicio por módulo del dominio
  };
}
```

**`apps/worker/src/bootstrap.ts`** (solo si módulo cola) — cablea de forma **eager** al arrancar el proceso: el worker es un daemon y fallar en el boot (env que falta, BD caída) es una feature, no un bug. Esquema (el detalle de colas, consumers y shutdown está en jobs.md):

```ts
// apps/worker/src/bootstrap.ts
export async function bootstrap() {
  const logger = makeLogger({ name: "worker", level: process.env.LOG_LEVEL ?? "info" }); // factory pino compartido (observability.md §2)
  const pool = new Pool({ connectionString: requireEnv("DATABASE_URL") }); // el worker POSEE su pool: lo cierra en el shutdown
  const db = makeDb(pool);
  const boss = await createBossWithQueues(requireEnv("DATABASE_URL")); // createQueue idempotente + DLQ (jobs.md)
  await registerConsumers({ boss, db, logger });                        // handlers (jobs.md)
  registerGracefulShutdown({ boss, pool, logger });                     // SIGTERM → boss.stop → pool.end (jobs.md §9)
}
```

Los tests de integración sustituyen exactamente estas costuras: `setDbForTests(testDb)` en web, `bootstrap` parametrizable en worker — por eso ningún servicio de core lee env ni crea conexiones por su cuenta.

## 7. Exports maps JIT y aliases `@app/*`

Los paquetes internos exportan **TypeScript fuente** — sin build, sin watch, sin cascada: un cambio en core es visible en las apps al instante. El coste (transpilar en el consumidor) lo pagan Next y tsx/tsup, y a 3-5 paquetes es despreciable. El scope `@app/*` es el canónico del template (la skill `bootstrap` puede fijar otro; el patrón es idéntico).

```jsonc
// packages/core/package.json (esquema; db es idéntico con sus subpaths)
{
  "name": "@app/core",
  "private": true,
  "type": "module",
  "exports": {
    ".": "./src/index.ts",
    "./contracts": "./src/contracts/index.ts",
    "./orders": "./src/orders/index.ts",
    "./jobs": "./src/jobs/index.ts"
    // …un subpath por módulo del §3. NUNCA "./src/*" comodín:
    // el exports map ES el enforcement de la API pública — un import profundo a internals no resuelve
  },
  "dependencies": { "zod": "catalog:", "pino": "catalog:" } // versiones únicas vía pnpm catalogs (tooling.md)
}
```

- **Consumo**: las apps declaran `"@app/core": "workspace:*"` — el alias `@app/*` sale del workspace de pnpm, no de `paths` de tsconfig.
- **apps/web**: `transpilePackages: ["@app/core", "@app/db"]` en `next.config.ts` — Next compila el TS fuente de los workspace packages.
- **apps/worker** (si existe): `tsx watch src/main.ts` en dev; para el deploy se bundlea con **tsup** con los paquetes del workspace inlineados (p. ej. `noExternal: [/^@app\//]`) — obligatorio porque exportan TS que Node no puede ejecutar.
- **core y db no tienen build**: su script es `typecheck: tsc --noEmit` (tsconfig extiende el base de la raíz; la orquestación está en `tooling.md`).

## 8. Qué NO va aquí

- **Schema Drizzle, migraciones, repos, transacciones SQL, implementación de los stores/withTransaction** → `references/db.md`.
- **defineJob, colas y políticas, consumers, retries, cron, graceful shutdown** (si módulo cola) → `references/jobs.md`.
- **Route handlers, withRoute/withAuth, mapeo AppError→envelope HTTP, SSE, webhooks** → `references/api.md`.
- **Config de pino, correlación por request/job, redact** → `references/observability.md`; ESLint/typecheck/catalogs → `references/tooling.md`.
- **Tests de todo lo anterior** → skill `testing`. Este documento define la forma del código; cómo probarla no se decide aquí.
