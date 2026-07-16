#!/usr/bin/env python3
"""Guardia anti-ficción del bucle de desarrollo (hook PreToolUse sobre Edit|Write).

Bloquea (exit 2) cualquier edición que marque una tarea de planning.md como [x]
sin que exista docs/verifications/<TASK-ID>/report.md — la evidencia precede a la
marca (skill testing, references/cua.md paso 4). Determinista a propósito: las
instrucciones en prosa son probabilísticas; esto no.
"""
import json
import os
import re
import sys


def main() -> int:
    try:
        data = json.load(sys.stdin)
    except Exception:
        return 0  # sin input parseable no hay nada que vigilar

    tool_input = data.get("tool_input", {}) or {}
    file_path = tool_input.get("file_path", "") or ""

    if os.path.basename(file_path) != "planning.md":
        return 0

    # Texto nuevo que introduce la edición: Edit (new_string), Write (content),
    # MultiEdit (edits[].new_string).
    parts = []
    if tool_input.get("new_string"):
        parts.append(tool_input["new_string"])
    if tool_input.get("content"):
        parts.append(tool_input["content"])
    for e in tool_input.get("edits", []) or []:
        if e.get("new_string"):
            parts.append(e["new_string"])
    new_text = "\n".join(parts)
    if not new_text:
        return 0

    project_dir = os.path.dirname(os.path.abspath(file_path))
    missing = []
    # Solo headings de tarea (#### T0.1 · ... / #### TD.1 · ... / #### T1.10b · ...)
    # con [x] literal. Convención de IDs: T<fase>.<n>[sufijo], donde <fase> es un
    # número (F0..Fn) o letra mayúscula (fase transversal, p.ej. D = design system).
    # Las subtareas "- [x]" no exigen evidencia (se marcan durante el trabajo);
    # las fechas tipo [2026-07-07] no matchean (regex estricta \[x\]).
    for m in re.finditer(r"^####\s+(T[A-Z0-9]+\.\d+[a-z]?)\b.*\[x\]", new_text, re.M):
        task_id = m.group(1)
        report = os.path.join(project_dir, "docs", "verifications", task_id, "report.md")
        if not os.path.isfile(report):
            missing.append(task_id)

    if missing:
        ids = ", ".join(sorted(set(missing)))
        print(
            f"BLOQUEADO por el arnés: se intenta marcar [x] {ids} sin "
            f"docs/verifications/<ID>/report.md. La evidencia precede a la marca. "
            f"Ejecuta la Verificación con el agente verifier, persiste el report "
            f"y vuelve a intentarlo.",
            file=sys.stderr,
        )
        return 2

    return 0


if __name__ == "__main__":
    sys.exit(main())
