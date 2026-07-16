# CI — GitHub Actions desde F0

Capa de integración continua de {{PROJECT_NAME}}. Este reference decide **dónde y cuándo corre cada suite** y da el workflow completo. El *cómo* de cada suite vive en su propio reference (p. ej. Testcontainers y el globalSetup en db-integration.md); aquí no se duplica.

## Contenido

1. [Principios](#1-principios)
2. [Bootstrap: el workflow nace con el primer commit](#2-bootstrap)
3. [Qué corre en CI — y qué queda fuera deliberadamente](#3-qué-corre-en-ci)
4. [El workflow completo](#4-el-workflow-completo)
5. [Decisiones que el workflow codifica (el porqué)](#5-decisiones)
6. [Caching](#6-caching)
7. [Gate de merge: branch protection + job agregador](#7-gate-de-merge)
8. [Tabla resumen: dónde corre cada suite](#8-tabla-resumen)
9. [Evolución del workflow por fases](#9-evolución)

---

## 1. Principios

- **CI existe desde el primer commit, no "cuando haya algo que testear".** La regla de trabajo del planning exige "sin regresión del E2E de la fase anterior" en cada tarea: eso solo es barato si la red de regresión automatizada corre sola en cada push. Retrofit de CI sobre un repo con suites a medias no ocurre nunca en la práctica.
- **Todos los jobs son gate de merge a `main`.** Un solo desarrollador también se beneficia: la disciplina "solo se mergea en verde" es lo que mantiene el E2E de fases anteriores como suelo firme mientras construyes la siguiente.
- **CI no usa ningún secret.** El workflow no declara `secrets.*`: las APIs externas van con msw + fixtures grabados (y en E2E con el fake server HTTP que sirve esos mismos fixtures, ver e2e.md §4). Si un test "necesita" una API key real en CI, está mal clasificado — es un `*.live.test.ts` y corre fuera de CI. Beneficio doble: cero gasto accidental y cero superficie de exfiltración.
- **CI verifica; no genera.** `UPDATE_GOLDEN=1` jamás se setea en CI: ante drift de golden files, CI debe fallar, no regenerar en silencio.
- **CI es red de regresión, no verificación de tarea.** El gate CUA y los E2E de fase contra APIs reales cierran tareas concretas con evidencia en `docs/verifications/<TASK-ID>/`; CI protege que lo ya cerrado siga funcionando. Son capas distintas y ninguna sustituye a la otra.

## 2. Bootstrap

La secuencia en la primera tarea de F0:

1. `git init` y esqueleto del monorepo.
2. Crear `.nvmrc` (versión de Node del proyecto), fijar `packageManager` (pnpm) en el `package.json` raíz, y crear `.github/workflows/ci.yml` + `.github/actions/setup/action.yml` (§4). **El primer commit ya incluye el workflow.**
3. Crear el repo en GitHub ({{REPO_URL}}), push, y activar branch protection sobre `main` con `CI OK (gate de merge)` como required status check — antes de escribir la segunda tarea.

El YAML de §4 muestra el **estado final** del workflow; los jobs condicionales (`seed-validators`, el tier de dominio) se añaden en las tareas que crean sus scripts (§9). No dejes jobs que invocan scripts inexistentes: un job rojo permanente entrena a ignorar el rojo.

## 3. Qué corre en CI

**Corre en CI** (en cada PR y en cada push a `main`):

| Job | Qué ejecuta | Necesita Docker |
|---|---|---|
| `lint` | `pnpm lint` + `pnpm typecheck` + `pnpm format:check` + `pnpm knip` + `pnpm readme:status:check` (los define la skill backend) | No |
| `unit` | `pnpm test:unit` (Vitest, `--project '*:unit'`) | No |
| `seed-validators` | `pnpm seed --validate` *(solo si el proyecto versiona seeds)* | No — valida los JSON del seed como lógica pura sobre ficheros |
| `integration` | `pnpm test:integration` (Vitest + Testcontainers) | Sí — el globalSetup arranca su propio `postgres:16` |
| `e2e` | `pnpm test:e2e` (Playwright contra la app real con Postgres real y APIs externas servidas por el fake server HTTP, ver e2e.md §4) | Sí — el stack de E2E arranca su propio `postgres:16` vía Testcontainers |
| tier de dominio | `pnpm test:<dominio>` dentro de su imagen/entorno *(solo si el tier existe, ver domain-tier.md)* | Según el tier |

**NO corre en CI**, y el porqué importa más que la regla:

- **Gate CUA (`agent-browser`)**: es agéntico e interactivo — reproduce el flujo humano con juicio de un LLM y produce evidencia para `docs/verifications/<TASK-ID>/`. Su valor es cerrar UNA tarea una vez, no vigilar regresiones; en CI sería no-determinista, lento y caro sin proteger nada que Playwright no proteja ya.
- **`pnpm test:live`**: gasta dinero real y depende de la disponibilidad y del catálogo cambiante de terceros. Corre opt-in en local, acotado por `LIVE_BUDGET_USD`, cuando toca cerrar deudas `[verificar]` o validar un cliente crítico. Un cron o un PR ajeno no deben poder facturar.
- **E2E de fase contra APIs reales**: son verificaciones de tarea manuales y "sagradas" — exigen datos reales, coste anotado y juicio humano. No son automatizables sin degradarlas a lo que ya cubren las suites con mocks.
- **Deploy**: fuera de este workflow (lo define la skill `deploy`). Si algún día se automatiza, será un workflow separado con trigger propio — CI decide si el código es mergeable, no cuándo se despliega.

## 4. El workflow completo

Los jobs comparten setup; extráelo a una action composite local para no mantener N copias:

```yaml
# .github/actions/setup/action.yml
name: setup
description: pnpm + Node del proyecto + deps con caché de store
runs:
  using: composite
  steps:
    - uses: pnpm/action-setup@v4          # lee la versión del campo packageManager
    - uses: actions/setup-node@v4
      with:
        node-version-file: .nvmrc          # UNA versión: la del proyecto (§5)
        cache: pnpm                        # caché del pnpm store, keyed por lockfile
    - run: pnpm install --frozen-lockfile
      shell: bash
```

```yaml
# .github/workflows/ci.yml
name: CI

on:
  pull_request:
  push:
    branches: [main]
  workflow_dispatch:

# Un push nuevo en la misma branch cancela el run anterior: el feedback debe ser
# sobre el último commit, no sobre uno obsoleto. En main nunca se cancela: cada
# commit de main queda con veredicto completo.
concurrency:
  group: ci-${{ github.ref }}
  cancel-in-progress: ${{ github.ref != 'refs/heads/main' }}

jobs:
  lint:
    name: Lint + typecheck
    runs-on: ubuntu-latest
    timeout-minutes: 8
    steps:
      - uses: actions/checkout@v4
      - uses: ./.github/actions/setup
      - run: pnpm lint
      - run: pnpm typecheck
      - run: pnpm format:check
      - run: pnpm knip
      - run: pnpm readme:status:check

  unit:
    name: Unit
    runs-on: ubuntu-latest
    timeout-minutes: 10
    steps:
      - uses: actions/checkout@v4
      - uses: ./.github/actions/setup
      - run: pnpm test:unit

  # Solo si el proyecto versiona seeds en git (se añade en la tarea que los crea):
  seed-validators:
    name: Seed validators
    runs-on: ubuntu-latest
    timeout-minutes: 5
    steps:
      - uses: actions/checkout@v4
      - uses: ./.github/actions/setup
      - run: pnpm seed --validate

  integration:
    # Docker ya está disponible en los runners ubuntu-latest: NO se usan service
    # containers. El globalSetup de Vitest arranca su propio postgres:16 con
    # startPostgresContainer() — mismo code path que en local (ver db-integration.md).
    name: Integration (Testcontainers)
    runs-on: ubuntu-latest
    timeout-minutes: 20
    needs: [lint]
    steps:
      - uses: actions/checkout@v4
      - uses: ./.github/actions/setup
      - run: pnpm test:integration

  e2e:
    name: E2E (Playwright)
    runs-on: ubuntu-latest
    timeout-minutes: 25
    needs: [lint]
    steps:
      - uses: actions/checkout@v4
      - uses: ./.github/actions/setup

      # Caché de browsers: la clave es la versión exacta de @playwright/test,
      # así se invalida exactamente cuando haces bump de la dependencia.
      - name: Resolver versión de Playwright
        run: echo "PLAYWRIGHT_VERSION=$(node -p "require('./apps/web/package.json').devDependencies['@playwright/test']")" >> "$GITHUB_ENV"
      - uses: actions/cache@v4
        id: pw-cache
        with:
          path: ~/.cache/ms-playwright
          key: playwright-${{ runner.os }}-${{ env.PLAYWRIGHT_VERSION }}
      - if: steps.pw-cache.outputs.cache-hit != 'true'
        run: pnpm exec playwright install --with-deps chromium
      - if: steps.pw-cache.outputs.cache-hit == 'true'
        run: pnpm exec playwright install-deps chromium

      # pnpm test:e2e es autosuficiente: NO se levanta compose ni se migra a
      # nivel de job. El webServer de playwright.config.ts ejecuta
      # scripts/e2e-stack.ts (tsx), que arranca su propio testcontainer
      # Postgres (startPostgresContainer()), migra + siembra (seedFixtures) y
      # levanta next (+ worker si existe) con el fake server HTTP de APIs
      # externas (startFakeExternalApis, ver e2e.md §4): cero llamadas reales,
      # cero secrets. Traces con trace: 'retain-on-failure' → test-results/.
      - run: pnpm test:e2e

      - uses: actions/upload-artifact@v4
        if: failure()
        with:
          name: playwright-report
          path: |
            apps/web/playwright-report/
            apps/web/test-results/
          retention-days: 7

  # Solo si existe un tier de dominio (ver domain-tier.md): job propio que
  # construye la imagen/entorno REAL del tier y corre la suite dentro —
  # valida los binarios de producción, no los del runner.

  # Job agregador: el ÚNICO required status check en branch protection (§7).
  ci-ok:
    name: CI OK (gate de merge)
    runs-on: ubuntu-latest
    timeout-minutes: 2
    needs: [lint, unit, integration, e2e]   # + seed-validators y el tier de dominio cuando existan
    if: always()
    steps:
      - if: contains(needs.*.result, 'failure') || contains(needs.*.result, 'cancelled')
        run: exit 1
      - run: echo "all green"
```

## 5. Decisiones

- **`timeout-minutes` explícito en TODOS los jobs.** El default de GitHub es 360 minutos: un `--wait` sobre un healthcheck que nunca sana, un webServer que no abre el puerto o un testcontainer colgado te roban horas de runner y, peor, bloquean el veredicto del PR. El colgado silencioso es el mayor ladrón de CI. Regla: 2–3× la duración esperada del job; si un job empieza a rozar su timeout, investiga (suele ser un test nuevo lento o un deadlock), no lo subas por reflejo.
- **`needs: [lint]` en los jobs caros** (integration, e2e, tier de dominio): lint+typecheck tarda ~1–2 min; no quemes 20 min de Docker y browsers en código que ni compila. No encadenes más que eso — cada eslabón extra alarga el camino crítico del feedback.
- **Sin matrix de Node ni de OS.** `node-version-file: .nvmrc` es la única fuente de verdad. El runtime real del producto es exactamente uno: la versión que fijan la imagen del deploy y el VPS. Una matrix 3 versiones × 2 OS multiplica por seis los minutos y añade flakes de plataformas donde el código jamás correrá. Cuando subas de versión de Node, cambias `.nvmrc` y el Dockerfile en el mismo PR y CI valida la nueva — eso es todo el "soporte multi-versión" que hace falta.
- **Integración sin service containers.** Podrías declarar `services: postgres:` en el job, pero entonces CI y local divergen: los service containers se fijan a nivel de job, no permiten preparar la template database antes de que Vitest calcule el provide/inject, y crean un segundo code path que solo se ejecuta en CI (los bugs de "solo falla en CI" nacen ahí). Con `startPostgresContainer()` en el globalSetup, CI ejecuta *exactamente* el mismo arranque que tu máquina.
- **Solo Chromium en E2E** salvo que el PRD exija cross-browser. Firefox/WebKit añaden minutos y flakes; si algún día importa, es una línea en `playwright.config.ts`.
- **Artifacts solo en fallo.** `playwright-report/` + traces suben únicamente con `if: failure()`: en verde no aportan nada y consumen cuota de storage. En rojo son la diferencia entre reproducir en 2 minutos y adivinar.
- **Los jobs con binarios pesados deben seguir siendo rápidos.** Si un tier de dominio corre en cada PR (es gate, no se filtra por paths — ver §7), sus fixtures son sintéticos y mínimos, nunca artefactos reales grandes. Si tarda >10 min, el problema es la suite, no el job.

## 6. Caching

Cachés keyed por lo que realmente las invalida:

| Qué | Mecanismo | Clave | Por qué |
|---|---|---|---|
| pnpm store | `actions/setup-node` con `cache: pnpm` | `pnpm-lock.yaml` | `pnpm install` pasa de minutos a segundos; se invalida solo cuando cambian deps |
| Browsers Playwright | `actions/cache` sobre `~/.cache/ms-playwright` | versión exacta de `@playwright/test` | Descargar Chromium (~150 MB) en cada run es el coste dominante del job e2e; la clave por versión invalida exactamente en el bump. En cache-hit sigue haciendo falta `install-deps` (librerías del sistema no cacheables) |
| Capas Docker (si hay imagen propia) | buildx con `cache-from/to: type=gha` | contenido del Dockerfile/contexto | Una imagen con binarios pesados cambia poco: con caché el build es segundos salvo cuando tocas el Dockerfile |

## 7. Gate de merge: branch protection + job agregador

Configura branch protection en `main` con **un único required check: `CI OK (gate de merge)`**. El porqué del agregador: los required checks se configuran *por nombre* en settings de GitHub, fuera del repo. Si en una fase futura añades un job y se te olvida tocar settings, ese job en rojo NO bloquearía el merge — y nadie lo notaría. Con `ci-ok`, la lista `needs` del propio YAML es la única fuente de verdad del gate y se revisa en el PR como cualquier código. Regla operativa: **todo job nuevo se añade a `needs` de `ci-ok` en el mismo PR que lo crea.**

El `if: always()` + check de resultados es necesario porque, sin él, un job fallido haría que `ci-ok` quedara `skipped` — y GitHub trata `skipped` como pasable. Por lo mismo, no filtres jobs por `paths`: un required check que a veces no corre es un gate con agujeros.

## 8. Tabla resumen

| Suite | Local dev | Pre-commit | CI | Verificación de tarea |
|---|---|---|---|---|
| lint + typecheck + format + knip | al guardar (IDE) | ✅ sobre staged; typecheck en pre-push (skill backend) | ✅ `lint` | — |
| unit — `pnpm test:unit` | ✅ en watch mientras desarrollas | opcional* | ✅ `unit` | — |
| integration — `pnpm test:integration` | ✅ antes de push si tocaste BD/transaccional | ✗ | ✅ `integration` | — |
| e2e — `pnpm test:e2e` | al tocar flujos de UI | ✗ | ✅ `e2e` (fake APIs) | — |
| tier de dominio (si existe) | al tocar esa capa (requiere su entorno) | ✗ | ✅ job propio | — |
| seed validators (si existen) | al tocar seeds | ✗ | ✅ `seed-validators` | — |
| live — `pnpm test:live` (si hay APIs de pago) | opt-in deliberado (`LIVE_BUDGET_USD`) | ✗ | ✗ **nunca** (gasta dinero) | ✅ cierres de deuda `[verificar]`, clientes críticos |
| Gate CUA (`agent-browser`) | — | ✗ | ✗ **nunca** (agéntico e interactivo) | ✅ toda tarea con superficie UI → evidencia en `docs/verifications/<TASK-ID>/` |
| E2E de fase (APIs reales) | — | ✗ | ✗ **nunca** (coste + juicio humano) | ✅ tareas de cierre de fase |

\* Pre-commit solo admite lo que corre en <10 s (lint-staged; unit del paquete tocado si sigue siendo instantáneo). Un pre-commit lento entrena el hábito de `--no-verify`, y entonces no tienes gate ninguno — CI es el gate real; pre-commit es solo cortesía de feedback temprano.

## 9. Evolución

El workflow crece con el proyecto; cada job aparece cuando existe lo que ejecuta:

- **Primera tarea de F0**: `ci.yml` con `lint`, `unit` y `ci-ok` + composite action + `.nvmrc` + `packageManager`. Branch protection activada.
- **Primera migración / lógica transaccional**: job `integration`.
- **Primer flujo de UI real**: job `e2e` con su primer spec.
- **Primeros seeds versionados** (si aplica): job `seed-validators`.
- **Primer tier de dominio** (si aplica): su job sobre la imagen/entorno recién creado.

En cada adición: job nuevo → `needs` de `ci-ok` → mismo PR. La verificación de la tarea que añade un job incluye ver ese job en verde (y, donde el planning lo pida, verlo **fallar** con un fixture roto a propósito: un gate que nunca has visto en rojo no está demostrado).
