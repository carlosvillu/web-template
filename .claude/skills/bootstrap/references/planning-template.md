# Plantilla de planning

Esqueleto del `planning.md` (raíz). Es EL documento operativo del bucle: /dev-loop lo lee para elegir tarea, el hook `guard-planning` bloquea `[x]` sin evidencia en `docs/verifications/<ID>/report.md`, y `scripts/readme-status.mjs` regenera la tabla del README desde la tabla **Estado global** (sé literal con su formato: `| Fase | Nombre | Entrega observable al cerrar la fase | Estado |`).

IDs de tarea: `T<fase>.<n>` con sufijo opcional `a-z` para divisiones (`T0.7a`). Fases numeradas `F0..Fn` + fases transversales con letra (`TD.x` = design system). Fases de deuda intercaladas: `F1b`, `F1c`… (mismo formato, se crean cuando la realidad las destape, no en el bootstrap).

---

```markdown
# Planning — {{PROJECT_NAME}}

> Plan de ejecución del `PRD.md` (v1, aprobado {{fecha}}). Fases → tareas → subtareas.
>
> **Filosofía baby steps**: cada tarea es autocontenida (se empieza y se termina en una sesión de trabajo), deja el sistema en un estado funcional (nunca a medias), y termina con una **verificación en el mundo real**: una acción concreta con un resultado observable que demuestra sin lugar a dudas que funciona — no "el código compila", sino "hago X y veo Y". Ninguna verificación depende de piezas que aún no se hayan construido en el momento de la tarea.
>
> Convenciones: `[ ]` pendiente · `[x]` hecha (marcar al completar, con fecha) · **Depende de** lista los IDs que deben estar hechos antes (el orden real lo dicta este grafo, no la numeración) · ⚠ marca prerequisitos externos que debe hacer el usuario · las referencias `§` apuntan al PRD; las `research/` a los informes. Los ítems `[verificar]` del PRD se cierran dentro de la tarea que integra ese componente.

## Estado global

| Fase | Nombre | Entrega observable al cerrar la fase | Estado |
|---|---|---|---|
| F0 | Fundaciones | {{qué se puede VER funcionando al cerrar F0 — depende de los módulos elegidos}} | ☐ |
| TD | Design system | `/design-system` muestra tokens y componentes fieles a Claude Design, lint de adherencia activo y skill frontend actualizada — se ejecuta tras T0.1, antes de continuar F0 | ☐ |
| F1 | {{nombre}} | {{entrega observable}} | ☐ |
| F2 | {{nombre}} | {{entrega observable}} | ☐ |

**Hitos de valor real** (el producto es útil antes de terminar): {{tras F1 ya …; tras F2 ya …}}.
<!-- Estado: ☐ pendiente · ✅ cerrada. readme-status.mjs lee ESTA tabla: no cambiar
     cabeceras ni el orden de columnas. Una fila por fase, incluidas las de deuda
     cuando se creen. -->

---

## F0 — Fundaciones

{{1-3 líneas: cuál es el corazón de F0 en ESTE proyecto y qué queda al cerrarla — sin features de negocio, pero el esqueleto completo funcionando.}}
<!-- Solo los módulos elegidos en la etapa 3 del bootstrap, numerados T0.1..T0.n con el
     grafo real de dependencias de references/f0-modules.md. T0.1 es SIEMPRE el
     esqueleto monorepo+gate. Si el módulo deploy entra, lleva ⚠ (VPS+DNS del usuario). -->

#### T0.1 · Monorepo y esqueleto de proyectos
- **Depende de**: —
- **Entrega**: pnpm workspaces con `apps/web` (Next.js App Router + Tailwind v4){{, `apps/worker` si va}}, `packages/core` (contratos Zod), `packages/db`; tsconfig/eslint/prettier compartidos; logging estructurado (pino) con campos de correlación desde el día 1; `pnpm gate` operativo (lint && typecheck && format:check && knip && readme:status:check && test); página raíz + healthcheck `/api/health`.
- **Subtareas**:
  - [ ] {{…}}
- **Verificación**: `pnpm build && pnpm gate` en verde → `curl localhost:3000/api/health` devuelve `{ok:true}`; un cambio en un tipo de `packages/core` rompe la compilación de las apps que lo importan (se comprueba a propósito).

<!-- ——— FORMATO CANÓNICO DE TAREA (usarlo en TODAS) ————————————————————————————
#### T<F>.<n> · Título [⚠ si tiene prerequisito externo]
- **Depende de**: T…, T… [; ⚠ <qué debe aportar el usuario>]        ← el grafo manda
- **Entrega**: qué existe al terminar, con rutas/nombres concretos y § del PRD.
- **Subtareas**: (opcional) checklist [ ] de los pasos gordos.
- **Mockup**: docs/mockups/<x>.html                                  ← solo tareas con
  pantalla propia (regla 7); el desarrollo PARTE de ese mockup.
- **Coste estimado**: ~$X                                            ← solo si la
  verificación consume APIs de pago (regla 9; base del cap de gasto del bucle).
- **Playwright permanente**: apps/web/e2e/<x>.spec.ts — comportamientos protegidos.
  ← toda tarea con comportamiento operable en navegador (regla 10).
- **Verificación**: la acción observable que demuestra que funciona ("hago X y veo Y"),
  con sus cláusulas concretas: qué comando/recorrido, qué resultado exacto, controles
  negativos si aplican. Sus cláusulas deterministas acabarán como tests del gate (regla 8).
Al cerrar: `#### T0.2 · Título [x] 2026-01-15 — PASS, ver docs/verifications/T0.2/ (coste $0)`
——————————————————————————————————————————————————————————————————————————————— -->

{{Resto de tareas T0.n de los módulos elegidos, y la última de F0 es su E2E de fase.}}

---

## TD — Design system (la piedra angular de toda UI)

{{Cabecera de fase según references/fd-design-system.md: URL del proyecto de Claude Design, espejo read-only en docs/design-system/, decisiones del usuario. Con ⚠ global si la URL aún no existe.}}

{{Las 7 tareas TD.1–TD.7 del patrón: tokens → primitivas core → resto de primitivas → gaps subidos a Claude Design → composites de producto → lint de adherencia → cierre de skill + OK humano. Detalle en fd-design-system.md.}}

---

## F1 — {{Nombre de la primera fase de features}}

{{Tareas T1.n desde el roadmap del PRD, formato canónico. La ÚLTIMA tarea de cada fase es su E2E sagrado: recorre el journey completo de la fase contra el sistema real y cita los criterios de éxito del PRD que cierra ("criterio §16.2").}}

---

## Reglas de trabajo

1. **Orden**: el grafo `Depende de` manda (la numeración es orientativa); entre fases se puede adelantar trabajo que no dependa de lo pendiente, pero una fase solo se cierra cuando su E2E final pasa.
2. **Definición de hecho**: subtareas completas + verificación ejecutada y anotada (fecha + resultado + coste real si aplica) + sin regresión del E2E de la fase anterior.
3. **Deudas `[verificar]`**: cada una se cierra en la tarea que la nombra y el resultado se anota también en el PRD para mantenerlo veraz.
4. **Los E2E de fase son sagrados**: las tareas E2E que cierran cada fase y los criterios de éxito del PRD son la vara de "funciona en el mundo real"; no se marcan por aproximación.
5. **Costes**: toda tarea que llame a APIs de pago anota el coste real observado; si difiere >25 % del estimado, se recalibra el estimador/receta en la misma tarea.
6. **Cambios de alcance**: si una tarea revela que el PRD necesita ajuste, se edita el PRD en la misma sesión y se anota en ambos documentos (planning y journal). PRD y planning nunca se cuentan historias distintas.
7. **Mockups de página**: cada página con pantalla propia tiene un mockup aprobado por el usuario en `docs/mockups/` (catálogo en `docs/mockups/README.md`), construido con los tokens del design system. La tarea que la desarrolla lo referencia con `- **Mockup**: docs/mockups/<x>.html` y su desarrollo **parte de ese mockup** (con los componentes `components/ui/` del DS, no reinventado). Una página que se desvíe del mockup sin acuerdo explícito es un error de review. Páginas nuevas sin mockup: se acuerda el layout con el usuario antes de implementarlas.
8. **Las cláusulas deterministas de una Verificación se quedan como tests**: todo check automatizable y gratuito de un DoD (asserts sobre ficheros, validadores de schema/seeds, linters, golden files) se codifica como test permanente dentro de `pnpm gate` en la misma tarea — así el "sin regresión" de la regla 2 es ejecutable y gratis para siempre. Las cláusulas con APIs de pago o juicio humano quedan one-shot con su evidencia en `docs/verifications/`.
9. **Coste estimado por tarea**: toda tarea cuya verificación consuma APIs de pago lleva una línea `- **Coste estimado**` — es la base del cap de gasto del bucle. Si una tarea sin estimado resulta necesitar APIs de pago, el bucle la trata como parada de gasto (no improvisa el presupuesto).
10. **Playwright permanente por tarea web**: toda tarea cuya Entrega añada o modifique comportamiento operable en navegador declara una línea `- **Playwright permanente**` con el fichero exacto y los comportamientos protegidos. El spec se crea o actualiza en esa misma tarea, usa providers fake/fixtures para ser determinista y gratuito, y queda en `pnpm test:e2e`. Los E2E de fase viven además en `apps/web/e2e/phases/` con tags `@fN @phase`. Una excepción por infraestructura o proveedor real debe quedar escrita en la tarea junto con la capa permanente alternativa; nunca se omite en silencio.
```
