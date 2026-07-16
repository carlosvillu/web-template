# Tooling — análisis estático y configuración del monorepo

Cómo se lintea, formatea, typechequea y vigila TODO el monorepo. Este reference es transversal: `apps/web` y la skill `frontend` se rigen por lo mismo — hay UNA configuración por herramienta y vive en la raíz. Nace en la primera tarea de F0 (tsconfig/eslint/prettier compartidos) y es gate desde el primer commit (principio 8 de la skill). **Sin CI remota, `pnpm gate` es el gate de merge** (así lo fija la skill `dev-loop`); si el proyecto añade CI, sus jobs invocan exactamente estos scripts.

## Índice

1. [Visión: qué hay, qué NO hay y por qué](#1-visión)
2. [`eslint.config.ts` — el corazón](#2-eslintconfigts)
3. [Prettier](#3-prettier)
4. [TypeScript: tsconfigs y typecheck](#4-typescript)
5. [knip](#5-knip)
6. [pnpm: workspace y catalogs](#6-pnpm)
7. [lefthook](#7-lefthook)
8. [Scripts raíz consolidados y el gate](#8-scripts-raíz)
9. [Qué NO va aquí](#9-qué-no-va-aquí)

## 1. Visión

| Herramienta | Config | Qué vigila |
|---|---|---|
| ESLint 9 (flat, typed) | `eslint.config.ts` raíz, ÚNICO | Correctness con type-checking: promesas perdidas, ciclos, imports muertos, reglas Next/React Compiler/Drizzle por zona |
| Prettier | `.prettierrc` raíz, ÚNICO | Formato. Solo formato |
| tsc | `tsconfig.base.json` + uno por paquete | Tipos, incluyendo los tests |
| knip | `knip.json` raíz | Exports muertos, deps sin usar, deps sin declarar en el package.json correcto |
| pnpm catalogs | `pnpm-workspace.yaml` | Una versión por dependencia compartida en todo el monorepo |
| lefthook | `lefthook.yml` raíz | Feedback temprano en pre-commit/pre-push (`pnpm gate` sigue siendo el gate real) |
| readme-status | `scripts/readme-status.mjs` (viene con el template) | La tabla de estado del README refleja `planning.md`; `readme:status:check` es parte del gate |

**Lo que NO hay es tan vinculante como lo que hay**:

- **Sin Turborepo.** A 3-5 paquetes con exports JIT (sin builds intermedios que orquestar), su caché no paga su complejidad. Se añadirá como **tarea explícita del planning** cuando el gate supere ~1-2 min de forma sostenida — nunca "de paso".
- **Sin project references de TS.** `pnpm -r --parallel typecheck` sobre 3-5 paquetes tarda segundos; los references añaden `composite`, `.tsbuildinfo` y fricción de config por un ahorro que aquí no existe.
- **Biome descartado deliberadamente**: sin typed rules completas ni reglas Next, y su `noFloatingPromises` es parcial — precisamente la regla que aquí es innegociable (§2). Reevaluar cuando eso cambie.
- **Sin husky/lint-staged** (lefthook hace ambas cosas), **sin syncpack** (catalogs resuelve el problema de raíz), **sin publint** (paquetes privados, nada se publica), **sin eslint-plugin-prettier** (§3).

## 2. `eslint.config.ts`

Un solo fichero en la raíz gobierna todo el monorepo; los bloques se acotan por `files`. Por qué uno solo: con flat config, N configs por paquete = N formas de divergir y plugins duplicados en versiones distintas; un fichero hace el gate auditable de una lectura. ESLint lee config en TS nativamente desde 9.18 (requiere `jiti` como devDependency raíz), pero `defineConfig`/`globalIgnores` de `'eslint/config'` — que este snippet usa — llegaron en **9.22**: fija ESLint ≥9.22.

**Reglas innegociables**: `@typescript-eslint/no-floating-promises` y `no-misused-promises` son `error` SIEMPRE, incluso en tests. Un `await` perdido en un handler = trabajo "completado" antes de terminar, estado corrupto y una operación que "pasó" sin resultado. Ninguna relajación de bloque las toca.

```ts
// eslint.config.ts (raíz — el ÚNICO del monorepo)
import js from '@eslint/js';
import { defineConfig, globalIgnores } from 'eslint/config';
import tseslint from 'typescript-eslint';
import * as importX from 'eslint-plugin-import-x';
import unusedImports from 'eslint-plugin-unused-imports';
import drizzle from 'eslint-plugin-drizzle';
import vitest from '@vitest/eslint-plugin';
import playwright from 'eslint-plugin-playwright';
import reactHooks from 'eslint-plugin-react-hooks';
import prettier from 'eslint-config-prettier';
import nextCoreWebVitals from 'eslint-config-next/core-web-vitals';

export default defineConfig(
  // ── 1. Ignores globales: lo generado no se lintea jamás ──────────────────
  globalIgnores([
    '**/dist/**',
    '**/.next/**',
    '**/coverage/**',
    'packages/db/drizzle/**', // SQL + snapshots generados por drizzle-kit
    '**/playwright-report/**',
    '**/test-results/**',
  ]),

  // ── 2. Base typed para TODO el código TS ─────────────────────────────────
  js.configs.recommended,
  tseslint.configs.strictTypeChecked,
  tseslint.configs.stylisticTypeChecked,
  {
    languageOptions: {
      parserOptions: {
        projectService: true, // resuelve el tsconfig de CADA paquete solo; sin listas de project
        tsconfigRootDir: import.meta.dirname,
      },
    },
    rules: {
      // Innegociables — ver el porqué arriba.
      '@typescript-eslint/no-floating-promises': 'error',
      '@typescript-eslint/no-misused-promises': 'error',
    },
  },

  // ── 3. import-x: higiene y fronteras de imports ──────────────────────────
  importX.flatConfigs.recommended,
  importX.flatConfigs.typescript,
  {
    rules: {
      // Un ciclo core↔db (o entre módulos de core) funde dos módulos en uno
      // sin decirlo: rompe la dirección de dependencias de architecture.md §1.
      'import-x/no-cycle': 'error',
    },
    // Si la resolución de '@app/*' fallara, el fix es eslint-import-resolver-typescript
    // (settings['import-x/resolver-next']), NO añadir paths al tsconfig (§4).
  },

  // ── 4. unused-imports: autofix de imports muertos ────────────────────────
  {
    plugins: { 'unused-imports': unusedImports },
    rules: {
      '@typescript-eslint/no-unused-vars': 'off', // la sustituyen las dos siguientes
      'unused-imports/no-unused-imports': 'error', // autofixable en pre-commit (§7)
      'unused-imports/no-unused-vars': [
        'warn',
        { args: 'after-used', argsIgnorePattern: '^_', varsIgnorePattern: '^_' },
      ],
    },
  },

  // ── 5. apps/web: Next + React Hooks (React Compiler) ─────────────────────
  // eslint-config-next ≥16 exporta flat config NATIVO (array): se importa
  // directo y se acota cada entrada a la zona web. NADA de FlatCompat aquí:
  // con eslintrc revienta (sus plugins son objetos flat); FlatCompat solo
  // valía para eslint-config-next ≤15.
  ...nextCoreWebVitals.map((cfg) => ({
    ...cfg,
    files: ['apps/web/**/*.{ts,tsx}'],
    settings: { ...cfg.settings, next: { rootDir: 'apps/web/' } }, // monorepo: las reglas @next/next lo necesitan
  })),
  {
    files: ['apps/web/**/*.{ts,tsx}'],
    // CUIDADO — doble registro: eslint-config-next YA registra los plugins
    // react/react-hooks. Volver a declarar `plugins: { 'react-hooks': reactHooks }`
    // revienta con "Cannot redefine plugin". Se toman SOLO las rules del preset
    // 'recommended-latest' (rules-of-hooks + exhaustive-deps + las reglas del
    // React Compiler; en eslint-plugin-react-hooks ≥7, la que arrastra next 16).
    // Garantiza UNA sola versión del plugin: root devDep alineada con la de
    // eslint-config-next (pnpm overrides si divergen).
    rules: { ...reactHooks.configs['recommended-latest'].rules },
  },

  // ── 6. Los que tocan la BD: packages/db (+ apps/worker si existe) ────────
  {
    files: ['packages/db/**/*.ts', 'apps/worker/**/*.ts'],
    plugins: { drizzle },
    rules: {
      // Un db.delete(tabla) sin .where() borra la tabla entera.
      'drizzle/enforce-delete-with-where': ['error', { drizzleObjectName: ['db'] }],
      'drizzle/enforce-update-with-where': ['error', { drizzleObjectName: ['db'] }],
      // `return repo.insert(...)` dentro de try{} pierde el stack y el catch: exige el await.
      '@typescript-eslint/return-await': ['error', 'in-try-catch'],
    },
  },

  // ── 7. Tests: relajar lo unsafe, MANTENER las promesas ──────────────────
  {
    files: ['**/*.test.{ts,tsx}', '**/test/**/*.ts', 'apps/web/e2e/**/*.ts'],
    rules: {
      // Fixtures y asserts hacen malabares de tipos legítimos:
      '@typescript-eslint/no-unsafe-assignment': 'off',
      '@typescript-eslint/no-unsafe-member-access': 'off',
      '@typescript-eslint/no-unsafe-argument': 'off',
      '@typescript-eslint/no-non-null-assertion': 'off',
      // NUNCA se relaja: un expect(...) sin await = test en falso verde.
      '@typescript-eslint/no-floating-promises': 'error',
    },
  },
  {
    files: ['**/*.test.{ts,tsx}', '**/test/**/*.test.ts'],
    plugins: { vitest },
    rules: { ...vitest.configs.recommended.rules },
  },
  {
    ...playwright.configs['flat/recommended'],
    files: ['apps/web/e2e/**/*.spec.ts'],
  },

  // ── 8. JS plano (configs, scripts .mjs): sin type-checking ───────────────
  {
    files: ['**/*.{js,mjs,cjs}'],
    extends: [tseslint.configs.disableTypeChecked],
  },

  // ── 9. prettier SIEMPRE al final: apaga toda regla de formato ────────────
  prettier,
);
```

Notas de mantenimiento:

- **El orden importa.** Flat config resuelve por "el último gana": los bloques por zona van después de la base, y `eslint-config-prettier` cierra SIEMPRE (si una regla de formato reaparece, es que algo se añadió detrás de él).
- **`projectService: true`** exige que cada fichero linteado pertenezca al `tsconfig.json` de su paquete — otra razón por la que el tsconfig de desarrollo incluye `src` + `test` + `e2e` (§4). Un fichero "fuera de proyecto" es un error de config, no un caso a silenciar.
- Los presets de typescript-eslint y react-hooks cambian entre majors: ante un upgrade, verifica el nombre del preset en Context7/docs oficiales antes de asumir que sigue existiendo.

## 3. Prettier

- **Un `.prettierrc` en la raíz** y un `.prettierignore` (`pnpm-lock.yaml`, `packages/db/drizzle/`, `dist`, `.next`, `coverage`). Cero configs por paquete: el formato no es una opinión por paquete.
- **`prettier --check .` corre en el gate** (`pnpm format:check` es parte de `pnpm gate`); `prettier --write` corre en pre-commit sobre staged (§7). El check en el gate existe porque pre-commit es cortesía, no gate: `--no-verify` existe.
- **JAMÁS `eslint-plugin-prettier`.** Ejecutar Prettier como regla de ESLint duplica el coste de lint, convierte diferencias de formato en errores rojos que ensucian la señal de correctness y pelea con `--fix`. ESLint corrige código, Prettier formatea texto; se integran por exclusión (`eslint-config-prettier` al final del flat config), no por fusión.

```jsonc
// .prettierrc
{
  "singleQuote": true,
  "semi": true,
  "printWidth": 100,
  "trailingComma": "all"
}
```

## 4. TypeScript

- **`tsconfig.base.json` en la raíz**: `strict: true`, `moduleResolution: "bundler"`, `noEmit` por defecto. **Sin `paths` que crucen paquetes**: `@app/core` se resuelve por su exports map + `workspace:*` (architecture.md §7) — un alias de compilador esconde la frontera del paquete y engaña a knip e import-x.

```jsonc
// tsconfig.base.json
{
  "compilerOptions": {
    "strict": true,
    "noUncheckedIndexedAccess": true,
    "noImplicitOverride": true,
    "target": "es2023",
    "module": "preserve",
    "moduleResolution": "bundler",
    "verbatimModuleSyntax": true,
    "isolatedModules": true,
    "skipLibCheck": true,
    "noEmit": true
  }
}
```

- **Por paquete, `tsconfig.json` de desarrollo que INCLUYE los tests** — `"include": ["src", "test"]` (web añade `e2e`; next añade sus libs/plugin). Es el contrato con la skill `testing`: `pnpm typecheck` cubre los tests y un contrato roto en `packages/core` rompe también las suites que lo usan — exactamente la señal que quieres.
- **`tsconfig.build.json` solo donde hay build** (p. ej. `apps/worker` si existe, que se bundlea con tsup): `extends` del de desarrollo + `exclude` de `**/*.test.ts` y `test/**`. core/db no tienen build (exports JIT, typecheck-only).
- **Scripts**: cada paquete declara `"typecheck": "tsc --noEmit"`; la raíz orquesta con `"typecheck": "pnpm -r --parallel typecheck"`. Por paquete y no un tsc global: cada paquete typechequea contra SU tsconfig (web con JSX/plugin next, worker con types de node) y los errores llegan atribuidos al paquete correcto.
- **tsgo** (`@typescript/native-preview`) puede usarse como acelerador **local y opcional** si el typecheck empieza a pesar — pero `tsc` es la verdad: es lo que corre en el gate y lo que decide un cierre de tarea. Si tsgo y tsc discrepan, gana tsc.

## 5. knip

Detecta lo que el typecheck no ve: exports que nadie importa, dependencias declaradas que nadie usa y — crítico con el `node_modules` estricto de pnpm — imports de paquetes **no declarados en el package.json del paquete que los usa** (en npm clásico "funcionan" por hoisting hasta que un día no).

```jsonc
// knip.json
{
  "$schema": "https://unpkg.com/knip@5/schema.json",
  "workspaces": {
    ".": { "entry": ["scripts/**/*.{ts,mjs}"] },
    "apps/web": {}, // los plugins de knip detectan Next (app router), Playwright y Vitest solos
    "apps/worker": { "entry": ["src/index.ts"] }, // solo si el módulo worker existe
    "packages/*": {} // entry desde el exports map del package.json (architecture.md §7)
  }
}
```

- Corre como paso de `pnpm gate` (`pnpm knip`) — todo gate nuevo entra en el script `gate` en el mismo PR que lo introduce.
- Un falso positivo se resuelve en `knip.json` (`ignoreDependencies`, entry explícito) con un comentario del porqué — nunca desactivando el paso. Un knip que no es gate deja de mirarse en una semana.
- Los subpath exports de core (`@app/core/<módulo>`…) son entries: un módulo exportado pero jamás importado por las apps o los tests aparecerá como muerto — y eso es señal de diseño, no ruido.

## 6. pnpm

La skill externa `pnpm` (instalada) cubre el detalle de workspaces/CI (`--frozen-lockfile`); aquí solo lo vinculante:

```yaml
# pnpm-workspace.yaml
packages:
  - apps/*
  - packages/*

# UNA versión por dependencia compartida para TODO el monorepo.
# Dos versiones de zod = dos identidades de tipo para el mismo Schema
# y errores de asignabilidad absurdos entre core y web.
catalog:
  zod: ^4.1.0
  drizzle-orm: ^0.44.0
  pino: ^9.9.0
  react: 19.2.0
  react-dom: 19.2.0
  typescript: ~5.9.0
  # pg-boss: ^12.0.0   # solo si el F0 incluye el módulo de cola (≥12.21: jobs.md)
```

```jsonc
// packages/db/package.json — consumo
{
  "name": "@app/db",
  "private": true,
  "dependencies": {
    "@app/core": "workspace:*", // interno: SIEMPRE workspace:*
    "drizzle-orm": "catalog:",  // compartido: SIEMPRE catalog:
    "pg": "^8.13.0"             // exclusivo de este paquete: versión normal aquí
  }
}
```

Reglas: toda dep usada por ≥2 paquetes se sube al catalog (y el upgrade pasa a ser un cambio de UNA línea); los internos van con `workspace:*`; los upgrades tocan `pnpm-workspace.yaml`, no N package.json. Si añades una dep compartida sin catalogizar, knip no te salvará — es revisión de PR/review.

## 7. lefthook

Pre-commit rápido (autofix sobre staged), pre-push barato (typecheck). Los tests NO van en hooks: `pnpm test` con Testcontainers en pre-commit entrena el hábito de `--no-verify` y entonces no hay gate ninguno — `pnpm gate` es el gate real (lo ejecuta el ciclo de `dev-loop` antes de cada cierre). Presupuesto: pre-commit <10 s.

```yaml
# lefthook.yml (raíz)
pre-commit:
  jobs: # secuencial: eslint corrige código primero, prettier formatea el resultado
    - name: eslint
      glob: '*.{ts,tsx}'
      run: pnpm exec eslint --fix --no-warn-ignored {staged_files}
      stage_fixed: true # re-stagea lo corregido: el commit lleva el fix
    - name: prettier
      glob: '*.{ts,tsx,css,json,md,yml,yaml}'
      run: pnpm exec prettier --write {staged_files}
      stage_fixed: true

pre-push:
  jobs:
    - name: typecheck
      run: pnpm -r --parallel typecheck
```

- Se instala con `"prepare": "lefthook install"` en el package.json raíz (§8): quien clona tiene hooks sin paso manual.
- El eslint de pre-commit es typed (mismo config único) y paga el arranque del project service (~segundos). Si supera el presupuesto de 10 s, se degrada el hook (p. ej. quitar eslint y dejar prettier), NUNCA el gate.
- El typed-lint completo del repo (`pnpm lint`) y `prettier --check` corren solo en el gate: sobre miles de ficheros no caben en ningún hook.

## 8. Scripts raíz

```jsonc
// package.json (raíz) — consolidado
{
  "scripts": {
    "dev": "pnpm --parallel --filter @app/web dev",   // añade --filter @app/worker si el módulo existe
    "build": "pnpm -r build",            // solo los paquetes con build (web, worker) lo declaran
    "lint": "eslint .",                  // un config, un comando, todo el monorepo
    "lint:fix": "eslint . --fix",
    "format": "prettier --write .",
    "format:check": "prettier --check .",
    "typecheck": "pnpm -r --parallel typecheck",
    "knip": "knip",
    "readme:status": "node scripts/readme-status.mjs",          // regenera la tabla de estado del README desde planning.md (script del template)
    "readme:status:check": "node scripts/readme-status.mjs --check",
    "gate": "pnpm lint && pnpm typecheck && pnpm format:check && pnpm knip && pnpm readme:status:check && pnpm test",
    "prepare": "lefthook install"
    // test / test:unit / test:integration / test:e2e / test:watch
    // → los define la skill `testing`. NO los redefinas ni los "mejores" aquí.
  }
}
```

`pnpm gate` es EL comando de cierre de toda tarea (skill `dev-loop`): si un paso nuevo se vuelve vinculante (p. ej. `drizzle-kit check`), entra en el script `gate` en el mismo PR que lo introduce. `pnpm test:e2e` se ejecuta además cuando la tarea tocó superficie web — es condicional, no parte del gate.

La regla: la raíz orquesta (`-r`, `--filter`), los paquetes implementan (`typecheck`, `dev`, `build` locales). Un script raíz que hace `cd apps/web && …` está mal: rompe el modelo de pnpm y el filtrado.

## 9. Qué NO va aquí

- **Configs de Vitest/Playwright, scripts `test:*`, `@app/test-utils`, variables de entorno de test** (`.env.test`…) → skill `testing`.
- **Exports maps, `transpilePackages`, tsup del worker, fronteras de paquetes** → `references/architecture.md` §7 (aquí solo su consecuencia sobre tsconfig y knip).
- **Convenciones de código React/Next** (kebab-case, RSC, React Compiler en runtime) → skill `frontend` (el lint de la zona web de §2 las vigila, no las define).
- **Detalle de workspaces/catalogs/CI de pnpm** → skill externa `pnpm`.
- **Docker, compose, reverse proxy y despliegue** → skill `deploy` (los scripts de aquí son lo que sus imágenes invocan en build).
