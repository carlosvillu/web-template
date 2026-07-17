#!/usr/bin/env node
// Regenera la tabla de estado del README raíz a partir de planning.md — la única
// fuente de verdad del progreso. La portada del repo no puede mentir sobre en qué
// punto está el desarrollo, y mantenerla a mano garantiza que un día mentirá.
//
//   pnpm readme:status          reescribe el bloque
//   pnpm readme:status --check  falla si está desfasado (lo usa el gate)
//
// Solo toca lo que hay entre los marcadores STATUS-TABLE. El resto del README
// (motivación, diagramas, quickstart) es prosa: la escribe un humano.
//
// La descripción de cada fase NO vive aquí: sale de la tabla «## Estado global»
// del propio planning.md (columna «Entrega observable al cerrar la fase»), que
// el bootstrap genera para cada proyecto. Un solo sitio que mantener.

import { readFileSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import prettier from 'prettier';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const PLANNING = join(ROOT, 'planning.md');
const README = join(ROOT, 'README.md');

const BEGIN = '<!-- STATUS-TABLE:BEGIN — generado por `pnpm readme:status`, no editar a mano -->';
const END = '<!-- STATUS-TABLE:END -->';

// Ids de fase válidos: `F0..Fn` (numeradas) y `T<LETRA>` para las transversales
// — hoy solo `TD`, el design system. Va aquí arriba porque parseDelivers y
// parsePlanning DEBEN reconocer exactamente el mismo conjunto: si una fase casa
// en una y no en la otra, sus tareas desaparecen del recuento en silencio y la
// portada miente por defecto (que es justo lo que este script existe para evitar).
const PHASE_ID = String.raw`F[\dA-Za-z]+|T[A-Z][\dA-Za-z]*`;

/**
 * Lee la tabla «## Estado global» de planning.md y devuelve un mapa
 * id de fase → «Entrega observable al cerrar la fase» (tercera columna).
 * Formato esperado por fila: | F1 | Nombre | Entrega… | Estado |
 */
function parseDelivers(md) {
  const delivers = {};
  let inSection = false;
  for (const line of md.split('\n')) {
    if (/^## Estado global\b/.test(line)) {
      inSection = true;
      continue;
    }
    if (inSection && line.startsWith('## ')) break; // siguiente sección: fin
    if (!inSection) continue;
    const row = line.match(new RegExp(String.raw`^\|\s*(${PHASE_ID})\s*\|([^|]*)\|([^|]*)\|`));
    if (row) delivers[row[1]] = row[3].trim();
  }
  return delivers;
}

/** Recorre planning.md agrupando las cabeceras `#### T…` bajo su fase (`## F…` / `## TD…`). */
function parsePlanning(md) {
  const phases = [];
  let current = null;

  for (const line of md.split('\n')) {
    const phase = line.match(new RegExp(String.raw`^## (${PHASE_ID}) — (.+)$`));
    if (phase) {
      current = { id: phase[1], name: phase[2], done: 0, total: 0 };
      phases.push(current);
      continue;
    }
    // "## Reglas de trabajo" y demás cierran la fase en curso.
    if (line.startsWith('## ')) current = null;

    // Ojo con las mayúsculas: las tareas del design system son `TD.1`, no `T1.1`.
    const task = line.match(/^#### (T[\w.]+) ·/);
    if (task && current) {
      current.total += 1;
      // Una tarea cerrada lleva `[x]` en su propia cabecera.
      if (/\[x\]/.test(line)) current.done += 1;
    }
  }
  return phases.filter((p) => p.total > 0);
}

function statusCell({ done, total }) {
  if (done === total) return '✅ Completa';
  if (done === 0) return '⬜ No empezada';
  return `🔨 ${done}/${total}`;
}

function render(phases, delivers) {
  const done = phases.reduce((n, p) => n + p.done, 0);
  const total = phases.reduce((n, p) => n + p.total, 0);
  const pct = Math.round((done / total) * 100);

  const rows = phases.map((p) => {
    // Fallback al nombre de la fase si la fila no está en «Estado global»
    // (p.ej. una fase de deuda añadida sobre la marcha sin fila propia).
    const what = delivers[p.id] ?? p.name;
    return `| **${p.id}** · ${p.name.split(' (')[0]} | ${what} | ${statusCell(p)} |`;
  });

  return [
    BEGIN,
    '',
    `**${done} de ${total} tareas cerradas (${pct} %).**`,
    '',
    '| Fase | Qué entrega | Estado |',
    '| --- | --- | --- |',
    ...rows,
    '',
    END,
  ].join('\n');
}

const planning = readFileSync(PLANNING, 'utf8');
const phases = parsePlanning(planning);
if (phases.length === 0) {
  console.error('readme:status — no se encontró ninguna fase en planning.md. ¿Cambió el formato?');
  process.exit(1);
}
const delivers = parseDelivers(planning);
if (Object.keys(delivers).length === 0) {
  console.error(
    'readme:status — no se encontró la tabla «## Estado global» en planning.md.\n' +
      'Las descripciones de fase salen de su columna «Entrega observable al cerrar la fase».',
  );
  process.exit(1);
}

const readme = readFileSync(README, 'utf8');
const start = readme.indexOf(BEGIN);
const end = readme.indexOf(END);
if (start === -1 || end === -1) {
  console.error(`readme:status — faltan los marcadores en README.md:\n  ${BEGIN}\n  ${END}`);
  process.exit(1);
}

// Formatea con el Prettier del repo antes de comparar o escribir. Sin esto, el
// script genera tablas sin alinear, `format:check` las rechaza, y el hook de
// pre-commit las reformatea POR DETRÁS del gate — el desfase exacto que este
// script existe para impedir. Una sola autoridad sobre el formato: Prettier.
const raw = readme.slice(0, start) + render(phases, delivers) + readme.slice(end + END.length);
const options = await prettier.resolveConfig(README);
const next = await prettier.format(raw, { ...options, filepath: README });

if (process.argv.includes('--check')) {
  if (next !== readme) {
    console.error(
      'readme:status — la tabla de estado del README está DESFASADA respecto a planning.md.\n' +
        'Corre `pnpm readme:status` y commitea el resultado.',
    );
    process.exit(1);
  }
  console.log('readme:status — la tabla del README coincide con planning.md ✓');
} else {
  writeFileSync(README, next);
  const done = phases.reduce((n, p) => n + p.done, 0);
  const total = phases.reduce((n, p) => n + p.total, 0);
  console.log(`readme:status — tabla regenerada: ${done}/${total} tareas.`);
}
