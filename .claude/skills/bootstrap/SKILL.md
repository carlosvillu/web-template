---
name: bootstrap
description: Conversación guiada que convierte una copia fresca del template en un proyecto listo para /dev-loop — entrevista de producto, PRD.md, entrevista técnica, planning.md y cierre (placeholders, LICENSE, primer commit). Usar cuando el proyecto aún no tiene PRD.md/planning.md, cuando el usuario diga "arranca el proyecto", "empecemos el proyecto", "genera el PRD", "bootstrap", "inicializa el template" o pida convertir una idea en plan de trabajo. NO usar si PRD.md ya existe y está aprobado (eso es /dev-loop o edición puntual).
---

# Bootstrap: del template a un proyecto ejecutable

Protocolo por etapas con **paradas de aprobación explícitas**. Nada avanza a la etapa siguiente sin el OK del usuario donde se indica PARADA. Los documentos se escriben en español; código y commits en inglés. No inventes respuestas del usuario: pregunta (con AskUserQuestion cuando haya opciones cerradas) y espera.

| Etapa | Hace | Produce | Parada |
|---|---|---|---|
| 0 | Sanity + datos básicos | nombre, idea, licencia, repo | — |
| 1 | Entrevista de producto (+ deep research opcional) | material del PRD, `research/NN-*.md` | — |
| 2 | Redactar PRD | `PRD.md` v1 aprobado | **SÍ** |
| 3 | Entrevista técnica | módulos F0 + URL de Claude Design | — |
| 4 | Redactar planning | `planning.md` aprobado | **SÍ** |
| 5 | Cierre | placeholders, journal, LICENSE, commit | fin |

References de esta skill (leer JUSTO antes de la etapa que los usa, no todos de golpe):
- `references/prd-template.md` — esqueleto comentado del PRD (etapa 2).
- `references/planning-template.md` — esqueleto del planning + reglas de trabajo (etapa 4).
- `references/f0-modules.md` — menú de módulos opcionales de F0 (etapas 3-4).
- `references/fd-design-system.md` — patrón de la fase TD del design system (etapas 3-4).

## Etapa 0 · Sanity y datos básicos

1. Verifica que es una copia fresca: **no existen `PRD.md` ni `planning.md`** en la raíz.
   - Ambos existen → PARA e informa: este proyecto ya fue bootstrapeado (ofrece /dev-loop o edición manual); no sobrescribas nada.
   - **Reanudación**: existe `PRD.md` pero no `planning.md` → bootstrap interrumpido. Confirma con el usuario que el PRD sigue siendo válido (¿está aprobado? cabecera con versión+fecha) y retoma en la etapa 3; si el PRD es un borrador sin aprobar, retoma en la etapa 2.
2. `git rev-parse --git-dir` — si no hay repo, `git init` (rama `main`).
3. Pregunta en un solo bloque:
   - **Nombre del proyecto** (para `{{PROJECT_NAME}}` y el package scope).
   - **La idea** en 2-5 frases (materia prima de la etapa 1).
   - **Licencia** (MIT / AGPL-3.0 / propietaria / otra) — se elige por proyecto, no la impone el template.
   - **¿Repo público?** (afecta al tono de los README y a la revisión de READMEs del bucle).
   - **Remote de GitHub** si ya existe (URL) — si no, se anota como deuda del arnés (activar CI cuando exista).

## Etapa 1 · Entrevista de producto

Objetivo: material suficiente para escribir el PRD sin inventar. Los proyectos serán mayormente **micro-SaaS de una sola feature**: la entrevista debe encontrar ESA feature y recortarlo todo alrededor. Pregunta por rondas cortas (no un interrogatorio de 20 ítems):

- **Usuario objetivo**: quién es, qué hace hoy sin el producto, ¿es el propio usuario (herramienta personal) o terceros?
- **Problema**: qué duele, con qué frecuencia, qué alternativas existen y por qué no bastan.
- **La feature única**: el recorrido mínimo que entrega valor completo (entrada → transformación → salida observable). Si el usuario describe tres features, ayúdale a elegir una y manda el resto a no-objetivos.
- **Monetización**: personal/gratis, suscripción, pago por uso… (condiciona auth mono/multi-usuario y el ledger de gasto en la etapa 3).
- **Alcance y no-objetivos**: qué queda explícitamente fuera de v1.
- **Integraciones previsibles**: APIs de pago (LLM, media, scraping…) — sus precios entrarán al PRD con `[verificar]`.

**Deep research opcional**: ofrece investigar estado del arte / competidores / precios / viabilidad técnica con la skill `deep-research`. Cada informe se guarda como `research/NN-<tema>.md` (numeración 01..) y el PRD lo citará (`research/01 §3`). Los informes son **solo consulta**: el bucle los lee, nunca los edita. Si el usuario declina, el PRD marcará las afirmaciones de mercado como `[verificar]`.

## Etapa 2 · Generar PRD.md — PARADA de aprobación

1. Lee `references/prd-template.md` completo.
2. Redacta `PRD.md` **sección a sección** siguiendo ese esqueleto: omite las secciones que la guía inline marca como prescindibles si el proyecto no las necesita, y marca toda incertidumbre (precios, límites de API, supuestos de mercado) con `[verificar]` — se cierran en la tarea del planning que integre esa pieza.
3. Cabecera: tagline, **Versión: 0.x (borrador)**, fecha, autor (usuario + Claude), fuentes (`research/*` si los hay).
4. Presenta el PRD al usuario y **recoge correcciones hasta que lo apruebe**. Al aprobar: sube a **v1.0** y estampa la **fecha de aprobación** en la cabecera. Sin PRD aprobado no hay etapa 3.

## Etapa 3 · Entrevista técnica corta

El stack es FIJO (pnpm workspaces TS · Next.js App Router + Tailwind v4 CSS-first · packages/core con Zod · Postgres + Drizzle · Vitest + Playwright · Base UI/shadcn · pino): aquí NO se discute el stack, solo dos cosas:

1. **Módulos opcionales de F0**. Lee `references/f0-modules.md`, cruza cada módulo con las señales del PRD y **propón TÚ la selección justificada** (módulo → qué frase/sección del PRD lo exige, o por qué se descarta). El esqueleto monorepo+gate (T0.1) entra SIEMPRE. El usuario confirma o ajusta.
2. **URL del proyecto de Claude Design** — **OBLIGATORIA**: el usuario la crea siempre antes del bootstrap. Si aún no existe, la fase TD del planning se genera igual pero **bloqueada con ⚠** (prerequisito externo: crear el proyecto y pasar la URL) y se lo adviertes: sin DS no se construye UI.

## Etapa 4 · Generar planning.md — PARADA de aprobación

1. Lee `references/planning-template.md` (y ten a mano `f0-modules.md` y `fd-design-system.md`).
2. Redacta `planning.md`:
   - Cabecera: filosofía baby steps + convenciones + tabla **Estado global** (una fila por fase; de esa tabla lee `scripts/readme-status.mjs`, sé literal con el formato).
   - **F0 modular**: solo los módulos confirmados en la etapa 3, como tareas `T0.n` con dependencias reales entre módulos (grafo de `f0-modules.md`). T0.1 siempre primero.
   - **Fase TD** (design system) según `references/fd-design-system.md`: el patrón de 7 tareas TD.1–TD.7 parametrizado con la URL de Claude Design, **intercalada tras T0.1** (T0.2 gana dependencia de orden sobre TD.7). Con ⚠ si la URL no existe aún.
   - **Fases de features** F1..Fn desde el roadmap del PRD: cada tarea en el formato canónico del template (Entrega con § al PRD, Depende de real, Verificación observable; Mockup/Coste estimado/Playwright permanente donde apliquen), y cada fase termina en su **tarea E2E sagrada** que cita los criterios de éxito del PRD que cierra.
   - **Reglas de trabajo** al final: cópialas del template ajustando solo los IDs de E2E de fase.
3. Sanity del resultado: toda tarea con pantalla propia referencia un mockup (aunque el mockup aún no exista, la regla 7 obligará a crearlo antes de la tarea); ningún `Depende de` apunta a un ID inexistente; toda verificación es ejecutable con lo construido hasta esa tarea.
4. Presenta el planning y **recoge correcciones hasta el OK del usuario**.

## Etapa 5 · Cierre

1. **Placeholders**: rellena `{{PROJECT_NAME}}`, `{{PROJECT_DESC}}`, URL del DS, remote, licencia y demás en `CLAUDE.md`, `AGENTS.md` y `README.md` (grep de `{{` para no dejar ninguno; verifica que los marcadores STATUS-TABLE del README siguen intactos).
2. **Journal**: añade a `docs/dev-loop/journal.md` la primera entrada `## <fecha> · Proyecto bootstrapeado` (decisiones de las etapas 0-4: módulos F0 elegidos, licencia, repo, URL del DS, deudas del arnés como "sin remote → CI pendiente").
3. **LICENSE** según lo elegido en la etapa 0 (año + nombre del usuario).
4. `pnpm readme:status:check` no puede fallar por formato de la tabla (si falla, arregla el planning, no el script).
5. **Primer commit**: `bootstrap: PRD v1, planning and project seed` (incluye PRD.md, planning.md, research/, docs, LICENSE, placeholders). Push solo si hay remote configurado y el usuario lo pidió.
6. Despídete con el estado real: próxima tarea elegible (normalmente T0.1) y la frase **"listo: ejecuta /dev-loop"** — más cualquier ⚠ pendiente (URL del DS, remote, credenciales).

## Reglas duras

- **Ninguna PARADA se salta**: PRD y planning los aprueba el usuario, no tú.
- **No escribas código de producto** durante el bootstrap: eso es trabajo de /dev-loop (T0.1 en adelante).
- **No toques** `scripts/`, hooks ni las demás skills del template: el bootstrap produce documentos y seeds, no arnés.
- Si el usuario quiere cambiar algo ya aprobado (PRD tras aprobar planning…), edita el documento y anota el cambio en el journal — nunca dejes PRD y planning contándose historias distintas.
