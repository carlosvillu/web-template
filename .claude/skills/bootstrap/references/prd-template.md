# Plantilla de PRD

Esqueleto comentado. El PRD resultante se escribe en `PRD.md` (raíz), en español, denso y citable: el planning apunta a él con `§N` y los E2E de fase citan sus criterios de éxito. Los comentarios `<!-- -->` son guía para quien redacta y NO van al documento final. Regla transversal: **toda afirmación no verificada (precio de API, límite, supuesto de mercado) se marca `[verificar]`** — el planning las cierra en la tarea que integra esa pieza.

En proyectos pequeños (micro-SaaS de una feature) es legítimo omitir secciones: cada comentario indica cuándo. Lo que NUNCA se omite: resumen ejecutivo, objetivos/no-objetivos, decisiones, arquitectura/stack, dominio central, modelo de datos, roadmap y criterios de éxito.

---

```markdown
# PRD — {{PROJECT_NAME}}

> **{{Tagline: una frase que define el producto.}}**
> {{2-4 líneas: el recorrido completo de valor — de qué entrada a qué salida observable, para quién, dónde corre.}}
>
> **Versión:** 0.1 (borrador) · **Fecha:** {{fecha}} · **Autor:** {{usuario}} + Claude
> **Documentos fuente:** {{`research/01-….md` … si hubo deep research; si no, eliminar la línea}}
<!-- Al aprobarse: Versión pasa a 1.0 y se añade la fecha de aprobación. El planning
     citará "PRD (v1, aprobado YYYY-MM-DD)". Cambios posteriores suben versión. -->

---

## Índice
<!-- Enlaces #ancla a todas las secciones presentes. Regenerar al cerrar el borrador. -->

## 1. Resumen ejecutivo
<!-- SIEMPRE. Qué es el producto en 1 párrafo + un diagrama ASCII del flujo de valor si
     ayuda. Después, las TESIS numeradas del producto (2-4): por qué esto merece existir,
     cada una citando research (`research/01 §3`) o marcada [verificar]. Cierra con una
     línea de stack ("Stack: monorepo TS · Next.js · Postgres+Drizzle · … · VPS propio"). -->

## 2. Contexto y oportunidad
<!-- OMITIR si no hubo research y el producto es una herramienta personal obvia.
     2.1 Estado del arte: síntesis con citas a research/. 2.2 Por qué este producto /
     por qué ahora: el hueco concreto que cubre. -->

## 3. Objetivos y no-objetivos
<!-- SIEMPRE. 3.1 Objetivos O1..On: capacidades observables del producto completo, no
     tareas ("O1 — Analizar una URL real y producir X editable"). 3.2 No-objetivos:
     lista explícita de lo que queda FUERA (multi-tenancy, apps móviles, integraciones
     descartadas…) — es la mejor defensa contra el scope creep del bucle. -->

## 4. Usuario y casos de uso
<!-- Quién es el usuario (en micro-SaaS personal: una línea) + 3-6 casos de uso
     narrados como recorridos ("entra con X, hace Y, obtiene Z"). OMITIR solo si el §1
     ya lo deja inequívoco. -->

## 5. Decisiones de producto ya tomadas
<!-- SIEMPRE. Tabla D1..Dn con lo acordado en la entrevista — vinculante para el resto
     del PRD y para el bucle (los agentes citan "decisión D3"). -->
| # | Decisión | Detalle |
|---|---|---|
| D1 | {{p. ej. Herramienta personal}} | {{Mono-usuario, sin billing}} |
| D2 | … | … |

## 6. Arquitectura general
<!-- SIEMPRE. 6.1 Diagrama (ASCII: apps, paquetes, BD, servicios externos, colas).
     6.2 Stack y justificación: el stack del template es fijo — aquí se justifica lo
     VARIABLE (módulos F0 elegidos, librerías de dominio, por qué worker o no worker).
     6.3 Patrones obligatorios si los hay (webhook+polling, idempotencia, etc.). -->

## 7. {{Dominio central}}
<!-- SIEMPRE, con el nombre real ("El pipeline", "El motor de búsqueda", "La feature X").
     Es el corazón del PRD: estados y transiciones si hay máquina de estados, contratos
     entre piezas, invariantes. Todo lo que el implementer no debe tener que adivinar. -->

## 8. Cliente: UX y rutas
<!-- SIEMPRE que haya UI. Mapa de rutas (`/`, `/settings`, …) con 1-2 líneas por
     pantalla, y los requisitos UX no negociables. Recordatorio: cada pantalla tendrá
     mockup aprobado en docs/mockups/ (regla 7 del planning) — aquí solo se enumeran. -->

## 9. Módulos del servidor
<!-- Para proyectos con backend no trivial: un sub-§ por módulo (responsabilidad,
     entradas/salidas, dependencias). En micro-SaaS pequeño: colapsar en una tabla
     módulo|responsabilidad o fundir con §6. -->

## 10. Modelo de datos
<!-- SIEMPRE. Tablas con columnas clave, enums, constraints e índices no obvios, y las
     relaciones. No hace falta DDL: suficiente detalle para que la migración Drizzle
     no invente semántica. -->

## 11. Integraciones externas
<!-- Un sub-§ por proveedor (API de LLM, media, pagos, scraping…): qué se usa, endpoints
     o SDK, límites, y PRECIOS con [verificar] salvo cita de research. OMITIR si el
     producto no llama a nada externo. -->

## 12. Despliegue y operación
<!-- Si el módulo deploy está en alcance: entornos, compose de prod, dominio/TLS,
     backups, procedimiento de deploy. Si v1 es solo local: una línea diciéndolo. -->

## 13. Observabilidad y seguridad
<!-- Logging estructurado (pino + correlación viene del template), métricas o alertas
     propias, y el modelo de seguridad: auth elegida, secretos, superficie pública,
     validación de entrada. En mono-usuario simple puede ser corto, pero existe. -->

## 14. Riesgos y mitigaciones
<!-- Tabla riesgo|impacto|mitigación. OMITIR solo en proyectos triviales sin APIs de
     pago ni datos de usuario. -->

## 15. Roadmap de fases (alto nivel)
<!-- SIEMPRE. Una viñeta por fase (F0, TD, F1..Fn) con su entrega observable — es el
     contrato con planning.md, que lo detalla tarea a tarea. Baby steps: cada fase deja
     el producto más útil que la anterior; anotar los hitos de valor real. -->

## 16. Criterios de éxito
<!-- SIEMPRE, NUMERADOS: los E2E de fase del planning citan "criterio 16.3". Cada
     criterio es medible y observable ("dada una URL real, obtener X en < N min con
     coste < $Y"), nunca "el código está limpio". -->

## 17. Apéndices
<!-- Opcionales. Los dos habituales:
     - Apéndice A — Mapa de fuentes: tabla research/NN → secciones que lo citan
       (mantiene el PRD auditable). Solo si hubo research.
     - Apéndice B — Superficie API interna: firmas v1 de los endpoints/funciones
       públicas entre módulos. Solo si §9 existe.
     Otros: JSON Schemas de contratos, presets, tablas de recetas/costes. -->
```
