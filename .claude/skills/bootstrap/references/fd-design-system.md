# Patrón de la fase TD (design system)

La fase TD materializa en código el design system del proyecto, que vive en **Claude Design**. Se parametriza con UNA entrada: la **URL del proyecto de Claude Design** (`https://claude.ai/design/p/<id>`), que el usuario crea SIEMPRE antes del bootstrap. Si no existe aún, la fase se genera igual pero con ⚠ en la cabecera (prerequisito externo: crear el proyecto y aportar la URL) — y ninguna tarea de UI de F0..Fn puede empezar hasta desbloquearla.

**Posición en el planning**: TD se intercala **tras T0.1** (existe `apps/web` donde materializar) y **antes de continuar F0** — T0.2 gana una dependencia de ORDEN (no técnica) sobre TD.7. Motivo: toda pantalla posterior se construye con las primitivas de TD; construir UI antes de TD fabrica deuda visual segura. Coste de la fase: $0 (sin APIs de pago).

## El flujo completo (cabecera de fase en el planning)

```
Claude Design (fuente de verdad) ──DesignSync──► docs/design-system/ (espejo read-only)
        ▲                                                 │
        └── gaps creados en código se SUBEN ◄─────────────┤ se traduce, nunca se edita
                                                          ▼
   tokens VERBATIM a globals.css ─► primitivas shadcn/Base UI ─► showcase /design-system
                                                          │
                              lint de adherencia ◄────────┴─► skill frontend cerrada + OK humano
```

Principios vinculantes (van en la cabecera de la fase):
- El código **OBEDECE** al DS, nunca al revés. El espejo `docs/design-system/` es solo-lectura: se regenera con la tool `DesignSync` (`list_files`/`get_file`) y JAMÁS se edita a mano.
- **Ningún valor visual se inventa en código**: si falta un token/variante, se añade al DS, se vuelca y se usa. Si falta un componente entero, se crea siguiendo las foundations del DS y se SUBE a Claude Design en la misma tarea.
- Un cambio visual empieza en Claude Design; el commit de código es la traducción, no la decisión.
- Gotcha de subagentes: `DesignSync` puede no estar disponible en hijos frescos — si el implementer no la tiene, la subida la ejecuta el bucle principal en el CLOSE.

## Las 7 tareas (adaptar títulos al inventario real del DS del proyecto)

#### TD.1 · Tokens del DS, fuentes y showcase `/design-system`
- **Depende de**: T0.1 [; ⚠ URL del proyecto de Claude Design si aún no existe]
- **Entrega**: espejo inicial regenerado en `docs/design-system/`; `globals.css` con TODOS los tokens del espejo (`tokens/*.css`) volcados **verbatim** — hex tal cual, sin conversiones, naming 1:1 — en los **3 bloques canónicos de Tailwind v4 CSS-first** (no existe `tailwind.config.js`):
  1. `:root` + overrides: valores crudos; tema por defecto en `:root`, el otro tema como override completo bajo `[data-theme=…]`, acentos bajo `[data-accent=…]`, semánticos FIJOS, densidad vía `--ui-fs`.
  2. `@theme inline {}`: mapeo de cada token a Tailwind con el naming del DS (`bg-surface`, `text-text-2`, `rounded-md`…).
  3. `@layer base {}`: defaults mínimos (fondo, texto, `font-size: var(--ui-fs)`).
  **Gotcha `--shadow-*`**: si el DS llama a sus sombras `--shadow-*`, ese namespace lo usa `@theme` y crea un `var()` circular — se vuelcan como `--elevation-*` en `:root` y `@theme` mapea `--shadow-sm: var(--elevation-sm)` (las clases resultantes conservan `shadow-sm/md/lg`). Es la ÚNICA desviación de naming permitida.
  Fuentes del DS self-hosted (0 requests a CDNs); página `/design-system` con specimens de fundaciones y switchers de tema/acento/densidad (por atributo en `<html>`, nunca por media query; defaults sin atributo = SSR limpio).
- **Verificación**: `/design-system` en navegador muestra los specimens; los switchers cambian tema/acento/densidad en vivo; comparación visual contra las guidelines del espejo sin desviaciones perceptibles.

#### TD.2 · Primitivas core y formularios
- **Depende de**: TD.1
- **Entrega**: las primitivas core del inventario del DS (típicamente button, input, textarea, select, checkbox, switch…) en `apps/web/src/components/ui/` — generadas con shadcn sobre **Base UI** y ajustadas 1:1 al espejo: variantes cva con **los MISMOS nombres de variante que el DS** (`components/<grupo>/<X>.jsx` es la spec; `<X>.prompt.md` la intención), clases semánticas de token, `data-slot` conservado, a11y de la primitiva intacta, glifos Unicode en lugar de librerías de iconos (shadcn trae imports de lucide — sustituirlos es parte del ajuste); secciones nuevas en `/design-system`.
- **Verificación**: comparación en navegador contra los specimens del espejo en ambos temas: variantes y estados hover/focus/disabled fieles; todos los controles operables por rol y accessible name.

#### TD.3 · Resto de primitivas del inventario (feedback, navegación, datos)
- **Depende de**: TD.2
- **Entrega**: las primitivas restantes que el DS SÍ define (badge, alert, empty-state, tabs, tablas…), mismo estándar que TD.2; secciones en `/design-system`.
- **Verificación**: comparación contra sus specimens en ambos temas; navegación operable por teclado.

#### TD.4 · Gaps: primitivas fuera del DS + subida a Claude Design
- **Depende de**: TD.3
- **Entrega**: las primitivas que el producto necesita y el DS original NO define (típicamente overlays y estructura: dialog, sheet, toast, tooltip, skeleton, progress, card, separator…), creadas siguiendo las **foundations** del DS (hairlines, radios, focus ring único, glifos Unicode, sin gradientes/glassmorphism); secciones en `/design-system`; y **subida de todas al proyecto de Claude Design vía `DesignSync`** en su formato (`.jsx` + `.prompt.md` + card), regenerando el espejo después — el DS sigue siendo inventario completo. Solo se suben **tokens y componentes**, no mecanismos de compilación propios (`@utility`, keyframes wrapper): eso sería contenido muerto para el DS.
- **Verificación**: revisión en navegador de las secciones nuevas en ambos temas (coherencia con las foundations); `DesignSync list_files` muestra los ficheros nuevos y el espejo regenerado los incluye.

#### TD.5 · Composites de producto (presentacionales puros)
- **Depende de**: TD.3
- **Entrega**: los componentes específicos del producto que el DS defina (cards de dominio, nodos, banners…) como presentacionales **PUROS**: props planas, **prohibido importar tipos de dominio de `packages/core`** — los wrappers de dominio llegan con las features; fieles a `components/product/` del espejo; secciones en `/design-system`. (Si el DS del proyecto no define composites aún, la tarea se reduce a los que el PRD haga inevitables, creados y subidos como en TD.4.)
- **Verificación**: comparación contra sus specimens en ambos temas; animaciones apagadas bajo `prefers-reduced-motion` sin perder el estado visible.

#### TD.6 · Lint de adherencia al DS
- **Depende de**: TD.5
- **Entrega**: reglas de lint (scope `apps/web`, dentro de `pnpm gate`) adaptando las ideas de `_adherence.oxlintrc.json` del proyecto de Claude Design al flat config del repo. Prohíben: paleta cruda de Tailwind (`bg-blue-500`…), valores arbitrarios crudos en `className` (`bg-[#…]`, `rounded-[10px]`) fuera de `globals.css`, e imports de `@radix-ui/*`, `lucide-react` o cualquier librería de iconos. NO prohíben: spacing fraccionario (`size-4.5` — es el mecanismo de fidelidad al px) ni token-vía-var (`[--x:var(--warning)]`).
- **Verificación**: un fichero de prueba con una violación de cada tipo hace fallar `pnpm lint` nombrando la regla; al retirarlo, `pnpm gate` queda verde (el control negativo muerde).

#### TD.7 · Cierre: skill frontend contra la realidad + OK humano
- **Depende de**: TD.4, TD.6
- **Entrega**: skill `frontend` actualizada **contra el código real committeado** (no contra el espejo): inventario definitivo de `components/ui/` con variantes/props leídas de los `.tsx`, desviaciones deliberadas documentadas, obligatoriedad explícita («si existe el componente del DS, usarlo es obligatorio; HTML crudo estilado equivalente = error de review») y ajustes descubiertos en la fase anotados en el journal.
- **Verificación (E2E de fase)**: recorrido completo de `/design-system` — ambos temas y ≥2 acentos — con evidencia visual en `docs/verifications/TD.7/`; `pnpm gate` verde; y **revisión humana final del showcase** (parada de fin de fase: el usuario da el OK visual).
