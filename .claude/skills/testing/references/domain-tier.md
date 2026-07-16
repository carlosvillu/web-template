# Tier de testing específico de dominio

> **Solo aplica si tu dominio lo necesita.** La mayoría de proyectos web viven con unit + integración + E2E + live. Este reference existe para cuando tu producto tiene una capa que **exige binarios o un entorno de ejecución propio** que la suite estándar no puede (ni debe) asumir: composición de vídeo/audio con FFmpeg, generación de PDFs con un motor nativo, procesamiento geoespacial con GDAL, renderizado de imágenes con sharp/ImageMagick, OCR… Aquí se explica CÓMO montar ese tier; los ejemplos usan media/FFmpeg como ilustración, pero el patrón es el mismo para cualquier binario.

## Cuándo crear un tier de dominio (y cuándo no)

Créalo cuando se cumplan las tres:

1. El código bajo test **invoca binarios reales** cuyo comportamiento no se puede mockear con honestidad (un filtergraph de FFmpeg, un render de PDF: mockear el binario es testear el mock — misma lógica que la regla "Postgres real" de db-integration.md).
2. Esos binarios **no están garantizados en la máquina de dev ni en el runner genérico** (o su versión importa: un libass distinto rasteriza distinto).
3. La suite es **lenta o pesada** comparada con unit/integración (encodes de segundos, no milisegundos).

NO lo crees si la lógica es separable: casi siempre puedes partir el módulo en **lógica pura** (construir el comando/filtergraph/spec → unit con golden files, ver unit-core.md §7) y una **capa fina de ejecución** (la que sí necesita el binario). Solo la segunda va al tier de dominio; el tier queda pequeño y la iteración diaria sigue siendo rápida. Ejemplo media: el generador de subtítulos `.ass` (timestamps → texto) es lógica pura co-locada en `src/**/*.test.ts`; solo el burn-in real con libass pertenece al tier.

## Anatomía del tier

### 1. Proyecto Vitest transversal, opt-in por env

En el `vitest.config.ts` raíz (stack-setup.md §3.1), inline y **vacío salvo opt-in** — así `vitest run` a secas nunca lo arrastra:

```ts
{
  test: {
    name: 'worker:media',                  // convención: <app>:<dominio>
    root: './apps/worker',
    include: process.env.RUN_MEDIA ? ['test/media/**/*.test.ts'] : [],
    setupFiles: ['@app/test-utils/setup-env'],
    testTimeout: 120_000,                  // los binarios tardan; en CI compartido más
  },
},
```

Script raíz: `"test:media": "RUN_MEDIA=1 vitest run --project 'worker:media'"`. **No forma parte de `pnpm test`**: la suite estándar debe seguir siendo rápida y ejecutable en cualquier máquina.

### 2. Entorno canónico: la imagen real de producción

El tier corre **dentro de la imagen Docker que irá a producción** (la del worker, la del servicio que use los binarios) — así el test verifica *la misma imagen* que se despliega, que es el punto. Ejecución canónica local: `docker compose -f docker-compose.dev.yml run --rm worker pnpm test:media`. En CI, un job dedicado que construye la imagen real y corre la suite dentro (ver ci.md §4) — nunca un binario de `apt-get` del runner, cuya versión puede divergir y desincronizar los goldens.

### 3. Skip explícito y ruidoso, nunca silencioso

En una máquina sin las herramientas, la suite se salta **avisando**. El porqué: un skip silencioso convierte "todo verde" en mentira; el agente que ve el output debe saber que la capa NO se ha verificado y cómo ejecutarla.

```ts
// apps/worker/test/media/setup.ts — importado por cada suite del tier
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
const run = promisify(execFile);

async function available(bin: string, args = ['-version']) {
  try { await run(bin, args); return true; } catch { return false; }
}

export const toolsAvailable = (await available('ffmpeg')) && (await available('ffprobe'));

if (!toolsAvailable) {
  // En CI el skip es un error: el job del tier DEBE tener las herramientas.
  if (process.env.CI || process.env.REQUIRE_MEDIA) {
    throw new Error('test:media requiere ffmpeg/ffprobe — este job debe correr en la imagen del worker');
  }
  console.warn(
    '\n[test:media] SKIP — faltan ffmpeg/ffprobe en esta máquina.\n' +
    'Ejecuta: docker compose -f docker-compose.dev.yml run --rm worker pnpm test:media\n',
  );
}
```

```ts
// patrón en cada suite: el skip queda visible en el reporter como "skipped", no desaparece
import { describe } from 'vitest';
import { toolsAvailable } from '../setup';

describe.skipIf(!toolsAvailable)('normalización', () => { /* … */ });
```

### 4. Healthcheck de capacidades como primera suite

La primera suite del tier verifica que el entorno tiene las capacidades exactas (filtros compilados, fuentes instaladas, versiones): si la imagen no las tiene, mejor un fallo claro aquí que veinte fallos crípticos después. Esos mismos checks son el `HEALTHCHECK` del Dockerfile — test e imagen comparten el contrato de capacidades.

## Principios de test dentro del tier

**Assets sintéticos generados en el propio test — prohibido commitear fixtures binarios.** Cada test genera sus inputs con las herramientas del propio tier (en media: fuentes `lavfi` de FFmpeg, clips de 2–3 s; en PDFs: un HTML mínimo; en geo: geometrías construidas en código). Por qué: son deterministas, se generan en <1 s, no pesan en git, y documentan en el propio test qué propiedades tiene el input. Un binario commiteado es opaco, engorda el repo para siempre y nadie sabe qué garantiza. Los helpers de generación viven en `@app/test-utils` (p. ej. `makeTestVideo({ width, height, color })`, `makeTestAudio({ freq, delaySeconds })` — un delay conocido da onsets EXACTOS para tests de sincronía).

**Asserts por propiedades medibles, nunca "el fichero existe y pesa >0".** Toda salida se valida con la herramienta de inspección del dominio (en media: `ffprobe -print_format json` → un helper `assertVideoProfile()` que fija resolución/fps/códec/pixel format; en PDFs: parsear el PDF y assertar páginas/texto). El contrato de salida del PRD es exacto: cada propiedad se asserta. **Tolerancia solo donde el dominio la impone** (la duración de un encode alinea a GOP → ±0,2 s; un loudness single-pass no clava el target → ±1 unidad): exigir igualdad exacta ahí produce flakes sin valor, y todo lo demás va exacto y sin tolerancia.

**Mide el efecto donde es observable, no donde es cómodo.** Ejemplo media (ducking de audio): en el mix final la voz se suma al bed y el RMS total *sube* — no sirve medir el mix; se renderiza solo la rama afectada del filtergraph (usando **el mismo builder que producción**) y se compara el RMS en una ventana sin voz vs con voz. Es el principio 9 de SKILL.md aplicado al dominio: si mides en un punto donde el bug no altera la medida, no estás midiendo.

**Cachés e invocaciones se cuentan, no se "ven en logs".** Si el módulo cachea trabajo caro (normalizados, renders), diseña el runner de comandos como dependencia inyectable y cuenta: segunda pasada sobre los mismos inputs = 0 invocaciones nuevas. Añade el assert de que la cache key cambia cuando cambian los parámetros — es lo que evita envenenar la caché en evoluciones futuras.

**El validador de calidad se testea también en negativo.** Si el tier incluye un QA validator (checks de perfil, de zona segura, de loudness), dale un output defectuoso a propósito y asserta que el check correspondiente sale `fail`. Un QA que nunca falla no verifica nada (control negativo, SKILL.md principio 9).

**Golden files solo de texto.** Para outputs de texto deterministas del tier (specs compiladas, reports JSON, ficheros de subtítulos): golden files normalizando lo volátil (paths temporales, timestamps). **Nunca golden de binarios** (mp4/png/pdf): se invalidan con cada versión de la herramienta y no explican qué cambió — para binarios, asserts de propiedades.

**Outputs a directorio temporal por suite** (`fs.mkdtemp` sobre `os.tmpdir()`), limpiado en `afterAll`. Nunca escribas outputs de test dentro del repo ni en los volúmenes de datos de la app.

## Qué NO cubre un tier de dominio

- **Calidad subjetiva** (estética, legibilidad real, "suena bien"): revisión humana de la tarea + gate CUA con evidencia en `docs/verifications/<TASK-ID>/`.
- **Artefactos reales de APIs de pago**: el tier usa sintéticos; el pipeline con material generado de verdad se verifica en las verificaciones de tarea y en el tier live (external-apis.md).
- **La orquestación del job** (colas, transiciones de estado): eso es integración con Postgres — ver worker-jobs.md.

## Checklist para estrenar el tier

- [ ] Proyecto Vitest inline opt-in por env + script raíz `test:<dominio>` (stack-setup.md §6).
- [ ] Setup con detección de binarios: skip ruidoso local, error en CI.
- [ ] Suite de healthcheck de capacidades = `HEALTHCHECK` del Dockerfile.
- [ ] Helpers de generación sintética y de aserción por propiedades en `@app/test-utils`.
- [ ] Job de CI propio sobre la imagen real, añadido a `needs` de `ci-ok` en el mismo PR (ci.md §7).
- [ ] Fila nueva en la tabla de suites de SKILL.md y en la tabla de decisión.
