# Convenciones de componentes y hooks (apps/web)

Cómo se escribe, se nombra y se ubica cada componente y hook de `apps/web`. Complementa a `architecture.md` (frontera server/client, páginas) y a `design-system.md` (tokens, estilos). Regla transversal: los componentes reciben y emiten tipos inferidos de los contratos Zod de `@app/core`, nunca shapes ad-hoc — un cambio de contrato debe romper la compilación aquí, esa es la señal deseada.

## Índice

1. [Convenciones React 19](#1-convenciones-react-19)
2. [Naming y ubicación](#2-naming-y-ubicación)
3. [shadcn/ui sobre Base UI](#3-shadcnui-sobre-base-ui)
4. [Cuándo extraer un hook (y cuándo no escribir un Effect)](#4-cuándo-extraer-un-hook-y-cuándo-no-escribir-un-effect)
5. [Accesibilidad vinculante: la API de test](#5-accesibilidad-vinculante-la-api-de-test)
6. [Composición: señales de alarma](#6-composición-señales-de-alarma)
7. [Qué NO va aquí](#7-qué-no-va-aquí)

---

## 1. Convenciones React 19

**Function declarations, siempre.** Ni arrow functions asignadas a const para componentes, ni `React.FC` (impide componentes genéricos y es verbosidad sin beneficio en React 19). Props tipadas con `interface` propia o, si el componente envuelve un elemento nativo, `React.ComponentProps<'x'> & {...}`:

```tsx
// Componente de dominio: interface con tipos de los contratos de @app/core
import type { Item } from '@app/core';

interface ItemDetailPanelProps {
  item: Item;
  onArchive: (itemId: string) => void;
}

export function ItemDetailPanel({ item, onArchive }: ItemDetailPanelProps) { /* … */ }

// Componente que extiende un elemento nativo: ComponentProps + intersección
type CountBadgeProps = React.ComponentProps<'span'> & { count: number };
```

**`ref` es una prop normal — `forwardRef` PROHIBIDO en código nuevo.** React 19 pasa `ref` como prop a function components; `forwardRef` es ruido legacy que además rompe el naming en DevTools. En React 19, `React.ComponentProps<'button'>` ya incluye `ref` con el tipo correcto:

```tsx
// ❌ ANTES (React 18) — no escribir nunca más
export const SaveButton = React.forwardRef<HTMLButtonElement, SaveButtonProps>(
  function SaveButton({ intent, ...props }, ref) {
    return <button ref={ref} type="button" {...props} />;
  },
);

// ✅ DESPUÉS (React 19) — ref viaja en las props
interface SaveButtonProps extends React.ComponentProps<'button'> {
  intent: 'save' | 'publish';
}

export function SaveButton({ intent, ref, ...props }: SaveButtonProps) {
  return <button ref={ref} type="button" data-intent={intent} {...props} />;
}
```

**Sin `defaultProps`.** Defaults en el destructuring: `function ItemCard({ locale = 'es', ...props })`. Es lo único que React 19 soporta en function components y lo único que TypeScript narrowea bien.

**React Compiler activado (`reactCompiler: true`) → sin `useMemo`/`useCallback` preventivos.** El compilador memoiza automáticamente; un `useMemo` "por si acaso" es ruido que oculta los pocos casos donde una memoización manual significa algo. Escribe el cálculo directo:

```tsx
// ❌ ruido: el compilador ya memoiza esto
const total = useMemo(() => estimateTotal(selection, rates), [selection, rates]);

// ✅ directo — y la fórmula vive como función pura en @app/core (testeable sin jsdom)
const total = estimateTotal(selection, rates);
```

La ÚNICA excepción legítima es una librería que exige identidad estable por contrato documentado (p. ej. librerías de canvas/grafos que remontan sus hijos si el mapa de tipos cambia de referencia: registro a nivel de módulo, componentes hijos con `memo`). Documenta la excepción JUNTO al código que la usa y no la generalices al resto de la app.

## 2. Naming y ubicación

| Cosa | Convención | Ejemplo |
|---|---|---|
| Ficheros y carpetas | kebab-case | `item-editor.tsx`, `items/` |
| Export de componente | PascalCase, el fichero se llama como su export | `item-editor.tsx` → `export function ItemEditor` |
| Hooks | camelCase con prefijo `use`, fichero `use-*.ts` | `use-event-source.ts` → `useEventSource` |
| Funciones puras co-locadas | fichero propio junto al componente | `items/items-to-rows.ts` |
| Tests | co-locados `*.test.ts(x)` (convención de la skill `testing`, su fuente de verdad) | `item-editor.test.tsx` |

**Un componente exportado por fichero.** Sub-componentes privados sin export pueden convivir en el mismo fichero mientras nadie más los necesite; en cuanto otro fichero los importa, se mudan al suyo. Por qué: el grep por nombre de fichero debe encontrar el componente a la primera.

**Dominio vs design system:**

- `components/<dominio>/` (una carpeta por dominio del producto, nombres del PRD/planning) — componentes que conocen los contratos del negocio de `@app/core`.
- `components/ui/` — el design system: espejo 1:1 del inventario de Claude Design, sin conocimiento de dominio. **No importa de dominios ni de stores, jamás** (regla de dependencia de la skill).

**Cuándo se promociona algo a `ui/`:** cuando cumple LAS DOS condiciones — (a) es agnóstico de dominio (no importa nada de `@app/core` ni de carpetas de dominio; habla en props genéricas) y (b) lo usan ≥2 dominios. Un badge que solo usa un dominio se queda en ese dominio; el día que otro lo necesite Y se pueda expresar sin tipos de dominio, se promociona (y se añade al inventario del DS en Claude Design primero — ver `design-system.md`). Promocionar antes de tiempo crea un pseudo-DS de piezas de un solo uso.

**Hooks:** transversales (los usan ≥2 dominios o son infraestructura: `use-event-source.ts`) en `src/hooks/`; hooks de un solo dominio co-locados en su carpeta (`components/items/use-item-selection.ts`). Mismo criterio de promoción que los componentes.

## 3. shadcn/ui sobre Base UI

**Qué es:** shadcn/ui NO es una dependencia — es código que se copia dentro del repo y pasa a ser nuestro. `npx shadcn add <componente>` genera el fichero en `components/ui/` según la config de `apps/web/components.json` (lo crea `npx shadcn init`; no lo escribas a mano). El código generado usa **primitivas de Base UI por defecto** — es exactamente lo que queremos. **NUNCA instalar las variantes Radix**: ver `@radix-ui/*` en `package.json` es un error de revisión, sin excepciones. Por qué: dos librerías de primitivas = dos sistemas de foco, portales y aria compitiendo.

```bash
npx shadcn add button dialog select badge   # copia los ficheros a src/components/ui/
```

**Editar el código copiado es lo esperado, no una herejía.** El componente generado es el punto de partida; se ajusta a los tokens y variantes del DS de Claude Design (ver `design-system.md`). Eso sí: cada edición debe mantener las primitivas Base UI y sus atributos aria intactos — se toca la piel, no el esqueleto.

**Variantes con cva, con los MISMOS nombres de variante que el DS de Claude Design.** Los nombres de variante son literales del espejo — la traducción DS↔código es 1:1 o no se podrá reconciliar el día que el DS cambie. Ejemplo del patrón (los tonos/variantes reales los dicta el espejo del proyecto):

```tsx
// apps/web/src/components/ui/badge.tsx (patrón; variantes y tokens = los del espejo del DS)
import { cva, type VariantProps } from 'class-variance-authority';
import { cn } from '@/lib/utils';

const badgeVariants = cva(
  'inline-flex items-center gap-1 whitespace-nowrap rounded-full border px-2.5 font-semibold',
  {
    variants: {
      tone: {
        neutral: 'border-border-2 bg-surface-3 text-text-2',
        success: 'border-success-border bg-success-soft text-success',
        warning: 'border-warning-border bg-warning-soft text-warning',
        danger: 'border-danger-border bg-danger-soft text-danger',
        // …los tonos que el DS del proyecto defina, con SUS nombres
      },
    },
    defaultVariants: { tone: 'neutral' },
  },
);

type BadgeProps = Omit<React.ComponentProps<'span'>, 'color'> & VariantProps<typeof badgeVariants>;

export function Badge({ className, tone = 'neutral', children, ...props }: BadgeProps) {
  return (
    <span data-slot="badge" className={cn(badgeVariants({ tone }), className)} {...props}>
      {children}
    </span>
  );
}
```

(Solo clases semánticas de token — `bg-success-soft`, no `bg-green-500`; los estados usan los semánticos FIJOS, el acento es la marca, NUNCA estado — `design-system.md` §3.)

**`data-slot` para estilos internos.** Cada parte de un componente compuesto lleva `data-slot="card-header"`, `data-slot="dialog-footer"`… Permite que un padre estilice partes internas (`[&_[data-slot=badge]]:opacity-50`) sin añadir props de estilo al componente. Es el mecanismo estándar del código que genera shadcn: consérvalo al editar y añádelo en partes nuevas.

**Componentes que shadcn no trae → Base UI directo.** Se crea el fichero en `components/ui/` a mano usando las primitivas de Base UI (mismo paquete que ya importan los ficheros generados — copia el import de cualquier componente existente). Dos avisos: Base UI compone con la prop `render` (no existe `asChild`, eso era Radix), y su API evoluciona — **consulta la doc actualizada (Context7 MCP si está configurado, o la doc oficial) antes de escribir contra ella de memoria**.

**Trampas de a11y de Base UI descubiertas en fases TD de proyectos con este arnés (heredables por los wrappers de dominio):**

1. **Una primitiva Base UI puede NO cablear `role`/aria por sí sola** → cablearlo explícito y VERIFICAR en el árbol de accesibilidad, no asumirlo. Se ha visto un Tooltip que necesitó `role="tooltip"` + un `id` en el popup + `aria-describedby` en el trigger a mano (Base UI no los emitía). Corolario: cuando envuelvas una primitiva, mira el árbol a11y real (CUA/testing) antes de dar por hecho que la semántica está.
2. **El accessible name no «sube» de un ancestro a un descendiente.** Si el rol vive en una parte interna (p. ej. el `role="slider"` en el `<input>` anidado en el Thumb, descendiente de Root), un `aria-label` en Root (el grupo) NO nombra el control: reenvía el label a la parte que porta el rol (`getAriaLabel` en el Slider) y quítalo de Root. Mismo principio para cualquier primitiva compuesta.
3. **Control etiquetado de Base UI = UN solo elemento interactivo, no un `<label>` envolviendo la Root.** Un Checkbox etiquetado se renderiza como un único `<button role="checkbox">` (`nativeButton`) cuyo texto visible ES el accessible name. Envolver la Root en un `<label>` doble-dispara (el span togglea y el label re-activa el input oculto → net no-op); y un `<label htmlFor>` hermano no puede apuntar al control porque Base UI pone el `for` en el input oculto. Patrón vinculante para cualquier control etiquetado de Base UI.
4. **Componentes que usan `Intl` en SSR deben fijar un `locale` determinista** o hay hydration mismatch (que dispara `console.error` TAMBIÉN en prod, no solo en dev). Ejemplo real: Progress construye `aria-valuetext` con `Intl.NumberFormat`; sin locale fijo, Node (server, p. ej. `es-ES`→"66 %" con NBSP) y el navegador (client→"66%") producen strings distintos. **Regla**: cualquier componente con fecha/número/`%`/moneda formateado en SSR fija locale explícito.

## 4. Cuándo extraer un hook (y cuándo no escribir un Effect)

Criterios de react.dev, en orden de fuerza — si no cumple ninguno, no extraigas:

1. **Repetición real (2+)**: la misma lógica con estado aparece en dos componentes. No "aparecerá": aparece. Extraer al primer uso es especular.
2. **Esconder un `useEffect` de sistema externo tras una API declarativa**: cuando un efecto sincroniza con algo fuera de React (EventSource, `visibilitychange`, `localStorage`, un `<video>`), el componente no debe ver el efecto — ve un hook que describe QUÉ quiere, no cómo. `useEventSource(url)` es el ejemplo canónico si el módulo SSE existe (su implementación vive en `state-and-sse.md`): el consumidor pide "los eventos de este recurso" y el hook esconde reconexión, backoff y cleanup.
3. **Legibilidad**: un componente donde estado, refs y efectos entrelazados sepultan el JSX mejora si la maraña se nombra (`useItemSelection(items)`). Si el hook resultante no tiene un nombre honesto de una frase, la extracción era mecánica, no conceptual.

**"You Might Not Need an Effect" aplica antes que todo lo anterior.** La mayoría de efectos candidatos a hook no deberían existir:

```tsx
// ❌ Effect para derivar estado — estado duplicado que puede desincronizarse
const [total, setTotal] = useState(0);
useEffect(() => {
  setTotal(estimateTotal(selection, rates));
}, [selection, rates]);

// ✅ derivado en render; la fórmula es función pura de @app/core con sus propios unit tests
const total = estimateTotal(selection, rates);
```

- Dato derivado de props/estado → se calcula en render (el React Compiler lo memoiza).
- Reacción a una acción del usuario → en el event handler, no en un efecto que observa estado.
- Fetch de datos en un `useEffect` de cliente → casi siempre error de arquitectura en este arnés: las lecturas llegan por RSC + api-client (`architecture.md`) y el estado vivo (si el módulo SSE existe) por SSE + store (`state-and-sse.md`).

## 5. Accesibilidad vinculante: la API de test

**Estas normas no son un extra: son el contrato con la suite de tests.** `testing/references/frontend.md` ordena las queries por preferencia (`getByRole` con accessible name primero); cada norma de esta tabla existe para que esa query exista. Un componente que las incumple no se puede testear NI usar con lector de pantalla — mismo defecto, dos síntomas. Corolario: el accessible name es API pública — cambiar un `aria-label` rompe tests A PROPÓSITO; se cambia de forma deliberada, con sus tests.

| Norma (obligatoria) | Por qué | Query que habilita |
|---|---|---|
| HTML semántico primero: `button`, `a`, `nav`, `main`, `table`, `ul` — nunca `div onClick` | Rol, foco y teclado gratis; un `div` clicable no es tabulable ni tiene rol | `getByRole('button', { name: /guardar/i })` |
| Todo input con label asociado (`<Label htmlFor>` o envolvente) | Sin label no hay accessible name → el campo es invisible para test y lector | `getByRole('textbox', { name: /nombre/i })` |
| `aria-label` en todo botón icon-only | Un icono no da nombre accesible | `getByRole('button', { name: /cerrar/i })` |
| Todo dialog con título accesible (`DialogTitle`; si no se ve, con clase `sr-only`) | Sin título, el dialog anuncia "diálogo" a secas y no es localizable por nombre | `getByRole('dialog', { name: /confirmar/i })` |
| Un `h1` por vista y jerarquía sin saltos (`h1`→`h2`→`h3`) | La estructura de headings ES la navegación del lector de pantalla | `getByRole('heading', { level: 2, name: /detalle/i })` |
| Estados como aria: `aria-expanded` (paneles/acordeones), `aria-selected` (tabs), `disabled`/`aria-disabled` | El estado visual sin aria es invisible fuera del píxel | `getByRole('tab', { selected: true })`, `expect(btn).toBeDisabled()` |
| Feedback async no urgente en `role="status"` (con `aria-label` si es un valor con nombre) | aria-live polite: anuncia sin interrumpir; localizable sin depender del texto exacto | `getByRole('status', { name: /total estimado/i })` |
| Errores y bloqueos en `role="alert"` | aria-live assertive + los tests esperan el error con `findByRole('alert')` | `findByRole('alert')` |

Ejemplo con el envelope de error de la API (`{code, message, details}` — contrato en `@app/core`):

```tsx
{saveError ? (
  <div role="alert" className="text-danger">
    {saveError.message}
    {saveError.details?.suggestion ? <p>{saveError.details.suggestion}</p> : null}
  </div>
) : null}
<output role="status" aria-label="total estimado">{formatAmount(total)}</output>
```

Los componentes custom sin semántica de serie (p. ej. nodos de un canvas, celdas virtualizadas) reciben `role` y `aria-label` explícitos — el accessible name es su API de test.

## 6. Composición: señales de alarma

Dos olores concretos disparan la refactorización (y la lectura de la skill instalada `vercel-composition-patterns`, que es la referencia de patrones — no la reinventes aquí):

1. **Proliferación de props booleanas.** `<ItemCard showActions showCost compact isGalleryMode />` es un componente pidiendo dividirse: cada boolean multiplica por dos sus estados internos y sus tests. Si la variación es visual, es una variante `cva` con nombre (§3); si es estructural (qué partes se renderizan), es composición — el padre pasa las partes como `children`/props de slot:

```tsx
// ❌ el componente decide todo por flags
<ItemCard item={i} showSummary showPublishButton />

// ✅ el padre compone; ItemCard solo da el marco
<ItemCard item={i}>
  <ItemSummary summary={i.summary} />
  <PublishButton itemId={i.id} />
</ItemCard>
```

2. **Prop drilling.** Un dato que atraviesa ≥2 niveles de componentes que no lo usan. Si es estado compartido de la página, la solución NO es Context ad-hoc: es leer del store Zustand con un selector en el componente que lo consume (`state-and-sse.md`). Si es estructura de UI, es composición: pasa el componente ya construido en vez del dato para construirlo abajo.

Regla de cierre: cuando un componente supere el punto en que ya no cabe en una lectura, se parte por secciones compuestas desde el padre — no por flags.

## 7. Qué NO va aquí

- **Tokens, estilos, traducción de Claude Design, qué clases semánticas existen** → `design-system.md`.
- **Páginas, layouts, server vs client, consumo de la API desde RSC** → `architecture.md`.
- **Stores Zustand, hook SSE, aplicar deltas** → `state-and-sse.md`.
- **Formularios y editores** (react-hook-form + zodResolver) → `forms.md`.
- **Cómo se testea cualquier cosa de este documento** → `.claude/skills/testing/references/frontend.md` (fuente de verdad; la tabla de §5 solo correlaciona norma↔query, no define estrategia de test).
