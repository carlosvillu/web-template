---
name: backend
description: Estrategia de desarrollo backend del proyecto — packages/core (contratos Zod, lógica pura, puertos), packages/db (Drizzle + Postgres), la capa API de apps/web (route handlers, webhooks, auth, SSE) y, si el F0 del proyecto los incluye, apps/worker + pg-boss. Incluye el análisis estático y tooling del monorepo (ESLint, Prettier, typecheck, knip, lefthook, catalogs). Usar SIEMPRE que se cree o modifique un contrato, módulo de core, tabla/migración/repo, job o consumer, route handler, webhook, logger, o configuración de lint/typecheck/hooks; se decida en qué paquete vive una pieza; o el usuario pida "crea el endpoint", "añade la tabla", "configura el linter". Complementa (nunca sustituye) a la skill testing para todo lo relativo a tests.
---

# Estrategia de backend

Esta skill define CÓMO se desarrolla todo el backend del proyecto: `packages/core`, `packages/db`, la capa API de `apps/web` y — si el F0 del proyecto incluye el módulo de cola — `apps/worker`. Es la fuente de verdad única de fronteras, convenciones y patrones de servidor: si un cambio no encaja en lo que describe este documento y sus references, o el cambio está mal planteado o esta skill necesita una actualización deliberada (nunca las dos cosas en silencio). Los tests de todo lo que se construya aquí los define la skill `testing` (léela SIEMPRE junto a esta). El PRD.md y el planning.md del proyecto mandan sobre cualquier ejemplo de este documento.

## Principios

1. **core define, db implementa, las apps cablean.** `packages/core` contiene contratos Zod, lógica pura y **puertos** (interfaces); no importa drizzle, pg ni ningún I/O de datos — sus dependencias de runtime son zod y pino (pino solo para el factory de logging compartido: los módulos consumen el puerto `Logger`, nunca pino directo). Los clientes HTTP de proveedores externos SÍ viven en core: usan fetch y reciben su config por deps — la frontera prohibida es la BD/cola, no la red. `packages/db` implementa los puertos de persistencia con Drizzle y depende de core. Las apps son composition roots (`apps/web/src/server/context.ts`; `apps/worker/src/bootstrap.ts` si existe el worker) que instancian adaptadores y los inyectan. Esta dirección es lo que permite unit tests puros de la lógica de dominio e integración real con Testcontainers.
2. **El estado canónico vive en nuestras tablas, no en infraestructura.** La verdad del dominio está en Postgres y toda mutación pasa por servicios transaccionales de core vía el patrón `withTransaction`. Si el proyecto tiene cola (pg-boss), esta solo despacha ejecución — jamás se lee `pgboss.job` para decidir negocio. Si el proyecto tiene un orquestador/máquina de estados, toda transición pasa por su `transition()` transaccional (`SELECT … FOR UPDATE` + encolado + NOTIFY en la MISMA transacción); ningún handler cambia estados por su cuenta.
3. **Todo lo que se re-entrega es idempotente.** pg-boss es at-least-once y los proveedores reintentan webhooks: cada handler de job y cada webhook handler, al (re)entrar, relee el estado real con FOR UPDATE y hace no-op si el trabajo ya se aplicó. Con trabajo externo de pago, la intención se persiste ANTES de la llamada, y nunca se mantiene un lock abierto durante una llamada HTTP.
4. **Los contratos Zod son la frontera universal.** En cada payload de job, en cada request/response de la API y en cada evento SSE hay un schema de `packages/core` con sufijo `Schema` y su tipo inferido. Se valida con `safeParse` en toda frontera de entrada; los datos internos ya validados viajan tipados.
5. **Ninguna conexión en module scope.** BD, pg-boss y StorageAdapter se obtienen de accessors lazy con override para tests (`getDb()`/`setDbForTests()` — contrato exigido por la skill `testing`). Importar un módulo jamás abre una conexión ni lee env.
6. **Errores tipados de extremo a extremo.** `AppError {code, message, details?, status}` en core; los wrappers de la API lo mapean al envelope `{code, message, details}`. El frontend hace switch sobre `code`: el wording de `message` nunca es contrato.
7. **Observabilidad desde el día 1.** Todo log es pino estructurado con correlación (`request_id` siempre; `job_id`/`run_id`/`step_id` donde apliquen); los secretos se redactan de forma declarativa en el logger base. Si algo falla en producción, los logs correlacionados deben bastar para diagnosticarlo.
8. **El análisis estático es un gate, no una sugerencia.** `pnpm gate` (lint + typecheck + format:check + knip + readme:status:check + test) es el gate de cierre de toda tarea; `no-floating-promises` es error innegociable (un await perdido en un handler = trabajo "completado" antes de terminar).

## Tabla de decisión: ¿qué voy a construir?

Localiza lo que estás construyendo y lee el reference indicado ANTES de escribir código:

| Vas a escribir… | Reference | Y de testing… |
|---|---|---|
| Un paquete/módulo nuevo, un puerto, un servicio de core, decidir dónde vive algo | `references/architecture.md` | skill `testing` (unit puro) |
| Un contrato Zod nuevo o un cambio de contrato | `references/architecture.md` §4 | skill `testing` (unit puro) |
| Una tabla, migración, repo, query, transacción, índice | `references/db.md` | skill `testing` (integración Postgres) |
| Una máquina de estados / un orquestador de pipeline (si tu proyecto tiene uno) | `references/architecture.md` + `references/db.md` | skill `testing` (integración transaccional) |
| Un job, un consumer del worker, cron, retries, shutdown — **SOLO si el F0 del proyecto incluye el módulo de cola (pg-boss + apps/worker)** | `references/jobs.md` | skill `testing` (integración; pg-boss no se mockea) |
| Un route handler, SSE, webhook, auth, el envelope de errores | `references/api.md` | skill `testing` (handler-level / server-level) |
| Logging, correlación, redaction, métricas internas | `references/observability.md` | — |
| ESLint/Prettier/typecheck/knip/lefthook/catalogs, un script raíz, el gate | `references/tooling.md` | skill `testing` (scripts `test:*`) |
| Un cliente de API externa de un proveedor | `references/architecture.md` §2 | skill `testing` (APIs externas) |

## Mapa de paquetes y dirección de dependencias

El scope canónico de los paquetes internos es `@app/*` (la skill `bootstrap` puede fijar otro para el proyecto; el patrón no cambia).

```
                    ┌────────────────────┐
                    │   packages/core     │  contratos Zod · lógica pura · puertos ·
                    │   (dep: zod, pino)  │  clientes HTTP de proveedores
                    └─────────▲──────────┘
                              │ implementa puertos / usa contratos
                    ┌─────────┴──────────┐
                    │    packages/db      │  schema Drizzle · migraciones · repos ·
                    │    (dep: core)      │  adaptadores de puertos
                    └─────▲───────▲──────┘
            composition   │       │   composition
                 root     │       │      root
        ┌─────────────────┴─┐   ┌─┴──────────────────┐
        │ apps/web           │   │ apps/worker        │
        │ server/context.ts  │   │ src/bootstrap.ts   │
        │ (API + auth [+SSE])│   │ (solo si módulo    │
        └────────────────────┘   │  de cola en F0)    │
                                 └────────────────────┘
```

`packages/test-utils` depende de db+core (lo gobierna la skill `testing`). Prohibido: core→db, core→drizzle/pg/pg-boss, ciclos entre paquetes (`import-x/no-cycle` lo vigila).

## Módulos de `packages/core`

Carpeta por módulo de dominio del PRD, cada una con `index.ts` (API pública, expuesta como subpath export), `contracts.ts` (schemas Zod del módulo) y servicios como factory functions con objeto de deps tipado — sin clases (salvo `AppError`), sin frameworks de DI:

```
packages/core/src/
├─ ports.ts          # puertos transversales: Logger, Clock [, StorageAdapter si módulo storage]
├─ contracts/        # contratos transversales (entre módulos / con el frontend) + envelope de error
├─ <dominio-1>/ <dominio-2>/ …   # un módulo por dominio del PRD
├─ clients/          # clientes HTTP compartidos por >1 módulo; los de un solo módulo viven en él
├─ observability/    # puerto Logger re-exportado + makeLogger (pino) + redact + serializers
└─ jobs/             # SOLO si módulo cola: registro defineJob (nombres + schemas de payload; handlers en apps/worker)
```

## Convenciones núcleo (el detalle vive en los references)

- **Nombres**: ficheros kebab-case; schemas `XxxSchema` + `type Xxx = z.infer<…>`; repos `<agregado>.repo.ts`; puertos sustantivos (`UserStore`, `JobQueue`, `MailerClient`); factories `makeXxxService(deps)`.
- **Exports JIT**: los paquetes internos exportan TS fuente (`"." → ./src/index.ts` + subpaths por módulo). Next los consume con `transpilePackages`; el worker (si existe) corre con tsx en dev y se bundlea con tsup para deploy. Imports profundos a internals: prohibidos por el exports map.
- **Migraciones**: `drizzle-kit generate` + SQL committeado + `migrate()` con lock en el arranque. `push` prohibido fuera de prototipado local sin datos.
- **Jobs** (solo si módulo cola): nombres de cola y payloads (Zod) en `core/jobs`; colas creadas explícitamente con política + DLQ; encolado transaccional con `{ db }` sobre la tx de Drizzle; `singletonKey` cuando el dominio exija dedupe.
- **Secretos**: nunca se loggea un secreto (redact declarativo) ni viaja al navegador. Dónde viven (env, tabla de settings cifrada…) lo decide el PRD del proyecto; la regla aquí es transversal.
- **Docs actualizadas**: Drizzle y pg-boss evolucionan rápido (Drizzle 0.x→1.0 cambia las relations) — consulta Context7 (MCP en `.mcp.json`) o los docs oficiales antes de asumir una API. Las skills `postgres-drizzle` y `supabase-postgres-best-practices` complementan aquí.

## Skills instaladas complementarias

Jerarquía: PRD/planning > skills propias (testing/frontend/backend/deploy) > skills externas. Si una skill externa contradice esto, gana esto.

| Skill | Úsala para |
|---|---|
| `supabase-postgres-best-practices` | Diseño de queries/índices/locking en Postgres (es genérica, no requiere Supabase) |
| `postgres-drizzle` | Patrones Drizzle y la distinción 0.x vs 1.0 (relations, drizzle-kit) |
| `pnpm` | Workspaces, catalogs, CI con pnpm 10/11 |
| `zod` | Reglas de composición y rendimiento de schemas al escribir contratos |

Si el F0 incluye pg-boss: no existe skill externa de pg-boss en el ecosistema — `references/jobs.md` + docs oficiales vía Context7 son la fuente.

## Definition of Done de una pieza de backend

1. Convenciones de esta skill respetadas (fronteras, puertos, contratos, idempotencia, logging).
2. Tests según la tabla de decisión de la skill `testing` (¿lógica pura? → unit; ¿toca Postgres? → integración con Testcontainers) escritos EN la misma tarea.
3. `pnpm gate` en verde (y `pnpm test:e2e` si la tarea tocó superficie web).
4. Si cierra una tarea del planning: verificación real y observable por el agente `verifier` + evidencia en `docs/verifications/<ID>/report.md` — sin excepciones (protocolo en la skill `dev-loop`).

## References

| Archivo | Léelo cuando… |
|---|---|
| `references/architecture.md` | Crees módulos/puertos/servicios/contratos o dudes de en qué paquete va algo |
| `references/db.md` | Toques schema, migraciones, repos, transacciones o índices |
| `references/jobs.md` | Toques pg-boss: jobs, consumers, cron, retries, shutdown — **solo si el F0 incluye el módulo de cola** |
| `references/api.md` | Escribas route handlers, SSE, webhooks, auth o el envelope de errores |
| `references/observability.md` | Toques logging, correlación, redaction o métricas internas |
| `references/tooling.md` | Toques ESLint/Prettier/typecheck/knip/lefthook/catalogs, scripts raíz o el gate |
