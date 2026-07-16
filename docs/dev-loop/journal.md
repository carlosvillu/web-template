# Journal del dev-loop — {{PROJECT_NAME}}

> Memoria del bucle entre sesiones. Append cronológico; una entrada por evento (tarea iniciada/cerrada, bloqueo, parada, decisión de arnés, cierre de fase, hotfix). **Escribe para el agente que retomará el trabajo sin tu contexto**: lo no obvio, las decisiones y sus porqués, las deudas — no un log de comandos. Nunca se reescriben entradas antiguas.

## Formatos de entrada

```markdown
## <YYYY-MM-DD> · ⏳ T<ID> iniciada
- 1-2 líneas: qué entrega y coste esperado. (Se escribe en el SELECT del ciclo.)

## <YYYY-MM-DD> · T<ID> cerrada — PASS
- Coste: $X (vs estimado $Y) · Ciclos verifier: N · Tests: N · Commit: <sha-corto> · Evidencia: docs/verifications/T<ID>/
- Decisiones no obvias que las siguientes tareas deben heredar: <1-3 líneas>
- Deuda anotada: <o "—">

## <YYYY-MM-DD> · arnés: <qué cambió>
- Qué pieza del arnés se corrigió (skill/agente/hook/gate), por qué (el ciclo que reveló la carencia) y desde cuándo aplica. El arnés evoluciona deliberadamente, nunca por deriva.

## <YYYY-MM-DD> · T<ID> cerrada — PASS · FASE F<N> COMPLETA
- Lo del cierre normal + resumen de fase: qué entrega observable quedó viva, commits de la fase, deudas que pasan a la siguiente, READMEs revisados. Termina en parada: esperar OK del usuario.

## <YYYY-MM-DD> · hotfix: <síntoma>
- Trabajo fuera del planning (bug en producción/uso real): causa raíz, fix, test permanente que lo protege, y si destapa deuda mayor → candidata a fase de deuda (F<N>b) acordada con el usuario.
```
