# Mockups de páginas — la referencia visual de la UI

Catálogo de los **mockups aprobados por el usuario** para cada página de la app. Regla de trabajo 7 del planning (vinculante): **toda página con pantalla propia parte de un mockup HTML aprobado que vive en esta carpeta**, construido con los **tokens del design system** (los mismos de `apps/web/src/app/globals.css` / `docs/design-system/tokens/`). Una página que se desvíe de su mockup sin acuerdo explícito con el usuario es un error de review. Páginas nuevas sin mockup: se acuerda el layout con el usuario ANTES de implementarlas.

**Qué son** (y qué NO son):
- Cada `<pagina>.html` es un mockup autónomo renderizable en local (`file://` en un navegador). Es la **fuente de la intención de layout**: estructura, jerarquía, secciones, densidad.
- Cada `<pagina>.png` (opcional) es la captura de ese HTML — la referencia visual rápida.
- **NO son código de producción**: al desarrollar la página real se reproduce ESE layout con los componentes `components/ui/` del DS — ni se copia el HTML crudo del mockup, ni se inventa una página nueva. Si el mockup pide un patrón que ningún componente cubre, el componente se crea en el DS primero (skill frontend); no se improvisa HTML «provisional».
- Si un mockup contiene lógica de ejemplo (cálculos, datos hardcodeados), **su layout es vinculante; su script NO** — la lógica real la dictan PRD y backend.

## Convención de nombres

- Un fichero por página, kebab-case, nombrado por la ruta: `dashboard.html` (`/`), `settings.html` (`/settings`), `runs-id.html` (`/runs/[id]`), `auth.html` (`/login`). Checkpoints/modales con pantalla propia: por su función (`brief-editor.html`).
- Desviaciones acordadas respecto al mockup (piezas que se omiten o cambian a propósito) se anotan en la sección «Notas de fidelidad» de este README, con fecha — así el reviewer no exige lo que se descartó.

## Cómo se referencia desde el planning

La tarea que desarrolla la página lleva una línea en su entrada:

```markdown
- **Mockup**: docs/mockups/<pagina>.html
```

El implementer LEE el mockup (y su `.png`) antes de escribir la página; el reviewer rechaza desviaciones no acordadas.

## Mapa página → mockup

| Página | Ruta | Mockup | Tarea | Captura |
|---|---|---|---|---|
| _(se rellena a medida que el usuario aprueba mockups)_ | | | | |

## Notas de fidelidad

_(Desviaciones acordadas, con fecha y motivo — ninguna todavía.)_
