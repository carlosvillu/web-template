# Testing de frontend (apps/web)

Testing de componentes y lógica de UI de `apps/web` con **Vitest (environment jsdom) + @testing-library/react + @testing-library/user-event + msw**. Esta capa cubre lógica de UI en aislamiento; el flujo humano completo en navegador real pertenece a Playwright (`apps/web/e2e/`) y al gate CUA de cada tarea.

## Índice

1. [Alcance y criterio de entrada](#1-alcance-y-criterio-de-entrada)
2. [Setup jsdom](#2-setup-jsdom)
3. [Componentes de visualización compleja: transformación pura + smoke](#3-componentes-de-visualización-compleja)
4. [SSE: hook con EventSource fake](#4-sse-hook-con-eventsource-fake)
5. [Paneles y editores con lógica](#5-paneles-y-editores-con-lógica)
6. [Formularios, loading y errores (msw)](#6-formularios-loading-y-errores-msw)
7. [Reglas transversales](#7-reglas-transversales)

---

## 1. Alcance y criterio de entrada

**El criterio para escribir (o no) un unit test de UI es una sola pregunta: ¿este componente/hook tiene lógica condicional o transformación de datos?**

- **Sí → unit test aquí.** Ejemplos típicos: el mapeo de filas de BD a estructuras de render, un recálculo de totales al cambiar una opción, badges condicionales por estado del dato, el estado de reconexión de un cliente SSE, la validación de un formulario.
- **No → NO escribas unit test.** Un componente que solo pinta props (una card, una leyenda, un layout) no tiene nada que pueda romperse que TypeScript no detecte ya; su renderizado real lo cubren E2E/CUA. Un test que solo verifica "renderiza sin explotar" es coste de mantenimiento sin señal. Cada test debe pagar su alquiler.

| Se testea en jsdom | Se testea en E2E/CUA (no aquí) |
|---|---|
| Estado/props/texto renderizado condicional | Layout visual, posiciones, colores "en vivo" |
| Interacción → valor renderizado (opción → total) | Flujo completo multi-página |
| Cliente SSE contra EventSource fake | SSE real atravesando Next/proxy |
| Estados de error/loading con msw | Errores reales de red/backend |

**Server components de Next**: @testing-library/react no renderiza componentes async de servidor de forma soportada. No lo intentes. La regla es estructural: **extrae la lógica del server component a funciones puras** (en `apps/web/src/lib/` o `packages/core`) y testéalas como unit tests normales (sin jsdom); el rendering del server component lo cubre E2E. Ejemplo: una agregación "total del mes por entidad" para un dashboard es una función pura sobre filas, no un test de página.

Ubicación: co-locados junto al código, `src/**/*.test.ts(x)`. Corren con `pnpm test:unit` (proyecto `web:unit`, declarado en `test.projects` del `vitest.config.ts` raíz).

## 2. Setup jsdom

```ts
// apps/web/vitest.config.ts
import { defineConfig } from 'vitest/config';
import react from '@vitejs/plugin-react';

export default defineConfig({
  plugins: [react()],
  test: {
    name: 'web:unit', // OBLIGATORIO: los scripts raíz filtran por --project '*:unit'
    environment: 'jsdom',
    include: ['src/**/*.test.{ts,tsx}'],
    exclude: ['**/*.live.test.ts', '**/node_modules/**'],
    setupFiles: ['@app/test-utils/setup-env', './vitest.setup.ts'],
    unstubGlobals: true, // limpia vi.stubGlobal (EventSource fake, etc.) entre tests
  },
});
```

```ts
// apps/web/vitest.setup.ts
import '@testing-library/jest-dom/vitest';

// jsdom no implementa varias APIs de layout/observación que muchas librerías de UI
// exigen para montar (canvas de grafos, virtual lists, charts). Centraliza los
// mocks aquí para que ningún test los repita. Añade SOLO los que tu librería
// necesite de verdad — cada mock es una mentira controlada.
class ResizeObserverMock {
  constructor(private cb: ResizeObserverCallback) {}
  observe(target: Element) {
    this.cb([{ target } as ResizeObserverEntry], this as unknown as ResizeObserver);
  }
  unobserve() {}
  disconnect() {}
}
globalThis.ResizeObserver = ResizeObserverMock as unknown as typeof ResizeObserver;

Object.defineProperty(window, 'matchMedia', {
  writable: true,
  value: (query: string) => ({
    matches: false, media: query, onchange: null,
    addEventListener() {}, removeEventListener() {},
    addListener() {}, removeListener() {}, dispatchEvent: () => false,
  }),
});

// jsdom devuelve 0 en offsetWidth/Height: librerías que miden viewport necesitan dimensiones
Object.defineProperties(HTMLElement.prototype, {
  offsetWidth: { get: () => 1280 },
  offsetHeight: { get: () => 720 },
});
```

Si usas una librería de canvas/grafos (React Flow, etc.), añade además los mocks que su documentación de testing indique (p. ej. `DOMMatrixReadOnly`, `SVGElement.getBBox`) — **solo si esa librería está en tu proyecto**: sin ellos el componente monta vacío y los tests dan falsos negativos silenciosos.

## 3. Componentes de visualización compleja

Para cualquier vista compleja derivada de datos (un canvas de nodos, una tabla agregada, un gráfico), divide el testing en dos piezas de coste muy distinto:

**(a) La transformación pura — donde vive casi todo el valor.** La derivación `filas → estructura de render` (agrupación, estado→badge, totales, extractos) es una función pura. Testéala directamente, sin renderizar nada: es rápido, no necesita mocks y sobrevive a cualquier rediseño visual.

```ts
// apps/web/src/components/board/rows-to-board.test.ts
import { expect, test } from 'vitest';
import { makeItem } from '@app/test-utils';
import { rowsToBoard } from './rows-to-board';

test('un item bloqueado produce una celda con badge y su dependencia como edge', () => {
  const items = [
    makeItem({ id: 'i1', status: 'blocked', blockedBy: 'i2' }),
    makeItem({ id: 'i2', status: 'open' }),
  ];
  const { cells, edges } = rowsToBoard(items);
  expect(cells.find((c) => c.id === 'i1')?.badge).toBe('blocked');
  expect(edges).toContainEqual(expect.objectContaining({ source: 'i2', target: 'i1' }));
});
```

**(b) Un smoke test renderizado** (uno, no uno por estado): monta el componente con los mocks de §2 y verifica que el contenido derivado aparece. Envuelve en el provider que el componente exija.

```tsx
test('pinta una celda por item con estado visible', async () => {
  render(
    <BoardProvider initial={{ items: [makeItem({ id: 'i1', status: 'running' })] }}>
      <Board />
    </BoardProvider>,
  );
  const cell = await screen.findByRole('article', { name: /i1/i }); // el componente expone accessible name
  expect(within(cell).getByText(/running/i)).toBeInTheDocument();
});
```

**Qué SÍ puedes assertar en jsdom**: presencia/ausencia de elementos, su `data` renderizada (texto, totales, extractos), número de elementos, que un click dispara el callback.

**Qué NO intentes assertar en jsdom**: posiciones x/y tras un layout automático, rutas de edges, pan/zoom, drag, animaciones, solapes visuales. jsdom no hace layout: cualquier assert geométrico es ficción — pertenece a E2E/CUA.

## 4. SSE: hook con EventSource fake

> **Solo si el módulo SSE existe en tu F0.**

jsdom no implementa `EventSource`. Usa un fake controlable desde el test (exportado por `@app/test-utils`) e instálalo con `vi.stubGlobal`. El contrato a testear es el del producto: **snapshot al conectar → deltas → tras reconexión llega un re-snapshot que SUSTITUYE (no mergea) el estado**. Testea ese contrato observable, no la mecánica interna de reconexión del hook.

Nota de armonización con la skill `frontend`: `FakeEventSource` declara las constantes estáticas del estándar (`static CONNECTING = 0; static OPEN = 1; static CLOSED = 2`) para que el código del hook que compara `readyState` funcione idéntico contra el fake; si el hook lee de un store, monta los `renderHook` con su provider (`wrapper`).

```ts
// packages/test-utils/src/fake-event-source.ts (esquema)
export class FakeEventSource {
  static instances: FakeEventSource[] = [];
  static last() { return this.instances.at(-1)!; }
  static reset() { this.instances = []; }

  readyState = 0;
  onopen: ((ev: Event) => void) | null = null;
  onerror: ((ev: Event) => void) | null = null;
  private listeners = new Map<string, Set<(ev: MessageEvent) => void>>();

  constructor(public url: string) { FakeEventSource.instances.push(this); }
  addEventListener(type: string, fn: (ev: MessageEvent) => void) {
    (this.listeners.get(type) ?? this.listeners.set(type, new Set()).get(type)!).add(fn);
  }
  removeEventListener(type: string, fn: (ev: MessageEvent) => void) { this.listeners.get(type)?.delete(fn); }
  close() { this.readyState = 2; }

  // ---- helpers solo-test ----
  open() { this.readyState = 1; this.onopen?.(new Event('open')); }
  emit(type: string, data: unknown, id = '') {
    const ev = new MessageEvent(type, { data: JSON.stringify(data), lastEventId: id });
    this.listeners.get(type)?.forEach((fn) => fn(ev));
  }
  fail() { this.onerror?.(new Event('error')); }
}
```

```tsx
// apps/web/src/hooks/use-live-events.test.tsx
import { renderHook, act } from '@testing-library/react';
import { beforeEach, expect, test, vi } from 'vitest';
import { FakeEventSource, makeItem } from '@app/test-utils';
import { useLiveEvents } from './use-live-events';

beforeEach(() => {
  FakeEventSource.reset();
  vi.stubGlobal('EventSource', FakeEventSource);
});

test('snapshot puebla el estado; un delta actualiza solo su entidad', () => {
  const { result } = renderHook(() => useLiveEvents('id_01'));
  const es = FakeEventSource.last();

  act(() => {
    es.open();
    es.emit('snapshot', { items: [makeItem({ id: 'a', status: 'running' }), makeItem({ id: 'b' })] }, '1');
  });
  expect(result.current.items.a.status).toBe('running');

  act(() => es.emit('changed', { id: 'a', status: 'succeeded' }, '2'));
  expect(result.current.items.a.status).toBe('succeeded');
  expect(result.current.items.b.status).toBe(makeItem().status); // el delta no toca al resto

  const before = result.current.items;
  act(() => es.emit('heartbeat', {}, '3'));
  expect(result.current.items).toBe(before); // heartbeat no provoca re-render de datos
});

test('tras reconectar, el re-snapshot sustituye el estado (sin entidades fantasma)', () => {
  const { result } = renderHook(() => useLiveEvents('id_01'));
  const es1 = FakeEventSource.last();
  act(() => {
    es1.open();
    es1.emit('snapshot', { items: [makeItem({ id: 'a' })] }, '1');
    es1.fail(); // conexión caída
  });

  const es2 = FakeEventSource.last(); // el hook (o el EventSource nativo) reconecta
  act(() => {
    es2.open();
    es2.emit('snapshot', { items: [makeItem({ id: 'a2' })] }, '9');
  });
  expect(result.current.items.a2).toBeDefined();
  expect(result.current.items.a).toBeUndefined(); // sustituye, no mergea
});
```

Si la reconexión de tu implementación es asíncrona (setTimeout con backoff), usa `vi.useFakeTimers()` y avanza el reloj dentro de `act`; no metas sleeps reales.

## 5. Paneles y editores con lógica

Los paneles/editores con lógica condicional son exactamente lo que esta capa existe para cubrir. Regla de oro común: **interactúa como el usuario (roles/texto + `userEvent`) y asserta el valor renderizado o el payload emitido** — nunca estado interno de React. Dale a cada fila/campo un accessible name (`aria-label` o heading): no es solo accesibilidad, es tu API de test estable.

### Patrón 1 — badges/estado condicional por dato + edición que emite

```tsx
test('badge según origen del dato, y editar emite el objeto nuevo', async () => {
  const user = userEvent.setup();
  const entity = makeEntity({
    fields: [
      { text: 'Valor A', source: { quote: 'cita literal', confidence: 0.95 } },
      { text: 'Valor B', source: null },
    ],
  });
  const onSave = vi.fn();
  render(<EntityEditor entity={entity} onSave={onSave} />);

  const row0 = screen.getByRole('group', { name: /valor a/i });
  expect(within(row0).getByText(/extraído/i)).toBeInTheDocument();
  expect(within(row0).getByText(/cita literal/i)).toBeInTheDocument(); // la evidencia es visible

  const row1 = screen.getByRole('group', { name: /valor b/i });
  expect(within(row1).getByText(/inferido/i)).toBeInTheDocument();

  await user.click(within(row0).getByRole('button', { name: /editar/i }));
  await user.clear(within(row0).getByRole('textbox'));
  await user.type(within(row0).getByRole('textbox'), 'Valor A editado');
  await user.click(screen.getByRole('button', { name: /guardar/i }));

  expect(onSave).toHaveBeenCalledWith(
    expect.objectContaining({
      fields: expect.arrayContaining([expect.objectContaining({ text: 'Valor A editado' })]),
    }),
  );
});
```

### Patrón 2 — recálculo renderizado al cambiar una opción

**El valor esperado del assert se calcula A MANO desde los datos de las factories** — si el test re-implementa la fórmula del código, no testea nada. Los datos se construyen en memoria con las factories puras `makeX` (`seedFixtures` es de BD: async, exige `db` e inserta filas — nunca en jsdom).

```tsx
test('cambiar la opción recalcula el total mostrado', async () => {
  const user = userEvent.setup();
  // 12 unidades × $0.90 = $10.80; × $3.40 = $40.80 — calculado a mano
  render(<Panel items={makeItems(12)} rates={[makeRate({ id: 'a', usd: 0.9 }), makeRate({ id: 'b', usd: 3.4 })]} />);

  expect(screen.getByRole('status', { name: /total/i })).toHaveTextContent('$10.80');
  await user.selectOptions(screen.getByRole('combobox', { name: /tarifa/i }), 'b');
  expect(screen.getByRole('status', { name: /total/i })).toHaveTextContent('$40.80');
});
```

### Patrón 3 — reacción de la UI a un rechazo del servidor

Si el servidor puede rechazar un guardado con explicación (validación, guardrail), la regla en sí tiene sus unit tests en `packages/core`: aquí testeas la reacción de la UI a su respuesta, con msw.

```tsx
useHttpMocks(
  http.post('*/api/items/:id/save', () =>
    HttpResponse.json(
      { code: 'blocked', message: 'Regla X violada', details: { suggestion: 'alternativa válida' } },
      { status: 422 },
    ),
  ),
);

test('un rechazo muestra explicación + sugerencia y bloquea la confirmación', async () => {
  const user = userEvent.setup();
  render(<ItemEditor item={makeItem()} />);
  await user.type(screen.getByRole('textbox'), ' contenido problemático');
  await user.click(screen.getByRole('button', { name: /guardar/i }));

  const alert = await screen.findByRole('alert');
  expect(alert).toHaveTextContent(/regla x violada/i);
  expect(alert).toHaveTextContent(/alternativa válida/i); // la sugerencia es accionable
  expect(screen.getByRole('button', { name: /confirmar/i })).toBeDisabled();
});
```

## 6. Formularios, loading y errores (msw)

Mockea HTTP con **msw en modo node** vía `useHttpMocks(...overrides)` de `@app/test-utils` (nunca `vi.mock` del módulo cliente: msw testea también la serialización real de la request). `useHttpMocks` registra el ciclo de vida (`beforeAll/afterEach/afterAll`) y `onUnhandledRequest: 'error'` automáticamente, para que una llamada no mockeada explote en vez de colgar el test; para un override puntual dentro de un test usa el export secundario `server` (`server.use(...)`). Una trampa de jsdom: el `fetch` global de Node exige URLs absolutas — centraliza la base en un helper (`apiUrl('/api/…')` que en test resuelve a `http://localhost:3000`) y escribe handlers con patrón `*/api/...`. Los handlers/fixtures compartidos viven en `packages/test-utils/fixtures/http/`.

Patrón para cualquier formulario (los tres estados — feliz, loading, error):

```tsx
useHttpMocks(); // handlers por defecto; el override puntual va con server.use(...)

test('submit muestra loading y deshabilita; un 500 re-habilita con error visible', async () => {
  server.use(
    http.post('*/api/items', async () => {
      await new Promise((r) => setTimeout(r, 50)); // ventana para assertar el loading
      return HttpResponse.json({ code: 'internal', message: 'boom' }, { status: 500 });
    }),
  );
  const user = userEvent.setup();
  render(<CreateForm />);

  await user.type(screen.getByRole('textbox', { name: /nombre/i }), 'Demo');
  await user.click(screen.getByRole('button', { name: /crear/i }));

  expect(screen.getByRole('button', { name: /creando/i })).toBeDisabled(); // loading observable

  expect(await screen.findByRole('alert')).toHaveTextContent(/error/i);
  expect(screen.getByRole('button', { name: /crear/i })).toBeEnabled(); // recuperable, no atascado
});
```

Qué testear en cada formulario: conmutación de modos si los hay, validación renderizada como mensaje, payload correcto (asserta el body en el handler msw). En formularios de settings con secretos: que un valor guardado NUNCA se re-renderiza en claro (assert negativo: `queryByText(secret)` es null; la UI solo muestra un placeholder enmascarado). Si un componente usa `useRouter`, stubbea `next/navigation` con `vi.mock` mínimo (`{ useRouter: () => ({ push: vi.fn() }) }`).

## 7. Reglas transversales

1. **Queries por rol y texto, en este orden de preferencia**: `getByRole` (con `name`) > `getByLabelText` > `getByText` > `getByTestId` (último recurso, p. ej. celdas de un canvas). Por qué: el test queda acoplado a lo que el usuario percibe, no al DOM; sobrevive a refactors de markup y detecta regresiones de accesibilidad gratis.
2. **`userEvent`, no `fireEvent`**: `userEvent` simula la secuencia real (focus, keydown, input...), que es lo que tus handlers verán en producción. `fireEvent` solo para eventos que userEvent no cubre.
3. **Asíncrono con `findBy*` / `waitFor`**, jamás sleeps. Timers propios (reconexión SSE, debounce) con `vi.useFakeTimers()`.
4. **Sin snapshot tests de componentes**: se convierten en `--update` reflejo y no detectan nada. Los golden files se reservan para outputs deterministas de compiladores/serializadores (ver unit-core.md), no para árboles JSX.
5. **Datos siempre desde las factories de `@app/test-utils`** (`makeX()`): construyen objetos válidos según los contratos Zod de `packages/core`, así un cambio de contrato rompe los tests en compilación, no en producción.
6. **No testees implementación**: nada de assertar `useState` interno, ni contar renders, ni espiar métodos privados. Si no puedes expresarlo como "el usuario hace X y ve Y" (o "el componente emite el payload Z"), probablemente pertenece a otra capa.
7. **Duda razonable = no lo testees aquí**: si el valor del test está en el píxel (layout, color en vivo, contraste), es E2E/CUA; si está en la regla de negocio, es un unit de `packages/core` o integración con Postgres real (ver db-integration.md). Esta capa cubre exactamente el pegamento: interacción → transformación → render.
