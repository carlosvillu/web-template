# Estado de cliente (Zustand) y cliente SSE

Cómo se modela el estado compartido de cliente en `apps/web` (Zustand con factory + provider) y — **solo si el módulo SSE está en el F0 del proyecto** — cómo entran los eventos SSE del servidor hasta la UI. Los tests de todo lo de aquí los define `testing/references/frontend.md`.

> **Alcance por módulos**: §1–§2 y §6 (stores Zustand) aplican a cualquier proyecto con estado compartido de cliente. **§3–§5 (reducer de eventos, cliente SSE, hook de dominio) SOLO aplican si el módulo SSE existe en el F0** (lo eligió el bootstrap; el endpoint servidor es de la skill backend). Sin módulo SSE: no hay estado "en vivo", las lecturas llegan por RSC + api-client y no se implementa nada de §3–§5.
>
> Los bloques de código son PATRÓN, no contrato literal: los nombres de eventos, shapes y campos los define `@app/core` en cada proyecto — importa los exports REALES y construye contra ellos. Si el contrato entregado difiere de lo esbozado aquí, manda el contrato.

## Índice

1. [Decisión: Zustand sí, TanStack Query no (v1)](#1-decisión-zustand-sí-tanstack-query-no-v1)
2. [Store por página: factory + provider + hook](#2-store-por-página-factory--provider--hook)
3. [Reducer puro de eventos SSE *(módulo SSE)*](#3-reducer-puro-de-eventos-sse-módulo-sse)
4. [use-event-source.ts: el cliente SSE transversal *(módulo SSE)*](#4-use-event-sourcets-el-cliente-sse-transversal-módulo-sse)
5. [Hook de dominio: componer SSE + store *(módulo SSE)*](#5-hook-de-dominio-componer-sse--store-módulo-sse)
6. [Otros stores](#6-otros-stores)
7. [Qué NO va aquí](#7-qué-no-va-aquí)

---

## 1. Decisión: Zustand sí, TanStack Query no (v1)

- **Zustand es el dueño del estado compartido de página.** Cuando varios componentes hermanos consumen a la vez el mismo estado (un snapshot + deltas en vivo, una selección compartida), eso es exactamente un store con selectores, no N `useState` sincronizados a mano.
- **SIN TanStack Query en v1.** Las listas llegan por RSC + fetch al api-client (`references/architecture.md`); el estado vivo (si existe) llega por SSE. Añadir RQ hoy sería una segunda capa de caché sin consumidor. Si duele (paginación con caché client-side, mutaciones optimistas repetidas, revalidación fina), se reevalúa **deliberadamente actualizando esta skill** — nunca con un `npm install` silencioso.
- **Sin stores globales de módulo.** Prohibido `create()` exportando un hook a nivel de módulo:

```ts
// ❌ PROHIBIDO: el módulo se comparte entre requests en el servidor (SSR) —
// el estado de un request contamina otro — y en cliente sobrevive a la navegación:
// vuelves a /items/otro-id y ves el estado zombi del recurso anterior.
export const useItemStore = create<ItemStore>()((set) => ({ /* ... */ }));
```

La alternativa obligatoria es el patrón de §2: **una instancia por montaje de página**, creada dentro del árbol de React.

## 2. Store por página: factory + provider + hook

Dos ficheros en `apps/web/src/stores/`: el reducer puro (si hay eventos, §3) y `<x>-store.tsx` (`'use client'` — extensión `.tsx`: contiene el JSX del Provider), que reúne las tres piezas del patrón — factory + provider + hook. La página (RSC) hace fetch del snapshot vía api-client y monta `<XStoreProvider initial={snapshot}>` alrededor del client shell.

```tsx
// apps/web/src/stores/item-store.tsx (patrón; el shape real lo dictan los contratos de core)
'use client';

import { createContext, use, useRef, type ReactNode } from 'react';
import { useStore } from 'zustand';
import { createStore } from 'zustand/vanilla';
import type { ItemSnapshot, EntryChanged, Entry } from '@app/core/contracts';
import { applyItemEvent, indexEntries } from './apply-event';

export interface ItemState {
  entries: Record<string, Entry>; // indexado por id — acceso O(1) para los deltas
  selectedEntryId: string | null; // entrada abierta en el panel lateral
}

export interface ItemActions {
  applySnapshot: (snapshot: ItemSnapshot) => void;   // SUSTITUYE el estado — contrato del stream
  applyEntryChanged: (delta: EntryChanged) => void;  // delta solo a su entrada
  selectEntry: (entryId: string | null) => void;
}

export type ItemStore = ItemState & ItemActions;

export const createItemStore = (initial: ItemSnapshot) =>
  createStore<ItemStore>()((set) => ({
    entries: indexEntries(initial.entries),
    selectedEntryId: null,
    applySnapshot: (snapshot) => set((s) => applyItemEvent(s, { event: 'snapshot', ...snapshot })),
    applyEntryChanged: (delta) => set((s) => applyItemEvent(s, { event: 'entry_changed', ...delta })),
    selectEntry: (entryId) => set({ selectedEntryId: entryId }),
  }));

export type ItemStoreApi = ReturnType<typeof createItemStore>;

const ItemStoreContext = createContext<ItemStoreApi | null>(null);

export function ItemStoreProvider({ initial, children }: { initial: ItemSnapshot; children: ReactNode }) {
  const storeRef = useRef<ItemStoreApi | null>(null);
  storeRef.current ??= createItemStore(initial); // lazy-init en render: una instancia por montaje
  return <ItemStoreContext value={storeRef.current}>{children}</ItemStoreContext>; // React 19: Context como provider
}

export function useItemStore<T>(selector: (state: ItemStore) => T): T {
  const store = use(ItemStoreContext);
  if (store === null) throw new Error('useItemStore requiere <ItemStoreProvider> (client shell de la página)');
  return useStore(store, selector);
}
```

Por qué así y no de otra forma:

- **Factory + provider** porque la instancia nace y muere con la página: navegar a otro recurso monta un provider nuevo con SU snapshot — imposible el estado zombi. En SSR, cada render crea su instancia; nada vive en scope de módulo.
- **`useRef` + `??=`** para crear el store exactamente una vez por montaje (React permite la lazy-init de refs en render), no una vez por render.
- **Acciones de dominio, no `setState` genérico.** Los componentes llaman `applyEntryChanged(delta)`, nunca `set({entries: ...})` a pelo: la transición vive en un solo sitio (el reducer de §3) y es testeable.
- **`initial` es el snapshot del contrato**, no props sueltas: el mismo shape que emite el SSE al conectar (si existe), así el hidrato inicial y el re-snapshot pasan por el mismo código.
- **Las mutaciones de servidor NO tocan el store**: son POSTs vía api-client; el estado nuevo llega por SSE (delta o re-snapshot) o re-fetch. Un toggle puramente local sí es acción del store.

### Selectores

Un valor → selector directo. Varios valores → `useShallow` (de `zustand/react/shallow`): sin él, el objeto literal nuevo de cada render fuerza re-render siempre.

```ts
import { useShallow } from 'zustand/react/shallow';

const status = useItemStore((s) => s.entries[entryId]?.status); // ✅ primitivo: compara por Object.is

const { selectedEntryId, selectEntry } = useItemStore(
  useShallow((s) => ({ selectedEntryId: s.selectedEntryId, selectEntry: s.selectEntry })), // ✅ shallow
);

const todo = useItemStore((s) => s); // ❌ suscribe a TODO: re-render por cada delta
```

Las derivaciones con sustancia (entries → estructura de vista) NO van en el selector: selecciona `s.entries` y deriva con una función pura co-locada (el React Compiler memoiza el cálculo).

## 3. Reducer puro de eventos SSE *(módulo SSE)*

La transición evento→estado es una **función pura separada del hook y del store**: se testea sin DOM, sin React y sin fakes (`testing/references/frontend.md`: es lógica de transformación, la capa donde vive el valor). Los eventos son una **discriminated union Zod de `@app/core`** (decisión vinculante: eventos SSE = discriminated unions), espejo del contrato del PRD. El discriminador y los shapes exactos los define core — impórtalos, no los redeclares.

```ts
// packages/core (lo posee core; aquí solo se consume) — esbozo del patrón
export const ItemEventSchema = z.discriminatedUnion('event', [
  SnapshotEventSchema,      // el estado COMPLETO
  EntryChangedEventSchema,  // delta de una entrada
  HeartbeatEventSchema,     // cada ~25 s, mantiene viva la conexión
]);
export type ItemEvent = z.infer<typeof ItemEventSchema>;
export const ITEM_EVENT_TYPES = ['snapshot', 'entry_changed', 'heartbeat'] as const;
```

```ts
// apps/web/src/stores/apply-event.ts — SIN 'use client': es TypeScript puro
import type { ItemEvent, Entry } from '@app/core/contracts';

export interface ItemEventState {
  entries: Record<string, Entry>;
}

export const indexEntries = (entries: Entry[]): Record<string, Entry> =>
  Object.fromEntries(entries.map((e) => [e.id, e]));

export function applyItemEvent(state: ItemEventState, event: ItemEvent): Partial<ItemEventState> {
  switch (event.event) {
    case 'snapshot':
      // SUSTITUYE, no mergea: el snapshot ES el estado completo. Entradas eliminadas
      // en servidor desaparecen; las nuevas aparecen. Mergear dejaría entradas
      // fantasma tras una reconexión — exactamente lo que testea
      // testing/references/frontend.md ("sin estado fantasma").
      return { entries: indexEntries(event.entries) };

    case 'entry_changed': {
      const prev = state.entries[event.entryId];
      // Delta de una entrada desconocida (p. ej. fila nueva creada en servidor): no
      // inventes un objeto parcial — ignora y confía en el siguiente snapshot.
      if (!prev) return {};
      return {
        entries: {
          ...state.entries, // inmutable: solo cambia la referencia de la entrada tocada
          [event.entryId]: {
            ...prev,
            status: event.status,
            // mapeo delta→campos EXPLÍCITO, campo a campo
          },
        },
      };
    }

    case 'heartbeat':
      return {}; // no toca estado: ningún selector re-renderiza
  }
}
```

Reglas: el mapeo delta→campos es **explícito** (nada de `{...prev, ...delta}`: si el contrato cambia, que lo detecte el compilador, no producción); un delta jamás toca otra entrada; el reducer devuelve `Partial` para que `set` de Zustand haga el merge de primer nivel.

## 4. use-event-source.ts: el cliente SSE transversal *(módulo SSE)*

Hook propio en `apps/web/src/hooks/` (~100 líneas), **sin librería npm**: el contrato de reconexión (query param `lastEventId`, backoff, visibility) es nuestro, y ninguna librería lo implementa como lo necesitamos. Es transversal: no sabe nada del dominio.

Comportamientos que DEBE tener (el porqué de cada uno):

1. **Estados `'connecting' | 'open' | 'reconnecting' | 'closed'`** — la UI pinta el estado de conexión (badge `role="status"`) y decide fallbacks (p. ej. revalidación periódica si el SSE no levanta, si el PRD lo pide).
2. **`EventSource` reconecta solo** cuando el error es transitorio (`readyState === CONNECTING`) y reenvía `Last-Event-ID` como header él mismo: no le estorbes, solo marca `'reconnecting'`.
3. **Al RECREAR la conexión manualmente** (error fatal `readyState === CLOSED`, o vuelta de background) pasa `?lastEventId=` como **query param**: `EventSource` no admite headers custom, y el endpoint del servidor acepta ambas vías (skill backend, `references/api.md`).
4. **Backoff exponencial con jitter, cap ~30 s** — sin jitter, todas las pestañas martillean el servidor a la vez tras un reinicio.
5. **Pausa en `visibilitychange` oculto, reconexión al volver** — una pestaña de fondo no necesita el stream y cada conexión SSE abierta es un handler vivo en el servidor. Al volver, el servidor re-snapshotea y §3 sustituye: no se pierde nada.
6. **Cleanup estricto** (`es.close()` + `clearTimeout` en el return del effect) — sin él, cada navegación deja un stream zombi consumiendo conexión.
7. **`useEffectEvent` (React 19.2)** para `onEvent`: el effect depende solo de `[url, enabled]`, así un callback inline en el consumidor no re-suscribe la conexión en cada render.

```ts
// apps/web/src/hooks/use-event-source.ts (esqueleto)
'use client';

import { useEffect, useEffectEvent, useRef, useState } from 'react';

export type EventSourceStatus = 'connecting' | 'open' | 'reconnecting' | 'closed';

interface UseEventSourceOptions {
  events: readonly string[]; // eventos SSE con nombre ("event: snapshot") — llegan por addEventListener, no por onmessage
  onEvent: (type: string, ev: MessageEvent<string>) => void;
  enabled?: boolean;         // false → cerrado (p. ej. recurso en estado terminal que ya no emite)
}

const MAX_BACKOFF_MS = 30_000;

export function useEventSource(url: string, { events, onEvent, enabled = true }: UseEventSourceOptions) {
  const [status, setStatus] = useState<EventSourceStatus>(enabled ? 'connecting' : 'closed');
  // lastEventId expuesto se actualiza SOLO en transiciones de conexión: actualizarlo por
  // evento sería un re-render por delta/heartbeat sin valor de UI. El tracking fino es un ref.
  const [lastEventId, setLastEventId] = useState('');
  const lastEventIdRef = useRef('');

  const fireEvent = useEffectEvent(onEvent); // siempre ve el onEvent actual sin re-suscribir

  useEffect(() => {
    if (!enabled) {
      setStatus('closed');
      return;
    }
    let es: EventSource | null = null;
    let retryTimer: ReturnType<typeof setTimeout> | null = null;
    let attempt = 0;
    let disposed = false;

    const connect = () => {
      const id = lastEventIdRef.current;
      es = new EventSource(id ? `${url}${url.includes('?') ? '&' : '?'}lastEventId=${encodeURIComponent(id)}` : url);

      es.onopen = () => { attempt = 0; setStatus('open'); setLastEventId(lastEventIdRef.current); };

      for (const type of events) {
        es.addEventListener(type, (ev) => {
          const msg = ev as MessageEvent<string>;
          if (msg.lastEventId) lastEventIdRef.current = msg.lastEventId; // id: monotónico (contrato del stream)
          fireEvent(type, msg);
        });
      }

      es.onerror = () => {
        if (disposed) return;
        if (es!.readyState === EventSource.CONNECTING) { setStatus('reconnecting'); return; } // el navegador ya reintenta
        es!.close(); // CLOSED: reintento manual con backoff + jitter
        setStatus('reconnecting');
        setLastEventId(lastEventIdRef.current);
        const delay = Math.min(MAX_BACKOFF_MS, 1_000 * 2 ** attempt) * (0.5 + Math.random() * 0.5);
        attempt += 1;
        retryTimer = setTimeout(connect, delay);
      };
    };

    const onVisibility = () => {
      if (document.visibilityState === 'hidden') {
        es?.close();
        if (retryTimer) clearTimeout(retryTimer);
        setStatus('closed');
      } else {
        attempt = 0;
        setStatus('connecting');
        connect(); // con ?lastEventId= → el servidor re-snapshotea al reconectar
      }
    };

    setStatus('connecting');
    connect();
    document.addEventListener('visibilitychange', onVisibility);

    return () => {
      disposed = true;
      document.removeEventListener('visibilitychange', onVisibility);
      if (retryTimer) clearTimeout(retryTimer);
      es?.close();
    };
  }, [url, enabled]);

  return { status, lastEventId };
}
```

Los timers del backoff se testean con `vi.useFakeTimers()` avanzando el reloj dentro de `act` — jamás sleeps reales (`testing/references/frontend.md`).

## 5. Hook de dominio: componer SSE + store *(módulo SSE)*

El hook de dominio que une las piezas: `useEventSource` recibe los eventos crudos, aquí se **validan con el schema Zod del contrato y se despachan al store**. Es la ÚNICA puerta de entrada del estado en vivo: ningún componente escucha SSE por su cuenta.

```ts
// apps/web/src/hooks/use-item-events.ts (patrón)
'use client';

import { ITEM_EVENT_TYPES, ItemEventSchema } from '@app/core/contracts';
import { useItemStore } from '@/stores/item-store';
import { useEventSource } from './use-event-source';

export function useItemEvents(itemId: string) {
  const applySnapshot = useItemStore((s) => s.applySnapshot);
  const applyEntryChanged = useItemStore((s) => s.applyEntryChanged);

  const { status, lastEventId } = useEventSource(`/api/items/${itemId}/events`, {
    events: ITEM_EVENT_TYPES,
    onEvent: (_type, ev) => {
      let payload: unknown;
      try { payload = JSON.parse(ev.data); } catch { return; } // data corrupta: ignora, no rompas el stream
      const parsed = ItemEventSchema.safeParse(payload);
      if (!parsed.success) return; // evento desconocido o shape inválido → ignorar (forward-compat)
      switch (parsed.data.event) {
        case 'snapshot': applySnapshot(parsed.data); break;      // SUSTITUYE (§3)
        case 'entry_changed': applyEntryChanged(parsed.data); break;
        case 'heartbeat': break; // solo mantiene viva la conexión; no toca el store
      }
    },
  });

  return { status, lastEventId };
}
```

- Cómo viaja el evento en el frame `data:` (payload completo con su discriminador, o `{type, data}`) lo fija el contrato de core — valida contra ese contrato exacto, no contra una suposición.
- Se monta **una vez** en el client shell de la página (dentro del provider del store); el resto de componentes lee del store con selectores, no de este hook.
- **Tras una reconexión el servidor manda re-snapshot y `applySnapshot` sustituye el estado.** Este es el contrato exacto que `testing/references/frontend.md` testea con un `FakeEventSource` (snapshot puebla → delta toca solo su entrada → re-snapshot sin estado fantasma): esos tests son la especificación ejecutable de este hook — escríbelos con él. En `renderHook`, el `wrapper` es el provider del store con un snapshot inicial de las factories del proyecto.
- El badge de conexión pinta `status` en un `role="status"` con accessible name (p. ej. `aria-label="conexión"`).

## 6. Otros stores

El patrón factory + provider de §2 se repite **solo** cuando hay estado compartido real entre componentes hermanos que no cuelga del servidor — p. ej. una selección múltiple si la comparten grid, toolbar de acciones bulk y diálogo de confirmación. Reglas:

- **Un `useState` local NO se promociona a store por costumbre.** Un diálogo abierto, un hover, un filtro de una sola vista: `useState`/`useReducer` en el componente. Store solo cuando el lifting a props cruza ≥2 niveles hacia ≥2 consumidores.
- **Estado de formularios jamás en Zustand**: react-hook-form es su dueño (`references/forms.md`).
- **Datos de servidor jamás copiados a un store "para cachearlos"**: eso es reinventar TanStack Query mal — las listas se re-piden por RSC/fetch (§1).
- Mismo esqueleto siempre (factory `createXStore` + `XStoreProvider` + `useXStore` en `stores/x-store.tsx`): un solo patrón por problema, como manda el principio 6 del SKILL.md.

## 7. Qué NO va aquí

- **El endpoint SSE del servidor** (ReadableStream, heartbeat, soporte de `Last-Event-ID`/`?lastEventId=`, config del reverse proxy para streaming) → skill **backend**, `references/api.md`.
- **Consumo de la API REST y páginas RSC** (api-client, snapshot inicial de la página) → `references/architecture.md`.
- **Cómo testear stores, reducer y hooks SSE** (FakeEventSource, jsdom, fake timers) → `testing/references/frontend.md` — fuente de verdad; este documento no define tests.
