# Arquitectura de apps/web — rutas, server/client y datos

Cómo se estructura `apps/web` (Next.js App Router): dónde va la frontera server/client y por dónde entran y salen TODOS los datos. Las reglas de estructura de carpetas y dependencias viven en el SKILL.md; aquí está el detalle de aplicarlas al routing y al data fetching. El mapa de rutas concreto lo dicta el PRD del proyecto (sección de rutas) — esta reference define el patrón, no el listado.

## Índice

1. [Rutas y `app/`](#1-rutas-y-app)
2. [Server vs Client Components](#2-server-vs-client-components)
3. [Datos: todo vía API REST propia](#3-datos-todo-vía-api-rest-propia)
4. [Por qué NO Server Actions ni lecturas directas a BD](#4-por-qué-no-server-actions-ni-lecturas-directas-a-bd)
5. [Qué NO va aquí](#5-qué-no-va-aquí)

---

## 1. Rutas y `app/`

### 1.1 Mapa de rutas → ficheros

Cada ruta del PRD se materializa como `app/(grupo)/<ruta>/page.tsx` componiendo UNA carpeta de dominio de `components/`. La tabla ruta→fichero→dominio se mantiene en el planning; toda página con pantalla propia tiene además su mockup en `docs/mockups/` (vinculante — `design-system.md` §5). Dos rutas existen en todo proyecto del template:

| Ruta | Fichero | Qué es |
|---|---|---|
| `/design-system` | `app/(app)/design-system/page.tsx` | Showcase de tokens y componentes (fase TD) |
| `/login` | `app/login/page.tsx` | Solo si el módulo auth existe — fuera de todo grupo, sin nav |

### 1.2 Route groups: chrome autenticado vs páginas sin sesión

```
app/
├─ (app)/                  # grupo con el CHROME GLOBAL compartido
│  ├─ layout.tsx           # nav global (el mockup del dashboard dicta si es topbar o rail) + región de contenido
│  ├─ page.tsx             # /
│  ├─ <rutas del PRD>/
│  │  ├─ page.tsx
│  │  ├─ loading.tsx       # skeleton de la vista
│  │  └─ error.tsx
│  └─ design-system/
├─ login/page.tsx          # FUERA del grupo (módulo auth): sin sesión, sin nav
├─ api/                    # route handlers → skill backend (references/api.md)
└─ layout.tsx              # root: html/body, tokens, fuentes
```

Reglas del grupo, aprendidas en proyectos anteriores con este arnés:

- **Toda página de la app va DENTRO del grupo con chrome, incluidas las "full-bleed"** (un canvas, un player a pantalla completa): sin el chrome global la página es un callejón sin salida. El viewport se reparte en el layout (`h-dvh` en columna flex; el hijo, `min-h-0 flex-1`), así la vista ocupa todo el alto restante bajo la nav con `h-full` — quien fija el viewport es el layout, no la página. No hace falta ningún `if` condicional en el layout.
- **Las páginas sin sesión quedan fuera** (login): enseñar la nav a quien va a ser rebotado sería enlazar a páginas prohibidas. La protección de rutas NO se hace en layouts: vive en el proxy/middleware y en los propios handlers — territorio de la skill backend.
- **Los destinos de la nav no se declaran en el componente**: viven en `lib/routes.ts` (label, `href`, `matches`, `pending`, `description`), la fuente de verdad que comparten la nav y cualquier superficie que enlace a áreas (tarjetas de home, breadcrumbs). Dos reglas que valen para toda superficie de navegación:
  - **Los destinos de fases futuras se MUESTRAN, deshabilitados** (si el mockup los tiene): `aria-disabled`, fuera del orden de tabulación, sin `href`, y con el motivo **en el nombre accesible** (`aria-label="Métricas · llega en la fase F2"`) — no solo en un `title`, que únicamente aparece con el hover del ratón. Activar uno cuando cierre su fase es **darle `href`**: aparece en todas las superficies a la vez.
  - **«Resaltado» y «página actual» son DOS preguntas, no un booleano.** El resaltado VISUAL usa prefijos de área (`isHighlighted`: `/items/x` resalta «Items»); `aria-current="page"` exige **igualdad exacta** (`isCurrentPage`). Fusionarlas hace que el lector de pantalla anuncie «página actual» en un enlace que en realidad te llevaría a otra vista.

### 1.3 `page/layout/loading/error` delgados

- **`page.tsx`**: `await params` → fetch vía api-client → componer componentes de dominio. Objetivo ~20 líneas; CERO lógica de transformación (va a funciones puras, §2.3) y CERO JSX de presentación más allá de componer. Por qué: una página delgada no necesita tests propios — su contenido lo cubren los tests del dominio y el E2E de la ruta.
- **`layout.tsx`**: estructura + providers compartidos. Nunca fetch de datos que solo usa una página hija.
- **`loading.tsx`**: skeleton con componentes del DS (`components/ui/skeleton.tsx` si el DS lo define). Existe en toda ruta que hace fetch — el streaming de RSC lo muestra gratis mientras la página espera a la API.
- **`error.tsx`**: la ÚNICA pieza de `app/` que lleva `'use client'` (lo exige Next). Pinta el mensaje del error + botón reset; sin lógica de recuperación propia.

### 1.4 Async request APIs: `await` SIEMPRE

En las versiones actuales de Next `params`, `searchParams`, `cookies()` y `headers()` son asíncronos. Tipa `params` como `Promise<...>` y haz `await` sin excepción:

```tsx
// app/(app)/items/page.tsx
interface ItemsPageProps {
  searchParams: Promise<{ status?: string }>;
}

export default async function ItemsPage({ searchParams }: ItemsPageProps) {
  const { status } = await searchParams;
  const items = await api.get(
    `/api/items?${new URLSearchParams({ ...(status && { status }) })}`,
    ItemListSchema,
  );
  return <ItemGrid items={items} />;
}
```

Los filtros de listados van en `searchParams`, no en estado de cliente: URL compartible y el E2E de testing puede navegar directo al estado filtrado.

## 2. Server vs Client Components

### 2.1 Reglas prácticas

1. **Páginas y layouts son Server Components SIEMPRE.** Nunca `'use client'` en un fichero de `app/` (excepción única: `error.tsx`).
2. **`'use client'` en el componente interactivo más profundo** — el formulario, el player, el panel en vivo. No en su contenedor "por si acaso": cada nivel que marcas como client arrastra todo su subárbol de imports al bundle.
3. **Children pattern para providers**: un provider client (`XStoreProvider`, `ThemeProvider`) recibe `children` y NO los convierte en client — los RSC pasan a través como contenido ya renderizado. Es la forma de tener store Zustand por página sin renunciar a que la página sea RSC.
4. **Props serializables = objetos de contratos Zod.** La frontera RSC→client solo transporta JSON plano: pasa tipos inferidos de `@app/core`, nunca funciones, class instances ni shapes ad-hoc. Si necesitas pasar un callback hacia abajo, la frontera está mal puesta: baja el `'use client'` o mueve el estado al store.
5. **Client-only real (una librería que toca `window` al importar) se resuelve con un wrapper client**, no con `dynamic(..., { ssr: false })` en la página — eso está prohibido dentro de un RSC. El wrapper es un client component que se auto-monta tras hidratar; la página lo compone como a cualquier otro.

### 2.2 Ejemplo canónico: página de detalle con estado en vivo *(patrón; el store/SSE solo si el módulo existe)*

```tsx
// app/(app)/items/[id]/page.tsx — RSC delgado: fetch → provider → shell → dominio
import { notFound } from 'next/navigation';
import { ItemSnapshotSchema } from '@app/core/contracts';
import { ApiError } from '@/lib/api-client';
import { api } from '@/lib/api-server';
import { ItemStoreProvider } from '@/stores/item-store';
import { ItemShell } from '@/components/items/item-shell';

interface ItemPageProps {
  params: Promise<{ id: string }>;
}

export default async function ItemPage({ params }: ItemPageProps) {
  const { id } = await params;

  let snapshot;
  try {
    snapshot = await api.get(`/api/items/${id}`, ItemSnapshotSchema);
  } catch (e) {
    if (e instanceof ApiError && e.status === 404) notFound();
    throw e; // el resto lo captura error.tsx
  }

  return (
    <ItemStoreProvider initial={snapshot}>
      <ItemShell itemId={id} />
    </ItemStoreProvider>
  );
}
```

El RSC hace el fetch inicial (snapshot con el que se pinta el primer frame, sin flash de loading en cliente); el provider (client, children pattern) crea el store por página con ese `initial`; el shell (client) monta el hook SSE una única vez y compone las vistas, que leen del store con selectores. Detalle en `references/state-and-sse.md`.

Si una página necesita varios recursos, lánzalos en paralelo (`Promise.all`) — un `await` secuencial por recurso es el waterfall clásico que `vercel-react-best-practices` te va a señalar.

### 2.3 Lógica fuera de los componentes

Los server components async NO se pueden renderizar con Testing Library (testing/references/frontend.md). La regla es estructural, no de tests: **toda transformación de datos vive en funciones puras** y el componente solo las llama.

- **Dónde**: la lógica extraída de un **server component** va a `lib/` o a `packages/core` (un RSC no importa de carpetas de componentes); la lógica de un **client component** se co-loca junto a él (`components/<dominio>/<x>-helpers.ts`); lo que también use el backend/worker, a `packages/core`.
- **Por qué**: una función pura de agregación se testea como unit sin jsdom en milisegundos; la misma lógica inline en el RSC es intesteable salvo por E2E. Además sobrevive a cualquier rediseño del componente.

## 3. Datos: todo vía API REST propia

**Decisión vinculante**: las páginas leen haciendo fetch a la API interna (definida en el PRD) y toda mutación es un fetch a esos mismos route handlers. En web NO hay DAL ni Server Actions (§4); la política de caché la fija el SKILL.md (con datos vivos: `no-store` siempre). La única pieza que implementa esto es `lib/api-client.ts` — nadie escribe `fetch` a mano contra la API.

### 3.1 Spec de `lib/api-client.ts`

| Aspecto | Regla |
|---|---|
| Dos entradas | `lib/api-client.ts` (isomorfo, importable desde `'use client'`) y `lib/api-server.ts` (`import 'server-only'`, SOLO para RSC). `next/headers` es server-only a nivel de grafo de módulos: un módulo compartido con client components no puede importarlo ni dinámicamente. |
| Base URL | **En servidor (RSC y jsdom): `resolveServerBaseUrl(process.env)` — función pura, PRECEDENCIA `INTERNAL_API_URL` (override explícito: otro host/proxy) > `http://localhost:${PORT}` (DERIVADA del puerto real: el web se llama A SÍ MISMO, y `PORT` es la var que Next lee para elegir puerto) > `http://localhost:3000` (default de Next).** Lección de un incidente real: una base HARDCODEADA al 3000 tumba con 500 todas las páginas RSC en cuanto la app arranca en otro puerto — y ningún test lo caza si el stack E2E fija `INTERNAL_API_URL` a mano (esa muleta debe retirarse: que el stack E2E sirva en un puerto distinto y ejercite la derivación). Del `PORT` se valida la FORMA (dígitos: un `PORT=abc` daría una URL inválida), **nunca el RANGO** — `PORT=99999` impide que Next arranque (⇒ el resolver jamás se llama con él) y rechazar `PORT=0` sería peor que no validar: Next SÍ arranca con él (en un puerto EFÍMERO) y caer al 3000 reintroduciría el mismo 500. La lección de fondo: **`process.env.PORT` no es «el puerto del servidor», es «el puerto que se PIDIÓ»** — con `PORT=0` difieren, y ninguna validación del env puede arreglarlo (el puerto real solo existe en el socket). `PORT=0` es **no soportado** en un despliegue self-hosted de puerto fijo. En cliente: rutas RELATIVAS (`''`) — la base es el propio origin y `PORT` no significa nada ahí; el guard de `typeof window` va PRIMERO. En jsdom el fetch de Node exige URL absoluta (testing/references/frontend.md) y los handlers msw usan patrones `*/api/...`, así que el puerto resuelto da igual. |
| Auth *(módulo auth)* | `api-server` reenvía la cookie de sesión con `cookies()` de `next/headers` (el fetch de RSC no la propaga solo). En cliente el navegador la manda gratis. |
| Cache | La política (p. ej. `cache: 'no-store'` SIEMPRE si hay datos vivos) la fija el cliente — nadie lo decide por llamada. |
| Validación | Toda respuesta se parsea con el schema Zod de `@app/core` que se le pasa. Respuesta que no cumple el contrato = error, no datos corruptos aguas abajo. |
| Errores | HTTP no-ok → parsea el envelope `{code, message, details?}` (contrato Zod de core, skill backend) y lanza `ApiError` tipada con `code`, `status` y `details`. |

```ts
// apps/web/src/lib/api-client.ts — núcleo isomorfo; lo importan los client components
import { z } from 'zod';
import { ErrorEnvelopeSchema, type ErrorEnvelope } from '@app/core/contracts';

export class ApiError extends Error {
  constructor(
    readonly code: ErrorEnvelope['code'],
    message: string,
    readonly status: number,
    readonly details?: unknown,
  ) {
    super(message);
    this.name = 'ApiError';
  }
}

// Base de SERVIDOR por precedencia: `resolveServerBaseUrl(env)` — función PURA sobre el env,
// definida en el propio api-client.ts (la tabla de arriba es el contrato; el código es el
// código). Su precedencia se testea en api-client.test.ts.
//
// En navegador: relativa (el origin propio). En jsdom (tests) o servidor: absoluta (el fetch de
// Node la exige). El guard de `typeof window` va PRIMERO: `PORT` es config del PROCESO servidor
// y no significa nada en cliente.
const base = () =>
  typeof window === 'undefined' || process.env.NODE_ENV === 'test'
    ? resolveServerBaseUrl(process.env)
    : '';

export async function apiFetch<S extends z.ZodType>(
  path: string,
  schema: S,
  init: RequestInit & { baseUrl?: string } = {},
): Promise<z.infer<S>> {
  const { baseUrl, ...rest } = init;
  const res = await fetch(`${baseUrl ?? base()}${path}`, { ...rest, cache: 'no-store' });

  if (!res.ok) {
    const body: unknown = await res.json().catch(() => null);
    const envelope = ErrorEnvelopeSchema.safeParse(body);
    if (envelope.success) {
      throw new ApiError(envelope.data.code, envelope.data.message, res.status, envelope.data.details);
    }
    throw new ApiError('internal', `Respuesta sin envelope de ${path}`, res.status);
  }

  return schema.parse(await res.json()) as z.infer<S>;
}

const json = (body: unknown, method: string): RequestInit => ({
  method,
  body: JSON.stringify(body),
  headers: { 'content-type': 'application/json' },
});

export const api = {
  get: <S extends z.ZodType>(path: string, schema: S) => apiFetch(path, schema),
  post: <S extends z.ZodType>(path: string, schema: S, body: unknown) => apiFetch(path, schema, json(body, 'POST')),
  patch: <S extends z.ZodType>(path: string, schema: S, body: unknown) => apiFetch(path, schema, json(body, 'PATCH')),
  del: <S extends z.ZodType>(path: string, schema: S) => apiFetch(path, schema, { method: 'DELETE' }),
};
```

```ts
// apps/web/src/lib/api-server.ts — SOLO server components: cookie de sesión + base interna
import 'server-only';
import { cookies } from 'next/headers';
import type { z } from 'zod';
import { apiFetch } from './api-client';

async function serverFetch<S extends z.ZodType>(path: string, schema: S, init: RequestInit = {}) {
  const cookieHeader = (await cookies()).toString(); // hace la página dinámica: correcto con datos vivos
  return apiFetch(path, schema, {
    ...init,
    baseUrl: resolveServerBaseUrl(process.env), // NUNCA un puerto hardcodeado
    headers: { ...init.headers, ...(cookieHeader && { cookie: cookieHeader }) },
  });
}

export const api = {
  get: <S extends z.ZodType>(path: string, schema: S) => serverFetch(path, schema),
  // post/patch/del: mismo molde que api-client, envolviendo serverFetch
};
```

Regla de imports: los RSC importan `api` de `@/lib/api-server`; los client components, de `@/lib/api-client`. `import 'server-only'` convierte el error de importar el módulo equivocado en fallo de build, no de runtime.

### 3.2 Uso: un GET (RSC) y un POST (client)

```tsx
// GET desde un server component
import { LedgerSchema } from '@app/core/contracts';
import { api } from '@/lib/api-server';
import { aggregateByGroup } from '@/lib/ledger'; // función pura consumida por RSC: vive en lib/ (§2.3)
import { LedgerTable } from '@/components/ledger/ledger-table';

export default async function LedgerPage() {
  const ledger = await api.get('/api/ledger', LedgerSchema);
  return <LedgerTable rows={aggregateByGroup(ledger)} />;
}
```

```ts
// POST desde un client component — una mutación de dominio
'use client';
import { ItemSchema } from '@app/core/contracts';
import { api, ApiError } from '@/lib/api-client';

export function useArchiveItem() {
  return async function archiveItem(itemId: string) {
    try {
      return await api.post(`/api/items/${itemId}/archive`, ItemSchema, {});
    } catch (e) {
      if (e instanceof ApiError && e.code === 'invalid_transition') {
        return; // otro cliente llegó antes; el estado real llega por SSE/re-fetch
      }
      throw e;
    }
  };
}
```

El `code` tipado de `ApiError` es la rama de decisión de la UI: `validation_error` → errores de campo con `details` (patrón completo en `references/forms.md`), resto → error genérico o toast. Nunca hagas branch sobre `message` (texto para humanos, cambia sin aviso).

## 4. Por qué NO Server Actions ni lecturas directas a BD

Decisión del arnés: **una sola superficie de datos**. La API REST del PRD es la que consume el navegador, la que consume el worker (si existe), la que golpeas con `curl` en las verificaciones de tarea y la que testea `testing/references/api.md` contra Postgres real. Server Actions (o un DAL con lecturas Drizzle en RSC) crearían una segunda superficie con su propia auth, su propia validación y su propio hueco de tests — cada mutación existiría dos veces o, peor, solo en la versión que la suite de API no ve. El coste real es un hop HTTP interno en cada lectura de RSC (el web se llama a sí mismo): milisegundos en loopback/red de compose, irrelevante para una app self-hosted. Se acepta el hop a cambio de que "funciona por curl" y "funciona en la UI" sean literalmente la misma afirmación.

Corolario: si al escribir una página sientes la necesidad de un dato que la API no expone, la tarea tiene una subtarea de backend (nuevo endpoint en el PRD, skill backend) — no un atajo a `@app/db` desde web.

## 5. Qué NO va aquí

- **Route handlers, SSE de servidor, auth, proxy/middleware, todo bajo `app/api/` y `server/`** → skill **backend**, `references/api.md`.
- **Componentes y hooks (nombres, ubicación, patrones)** → `references/components.md`.
- **Stores, cliente SSE** → `references/state-and-sse.md`.
- **Formularios y mapeo del envelope a errores de campo** → `references/forms.md`.
- **Tests de páginas y componentes** → skill **testing**: `references/frontend.md` (jsdom) y `references/e2e.md` (Playwright); el cierre de tarea siempre pasa por `references/cua.md`.
