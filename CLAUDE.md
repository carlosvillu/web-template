# {{PROJECT_NAME}}

{{PROJECT_DESC}}. El desarrollo lo ejecuta un **bucle autónomo de agentes** gobernado por la skill `dev-loop`.

> **Si no existen `PRD.md` y `planning.md`, este repo es todavía el template sin arrancar: el punto de entrada es `/bootstrap`** (genera el PRD, el planning y rellena los placeholders). No inventes tareas sin planning.

## Mapa de documentos (fuentes de verdad)

| Documento | Qué es |
|---|---|
| `PRD.md` | El producto completo, aprobado por el humano en el bootstrap |
| `planning.md` | **La fuente de verdad del estado del desarrollo**: fases F0–Fn + TD (design system) → tareas con `Depende de` + Verificación observable. Las reglas de trabajo del final son vinculantes |
| `.claude/skills/{testing,backend,frontend,deploy}` | CÓMO se desarrolla, testea y despliega. Cada SKILL.md tiene una tabla de decisión → reference a leer ANTES de escribir código |
| `research/` | Informes que respaldan el PRD (solo consulta, no editar) |
| `docs/design-system/` | Espejo de solo-lectura del proyecto de Claude Design del producto ({{CLAUDE_DESIGN_URL}}) — la fuente de verdad visual. Se regenera con la tool `DesignSync`; JAMÁS se edita a mano |
| `docs/mockups/` | Mockups/wireframes de referencia generados en el bootstrap |
| `docs/verifications/<TASK-ID>/` | Evidencia de cierre de cada tarea (report.md + capturas/outputs) |
| `docs/dev-loop/journal.md` | Diario del bucle: qué se cerró/bloqueó, cuándo, coste, rarezas |
| `README.md` + `<paquete>/README.md` | La cara pública del proyecto ({{LICENSE}}). Su tabla de estado se **genera** desde `planning.md` con `pnpm readme:status` y el gate la verifica; la prosa se revisa al cerrar cada fase |

**Jerarquía cuando algo contradiga algo**: PRD/planning > skills propias (testing/backend/frontend/deploy) > skills externas > costumbre. Si una pieza no encaja en las skills propias, o está mal planteada o la skill necesita actualización deliberada — nunca las dos cosas en silencio.

## El bucle de desarrollo

El trabajo avanza tarea a tarea de `planning.md` vía la skill **`dev-loop`** (invócala con `/dev-loop` o cuando el usuario pida "sigue/continúa con el desarrollo"). No improvises un proceso alternativo: el protocolo (selección de tarea, subagentes implementer/verifier, gates, cierre) vive ahí. Para preguntas sobre el arnés mismo (cómo funciona, comandos, por qué se paró, onboarding), la skill **`dev-help`** es el punto de entrada.

### Reglas de oro (resumen; el detalle en la skill)

1. **Una tarea por ciclo, contexto fresco.** Cada tarea la implementa un subagente `implementer` nuevo con un brief acotado. Nunca "adelantar" trabajo de otras tareas en el mismo ciclo.
2. **La evidencia precede a la marca.** Ninguna tarea se marca `[x]` sin `docs/verifications/<ID>/report.md` con veredicto PASS (un hook lo bloquea a nivel de harness). La Verificación se ejecuta LITERAL, sin rebajarla.
3. **Quien implementa no se evalúa a sí mismo.** El gate de cierre lo ejecuta el subagente `verifier` (escéptico, con contexto fresco); el implementer jamás toca `planning.md` ni `docs/verifications/`.
4. **`pnpm test` verde antes del gate; gate local completo antes de commit.** El gate local es EL gate: `pnpm gate` (lint + typecheck + format:check + knip + readme:status:check + test); + `pnpm test:e2e` si hubo superficie web.
5. **Prohibido debilitar tests para ponerse en verde.** Borrar/relajar un test existente solo con justificación explícita en el journal y en el mensaje de commit. Un test flaky se arregla o se borra con causa raíz, no se reintenta.
6. **Coste consciente.** Cap por tarea = estimado del planning ×3 (mín. $1). Superarlo = parada de gasto. Todo coste real va al report y al journal.
7. **Cambios de alcance** (el PRD necesita ajuste): menores → editar PRD+planning en la misma sesión y anotarlo; mayores → parar y preguntar al usuario.

### Paradas del bucle (informar al usuario y detenerse)

- Prerequisito externo ⚠ en la siguiente tarea (API keys, apps de developer, VPS, presupuesto real).
- Fin de fase: tras cerrar el E2E de fase, presentar resumen y esperar OK.
- Verificación que exige juicio humano explícito ("revisión humana", "a juicio humano"): hacer lo automatizable, dejar la evidencia preparada y pedir el juicio.
- Circuit breaker: 2 FAIL consecutivos del verifier en la misma tarea, o 2 tareas seguidas bloqueadas.
- Decisión de gasto por encima del cap.

## Arranque de sesión (bootstrap de contexto)

Antes de tocar nada: (1) `git log --oneline -5`, (2) estado de `planning.md` (próxima tarea elegible por el grafo `Depende de`), (3) tail de `docs/dev-loop/journal.md`. Con eso se retoma el trabajo sin depender del contexto de sesiones anteriores.

## Convenciones transversales

- Código, identificadores y mensajes de commit en inglés; docs del proyecto, UI y comunicación en español.
- Commits solo en verde (gate local), como mínimo uno por tarea cerrada: `T<ID>: <resumen imperativo>`. **El bucle puede hacer `git push` a `main`** una vez el gate pasa — publicar el progreso es parte del ciclo, no una decisión aparte. El hook `guard-planning` protege `planning.md` a nivel de harness.
- **Ningún secreto en el árbol.** Las credenciales reales viven solo en `.env` / `.env.test.local` (gitignored) o en el `.env` del VPS. Todo lo que parezca una clave en un fichero committeado debe ser un literal de test evidente (`test-…-not-a-secret`).
- Stack y scripts canónicos: los define la skill backend (`references/tooling.md` §8) + testing (`stack-setup.md` §6). `pnpm gate` es el único script propiedad del arnés.
- Despliegue y operación de producción: SIEMPRE vía la skill `deploy` (autodetecta si corre en el VPS o en desarrollo). La configuración vive en `deploy.env`.
- Los `[verificar]` del PRD se cierran en la tarea que los nombra y se anotan en PRD y planning.
