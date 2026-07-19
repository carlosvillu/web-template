---
name: testing
description: Estrategia de testing unificada de {{PROJECT_NAME}} — todas las capas (packages/core, packages/db, apps/web, apps/worker si existe, API+BD, E2E, APIs externas de pago) y el gate CUA de cierre de tarea. Usar SIEMPRE que se escriba o modifique código del proyecto, se añadan tests, se configure Vitest/Playwright/Testcontainers/msw/CI, se vaya a marcar una tarea de planning.md como completada, se ejecute una verificación de tarea (CUA con agent-browser o script), o se toque cualquier cosa relacionada con test, spec, coverage, mock, fixture, golden file o pipeline de CI. También cuando el usuario pida "verifica", "testea", "comprueba que funciona" o cierre de tarea.
---

# Estrategia de testing — {{PROJECT_NAME}}

Esta skill define CÓMO se testea todo el proyecto. Es la fuente de verdad única: si un test nuevo no encaja en lo que describe este documento y sus references, o el test está mal planteado o esta skill necesita una actualización deliberada (nunca las dos cosas en silencio).

> **Módulos opcionales de F0**: el stack base es fijo (pnpm workspaces + Next.js App Router + `packages/core` con Zod + Postgres/Drizzle + Vitest/Playwright), pero módulos como worker, pg-boss, storage, auth, SSE o spend ledger solo existen si el `planning.md` de TU proyecto los incluyó en F0. Las secciones marcadas "**solo si el módulo existe**" se ignoran si tu F0 no lo trae — no montes harness para superficie que no existe.

## Principios

1. **La "Verificación" del planning es la vara.** Cada tarea de `planning.md` termina con una verificación observable en el mundo real. Los tests automatizados existen para que esa verificación no regresione después; el gate CUA/script existe para ejecutarla de verdad la primera vez. "El código compila" o "los tests unitarios pasan" NUNCA cierran una tarea por sí solos.
2. **Los tests nacen con el código, en la misma tarea.** No hay fase de "añadir tests después". Una subtarea sin sus tests está a medias, y el planning prohíbe dejar el sistema a medias.
3. **Postgres real para todo lo transaccional.** Todo lo que dependa de comportamiento de Postgres (`FOR UPDATE`, `NOTIFY`, constraints, enums, JSONB, transacciones) no se puede mockear con fidelidad. Integración = Testcontainers, siempre. Mockear la BD para testear código transaccional es testear el mock.
4. **La suite nunca gasta dinero.** `pnpm test` corre offline: APIs externas de pago mockeadas con msw + fixtures grabados de respuestas reales. Las llamadas reales viven solo en `pnpm test:live` (opt-in, presupuestado) y en las verificaciones de tarea.
5. **Evidencia o no ocurrió.** Toda verificación de cierre de tarea deja rastro en `docs/verifications/<TASK-ID>/` (report.md + screenshots/outputs). Marcar `[x]` en planning.md sin carpeta de evidencia es un error de proceso.
6. **Forma de trofeo, no pirámide clásica.** El grueso del valor está en integración (lógica transaccional + API contra BD real) y en los E2E/CUA que prueban el sistema como bloque. Unit se reserva para lógica pura con sustancia (contratos, validadores, transformaciones deterministas). No se escriben unit tests de pegamento trivial para inflar cobertura.
7. **Determinismo antes que reintentos.** Un test flaky se arregla o se borra, no se reintenta hasta que pase. Nada de `sleep`/`waitForTimeout` fijos: polling con timeout explícito, esperas por condición observable.
8. **CUA acepta; Playwright conserva.** Toda tarea que añada o modifique comportamiento operable en navegador declara en `planning.md` su `Playwright permanente` (fichero + comportamientos) y lo entrega en la misma tarea. La sesión CUA demuestra que la feature funciona en el mundo real al cerrarla, pero no sustituye el spec determinista que debe detectar regresiones futuras.
9. **EL ARNÉS NUNCA PUEDE SER MÁS CÓMODO QUE LA REALIDAD.** Es el anti-patrón más caro que existe en desarrollo autónomo: la suite verde mientras la funcionalidad está rota. Las ocho formas que adopta (todas observadas en proyectos reales; ninguna teórica):
   - **Un doble emite lo que le conviene al test, no lo que emite el productor REAL.** Lección aprendida: un fixture traía un valor ya formateado (`"34,90 €"`) cuando el proveedor real emitía el número crudo (`"34.9"`); un cross-check por comparación de strings corrompía el dato en todos los casos reales — con toda la suite en verde. Otra: un fake de un LLM devolvía contenido SIEMPRE, incluso cuando el input no lo justificaba, y el warning que la UI debía mostrar era inobservable. Antes de escribir un doble, **ve a leer qué emite el productor real**.
   - **El arnés FIJA A MANO lo que producción DERIVA.** Lección aprendida: el stack de E2E ponía por env exactamente la variable cuyo cálculo estaba roto en producción — el test que debía cazar el bug era el que lo tapaba, durante fases enteras. Otra: un `Request` construido a mano no lleva `content-length` (lo pone la capa de fetch al enviar), así que un test de límite de tamaño solo ejercitaba la rama que ningún cliente real usa.
   - **Se mide el componente AISLADO de la condición en la que vive.** Lección aprendida: unos colores se calibraron contra una superficie idealizada (blanco puro) con margen cero — pasaban en el laboratorio y fallaban el contraste WCAG sobre las superficies reales donde se pintaban.
   - **EL TEST HACE EL CHEQUEO POR SU CUENTA, en vez de pedírselo al código que corre en producción.** Es la forma más traicionera: el test es correcto, pasa, y vigila una puerta por la que el dato no entra. Lección aprendida: un test barría un conjunto de datos con su propia función de búsqueda de errores, mientras el validador — el único código que producción ejecuta antes de escribir en la BD — solo miraba un subconjunto; los datos malos entraban con `ok: true`. *La regla: **un test que reimplementa la comprobación no prueba que la comprobación exista**; asserta sobre la SALIDA de la función que corre en producción, no sobre una reimplementación de su lógica.* Si te descubres reescribiendo en el test lo que el código ya hace, pregúntate por qué no se lo estás preguntando a él.
   - **EL RUNTIME DEL TEST ES MÁS PERMISIVO QUE EL DE PRODUCCIÓN.** No miente ningún doble ni mira mal ningún assert: el test se ejecuta en un sitio donde el código funciona, y producción lo ejecuta en uno donde no. Lección aprendida: un barrel de `packages/core` re-exportaba código con un binario nativo y un módulo de CLIENTE lo importaba; el bundler intentaba resolver módulos de Node para el navegador y la app entera dejaba de compilar — con más de mil tests en VERDE, porque `pnpm test` corre en Node y en Node ese import funciona. El único test que compila la app de verdad para un navegador es el E2E, y fue el único que lo vio. La regla: **cuando el código va a correr en dos runtimes (Node y bundler; servidor y navegador; local y VPS), un test que solo ejercita el cómodo no prueba el otro** — y no basta con "acordarse": hazlo comprobable con un guard estructural en el gate (p. ej. un test que recorre el grafo de imports desde los ficheros `'use client'` y falla si alcanza código server-only). *(Sub-lección: el guard nació mirando solo `import` y no `export … from` — pero un barrel re-exporta, que era EL mecanismo del bug; al reinyectar el bug para el control negativo, el guard siguió verde. Un guard que no se pone rojo cuando el bug vuelve no es un guard: es decoración.)*
   - **EL CASO DE PRUEBA CAE JUSTO DONDE EL BUG SE ESCONDE (el punto fijo).** El test es correcto, mide lo que dice medir, ejercita el camino real… y aun así no puede fallar, porque el punto elegido es uno donde la fórmula rota y la correcta dan el mismo resultado. Lección aprendida: un estimador escalaba un coste con un factor `(x / ancla)` y la verificación medía exactamente en `x = ancla`, donde el factor es 1 — el verificador saboteó el escalado a `(x/ancla)²` (que preserva la identidad en el ancla) y decenas de comprobaciones, incluida una cuenta a mano, se quedaron en VERDE. **La regla: cuando lo que pruebas es una LEY (una fórmula, un escalado, una proporción), un solo punto nunca basta — y menos si es el punto donde la ley es trivial. Elige al menos uno lejos del ancla, donde una ley equivocada dé un número distinto.** Ojo: esto se aplica también a las **Verificaciones del `planning.md`**, no solo a los tests.
   - **EL TEST DICE CONSERVAR UNA CLÁUSULA, PERO LA EJERCITA EN OTRA CAPA.** La regla del planning manda convertir en test permanente toda cláusula determinista de una Verificación. El fallo está en el «cómo»: si la Verificación dice *«`curl` contra el servidor levantado devuelve X»* y el test permanente llama al handler **en proceso**, no conserva la cláusula — conserva otra cosa, y encima **declara por escrito que la conserva**, que es lo que apaga la alarma de todos. Lección aprendida: un test se presentaba como «la conservación permanente de esta cláusula»; llamaba al handler en proceso bajo `NODE_ENV=test`, donde la rama de configuración del logger propia de desarrollo nunca se construye. Una dependencia de esa rama no estaba declarada ⇒ **HTTP 500 en TODA ruta bajo el dev server**, con la suite en VERDE y el test que decía protegerlo también en verde (producción funcionaba: el fallo era dev-only, y dev era justo la capa que la cláusula nombraba). *La regla: **el test permanente tiene que ejercitar la MISMA capa que la Verificación** (HTTP contra el server levantado si la cláusula habla de HTTP; el bundler si habla del bundler). Si no puedes ejercitar esa capa en el gate, dilo en la tarea y deja la cláusula como one-shot del verifier — pero **no escribas un test que afirme conservar lo que no conserva**: cobertura falsa es peor que ninguna.* Corolario: **una rama de config que ningún test instancia no existe hasta que un usuario la pisa** — si `NODE_ENV`/env selecciona ramas, algún test tiene que construir cada rama de verdad.
   - **EL ASSERT NEGATIVO QUE NO PUEDE CASAR (el centinela fantasma).** Un `not.toContain(X)` solo prueba algo si `X` PODRÍA aparecer por el canal que se observa; si no puede, el assert pasa siempre — con la fuga delante. Tres mecanismos observados, todos con la suite en verde: (1) **el literal no sobrevive a las transformaciones del canal** — un assert de privacidad buscaba un segmento entero de un dato que el código trunca a N chars antes de persistir, así que el segmento completo no casa nunca (hay que asertar prefijos que sobrevivan al truncado); y un literal con comillas (`"campo"`) jamás casa contra HTML renderizado, donde es `&quot;campo&quot;`. (2) **el canal observado está VACÍO** — una captura de logs que capturaba 0 líneas hacía pasar vacuamente todo `not.toContain`; el guard es un assert POSITIVO de que el canal lleva datos. (3) **se asserta la propiedad cómoda y no la peligrosa** — unos tests de paginación asertaban ausencia de SOLAPE entre páginas pero nunca ausencia de HUECO, y el hueco era el bug. Además, si el dato puede mutar antes de persistirse (p. ej. se DECODIFICA), el grep debe cubrir también las formas derivadas — un grep del codificado no ve el decodificado que sí se guardó. *La regla: **todo assert negativo de ausencia (privacidad, secretos, fuga de datos) exige en la misma pasada (a) un control positivo que pruebe que el canal observado lleva datos y el patrón apunta bien, y (b) un control negativo EJECUTADO: reinyecta la fuga y comprueba que el assert se pone ROJO.** Un assert de ausencia sin las dos patas es decoración.*

   **Las ocho preguntas, antes de dar por bueno un test:** (a) *¿Este doble emite lo que emite el productor real?* → **ve a leer el productor**, no lo supongas. (b) *¿El arnés está fijando algo que en producción se calcula?* → si sí, el test no prueba el cálculo. (c) *¿Estoy midiendo en el entorno real o en uno idealizado?* (d) *¿Estoy ejerciendo el camino que recorre el dato de verdad, o uno paralelo que he construido en el test?* (e) *¿El test corre en el MISMO runtime que producción?* → si el código viaja a un navegador, un bundler o una VPS, Node en tu portátil no es ese sitio. (f) *Si lo que pruebo es una LEY, ¿la estoy midiendo en un punto donde una ley equivocada daría lo mismo?* → entonces no la estás midiendo. (g) *Si este test dice conservar una cláusula de una Verificación, ¿la ejercita en la MISMA capa que ella?* → si la cláusula habla de HTTP y el test llama al handler en proceso, no la conserva; y si hay ramas que dependen de env (`NODE_ENV`), ¿las instancia alguien de verdad? (h) *Si el assert es NEGATIVO (ausencia de X), ¿puede X aparecer por este canal?* → comprueba que el literal sobrevive a truncados/escapes/decodificaciones del camino real, y que el canal no está vacío — con un control positivo en la misma pasada.
   Y la prueba de fuego, que es barata y no es opcional en un fix de bug **ni en ningún assert negativo de privacidad/seguridad**: **CONTROL NEGATIVO — reintroduce el bug (o la fuga) y comprueba que el test se pone ROJO.** Un test que no has visto fallar no sabes si muerde. **Y mira QUÉ se pone rojo**: si el rojo aparece en un test paralelo mientras el validador de producción sigue diciendo `ok: true`, el rojo está en el sitio equivocado — solo mirarlo lo revela. *(No existe un mecanismo de código único que cace estas formas: viven en capas distintas y cada guard puntual es frágil por su cuenta. La defensa es este principio, aplicado por el `implementer` al escribir y por los pases de review y el `verifier` al cerrar.)*

## Las suites

| Suite | Comando | Qué cubre | Dónde corre |
|---|---|---|---|
| Unit | `pnpm test:unit` | Lógica pura: contratos Zod, validadores, transformaciones deterministas, golden files | Local + CI (cada push) |
| Integración | `pnpm test:integration` | Migraciones, repos, API routes, lógica transaccional (y pg-boss/worker si existen) contra Postgres real (Testcontainers) | Local + CI (cada push) |
| E2E | `pnpm test:e2e` | Playwright: flujos de navegador completos con app levantada y APIs externas mockeadas | Local + CI (cada push) |
| Live | `pnpm test:live` | Clientes de APIs de pago contra APIs reales, con guard de presupuesto (`LIVE_BUDGET_USD`) — **solo si tu proyecto consume APIs de pago** | Solo local, opt-in explícito |
| Dominio | `pnpm test:<dominio>` | Tier específico del dominio con binarios/entorno propio (p. ej. media/FFmpeg) — **solo si tu dominio lo necesita**, ver `references/domain-tier.md` | Según su entorno + CI (job propio) |
| CUA | (flujo agéntico, no runner) | Verificación de cierre de tarea con `agent-browser` reproduciendo el flujo humano | Solo local, al cerrar cada tarea |

`pnpm test` = unit + integración, y es parte de `pnpm gate` (lint && typecheck && format:check && knip && readme:status:check && test) — el gate mínimo antes de cualquier commit. `pnpm test:e2e` se ejecuta además cuando la tarea tocó superficie web.

## Tabla de decisión: ¿qué tests escribo?

Localiza lo que estás construyendo y lee el reference indicado ANTES de escribir los tests:

| Vas a escribir… | Tests que exige | Reference |
|---|---|---|
| Setup inicial de testing (primeras tareas de F0), nuevo paquete, scripts pnpm | Bootstrap de configs y `@app/test-utils` | `references/stack-setup.md` |
| Contratos Zod, lógica pura de `packages/core`, validadores, parsers, transformadores deterministas | Unit table-driven + fixtures válidos/inválidos + golden files | `references/unit-core.md` |
| Schema Drizzle, migraciones, repos, índices, constraints | Integración con Testcontainers (template database) | `references/db-integration.md` |
| Worker, colas pg-boss, máquinas de estado transaccionales, timeouts, idempotencia *(solo si el módulo worker/colas existe)* | Integración exhaustiva contra Postgres real + concurrencia | `references/worker-jobs.md` |
| API routes de Next (CRUD, mutaciones, webhooks; SSE/auth/downloads si esos módulos existen) | Handler-level contra BD real; server-level para SSE/auth/streaming | `references/api.md` |
| Componentes React, hooks, formularios, editores | Testing Library + jsdom si hay lógica; además el spec Playwright permanente declarado por la tarea para el comportamiento operable | `references/frontend.md` + `references/e2e.md` |
| Un flujo de usuario completo, el E2E de una fase | Playwright spec con seeds, auth fixture y esperas por condición observable | `references/e2e.md` |
| Cliente de cualquier API externa (LLM, scraping, pagos, terceros), o cerrar una deuda `[verificar]` | Mocks msw + fixtures grabados; live test presupuestado si aplica | `references/external-apis.md` |
| Lógica que exige binarios o entorno propio (media, PDFs, geoespacial…) *(solo si tu dominio lo necesita)* | Tier de dominio con assets sintéticos + asserts por propiedades | `references/domain-tier.md` |
| Workflow de CI, un job nuevo, caching | GitHub Actions según el layout definido | `references/ci.md` |
| Cerrar una tarea del planning | Gate CUA (si hay UI) o script observable + evidencia | `references/cua.md` |

Si el código toca varias filas (lo normal: un endpoint nuevo = contrato + repo + handler + quizá UI), aplica cada fila a su parte. La pregunta correcta nunca es "¿qué test escribo?" sino "¿en qué capas tiene comportamiento esta pieza?".

## Definition of Done de una tarea del planning

Una tarea se marca `[x]` solo cuando TODO esto es cierto:

1. Subtareas implementadas y `pnpm gate` en verde (incluyendo los tests nuevos de la tarea).
2. Los tests nuevos cubren la "Entrega" de la tarea: cada comportamiento prometido tiene al menos un test que fallaría si se rompiera.
3. Si la tarea tocó superficie web, su línea `Playwright permanente` de `planning.md` está satisfecha: el fichero existe, cada comportamiento nombrado tiene un assert que fallaría al romperse y `pnpm test:e2e` queda en verde. Un CUA PASS sin este spec es FAIL de DoD.
4. **La "Verificación" literal del planning ejecutada de verdad**:
   - Con superficie UI → sesión CUA con `agent-browser` siguiendo `references/cua.md`.
   - Solo backend → script/curl observable contra el sistema levantado (compose + pnpm dev), no contra mocks.
5. Evidencia persistida en `docs/verifications/<TASK-ID>/` (report.md con plantilla de `references/cua.md` + capturas/outputs; coste real anotado si hubo APIs de pago).
6. Si la tarea cerraba una deuda `[verificar]`, el resultado está anotado en PRD.md y planning.md.
7. Sin regresión del E2E de la fase anterior.
8. `planning.md` actualizado: `[x]` + fecha + resultado (+ coste real si aplica).

Un fallo en el paso 4 significa que la tarea NO está completa, aunque toda la suite esté en verde: arregla y repite la verificación.

### Rojos FANTASMA del gate (antes de depurar tu código, descarta estos)

Dos fallos conocidos del stack que **no son de tu código**. Si el gate o el E2E se ponen rojos de forma inexplicable, comprueba PRIMERO:

1. **¿Tienes un `pnpm dev` vivo?** → **mátalo y repite.** Los tests server-level que arrancan su propio `next dev`/`next start` chocan con un dev server ya escuchando (*«Another next dev server is already running»*) y el gate falla con todos los tests en verde. El gate NO es hermético frente a un dev server en marcha — y una sesión CUA, por definición, tiene la app levantada.
2. **¿`pnpm test:e2e` sale con código ≠0 pero reporta TODOS los tests verdes?** (o falla con `routes.d.ts`, o «next dev murió durante el arranque») → **basura de `.next`**: `rm -rf apps/web/.next` y repite el ciclo COMPLETO.

Ninguno de los dos se arregla reintentando a ciegas ni relajando un test. Y si el rojo NO es uno de estos, es tuyo: no lo trates como flake (regla de oro del dev-loop).

## Convenciones núcleo (el detalle vive en los references)

- **Ubicación**: unit co-locados `src/**/*.test.ts` · integración `test/integration/**/*.test.ts` por paquete · E2E `apps/web/e2e/**/*.spec.ts` · live `**/*.live.test.ts` · tier de dominio en su carpeta propia (p. ej. `apps/worker/test/<dominio>/`).
- **Contrato con planning**: cada tarea web nombra el spec exacto que crea o amplía y los comportamientos que quedan protegidos. Reusar un spec es válido cuando amplía el mismo flujo; una línea genérica como "añadir E2E" no lo es.
- **Utilidades compartidas**: todo helper de test reutilizable vive en `packages/test-utils` (`@app/test-utils`) — `startPostgresContainer()`, `createTestDatabase()`, factories de dominio (`makeX()`/`insertX()`), `seedFixtures()`. No dupliques harness por paquete. (El scope `@app/*` lo fija la skill `bootstrap` al crear el proyecto.)
- **Factories, no fixtures de BD gigantes**: los datos de test se construyen con factories con defaults sensatos y overrides explícitos de lo que importa al caso.
- **Golden files**: en `test/golden/` junto a su suite; se regeneran solo con `UPDATE_GOLDEN=1` y el diff se revisa a mano antes de commitear.
- **Fixtures HTTP grabados**: `packages/test-utils/fixtures/http/<provider>/…`, sanitizados de secretos, regrabados al detectar drift.
- **Nombres de test**: describen el comportamiento y el porqué de fallar (`"rechaza transición running→pending sin tocar la BD"`), no el nombre del método.
- **CI**: `pnpm gate` desglosado en jobs (lint+typecheck, unit, integración, E2E) es gate de merge. CUA y live NUNCA corren en CI.

## References

| Archivo | Léelo cuando… |
|---|---|
| `references/stack-setup.md` | Montes o toques la infraestructura de testing, crees un paquete, añadas scripts |
| `references/unit-core.md` | Escribas unit tests de lógica pura, contratos, golden files, validadores |
| `references/db-integration.md` | Toques schema/migraciones/repos o necesites el harness de Testcontainers |
| `references/worker-jobs.md` | Toques el worker, pg-boss, máquinas de estado o timeouts *(solo si el módulo existe)* |
| `references/api.md` | Escribas o modifiques API routes, SSE, webhooks, auth |
| `references/frontend.md` | Escribas componentes/hooks de apps/web |
| `references/e2e.md` | Escribas specs de Playwright o el E2E de una fase |
| `references/cua.md` | Vayas a cerrar CUALQUIER tarea del planning (gate obligatorio) |
| `references/external-apis.md` | Toques un cliente de API externa o una deuda `[verificar]` |
| `references/domain-tier.md` | Tu dominio necesite un tier de testing con binarios/entorno propio *(solo si aplica)* |
| `references/ci.md` | Toques `.github/workflows/` o decidas qué corre dónde |
