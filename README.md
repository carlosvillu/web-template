# web-template — arnés de desarrollo autónomo para proyectos web

Este repo es un **template**: la infraestructura de proceso (skills, agentes,
hooks, scripts, convenciones) para que un bucle autónomo de agentes de Claude
Code construya un proyecto web completo tarea a tarea, con evidencia verificable
de cada cierre. No contiene producto: el producto lo define el bootstrap de cada
proyecto.

> **Nota**: este README describe el template en sí. La skill `bootstrap` lo
> reescribe para el proyecto destino (motivación, quickstart, diagramas) —
> conservando los marcadores `STATUS-TABLE` de abajo, de los que depende
> `pnpm readme:status`.

## Cómo se usa

```bash
cp -r web-template mi-proyecto && cd mi-proyecto
git init && git add -A && git commit -m "chore: bootstrap from web-template"
claude
> /bootstrap     # entrevista → PRD.md + planning.md + mockups + rellena {{placeholders}}
> /dev-loop      # y el bucle empieza a cerrar tareas
```

`/bootstrap` genera `PRD.md`, `planning.md` (fases F0–Fn + TD con verificaciones
observables), `docs/mockups/`, y sustituye los placeholders del template:
`{{PROJECT_NAME}}`, `{{PROJECT_DESC}}`, `{{LICENSE}}`, `{{CLAUDE_DESIGN_URL}}`,
`{{REPO_URL}}` (y los de `deploy.env` cuando se aprovisione producción).
`/dev-loop` ejecuta el ciclo: elegir tarea elegible → subagente `implementer` →
gate → subagente `verifier` → evidencia en `docs/verifications/<ID>/` → commit
(y push) en verde.

## Qué contiene

```
.claude/
  skills/
    dev-loop/        # el protocolo del bucle (selección, implementer/verifier, gates, cierre)
    dev-help/        # onboarding y soporte sobre el arnés mismo
    bootstrap/       # entrevista inicial → PRD + planning + placeholders
    testing/         # CÓMO se testea: tiers unit/integration/e2e/live, anti-flaky, CUA del verifier
    backend/         # CÓMO se construye el backend: API, arquitectura, DB, jobs*, observabilidad, tooling (§8 = stack y scripts canónicos)
    frontend/        # CÓMO se construye el frontend: arquitectura, componentes, design system (espejo DesignSync), forms, estado/SSE*
    deploy/          # deploy con autodetección local(VPS)/remote + verify/rollback/backup (config en deploy.env)
    …                # skills externas de terceros (pnpm, zod, drizzle, react…)
  agents/            # implementer, verifier, ds-reviewer
  hooks/guard-planning.sh   # bloquea marcar [x] sin report.md con PASS
scripts/
  readme-status.mjs  # regenera la tabla de estado de este README desde planning.md (el gate la verifica)
docs/
  design-system/     # espejo de solo-lectura de Claude Design (tool DesignSync)
  verifications/     # evidencia por tarea
  dev-loop/          # journal del bucle
CLAUDE.md / AGENTS.md   # el contrato del arnés (mapa de documentos, reglas de oro, paradas)
deploy.env           # configuración de despliegue (sin secretos; lo rellena el bootstrap)
lefthook.yml         # pre-commit (eslint+prettier sobre staged), pre-push (typecheck)
```

\* `jobs` y `SSE` solo aplican si el F0 del proyecto incluye esos módulos opcionales.

**Stack fijo**: pnpm workspaces + TypeScript, `apps/web` (Next.js App Router +
Tailwind v4), `packages/core` (dominio + Zod), `packages/db` (Postgres +
Drizzle), Vitest + Playwright, Base UI/shadcn, pino. El gate local es
`pnpm gate` = lint + typecheck + format:check + knip + readme:status:check + test.

## Estado del desarrollo

La tabla de abajo la genera `pnpm readme:status` desde `planning.md` una vez el
proyecto está bootstrapeado. **No borres los marcadores**: el gate
(`readme:status:check`) falla sin ellos.

<!-- STATUS-TABLE:BEGIN — generado por `pnpm readme:status`, no editar a mano -->

_(sin planning.md todavía — corre `/bootstrap` y después `pnpm readme:status`)_

<!-- STATUS-TABLE:END -->

## Licencia

{{LICENSE}} — la fija el bootstrap para cada proyecto.
