# E2E de navegador con Playwright

Esta capa prueba **recorridos de usuario reales** contra el sistema completo levantado: Next.js (`apps/web`) + worker (si existe) + Postgres real (testcontainer) + colas/SSE si existen. Lo único sustituido son las APIs externas, mockeadas **a nivel de red del servidor**. Todo lo demás es el producto de verdad.

**Por qué esta capa existe y dónde termina**: un E2E es caro (segundos por test) y tiene más superficie de flakiness que cualquier otra capa. Úsala para verificar el cableado UI ↔ API ↔ backend y los flujos que el usuario ejecuta con las manos. NO la uses para cubrir ramas de lógica: eso es unit/integración (ver db-integration.md). La verificación de tarea con `agent-browser` (gate CUA) y el tier live con APIs reales son capas distintas (ver cua.md y external-apis.md).

## Tabla de contenidos

1. [Ubicación y convenciones](#1-ubicación-y-convenciones)
2. [Topología: la app completa contra un Postgres efímero](#2-topología)
3. [playwright.config.ts](#3-playwrightconfigts)
4. [APIs externas: mock a nivel de red del servidor](#4-apis-externas)
5. [Auth: login una vez, storageState reutilizado](#5-auth)
6. [Seeds por spec: factories, no clicks](#6-seeds-por-spec)
7. [Esperar UI en vivo (SSE)](#7-ui-en-vivo)
8. [Flujos de acción con efecto en el grafo/datos](#8-flujos-de-acción)
9. [Descargas y uploads](#9-descargas-y-uploads)
10. [Tags por fase y los E2E "sagrados"](#10-tags-por-fase)
11. [Qué corre en CI y qué es solo local](#11-ci-vs-local)
12. [Reglas anti-flakiness](#12-anti-flakiness)

## 1. Ubicación y convenciones

- Specs en `apps/web/e2e/**/*.spec.ts`; config en `apps/web/playwright.config.ts`; helpers en `apps/web/e2e/support/`; fixtures binarios (imágenes, ficheros) referenciados desde `packages/test-utils/fixtures/` — no dupliques binarios por spec.
- Se ejecuta con `pnpm test:e2e` desde la raíz (delega en `playwright test` dentro de `apps/web`).
- Solo Chromium por defecto. Cross-browser multiplica tiempo de suite; añade firefox/webkit solo si el PRD lo exige o aparece un bug real de navegador.
- Los E2E de fase viven en `apps/web/e2e/phases/` y son la traducción a suite de los E2E sagrados del planning (§10 de este documento).
- Cada tarea de `planning.md` que añada o modifique comportamiento operable en navegador incluye una línea `Playwright permanente` con el path exacto y los comportamientos a conservar. Ese spec se crea o amplía en la misma tarea: el CUA de cierre no cuenta como sustituto ni como regresión automatizada.

## 2. Topología

Playwright levanta **un único comando** (`webServer`) que arranca todo el sistema en orden y solo abre el puerto 3100 cuando la BD está migrada y sembrada y todos los procesos corren. Por qué un script y no varios `webServer`: el orden importa (Postgres antes que migraciones, migraciones antes que web/worker) y un script único falla rápido con un log legible si cualquier pieza no arranca.

```ts
// apps/web/scripts/e2e-stack.ts — lo lanza Playwright como webServer, SIEMPRE vía tsx
// ('pnpm exec tsx scripts/e2e-stack.ts'): importa @app/test-utils, que se consume como
// TypeScript directo sin build, y Node plano no puede cargarlo (ERR_UNKNOWN_FILE_EXTENSION).
// Orden: Postgres (testcontainer) → database desde la template → seed → fake APIs → worker (si existe) → web.
// Si algo falla: exit != 0 y Playwright aborta mostrando el log (stdout: 'pipe').
import { startPostgresContainer, createTestDatabase, seedFixtures } from '@app/test-utils';
import { startFakeExternalApis } from '@app/test-utils/fake-apis';
import { spawn } from 'node:child_process';
import { writeFileSync } from 'node:fs';

const pg = await startPostgresContainer();            // pg16 + migraciones + template (ver db-integration.md)
const { db, connectionString } = await createTestDatabase({
  label: 'e2e',
  serverUri: pg.serverUri,      // overrides: este script corre FUERA de vitest, no hay inject()
  templateDb: pg.templateDb,
});
await seedFixtures(db);                               // conjunto base de la suite (factories insertX)
const fakes = await startFakeExternalApis({ port: 4010 }); // sirve fixtures de packages/test-utils/fixtures/http/

const env = {
  ...process.env,
  PORT: '3100',
  DATABASE_URL: connectionString,
  // Un <PROVIDER>_BASE_URL por proveedor externo del proyecto + keys dummy:
  // PROVIDER_BASE_URL: `${fakes.baseUrl}/provider`, PROVIDER_API_KEY: 'e2e-dummy',
  APP_PASSWORD: process.env.E2E_PASSWORD ?? 'e2e-password', // solo si el módulo auth existe
};

// Los specs corren en OTRO proceso: publica el runtime en un fichero conocido.
writeFileSync(new URL('../e2e/.runtime.json', import.meta.url),
  JSON.stringify({ databaseUrl: connectionString, fakesUrl: fakes.baseUrl }));

// spawn('pnpm', ['--filter', '@app/worker', 'start'], { env, stdio: 'inherit' }); // solo si el módulo worker existe
spawn('pnpm', ['--filter', '@app/web', 'start'], { env, stdio: 'inherit' });
// En CI, `web start` sirve el build de producción (next build previo en el workflow):
// el build de prod detecta errores que `next dev` tolera. En local, E2E_DEV=1 permite `next dev`.
```

Reglas derivadas:

- **El script es TypeScript y se lanza con `tsx`** (`pnpm exec tsx scripts/e2e-stack.ts`; `tsx` es devDependency de `apps/web`): `@app/test-utils` se consume como TS directo sin build — Vitest lo transpila al vuelo en las otras capas, pero el webServer es un proceso normal y con `node` plano el stack nunca arrancaría (timeout de 180 s sin pista de la causa).
- **Puerto propio (3100)**: la suite nunca pelea con tu `pnpm dev` en 3000. Ojo con `reuseExistingServer`: Playwright **siempre apaga** los servidores que él mismo arrancó (web, worker y testcontainer incluidos) — la reutilización solo aplica si TÚ lanzaste el stack a mano (`pnpm e2e:stack` en otra terminal) y la URL ya responde.
- **Un solo Postgres y una sola database para toda la suite**: el script la crea una vez clonando la template con `createTestDatabase({ serverUri, templateDb })` — sus overrides existen exactamente para scripts fuera de vitest como este — y la siembra con `seedFixtures(db)`. El aislamiento entre specs es **por datos únicos** (factories con IDs únicos), no por database (ver §6).
- **NO fijes por env variables que producción deriva** (principio 9 de SKILL.md): si la app calcula una URL interna, el stack E2E no debe ponérsela hecha — el test que debía cazar el cálculo roto sería el que lo tapa.
- Readiness: el `webServer` espera por `port: 3100`; como el script solo arranca web después de migrar y sembrar, cuando el puerto abre la BD está garantizada. `/api/health` queda como healthcheck manual del stack.

## 3. playwright.config.ts

```ts
import { defineConfig, devices } from '@playwright/test';

const baseURL = process.env.E2E_BASE_URL ?? 'http://localhost:3100';

export default defineConfig({
  testDir: './e2e',
  timeout: 90_000,          // un flujo con varios pasos de backend tarda; el default de 30 s se queda corto
  expect: { timeout: 15_000 },
  fullyParallel: true,
  forbidOnly: !!process.env.CI,   // un .only olvidado no puede desactivar la suite en CI
  retries: process.env.CI ? 2 : 0, // retries SOLO en CI: en local un test que necesita retry es un bug a arreglar
  workers: process.env.CI ? 2 : undefined,
  reporter: process.env.CI ? [['github'], ['html', { open: 'never' }]] : 'list',
  use: {
    baseURL,
    trace: 'retain-on-failure',     // trace en CADA fallo: la herramienta nº1 para depurar flakiness en CI
    screenshot: 'only-on-failure',
    video: 'retain-on-failure',
    testIdAttribute: 'data-testid',
  },
  projects: [
    { name: 'setup', testMatch: /auth\.setup\.ts/ },   // solo si el módulo auth existe
    {
      name: 'chromium',
      use: { ...devices['Desktop Chrome'], storageState: 'e2e/.auth/user.json' },
      dependencies: ['setup'],      // todos los specs arrancan ya logueados (§5)
    },
  ],
  webServer: {
    command: 'pnpm exec tsx scripts/e2e-stack.ts', // tsx obligatorio: @app/test-utils es TS sin build (§2)
    port: 3100,
    reuseExistingServer: !process.env.CI,
    timeout: 180_000,               // pull de imagen pg16 + build en frío
    stdout: 'pipe',
    stderr: 'pipe',
  },
});
```

## 4. APIs externas

**Regla de diseño para testabilidad (obligatoria desde el primer cliente)**: todo cliente de API externa en `packages/core` lee su base URL de configuración (`<PROVIDER>_BASE_URL`) con el default de producción. Sin esto, esta capa entera es imposible. Impónlo en el primer PR de cada cliente.

**Por qué msw del navegador NO sirve aquí**: las llamadas a proveedores externos salen de los procesos de **Next.js y del worker**, no del navegador (las keys jamás tocan el cliente). msw en modo browser (service worker) solo intercepta fetch del navegador; msw en modo node solo intercepta dentro del proceso que lo importa — y los procesos de la app son ajenos al proceso de Playwright. La única frontera interceptable es la **red real**: un fake server HTTP local (`startFakeExternalApis()` en `@app/test-utils/fake-apis`) que sirve los mismos fixtures grabados de `packages/test-utils/fixtures/http/` que usa msw en integración. Un solo corpus de fixtures, dos mecanismos de entrega.

Comportamiento del fake por proveedor:

- **APIs asíncronas con cola (submit + polling)**: el fake devuelve `request_id` + `status_url` apuntando al propio fake; el status transiciona según una línea temporal corta y determinista. La app lo consume por su camino de polling real — el E2E ejercita código de producción, no un atajo. Los webhooks firmados no se pueden fingir honestamente sin la clave privada del proveedor: se prueban en integración con claves de test inyectadas (api.md §2.6) y en real como verificación de tarea.
- **APIs de LLM**: sirve respuestas grabadas con structured output válido, elegidas por fixture de entrada. Determinista: el mismo input produce el mismo output, lo que permite asserts exactos en la UI.
- **APIs de datos** (scraping, terceros): payloads grabados de respuestas reales.

**Si tu F0 incluye el módulo worker con executors de demo** (flags `sleep_ms`/`fail_times`/`hang`), prefiérelos para los specs de mecánica de pipeline: ejercitan backend + SSE + UI sin ninguna API externa, son más rápidos y no acoplan el test a fixtures.

Los fallos inyectados (fallos, 429, timeouts) en E2E deben ser **deterministas por spec** (p. ej. `fail_times` en un nodo concreto para probar el visor de errores y retry). La aleatoriedad pertenece a los tests de integración, nunca a E2E: un E2E que a veces ve un retry y a veces no, no afirma nada.

## 5. Auth

> **Solo si el módulo auth existe en tu F0.**

Login **una vez** por ejecución en un setup project; todos los specs reutilizan la sesión vía `storageState`. Por qué: si hay rate limit al login, loguear por test se bloquearía a sí mismo; además ahorra segundos por spec y el flujo de login ya tiene su propio spec dedicado (el único que corre sin storageState).

```ts
// apps/web/e2e/auth.setup.ts
import { test as setup, expect } from '@playwright/test';

setup('login y persistir sesión', async ({ page }) => {
  await page.goto('/login');
  await page.getByLabel(/contraseña/i).fill(process.env.E2E_PASSWORD ?? 'e2e-password');
  await page.getByRole('button', { name: /entrar/i }).click();
  await expect(page).toHaveURL('/');            // el middleware redirige al dashboard
  await page.context().storageState({ path: 'e2e/.auth/user.json' });
});
```

`e2e/.auth/` va en `.gitignore`. El spec de auth negativa (sin sesión → redirect a login; endpoint protegido → 401) usa `test.use({ storageState: { cookies: [], origins: [] } })` para arrancar deslogueado.

## 6. Seeds por spec

**Prepara datos con factories directas a la BD o con la API interna — nunca con clicks.** Por qué: preparar por UI convierte cada spec en un test de todos los flujos anteriores (lento, y un bug en el primer formulario rompe 40 specs posteriores); el flujo de UI que no estás probando ya tiene su propio spec.

Distingue dos tipos de preparación — este criterio importa:

- **Datos en reposo** (entidades, configuraciones, ficheros): inserta directo con las factories `insertX` de `@app/test-utils` contra la BD del stack — construyen con `makeX` en memoria e insertan vía Drizzle. Son filas; no necesitan al backend vivo.
- **Procesos vivos** (algo que el backend debe ejecutar: un run, un job): créalos vía la API interna con el `request` fixture (hereda la sesión del storageState). Un proceso insertado por SQL **no se mueve**: se salta la lógica de encolado y nunca arranca. Si haces INSERT de procesos verás specs colgados esperando estados que jamás llegan.

```ts
// apps/web/e2e/support/seed.ts
import { readFileSync } from 'node:fs';
import { drizzle } from 'drizzle-orm/node-postgres';
import * as schema from '@app/db/schema';
import { insertProject } from '@app/test-utils';

const { databaseUrl } = JSON.parse(readFileSync(new URL('../.runtime.json', import.meta.url), 'utf8'));
export const db = drizzle(databaseUrl, { schema });

export async function seedProject(overrides = {}) {
  return insertProject(db, overrides);   // makeProject() + INSERT; ID nuevo → ningún spec colisiona con otro
}
```

Reglas: los specs **nunca truncan ni borran datos globales** (la BD es compartida y la suite corre en paralelo); cada spec crea lo suyo con IDs únicos y filtra por ellos en la UI (busca su entidad por nombre único, no "la primera de la lista").

## 7. UI en vivo

> **Solo si el módulo SSE existe en tu F0.**

Contrato de testabilidad con el componente: cada elemento vivo expone `data-testid` **único por instancia** (p. ej. `data-testid="node-<key>-<version>"`) y su estado como atributo observable (`data-status`, espejo literal del enum del PRD). El testid único por instancia es a propósito: si tu diseño incluye invalidación/versionado, la instancia antigua y la nueva pueden convivir en pantalla, y un testid compartido matchearía dos elementos (strict mode violation de Playwright). Aporta señal exacta sin acoplarse a estilos ni colores.

**Las web-first assertions de Playwright reintentan solas hasta su timeout: son tu mecanismo de espera.** `waitForTimeout` está prohibido — un sleep fijo o es demasiado corto (flaky) o demasiado largo (suite lenta), y siempre es ambos a la vez en máquinas distintas.

```ts
import { test, expect } from '@playwright/test';
import { createDemoProcess } from './support/processes'; // POST a la API interna

test('los elementos cambian de estado en vivo vía SSE', { tag: ['@f0'] }, async ({ page, request }) => {
  const proc = await createDemoProcess(request);
  await page.goto(`/items/${proc.id}`);

  const el = page.getByTestId('node-step2-1');
  await expect(el).toHaveAttribute('data-status', 'running', { timeout: 20_000 });
  await expect(el).toHaveAttribute('data-status', 'succeeded', { timeout: 30_000 });
  // Si el assert exige combinar varias fuentes, usa polling explícito:
  await expect(async () => {
    const statuses = await page.getByTestId(/node-/).evaluateAll(
      (els) => els.map((e) => e.getAttribute('data-status')));
    expect(statuses.every((s) => s === 'succeeded')).toBe(true);
  }).toPass({ timeout: 45_000 });
});
```

Peligro estructural con SSE: **nunca uses `waitForLoadState('networkidle')`**. Una página con conexión SSE abierta permanentemente (más heartbeat) hace que networkidle **no se cumpla jamás** y el test muere por timeout de forma desconcertante. Y si la Verificación pide "ver el cambio en vivo", **no hagas `reload`** entre estados: un reload enmascararía un SSE roto con el fallback de revalidación.

## 8. Flujos de acción

Para acciones de la UI con efecto en el estado del sistema (aprobar, editar, cancelar): el patrón es esperar el estado previo, actuar, y afirmar el efecto **tanto en la UI como en el avance del sistema**.

```ts
test('editar versiona la entidad y reanuda el proceso', { tag: ['@f1'] }, async ({ page, request }) => {
  const proc = await createProcess(request);
  await page.goto(`/items/${proc.id}`);

  const el = page.getByTestId('node-review-1');
  await expect(el).toHaveAttribute('data-status', 'waiting_approval', { timeout: 60_000 });

  await el.click();
  const panel = page.getByRole('complementary'); // panel lateral
  await panel.getByRole('textbox', { name: /campo/i }).first().fill('Editado en E2E');
  await panel.getByRole('button', { name: /aprobar y continuar/i }).click();

  await expect(el).toHaveAttribute('data-status', 'succeeded');
  // Si hay invalidación aguas abajo, se afirma EN POSITIVO — un assert negativo
  // (not.toHaveAttribute) pasaría en casi cualquier estado y no verificaría nada:
  await expect(page.getByTestId('node-next-1')).toHaveAttribute('data-status', 'superseded');
  await expect(page.getByTestId('node-next-2')).toHaveAttribute('data-status', /^(queued|running)$/);
});
```

Cubre también los caminos no felices, que son los que se rompen sin que nadie mire: rechazar deja el estado `rejected` y no avanza; cancelar detiene; los overrides de configuración ganan a los defaults. Los asserts de efectos en BD (fila versionada, diff en audit log) pertenecen a integración; en E2E afirma lo que el usuario VE.

## 9. Descargas y uploads

> Descargas: **solo si el módulo storage existe.**

**Descargas**: registra el listener **antes** del click (si no, la descarga puede dispararse antes de que escuches) y verifica integridad por checksum contra el valor conocido del seed — "se descargó algo" no demuestra que se descargó lo correcto.

```ts
import { createHash } from 'node:crypto';
import { readFile } from 'node:fs/promises';

test('el fichero descargado es íntegro', async ({ page }) => {
  const { item, sha256 } = await seedItemWithFile(); // fichero real en storage + checksum en fila
  await page.goto('/library');
  const card = page.getByTestId(`item-card-${item.id}`);
  const downloadPromise = page.waitForEvent('download');
  await card.getByRole('button', { name: /descargar/i }).click();
  const download = await downloadPromise;
  const bytes = await readFile(await download.path());
  expect(createHash('sha256').update(bytes).digest('hex')).toBe(sha256);
});
```

**Uploads**: `setInputFiles` con fixtures de `packages/test-utils/fixtures/`. Prueba también el rechazo — suele ser criterio de verificación del planning:

```ts
test('un fichero que incumple los requisitos se rechaza con mensaje claro', async ({ page }) => {
  await page.goto('/settings');
  const input = page.getByLabel(/imagen/i);
  await input.setInputFiles(fixturePath('img-valida-2000px.png'));
  await expect(page.getByRole('img', { name: /previsualización/i })).toBeVisible();
  await input.setInputFiles(fixturePath('img-pequena-640px.png'));
  await expect(page.getByRole('alert')).toContainText(/tamaño mínimo/i);
});
```

## 10. Tags por fase

Todo spec lleva el tag de la fase que cubre (`{ tag: ['@f0'] }` … `@fN`; `@td` para la fase de design system), y los E2E de fase llevan además `@phase`. Por qué: permite ejecutar la porción relevante mientras trabajas una tarea (`pnpm test:e2e --grep @f2`) y define la **regla de no-regresión** del planning: al cerrar cualquier tarea de F_n, deben seguir en verde los specs `@f0`…`@f(n)`.

Los **E2E sagrados** del planning tienen doble vida — no las confundas:

| | Spec mockeado (en suite, corre en CI) | Verificación real de la tarea (NO en suite) |
|---|---|---|
| Naturaleza | Flujo completo con APIs fake, determinista, coste $0 | Flujo real con APIs de pago, coste anotado, gate CUA |
| Cuándo | En cada push, para siempre | Una vez, al cerrar la tarea de fase |

El spec mockeado protege el flujo para siempre y a coste cero; la verificación real se ejecuta **una vez, como cierre de la tarea**, con `agent-browser` reproduciendo el flujo humano y evidencia persistida en `docs/verifications/<TASK-ID>/` (ver cua.md). No intentes meter la versión con APIs reales en la suite: gastaría dinero en cada push y su no-determinismo la haría roja de forma aleatoria.

## 11. CI vs local

- **Corre en CI** (ver ci.md): toda la suite E2E mockeada, en el build de producción de Next, con `retries: 2`, trace/screenshot/video subidos como artifacts en fallo. El job es autosuficiente: NO levanta compose ni migra/siembra a nivel de job — `pnpm test:e2e` lo hace todo vía el stack script (§2). El workflow instala Chromium con `npx playwright install --with-deps chromium` y cachea el binario.
- **NO corre en CI**: el gate CUA (`agent-browser`), `pnpm test:live`, y las verificaciones de fase con APIs reales. Son acciones humanas/agénticas de cierre de tarea con presupuesto, no jobs repetibles.
- En local, para iterar en segundos: lanza el stack tú mismo en otra terminal (`pnpm e2e:stack`) y `reuseExistingServer: !process.env.CI` lo detectará y lo reutilizará sin tocarlo. Si el stack lo arranca Playwright, **lo apaga al terminar la suite** (con todo su árbol: web, worker y testcontainer) — no esperes que sobreviva entre ejecuciones.

## 12. Anti-flakiness

Reglas duras, en orden de frecuencia con que salvan la suite:

1. **Selectores por rol primero** (`getByRole`, `getByLabel`): prueban además que la UI es accesible y sobreviven a refactors de markup. `getByTestId` como segunda opción para superficies sin semántica clara. **Prohibido**: selectores CSS por clase, `nth()`, XPath — se rompen con cualquier cambio de estilo y fallan en silencio seleccionando otro elemento.
2. **Espera siempre por condición observable, jamás por tiempo**: web-first assertions, `expect.poll`, `toPass()`. Cero `waitForTimeout` (greppea la suite en review). Cero `networkidle` (§7: el SSE lo rompe estructuralmente).
3. **Retries solo en CI**. Localmente `retries: 0`: si un test necesita reintento en tu máquina, tiene una carrera — arréglala hoy, porque en CI será un 10 % de builds rojos.
4. **Datos únicos por spec, ninguna dependencia de orden**: cada test crea sus entidades (factories, §6) y localiza por sus IDs/nombres únicos. `fullyParallel` debe poder barajar los tests sin que nada cambie.
5. **`mode: 'serial'` solo dentro de un journey de fase** (`e2e/phases/*`): ahí los pasos son un único recorrido con estado acumulado. En el resto de la suite, cada test es independiente y re-ejecutable solo.
6. **Timeouts generosos y localizados**: sube el timeout del `expect` concreto que espera un paso lento (`{ timeout: 60_000 }`), no el global — un timeout global inflado convierte cada fallo real en minutos de espera.
7. **Fakes deterministas**: latencias fijas y transiciones scriptadas en los fakes; nada aleatorio en E2E (§4).

Cuando un E2E falle en CI: descarga el trace (`retain-on-failure` lo conserva en cada fallo) y ábrelo con `npx playwright show-trace` antes de tocar nada — el 90 % de los diagnósticos están ahí (screenshot por acción, red, consola, snapshot del DOM).
