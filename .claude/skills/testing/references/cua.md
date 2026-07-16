# El gate CUA — verificación agéntica de cierre de tarea

**Regla del proyecto**: ninguna tarea del `planning.md` se marca `[x]` sin haber ejecutado su campo **"Verificación"** contra el sistema real levantado, y sin haber persistido la evidencia en `docs/verifications/<TASK-ID>/`. Esto es un *gate*, no una sugerencia: es la materialización de la filosofía baby-steps del planning ("no 'el código compila', sino 'hago X y veo Y'") y de la regla de trabajo "verificación ejecutada y anotada".

CUA = *Computer-Using Agent*: un agente (tú, normalmente el agente `verifier`) que opera la aplicación **como lo haría un humano**, con el CLI `agent-browser` (Vercel Labs), reproduciendo el flujo descrito en la Verificación de la tarea y comprobando lo **observable** — el elemento de la UI cambia de estado, la cifra aparece en la página, el download llega con el checksum correcto.

## Por qué existe este gate

- Los tests (unit, integración, E2E) demuestran que el código hace lo que sus tests dicen. El gate CUA demuestra que **el sistema entero** (docker compose + web + worker + Postgres + SSE atravesando el stack real) hace lo que la tarea prometía. Son fallos de categorías distintas: una función perfecta en Vitest puede convivir con una UI que nunca se actualiza porque el reverse proxy bufferiza el SSE.
- La Verificación de cada tarea del planning ya está redactada en términos observables. El gate solo obliga a **ejecutarla de verdad y dejar prueba**, para que un `[x]` en el planning sea un hecho auditable y no una intención.
- El lector futuro (humano o agente) de `docs/verifications/` puede reconstruir qué funcionaba, cuándo y a qué coste — imprescindible si las verificaciones gastan dinero real (coste real anotado; si difiere >25 % del estimado, se recalibra en la misma tarea).

## CUA vs E2E Playwright — se complementan, no se sustituyen

| | E2E Playwright (`apps/web/e2e/**/*.spec.ts`) | Gate CUA (agent-browser) |
|---|---|---|
| Naturaleza | Código repetible, corre en CI en cada push | Verificación agéntica **exploratoria**, una vez por cierre de tarea |
| Qué protege | Regresiones de flujos ya conquistados | Que la tarea recién terminada funciona en el mundo real |
| Entorno | Servidor de test, datos controlados por la suite | Sistema completo levantado como en desarrollo/producción, APIs reales si la Verificación lo pide |
| Juicio | Asserts programados de antemano | Criterio del agente: mira la pantalla, lee consola/errores, evalúa "¿esto es lo que la Verificación describe?" |
| Fallo | Rompe el build | La tarea **no está hecha** |

Regla práctica: cuando un flujo se verifica por CUA y va a repetirse (los E2E de fase son candidatos obvios), destila después un spec de Playwright que congele lo esencial. El CUA descubre; el E2E vigila. Ver `e2e.md`.

## El flujo completo, paso a paso

### Paso 0 — Decide la superficie: ¿UI, solo backend u otro cliente?

Lee la Verificación de la tarea en `planning.md`:

- **Tiene superficie UI** (menciona "en el navegador", "la página", "el panel", "click", "ver en vivo"...): gate CUA con agent-browser.
- **Solo backend** (menciona `curl`, `psql`, scripts, logs): no fuerces un navegador donde no aporta. Ejecuta el script/curl **contra el sistema levantado** (nunca contra mocks) y captura la salida como evidencia. **El report en `docs/verifications/` se escribe igual** — el gate es la evidencia, no el navegador.
- **Superficie no-navegador** (una tool MCP, un CLI, un endpoint para agentes): la verificación se hace desde el **cliente real** de esa superficie (p. ej. la tool se invoca desde Claude Code de verdad, no desde un harness que simule el protocolo) y el efecto se observa donde la Verificación lo describa. La evidencia se captura igual.

Muchas tareas mezclan superficies (navegador + terminal; o su objetivo es el VPS — ver la subsección del Paso 1): cubre cada punto con la herramienta que la Verificación describe.

### Paso 1 — Levanta el sistema completo

El CUA verifica el sistema real, así que el sistema real tiene que estar entero:

```bash
docker compose -f docker-compose.dev.yml up -d   # Postgres 16 (+ lo que la fase añada)
pnpm db:migrate
pnpm seed                                        # seeds que la tarea necesite
pnpm dev                                         # web (+ worker si existe), en otra terminal o en background
curl -s localhost:3000/api/health                # gate de arranque: {ok:true, db:true}
```

Por qué: un CUA contra un sistema a medias produce falsos FAIL (worker caído = trabajos eternamente `queued`) o, peor, falsos PASS (verificar contra un `pnpm dev` de hace 3 días que no incluye tu cambio). Antes de empezar, confirma que el código que corre es el que verificas (`git status` limpio o anota el diff en el report).

**Preparar datos por API/seed está permitido y es recomendable** — solo el flujo bajo verificación debe ser humano (ver Reglas de oro). Ej.: para verificar el paso 3 de un flujo puedes preparar los pasos 1 y 2 por API si ya fueron verificados en sus tareas; lo que no puedes es ejecutar el paso 3 por API.

#### Verificaciones cuyo objetivo es el VPS (deploy, webhooks reales, backup/restore)

Algunas Verificaciones no se ejecutan contra el stack local: su objetivo **es el VPS**, y montar compose + `pnpm dev` en tu máquina produciría evidencia que no verifica lo que la tarea pide. El equivalente del Paso 1 para estas tareas:

- **Despliega el commit exacto que verificas** y anota el sha desplegado en el report (campo "Sistema"): un PASS contra un deploy de hace tres días vale tan poco como uno contra un `pnpm dev` viejo.
- **Evidencia remota por ssh**: los outputs de comandos en el VPS se capturan con `ssh <vps> '<comando>' | tee docs/verifications/<TASK-ID>/<output>.txt` — la evidencia se persiste en tu repo, no se queda en la sesión remota.
- **Curl/navegador desde fuera del VPS**: comprobar `https://<dominio>` (certificado incluido) y que el SSE atraviesa el reverse proxy se verifica desde tu máquina u otra red, no desde localhost del VPS.
- **Restore drill**: restaurar el backup en un **contenedor limpio** (no sobre la BD viva) y arrancar la app desde él; la evidencia es el output del restore + la app funcionando contra la BD restaurada.

### Paso 2 — Carga la skill del CLI

```bash
npx -y agent-browser skills get core --full
```

Hazlo **siempre al empezar la sesión de verificación**, aunque creas que te acuerdas: la skill viaja con el CLI (version-matched) y es la referencia autoritativa de comandos, waits y troubleshooting. Por eso este documento **no duplica** su referencia de comandos — se quedaría obsoleta. Aquí solo se fija el *contrato de uso* del gate. Si en tu Claude Code está disponible la skill `agent-browser`, invócala — pero la guía del CLI (`skills get core --full`) sigue siendo la referencia autoritativa de comandos. Si el CLI falla raro, `npx -y agent-browser doctor` antes de culpar a la app.

### Paso 3 — Ejecuta el flujo de la Verificación (snapshot → refs → acciones)

El bucle canónico del CLI: `open` → `snapshot -i` → actuar sobre los refs `@eN` → re-`snapshot` tras cada cambio de página (los refs caducan al cambiar el DOM). Traduce la Verificación del planning a ese bucle, comprobando **lo observable en cada paso**, no solo el final feliz.

Ejemplo — una Verificación que pide *ver los elementos cambiar de estado en vivo*, aprobar un paso y capturar el resultado:

```bash
export AGENT_BROWSER_SESSION=t0.11        # sesión aislada con nombre de la tarea
EV=docs/verifications/T0.11 && mkdir -p "$EV"

npx -y agent-browser open http://localhost:3000/login
npx -y agent-browser snapshot -i          # localiza los refs del form de login
npx -y agent-browser fill @e3 "$APP_DEV_PASSWORD"
npx -y agent-browser click @e5
npx -y agent-browser wait --url "**/"     # sesión iniciada

# Lanza el flujo DESDE LA UI y captura la URL resultante:
npx -y agent-browser snapshot -i                    # refs frescos del dashboard
npx -y agent-browser click @e8                      # "Nuevo …"
npx -y agent-browser wait --url "**/items/*"
npx -y agent-browser get url                        # anota la URL creada (va al report)
npx -y agent-browser screenshot "$EV/01-inicial.png"
npx -y agent-browser wait --text "running"          # SIN reload: el punto es el SSE
npx -y agent-browser screenshot "$EV/02-running.png"
npx -y agent-browser wait --text "waiting_approval"
npx -y agent-browser snapshot -i                    # refs frescos del panel
npx -y agent-browser click @e12                     # "Aprobar y continuar"
npx -y agent-browser wait --text "succeeded"
npx -y agent-browser screenshot "$EV/03-completado.png"
npx -y agent-browser console > "$EV/browser-console.txt"   # errores JS = parte del veredicto
npx -y agent-browser close
```

Criterios de ejecución:

- **Verifica lo observable, literalmente.** Si la Verificación dice "ver el cambio en vivo", **no hagas `reload`** entre estados: un reload enmascararía un SSE roto con el fallback de revalidación. Si dice "la cifra aparece en la página X", navega a X y lee la cifra (`get text`), no consultes la tabla por psql — eso verifica la BD, no la feature.
- **Waits correctos, no `wait 2000`.** Usa `wait --text`, `wait --url` o `wait <selector>` según el caso (la skill del CLI lo detalla). **Nunca `wait --load networkidle` en páginas con SSE vivo**: la conexión abierta (heartbeat incluido) hace que networkidle no se alcance jamás y el comando cuelga hasta el timeout. Un CUA flaky por waits malos genera FAILs falsos que erosionan la confianza en el gate.
- **Downloads**: cuando la Verificación pide "descargarlo", usa `download <ref> <ruta-en-$EV>` y valida el fichero (checksum, `unzip -l`, schema del JSON) — el download que "llega" es el fichero íntegro en disco, no el click.
- **Fallos provocados**: cuando la Verificación exige romper algo (inyectar un fallo, usar una key inválida), provoca el fallo de verdad y captura el estado de error observable (el visor de errores, el 401) antes de arreglarlo.
- **Si algo inesperado aparece** (error en consola, estado raro, texto cortado), persíguelo: el CUA es exploratorio. Un PASS con un error rojo en la consola del navegador no es un PASS — como mínimo se anota en el report.
  - **Excepción estrecha**: un warning que (a) proviene de una **dependencia de terceros fijada** (no de código del proyecto) Y (b) **desaparece en el build de producción** (react-dom strippea los warnings dev-only) NO bloquea el PASS. Se anota como deuda upstream y se confirma re-ejecutando el flujo contra `next build && next start`, donde la consola debe quedar limpia. Un `console.error`/warning de **código propio**, o que sobreviva a prod, sigue siendo FAIL. Discriminador: ¿el ruido es de dependencia y muere en prod? → deuda. ¿Es propio o sobrevive a prod? → FAIL.
- **Contraste de texto (aserción obligatoria en cualquier verificación de UI)**: no basta con "se ve bien" ni con medir el color de fondo — **mide el contraste real texto/fondo** de los elementos con color de acento/semántico (botones, badges, chips, alerts), en dark Y light Y en cada acento que la tarea toque, con `getComputedStyle` (color + background) y el ratio WCAG. Umbral: **4.5:1** texto normal, **3:1** texto grande/negrita. Por debajo = FAIL (o hallazgo a rutear si el color viene del design system: el defecto está en los valores del DS, decisión del usuario, pero se REPORTA con la tabla de ratios, no se ignora). Lección aprendida: en la fase TD de un proyecto real, ningún verifier de las primeras tareas cazó un botón con texto casi-negro sobre acento oscuro porque todos medían fondos y tokens, nunca el contraste del texto sobre el acento — es un agujero de protocolo que las fases siguientes no deben repetir.

### Paso 4 — Captura la evidencia

Todo va a `docs/verifications/<TASK-ID>/` (el `<TASK-ID>` tal cual en el planning: `T0.11`, `T1.10b`...):

- **Screenshots numerados por estado clave** (`01-...png`, `02-...png`): estado inicial, cada transición relevante, estado final, y el error si se provocó uno. `screenshot --full` para páginas largas; `--annotate` si el screenshot debe explicarse solo.
- **Outputs de terminal** para la parte backend: `curl ... | tee "$EV/output.txt"`, salida del script de smoke, `psql` de la query de comprobación.
- **Consola y errores del navegador** (`console`, `errors`) cuando la tarea es de UI.
- **`report.md`** con la plantilla de abajo. Escríbelo **antes** de tocar el planning: la evidencia precede a la marca, siempre — es lo que impide el "ya lo verificaré luego" que convierte el planning en ficción.

Estos artefactos se commitean: son la memoria del proyecto.

### Paso 5 — Anota la tarea en `planning.md`

Solo cuando el veredicto es PASS:

```markdown
#### T0.11 · <título de la tarea> [x] YYYY-MM-DD — PASS, ver docs/verifications/T0.11/
```

Marca también las subtareas `[x]`. El formato mínimo obligatorio: `[x]` + fecha + resultado en una línea + puntero a la evidencia. Si la verificación gastó dinero, la cifra real va en el report (y en la línea si fue relevante, p. ej. "coste $0,11 < $0,15 ✓").

## Plantilla exacta de `report.md`

```markdown
# Verificación T<ID> — <título de la tarea>

- **Tarea**: T<ID> · <título> (`planning.md`)
- **Fecha**: YYYY-MM-DD
- **Ejecutor**: <agente> · agent-browser <versión> · sesión `t<id>`
- **Sistema**: commit `<sha>` · docker compose dev + `pnpm dev` + seeds `<cuáles>`

## Verificación esperada (literal de planning.md)
> <copia el campo "Verificación" de la tarea, sin recortar>

## Pasos ejecutados
1. <paso> → <qué se observó>
2. ...

## Resultado observado vs esperado
| # | Esperado | Observado | Evidencia | OK |
|---|---|---|---|---|
| 1 | El elemento pasa a running en vivo sin reload | Cambio de estado en <2 s vía SSE | 02-running.png | ✅ |
| 2 | ... | ... | ... | ✅/❌ |

## Coste real
<n/a — sin APIs de pago> | <desglose: proveedor, llamadas, $ total; vs estimado; recalibración si >25 %>

## Veredicto
**PASS** | **FAIL** — <una frase>. <Si FAIL: causa raíz, fix aplicado o pendiente.>
<Notas: rarezas observadas aunque el veredicto sea PASS, deudas [verificar] cerradas, etc.>
```

## Reglas de oro

1. **El CUA usa la app como un humano.** Para el paso que se está verificando: nada de atajos por API, ni `eval` que simule el click, ni tocar la BD para "avanzar" el flujo. Si el botón no es clicable por el agente, probablemente tampoco por el usuario — eso ES un hallazgo. Los atajos sí valen para **preparar** el escenario (seeds, crear entidades por API, login vía `state save` de una sesión previa).
2. **Un fallo de CUA = tarea NO completada.** No hay "pass con asterisco": se arregla la causa y se **repite el flujo completo** (no solo el paso que falló — el fix puede haber roto lo anterior). El report del FAIL también se guarda (añade `report-fail-1.md` o una sección): los fallos documentados valen tanto como los éxitos.
3. **Sesiones con nombre por tarea.** `--session <task-id>` (o `AGENT_BROWSER_SESSION=<task-id>`): aísla cookies/tabs/refs de la verificación frente a cualquier otra automatización concurrente, y hace atribuible cada acción. `close` al terminar; `close --all` si dudas de qué quedó vivo.
4. **No rebajes la Verificación.** Si el texto del planning pide "20 procesos concurrentes", son 20, no 3. Los E2E de fase son sagrados: no se marcan por aproximación. Si la Verificación resulta imposible tal cual está escrita, eso es un cambio de alcance: se edita planning/PRD en la misma sesión, no se finge.
5. **Presupuesto consciente.** Si la verificación llama a APIs de pago de verdad: usa el tier barato que la tarea permita, anota cada dólar y contrasta con la página de gasto si existe spend ledger — la propia página de gasto es parte de lo observable en muchas tareas. (La suite de tests, en cambio, jamás gasta: los mocks viven en `packages/test-utils`, ver `external-apis.md`.)
6. **El gate no sustituye a los tests.** Llegar al CUA con la suite en rojo es hacer trampa al orden: `pnpm gate` verde primero, CUA después. El CUA valida el sistema; los tests validan que puedas tocarlo mañana.
