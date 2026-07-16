# Tour completo del arnés de desarrollo autónomo — template

> Documento de referencia de la skill `dev-help`. Describe el TEMPLATE de arnés que este proyecto usa. Si algo de aquí contradice a `.claude/skills/dev-loop/SKILL.md`, a los agentes o al hook, **ganan ellos** (son el código del arnés; esto es su manual).

## 1. Qué es y por qué existe

El arnés es el sistema que permite desarrollar el producto definido en `PRD.md` de forma **autónoma pero auditable**: Claude ejecuta las tareas de `planning.md` una a una — implementa, testea, se auto-revisa, verifica contra el sistema real y deja evidencia — y solo se detiene donde una persona aporta valor real (decisiones de gasto, prerequisitos externos, juicio humano, fin de fase).

No es un invento ad-hoc: se diseñó tras una investigación verificada del estado del arte (2026) de bucles de desarrollo con agentes, y ya ha desarrollado proyectos completos. Los hallazgos que lo moldearon:

| Hallazgo (fuente) | Cómo lo codifica el arnés |
|---|---|
| Los agentes **sobre-aprueban su propio trabajo** (Anthropic engineering) | Quien implementa (implementer) NUNCA verifica; lo hace un agente separado (verifier) con mandato escéptico explícito |
| La compactación de contexto **no basta** en proyectos largos; hace falta estado durable en ficheros | El estado vive en `planning.md` + `docs/dev-loop/journal.md` + git log; cualquier sesión nueva retoma leyendo esos tres |
| **Una tarea por sesión de agente** fue la contramedida crítica contra "intentar todo a la vez" | Cada tarea la implementa un agente NUEVO con contexto fresco y brief acotado |
| La verificación e2e **real** (conducir la app como usuario) mejora dramáticamente vs "compila" | El gate de cierre es la Verificación literal del planning contra el sistema levantado (protocolo CUA de la skill testing) |
| Las instrucciones en prosa son **probabilísticas**; los "no debe pasar nunca" exigen mecanismos deterministas | El hook `guard-planning` bloquea a nivel de harness marcar tareas sin evidencia — no depende de que el modelo "se acuerde" |
| Los bucles degeneran sin **circuit breakers** (loops sin progreso, mismo error repetido) | 2 FAILs consecutivos del verifier en la misma tarea → parada; 2 tareas seguidas bloqueadas → parada |

## 2. Cómo nace un proyecto desde el template

Este repo empieza como una copia del template (`cp -r web-template <mi-proyecto>`). Un proyecto recién copiado NO tiene `PRD.md` ni `planning.md` — eso lo genera **`/bootstrap`**, una skill que:

1. Conversa con el usuario sobre la idea de producto.
2. Recibe la URL del proyecto en **Claude Design** (el usuario SIEMPRE la proporciona) y sincroniza su espejo read-only en `docs/design-system/` con el tool DesignSync.
3. Escribe `PRD.md` (el producto) y `planning.md` (fases y tareas con dependencias, Verificación literal por tarea, estimaciones de coste).

El planning resultante es **modular**: la fase F0 (fundaciones) incluye solo los módulos que el PRD exige (worker, cola pg-boss, storage, auth, SSE, spend ledger…); la base mínima siempre es `apps/web` + `packages/core` + gate + Playwright. Hay además una **fase transversal TD** (design system) que traduce el espejo de `docs/design-system/` a código (`components/ui/`).

Stack fijo del template: pnpm monorepo TypeScript · Next.js App Router + Tailwind v4 CSS-first · Postgres + Drizzle · Vitest + Playwright · Base UI/shadcn · pino. Docs del proyecto en español; código y commits en inglés.

## 3. Mapa de piezas (qué es cada fichero)

```
CLAUDE.md                          ← orientación que carga toda sesión: mapa, jerarquía, reglas de oro, paradas
.claude/
├─ skills/
│  ├─ bootstrap/                   ← arranque de un proyecto nuevo (PRD + planning); se usa una vez
│  ├─ dev-loop/SKILL.md            ← EL PROTOCOLO del bucle (la pieza central)
│  ├─ dev-help/                    ← esta guía
│  ├─ testing/ backend/ frontend/ deploy/ ← las skills de CÓMO desarrollar (el bucle las orquesta)
│  └─ (externas: pnpm, zod, postgres-drizzle, agent-browser, next-dev-loop, vercel-*, web-design-guidelines, supabase-postgres-best-practices)
├─ agents/
│  ├─ implementer.md               ← el que construye una tarea
│  ├─ verifier.md                  ← el que la verifica y emite PASS/FAIL
│  └─ ds-reviewer.md               ← el que revisa la adherencia al Design System (REVIEW 5c)
├─ hooks/guard-planning.sh         ← guardia determinista: sin evidencia no hay [x]
└─ settings.json                   ← permisos (allowlist para no interrumpir el bucle) + registro del hook
docs/
├─ dev-loop/journal.md             ← diario del bucle: memoria entre sesiones
├─ verifications/<TASK-ID>/        ← evidencia de cada tarea cerrada (report.md + capturas/outputs)
├─ mockups/                        ← mockups de las superficies web
└─ design-system/                  ← espejo READ-ONLY del proyecto en Claude Design (lo escribe DesignSync)
planning.md                        ← fuente de verdad del estado: fases, tareas, deps, [x]  (lo genera /bootstrap)
PRD.md                             ← el producto (qué se construye)                        (lo genera /bootstrap)
```

Y en el `package.json` raíz, **`pnpm gate`** = lint + typecheck + format:check + knip + readme:status:check + test (unit+integración). Lo crea la tarea T0.1 de cada proyecto y es el gate de merge local. `pnpm test:e2e` corre además cuando la tarea tocó superficie web.

**Jerarquía cuando algo contradiga algo**: PRD/planning > skills propias (testing/backend/frontend/deploy) > skills externas. El arnés (dev-loop) orquesta; las skills propias definen el CÓMO técnico.

## 4. El ciclo de vida de una tarea (el bucle)

Cada tarea de `planning.md` pasa por estos pasos (detalle canónico en `dev-loop/SKILL.md`):

1. **SELECT** — el bucle elige la siguiente tarea por el grafo `Depende de` (la numeración es orientativa). Antes de empezar comprueba si toca parar (⚠, gasto, juicio humano).
2. **BRIEF** — compone un encargo acotado: texto literal de la tarea + qué references de las skills leer (según sus tablas de decisión) + contexto vivo del journal. No se le pega el PRD entero al agente: lee lo que su tarea exige.
3. **IMPLEMENT** — un agente `implementer` NUEVO (contexto fresco) construye código + tests de esa tarea y entrega un informe estructurado. Tiene prohibido: tocar `planning.md` o `docs/verifications/`, debilitar tests, hacer commits, salirse del alcance.
4. **GATE** — el bucle re-ejecuta `pnpm gate` ÉL MISMO (no se fía del "me salió verde" del agente). Rojo → de vuelta al implementer.
5. **REVIEW** — pases obligatorios sobre el diff (solo si la tarea produjo código; se saltan en tareas de solo-docs/skill), ANTES de VERIFY porque mutan código y lo que VERIFY bendice debe ser lo que se commitea: (5a) `code-review` con esfuerzo proporcional al riesgo (low para diffs mecánicos y UI/copy, medium por defecto, high en dinero/pagos, auth/seguridad y núcleo de dominio) — caza bugs. (5b) `simplify` — solo calidad, auto-aplica cleanups; re-gate obligatorio inspeccionando su diff. (5c) `ds-reviewer` si el diff tocó `apps/web/**` — adherencia al Design System. Cada pase una vez, sin punto fijo.
6. **VERIFY** — un agente `verifier` (fresco, escéptico) ejecuta la **Verificación literal** del planning contra el sistema levantado: con UI usa `agent-browser` como un humano; solo-backend usa curl/scripts/psql observables. Persiste evidencia en `docs/verifications/<ID>/` y emite PASS/FAIL. Máximo 2 FAIL seguidos → el bucle para e informa.
7. **CLOSE** — solo con PASS: marca `[x]` en planning (el hook exige que el report exista), regenera la tabla de estado del README (`pnpm readme:status`), anota el journal, y commitea (`T<ID>: resumen`) + **push**. Tras el commit, re-corre el gate sobre lo commiteado (el pre-commit puede reformatear).
8. **STOP-CHECK** — ¿parada natural? Si no, siguiente tarea.
9. **REVISIÓN DE READMEs** (solo al cerrar fase) — la prosa de los READMEs se revisa contra lo que la fase acaba de volver falso.

### Paradas del bucle (cuándo se detiene y te busca)

- **⚠ prerequisito externo** en la siguiente tarea (API keys, apps de developer, infraestructura…): son tuyos.
- **Fin de fase**: tras cerrar el E2E de fase (la última tarea de cada fase), revisión de READMEs, resumen y espera tu OK.
- **Juicio humano** en la Verificación ("a juicio humano", "revisión humana"): prepara lo automatizable y te pide el veredicto.
- **Gasto**: si la verificación puede superar el cap (estimado del planning ×3, mínimo $1) o usará APIs de pago sin estimación.
- **Circuit breaker**: 2 FAILs seguidos en la misma tarea, 2 tareas seguidas sin cerrarse, o el mismo error dos veces sin progreso.
- **Cambio de alcance mayor** (el PRD necesita un ajuste de producto): los menores se editan y anotan solos; los mayores son tuyos.

## 5. Comandos que acepta el arnés

| Comando | Qué hace |
|---|---|
| `/bootstrap` | Arranca el proyecto: PRD.md + planning.md desde tu idea + URL de Claude Design (una sola vez) |
| `/dev-loop` | Bucle continuo hasta parada natural (el modo por defecto) |
| `/dev-loop task` | Exactamente UNA tarea (la siguiente elegible) y para |
| `/dev-loop task T0.5` | Esa tarea concreta (si sus dependencias están cerradas) |
| `/dev-loop phase` | Encadena hasta cerrar el E2E de la fase actual, incluido |
| `/dev-loop status` | Solo informa: estado, próxima tarea, bloqueos. No ejecuta nada |
| `/dev-help [pregunta]` | Esta guía |
| Lenguaje natural | "sigue/continúa con el desarrollo" ≡ `/dev-loop` · "¿cómo va?" ≡ status |

Internos (los usa el bucle, no hace falta que los invoques): `code-review` y `simplify` en el paso 5, `agent-browser` en las verificaciones con UI, DesignSync para refrescar el espejo del DS, y las skills testing/backend/frontend/deploy como fuente de CÓMO desarrollar.

## 6. Los subagentes en detalle

**`implementer`** (`.claude/agents/implementer.md`) — recibe el brief de UNA tarea; lee los references vinculantes antes de codificar; los tests nacen con el código; entrega con las suites del paquete en verde y un informe (qué construyó, ficheros, tests, decisiones no obvias, dudas). Si una duda cambia el alcance, NO la resuelve: la reporta y para en punto estable. El bucle puede "continuarlo" (mantiene su contexto) para pasarle fallos del gate o hallazgos de la review.

**`verifier`** (`.claude/agents/verifier.md`) — mandato escéptico: "tu éxito se mide por fallos legítimos encontrados, no por PASS emitidos". Prohibido modificar código de producto (solo escribe evidencia); prohibido rebajar la Verificación (si pide 20 runs concurrentes, son 20); prohibido "convencerse de que un problema no es para tanto" — todo problema va al report y bloquea el PASS. Sigue el protocolo de `testing/references/cua.md` (sistema entero levantado, waits por condición, evidencia antes del veredicto).

**`ds-reviewer`** (`.claude/agents/ds-reviewer.md`) — revisa estáticamente el diff frontend contra el catálogo vivo del Design System (`docs/design-system/components/` + `_adherence.oxlintrc.json`): HTML crudo que debería ser una primitiva, tokens hardcodeados, props fuera de contrato. Su contrato es cero falsos positivos: el HTML legítimo (layout, superficies sin primitiva) no se marca.

**Por qué separados**: sesgo de auto-aprobación documentado (§1). Además cada uno arranca con contexto fresco — el implementer no arrastra deriva de tareas anteriores, y el verifier no hereda las suposiciones del implementer.

Nota operativa: los agentes definidos a mitad de sesión no se registran hasta reiniciar Claude Code. Si `/dev-loop` no los encuentra, el fallback es usar `general-purpose` con la definición del agente inlineada en el prompt.

## 7. Guardrails deterministas (lo que NO depende de que el modelo se porte bien)

- **`guard-planning.sh`** (hook PreToolUse sobre Edit/Write): si una edición añade `[x]` al heading de una tarea (`#### T<ID> … [x]`) y no existe `docs/verifications/<ID>/report.md`, el hook **bloquea la edición** con mensaje. Las subtareas (`- [x]`) no exigen evidencia; las fechas `[2026-…]` no disparan falsos positivos (regex estricta).
- **Permisos** (`settings.json`): allowlist de comandos de desarrollo (pnpm, npx, git, docker, curl, psql…) para que el bucle no se pare en prompts; lectura de `.env*.local` (claves reales) **denegada**. En este template `git push` SÍ está permitido: el bucle pushea al cerrar cada tarea.
- **`pnpm gate` re-ejecutado por el bucle**: el veredicto de calidad no es del agente que implementó.
- **Guards ruidosos en scripts prematuros**: los scripts que aún no pueden correr (p. ej. `test:e2e` antes de que exista Playwright, `test:live` antes de que exista el techo de gasto) fallan con mensaje `DESHABILITADO hasta T<ID>` en vez de dar verde en silencio — un script prematuro que "pasa" sin ejecutar nada es un falso verde, y uno que gasta dinero sin límite es peor.

## 8. Evidencia: la regla central

**"La evidencia precede a la marca."** Ninguna tarea está hecha porque lo diga un agente ni porque compile: está hecha cuando su Verificación (el campo literal de `planning.md`) se ejecutó contra el sistema real y quedó rastro auditable en `docs/verifications/<TASK-ID>/`:

- `report.md` con la plantilla de `testing/references/cua.md`: verificación esperada (cita literal), pasos ejecutados, tabla esperado/observado/evidencia, coste real, veredicto.
- Ficheros crudos: screenshots numerados (si hay UI), outputs de terminal (`| tee`), logs.
- Los FAIL también se documentan (`report-fail-N.md`): valen tanto como los PASS.
- Todo se commitea: es la memoria del proyecto.

## 9. Presupuesto y costes

- La suite de tests **jamás** gasta dinero (mocks msw + fixtures; regla de la skill testing).
- Las verificaciones sí pueden gastar si el proyecto usa APIs de pago. Cap por tarea = **estimado del planning ×3, mínimo $1**. Si va a superarse → parada de gasto y decisión tuya.
- Todo coste real va al report y al journal; si difiere >25 % del estimado, se recalibra en la misma tarea.

## 10. Cómo intervenir tú

- **Arrancar un proyecto nuevo**: copia el template, entra, y lanza `/bootstrap` con tu idea y la URL de tu proyecto en Claude Design.
- **Ver dónde está todo**: `/dev-loop status` o `/dev-help`.
- **Avanzar con control fino**: `/dev-loop task` (de una en una) hasta que cojas confianza; luego `/dev-loop`.
- **Resolver un ⚠**: los prerequisitos externos (crear apps de developer, infraestructura, poner API keys) son tuyos; el planning los marca con ⚠. Cuando lo resuelvas, díselo al bucle y continúa.
- **Si el bucle paró por circuit breaker**: el journal y el último report del verifier explican la causa; decide tú (arreglar a mano, re-plantear la tarea, o pedirle al bucle que reintente con contexto nuevo).
- **Cuestionar una decisión del arnés**: el arnés evoluciona deliberadamente — pide el cambio y quedará editado en la skill/agente correspondiente con nota en el journal (nunca deriva silenciosa).
- **Interrumpir / retomar una sesión**: puedes cortar en cualquier momento; el estado durable (planning + journal + git) garantiza que la siguiente sesión retoma sin pérdida — su bootstrap es `git status` + `git log` + planning + tail del journal. No dejes a medias un CLOSE (si ves planning marcado sin commit, el journal lo aclara).

## 11. FAQ rápido

- **¿Por qué la primera tarea tarda más?** T0.1 monta el monorepo, el tooling y el gate: es la tarea más grande del planning. El régimen normal es más corto y la review escala con el riesgo del diff.
- **¿El bucle puede "hacer trampa" y marcar cosas sin verificar?** El hook lo bloquea a nivel de harness, y quien emite el PASS nunca es quien implementó.
- **¿Puede gastar dinero sin que me entere?** No: la suite no gasta por diseño, los scripts con coste están desarmados hasta que exista su techo de gasto, y las verificaciones con coste tienen cap y paran para preguntarte si lo superan. Todo dólar queda anotado.
- **¿Qué pasa si cierro la sesión a mitad de una tarea?** Nada grave: el trabajo no commiteado queda en el árbol y el journal explica el estado; la siguiente sesión hace bootstrap (git status + planning + journal) y entiende dónde estaba.
- **¿Dónde veo lo que se ha hecho?** `git log --oneline`, `planning.md` (marcas con fecha y puntero a evidencia), la tabla de estado del README, `docs/dev-loop/journal.md` (la narrativa) y `docs/verifications/` (las pruebas).
- **¿Y el diseño visual?** Cada proyecto tiene su proyecto en Claude Design; el tool DesignSync mantiene un espejo read-only en `docs/design-system/`, y la fase TD del planning lo traduce a componentes en `apps/web/src/components/ui/`. El `ds-reviewer` vigila que el resto del código los reutilice.
