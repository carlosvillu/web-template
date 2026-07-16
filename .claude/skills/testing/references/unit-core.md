# Unit testing — `packages/core` y lógica pura

Esta capa cubre todo lo que es **función pura**: contratos Zod, validadores deterministas, parsers, transformadores, cálculos de negocio, tablas de transición si tu F0 incluye una máquina de estados, y validadores de seeds si tu proyecto versiona datos en git. Es la capa más barata de ejecutar y la que más bugs caros previene: casi todo lo que aquí se testea decide **qué entra al sistema** o **qué estado toma**. Un test aquí cuesta milisegundos.

## Índice

1. [Alcance y principios](#1-alcance-y-principios)
2. [Patrones transversales](#2-patrones-transversales)
3. [Contratos Zod (y espejo JSON Schema si usas structured outputs de un LLM)](#3-contratos-zod)
4. [Máquina de estados: exhaustividad por producto cartesiano](#4-máquina-de-estados)
5. [Validadores deterministas con warnings tipados](#5-validadores-deterministas)
6. [Fórmulas y leyes: mide lejos del punto fijo](#6-fórmulas-y-leyes)
7. [Compiladores/serializadores: golden files](#7-compiladores-y-serializadores)
8. [Validadores de seeds en CI](#8-validadores-de-seeds-en-ci)
9. [Criterio de exhaustividad por tipo de código](#9-criterio-de-exhaustividad)

## 1. Alcance y principios

- **Ubicación**: co-locados con el código, `src/**/*.test.ts`, en cualquier paquete. Corren con `pnpm test:unit`, que filtra por `--project '*:unit'` sobre los proyectos declarados en el `vitest.config.ts` raíz vía `test.projects` (convención de nombres `<paquete>:unit` de stack-setup.md §3.2). Los proyectos `*:unit` **no** declaran el globalSetup de Testcontainers: la suite unit arranca sin Docker y en segundos. Por qué: el feedback loop de la lógica pura debe ser inmediato; si un test "unit" necesita Postgres, está mal clasificado — muévelo a `test/integration/` (ver db-integration.md).
- **No mockees lógica pura.** Una función `(input) => output` se testea llamándola. Los mocks (msw, spies) son para fronteras I/O, y en `packages/core` no debería haber fronteras I/O: si una función del core necesita red o BD, es un olor de diseño — extrae la lógica pura y deja el I/O en el caller (web/worker).
- **Determinismo por inyección, no por mocking de globals.** Si una función necesita tiempo, aleatoriedad o IDs, recibe `clock`, `random` o `idFactory` como parámetro (con default de producción). Así el test pasa valores fijos y no hay `vi.useFakeTimers()` salpicado. Excepción aceptable: fake timers para utilidades de timing puro (backoff, debounce).
- **El input canónico son las factories de `@app/test-utils`** (`makeX()`): cada una devuelve un objeto **válido según su schema Zod** y acepta overrides parciales. Por qué: cuando el contrato evoluciona, se actualiza la factory una vez y no cincuenta JSON copiados.

## 2. Patrones transversales

### Table-driven tests

El formato por defecto para validadores, linters y parsers: una tabla de casos con nombre, input y expectativa, ejecutada con `it.each`. Por qué: añadir un caso de regresión cuesta una línea, el nombre del caso aparece en el output de Vitest, y la tabla ES la documentación del comportamiento.

### Golden files

Para outputs textuales largos donde **cada carácter importa** (prompts resueltos, payloads serializados a APIs externas, ficheros generados): compara contra un fichero versionado en git, carácter a carácter. Los goldens viven en `test/golden/` junto a la suite que los usa. Se regeneran con `UPDATE_GOLDEN=1` — y el diff resultante **se revisa en el PR como código**: regenerar no es "arreglar el test", es declarar conscientemente que el output cambió.

Helper compartido: `expectGolden()` en `@app/test-utils` (firma y pitfalls en stack-setup.md §4.5; el caller resuelve el path con `new URL('./golden/caso.txt', import.meta.url)`).

Reglas: nunca normalices whitespace antes de comparar (un espacio perdido en un output que consume una API es un bug real); serializa JSON con claves ordenadas y `null, 2` para que los diffs sean estables; un golden por caso, con nombre descriptivo.

### Fixtures inválidos = fixture válido + mutación dirigida

Nunca escribas a mano un JSON inválido completo: se desincroniza del schema y el test acaba fallando por el motivo equivocado. El patrón es partir de la factory válida y romper exactamente una cosa. Así, cuando el test falla, solo puede ser por la propiedad que rompiste.

## 3. Contratos Zod

Los contratos de `packages/core` son la columna vertebral de los datos que cruzan el sistema. Cada schema tiene una suite con: (a) el fixture canónico válido, (b) una tabla de mutaciones inválidas — una por regla de negocio del schema.

```ts
// packages/core/src/contracts/order.test.ts
import { describe, expect, it } from "vitest";
import { makeOrder } from "@app/test-utils";
import { OrderSchema, type Order } from "./order";

it("el fixture canónico valida", () => {
  expect(OrderSchema.safeParse(makeOrder()).success).toBe(true);
});

const invalid: Array<[name: string, mutate: (o: Order) => unknown]> = [
  ["sin líneas", (o) => ({ ...o, lines: [] })],
  ["cantidad negativa", (o) => ({ ...o, lines: [{ ...o.lines[0], qty: -1 }] })],
  ["estado fuera del enum", (o) => ({ ...o, status: "teleported" })],
  // …una mutación por regla de negocio del schema
];

it.each(invalid)("rechaza: %s", (_name, mutate) => {
  expect(OrderSchema.safeParse(mutate(makeOrder())).success).toBe(false);
});
```

**Si usas structured outputs de un LLM con un espejo JSON Schema, testea el espejo aparte**, porque puede divergir a propósito: las APIs de structured outputs (p. ej. Anthropic) **no aplican** `minItems`/`maxItems` y exigen `additionalProperties: false` — las cardinalidades viven SOLO en Zod. El test fija ese reparto de responsabilidades para que nadie lo "arregle" moviendo constraints al JSON Schema donde serían ignorados silenciosamente:

```ts
import Ajv2020 from "ajv/dist/2020"; // valida contra el meta-schema draft 2020-12
const ajv = new Ajv2020({ strict: true });
const validateMirror = ajv.compile(orderJsonSchema); // compile YA falla si el schema no es draft 2020-12 válido

it("todo objeto del espejo lleva additionalProperties:false (requisito del proveedor)", () => {
  const walk = (node: unknown): void => {
    if (node === null || typeof node !== "object") return;
    const n = node as Record<string, unknown>;
    if (n.type === "object") expect(n.additionalProperties).toBe(false);
    Object.values(n).forEach(walk);
  };
  walk(orderJsonSchema);
});

it("divergencia documentada: cardinalidad que el espejo tolera pero Zod rechaza", () => {
  const inflated = { ...makeOrder(), lines: Array(101).fill(makeOrder().lines[0]) };
  expect(validateMirror(inflated)).toBe(true);           // el proveedor no lo frenaría
  expect(OrderSchema.safeParse(inflated).success).toBe(false); // Zod sí — aquí vive la cardinalidad
});

it("el espejo acepta todo lo que Zod acepta (espejo ⊇ Zod)", () => {
  expect(validateMirror(makeOrder())).toBe(true);
});
```

Si el espejo se genera desde Zod o se mantiene a mano es indiferente para el test: **se testea el artefacto resultante, no el generador**.

## 4. Máquina de estados

> **Solo si tu F0 incluye una máquina de estados** (habitual con el módulo worker/orquestación — ver worker-jobs.md para su capa de integración).

**Regla: toda transición ilegal rechaza, y los tests lo demuestran por producto cartesiano estados × eventos.** La tabla de transiciones es una función pura `nextStatus(status, event)` en `packages/core`. **El cartesiano exhaustivo vive SOLO en esta capa**: la suite de integración NO lo repite — cubre las transiciones legales end-to-end más una muestra representativa de ilegales verificando el rollback, y los efectos transaccionales. Aquí se testea la tabla, y se testea ENTERA: con ~13 estados y ~14 eventos hay <200 combinaciones — trivial de ejecutar y la única forma de garantizar que añadir un estado o evento nuevo obliga a decidir explícitamente cada celda nueva. Una transición ilegal que pase inadvertida corrompe estado (y duplica gasto si hay APIs de pago aguas abajo): suele ser el test más rentable del proyecto.

Clave del patrón: la lista de transiciones legales del test se **transcribe a mano del PRD**, independiente de la implementación. Si el test derivara los casos de la propia tabla de producción, sería una tautología que siempre pasa.

```ts
// packages/core/src/orchestrator/state-machine.test.ts
import { describe, expect, it } from "vitest";
import {
  STEP_STATUSES, STEP_EVENTS, nextStatus, IllegalTransitionError,
  type StepStatus, type StepEvent,
} from "./state-machine";

// Transcripción manual del PRD — NO derivar de la implementación.
// Este espejo y el de worker-jobs.md se actualizan desde la misma tabla en la misma sesión.
const LEGAL: Array<[StepStatus, StepEvent, StepStatus]> = [
  ["pending", "enqueue", "queued"],
  ["queued", "start", "running"],
  ["running", "succeed", "succeeded"],
  ["running", "fail", "failed"],
  ["failed", "retry", "queued"],
  // …completar 1:1 con la tabla del PRD
];
const legalMap = new Map(LEGAL.map(([s, e, to]) => [`${s}:${e}`, to]));

describe("máquina de estados — producto cartesiano completo", () => {
  const pairs = STEP_STATUSES.flatMap((s) => STEP_EVENTS.map((e) => [s, e] as const));

  it.each(pairs)("(%s, %s)", (status, event) => {
    const expected = legalMap.get(`${status}:${event}`);
    if (expected !== undefined) {
      expect(nextStatus(status, event)).toBe(expected);
    } else {
      expect(() => nextStatus(status, event)).toThrow(IllegalTransitionError);
    }
  });

  it("los estados terminales no aceptan ningún evento", () => {
    for (const terminal of TERMINAL_STATUSES) {
      expect(LEGAL.some(([s]) => s === terminal)).toBe(false);
    }
  });
});
```

Si al implementar se decide añadir una transición nueva, se actualiza el PRD y ambos espejos LEGAL (este y el de integración) en la misma sesión; la skill no inventa transiciones. Si el cálculo de invalidación/cierre transitivo de un grafo vive en el core, añade asserts como función pura: dado un DAG fixture, invalidar el nodo X devuelve exactamente el conjunto esperado de descendientes.

## 5. Validadores deterministas

Patrón para cualquier validador de dominio con **perfiles** (variantes de comportamiento por origen/modo) y **warnings tipados** (discriminated union con `code`): testea cada código de warning con un caso que lo dispara y, para cada perfil, que las reglas ajenas NO se disparan — la diferencia entre perfiles es exactamente lo que un refactor descuidado rompería.

```ts
it("perfil A: dispara el warning X con corrección determinista", () => {
  const res = validate(makeEntity({ /* condición que dispara X */ }), { profile: "a" });
  expect(res.warnings).toContainEqual(expect.objectContaining({ code: "x_mismatch" }));
  expect(res.entity.field).toBe(valorCorregido); // corrección determinista, no solo aviso
});

it("perfil B: NUNCA emite x_mismatch (la regla no aplica a este perfil)", () => {
  const res = validate(makeEntity(), { profile: "b" });
  expect(res.warnings.map((w) => w.code)).not.toContain("x_mismatch");
});
```

Si el validador bloquea con explicación (p. ej. un linter de contenido/compliance): el contrato del resultado es `{ ok: true } | { ok: false, violations: [{ rule, excerpt, explanation, suggestion }] }` — el test exige `excerpt`/`explanation`/`suggestion` no vacías cuando eso es requisito de producto, no cortesía. Exhaustividad exigida: **cada regla del catálogo tiene ≥1 caso que bloquea y ≥1 caso legítimo cercano que pasa** (el par positivo/negativo pegado a la frontera es lo que detecta regexes demasiado agresivas). Si el matcher normaliza mayúsculas/acentos, testea también esas variaciones.

> Lección aprendida (cambio de contrato): cuando un validador deja de poder invalidar (p. ej. un fallo duro que mataba el flujo con dinero ya gastado se convierte en decisión del usuario), los tests que assertaban `ok: false` prueban un contrato que ya no existe — actualízalos en la misma sesión que el contrato, o quedarán vigilando una puerta demolida.

## 6. Fórmulas y leyes

Cálculos deterministas de negocio (estimadores, combinatorias, prorrateos): mismo input = mismo output, y **el valor esperado del assert se calcula A MANO** desde los datos del fixture — si el test re-implementa la fórmula, no testea nada.

```ts
it("2 grupos × 3 opciones × 2 idiomas = 12 combinaciones con códigos únicos", () => {
  const plan = compose({ groups: 2, options: 3, languages: ["es", "en"] });
  expect(plan.items).toHaveLength(12);
  expect(new Set(plan.items.map((i) => i.code)).size).toBe(12);
});

it("el desglose suma el total", () => {
  const est = estimate(plan, makeRecipe());
  const sum = est.lineItems.reduce((s, li) => s + li.usd, 0);
  expect(est.totalUsd).toBeCloseTo(sum, 6); // el desglose ES el total: sin partidas fantasma
});
```

**Regla crítica (principio 9.f de SKILL.md): cuando la fórmula escala respecto a un ancla (`x / base`), NUNCA midas solo en `x = base`** — ahí el factor es 1 y una fórmula rota que preserve la identidad en el ancla pasa todos los asserts. Añade sondas lejos del ancla (p. ej. a 0.4× y 1.5×), donde una ley equivocada dé un número distinto. Y si la Verificación del planning solo mide en el ancla, la Verificación tiene el mismo agujero: repáralo en el planning, no lo herede el test.

## 7. Compiladores y serializadores

Cualquier módulo cuyo output textual va a un consumidor exigente (un modelo de pago, una API con formato estricto, un fichero con sintaxis propia) se testea con **golden files comparados carácter a carácter** (patrón §2), sobre 3+ combinaciones representativas de inputs:

```ts
it.each([
  ["caso-a-es", makeInput({ variant: "a" }), "es"],
  ["caso-b-en", makeInput({ variant: "b" }), "en"],
])("golden %s", async (name, input, language) => {
  const result = compile({ input, language });
  await expectGolden(result.output, new URL(`../../test/golden/${name}.txt`, import.meta.url));
});
```

Complementa los goldens con **asserts semánticos que sobreviven a regeneraciones**: el output contiene los fragmentos obligatorios (guards, cabeceras), y NO contiene ningún placeholder sin resolver (`{` huérfano). **Un slot irresoluble produce un error accionable**: testea que el error nombra la variable y su fuente, porque ese mensaje es lo que el operador verá.

Los casos frontera de troceo/particionado son lógica pura crítica: un input que excede un límite se parte en el plan, jamás revienta en runtime — testea el caso exactamente igual al límite (sin trocear), el que exige 2 trozos y el que exige 3, y que las partes suman el total.

## 8. Validadores de seeds en CI

> **Solo si tu proyecto versiona seeds en git** (datos que la BD solo materializa: catálogos, templates, configuraciones).

Su validador es una función pura, y sus tests unitarios son **el gate de CI**: el test más importante es el que valida el seed REAL del repo — así, romper un JSON en un PR rompe `pnpm test:unit` sin necesidad de BD ni seed job.

```ts
it("el seed real del repo valida — esto ES el gate de CI", () => {
  expect(validateSeed(loadSeed()).errors).toEqual([]);
});

it.each([
  ["referencia inexistente", (s) => { s.items[0].refs.push("nope"); }, "unknown_ref"],
  ["slugs duplicados", (s) => { s.items[1].slug = s.items[0].slug; }, "duplicate_slug"],
])("seed: %s", (_n, breakSeed, code) => {
  const seed = loadSeed();
  breakSeed(seed);
  expect(validateSeed(seed).errors.map((e) => e.code)).toContain(code);
});
```

Cada regla del validador tiene un código de error con caso propio, y el seed real en verde. Los mensajes de error se testean porque su consumidor es un humano leyendo el log de CI: deben nombrar el fichero, el slug y el campo. **Y recuerda el principio 9 de SKILL.md**: el test asserta sobre la salida del validador que producción ejecuta (`validateSeed(...)`), nunca sobre una reimplementación paralela de su lógica — un barrido propio del test que encuentra el error mientras el validador dice `ok: true` es un rojo en el sitio equivocado.

## 9. Criterio de exhaustividad

No todo el código merece el mismo rigor. La vara, de más a menos:

| Código | Exhaustividad | Por qué |
|---|---|---|
| Máquina de estados (si existe) | **Producto cartesiano completo** estados × eventos | Una transición ilegal aceptada corrompe estado; el espacio es pequeño y cerrado |
| Linters/guardas de compliance | Todas las reglas × (1 caso que bloquea + 1 legítimo frontera) | Falso negativo = riesgo real; falso positivo = fricción que invita a desactivarlo |
| Contratos Zod | 1 caso por regla de negocio del schema (+ divergencias del espejo si hay LLM) | El contrato es la frontera del sistema: lo que no rechace el schema entra al pipeline |
| Compiladores / serializadores | Goldens por combinación representativa + fronteras (troceo, slots) | Output textual de alta superficie: el golden detecta cualquier cambio; las fronteras son donde revienta |
| Estimadores / combinatorias | Aritmética verificable a mano + sondas lejos del ancla | Números que el usuario aprueba: deben cuadrar, y la ley debe medirse donde no es trivial |
| Utilidades corrientes | Casos representativos + bordes obvios (vacío, uno, muchos) | Rigor proporcional al blast radius |

Regla final: si al escribir un test de esta capa necesitas un mock, para y pregúntate qué I/O se ha colado en la lógica pura — la respuesta correcta casi siempre es mover el I/O fuera, no añadir el mock.
