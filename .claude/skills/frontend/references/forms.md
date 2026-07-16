# Formularios y editores complejos

Cómo se escribe TODO formulario de `apps/web`: creación de recursos, editores de artefactos, settings. Los tests que exige cada pieza los define `testing/references/frontend.md` — léelo junto a este documento; aquí solo se marca QUÉ debe ser observable para que esos tests existan.

## Índice

1. [El patrón único: RHF + zodResolver + api-client](#1-el-patrón-único-rhf--zodresolver--api-client)
2. [Anatomía de un formulario de creación](#2-anatomía-de-un-formulario-de-creación)
3. [El envelope de error `{code, message, details}`](#3-el-envelope-de-error-code-message-details)
4. [Editores complejos: field arrays, re-validación en servidor, bloqueos](#4-editores-complejos-field-arrays-re-validación-en-servidor-bloqueos)
5. [Accesibilidad de formularios = API de test](#5-accesibilidad-de-formularios--api-de-test)
6. [Settings: los secretos nunca se re-renderizan en claro](#6-settings-los-secretos-nunca-se-re-renderizan-en-claro)
7. [Qué NO va aquí](#7-qué-no-va-aquí)

---

## 1. El patrón único: RHF + zodResolver + api-client

Decisión del arnés, no negociable:

1. **react-hook-form + `zodResolver` con el MISMO schema Zod de `@app/core`.** El schema que valida en el cliente es el mismo objeto que re-valida el route handler (skill backend). Por qué: elimina por construcción el drift cliente/servidor — no hay dos definiciones de "válido" que puedan divergir.
2. **Submit por `fetch` a la API REST vía `lib/api-client.ts`.** Sin Server Actions, sin `useActionState`, sin `useFormStatus`: una sola superficie de mutación, la misma que usan worker, curl y los tests de `testing/references/api.md`. Una action sería una segunda superficie sin envelope y sin cobertura de esa capa.
3. **`mode: 'onBlur'` por defecto.** `onChange` grita errores mientras el usuario aún teclea; `onSubmit` avisa demasiado tarde. `onBlur` valida al abandonar el campo — el punto donde el error es útil. Solo se cambia con motivo escrito en el componente.
4. **El estado de envío es de RHF** (`formState.isSubmitting`), no un `useState` paralelo. Un booleano duplicado acaba desincronizado del ciclo real del submit.

El resolver consume el schema tal cual sale de core. Si el formulario edita un subconjunto, el subconjunto se deriva del contrato (`Schema.pick(...)`) en el propio componente — nunca se redeclara un shape a mano: un cambio de contrato debe romper la compilación del form.

**Las reglas cross-field viven EN el schema de core** (refine/superRefine), no en `if`s del componente: el handler debe rechazar exactamente lo mismo que el cliente. Ejemplo típico: un formulario con dos modos de entrada excluyentes (URL o texto libre) donde el modo B no exige el campo del modo A — esa conmutación es del schema, y en la UI es **conmutación de campos renderizados, no de `disabled`**.

## 2. Anatomía de un formulario de creación

```tsx
'use client';
// apps/web/src/components/items/create-item-form.tsx
import { useRouter } from 'next/navigation';
import { useForm } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { CreateItemSchema, ItemSchema, type CreateItem } from '@app/core/contracts';
import { api, ApiError } from '@/lib/api-client';
import { applyEnvelopeToForm } from '@/lib/form-errors';
import { Button } from '@/components/ui/button';

export function CreateItemForm() {
  const router = useRouter();
  const { register, handleSubmit, setError, formState } = useForm<CreateItem>({
    resolver: zodResolver(CreateItemSchema), // EL schema de core, no una copia
    mode: 'onBlur',
    defaultValues: { name: '', kind: 'standard' },
  });
  const { errors, isSubmitting } = formState;

  const onSubmit = handleSubmit(async (values) => {
    try {
      const item = await api.post('/api/items', ItemSchema, values);
      router.push(`/items/${item.id}`);
    } catch (e) {
      if (e instanceof ApiError) return applyEnvelopeToForm(e, setError); // §3
      throw e; // red caída u otro error no-API: lo captura el error boundary
    }
  });

  return (
    <form onSubmit={onSubmit} noValidate>
      <div>
        <label htmlFor="item-name">Nombre</label>
        <input
          id="item-name"
          aria-invalid={errors.name ? true : undefined}
          aria-describedby={errors.name ? 'item-name-error' : undefined}
          {...register('name')}
        />
        {errors.name && <p id="item-name-error" role="alert">{errors.name.message}</p>}
      </div>

      {/* …resto de campos: mismos patrones… */}

      {errors.root?.server && <div role="alert">{errors.root.server.message}</div>}

      <Button type="submit" disabled={isSubmitting}>
        {isSubmitting ? 'Creando…' : 'Crear'}
      </Button>
    </form>
  );
}
```

Puntos que los tests de `testing/references/frontend.md` asertan literalmente — si falta alguno, el test no puede escribirse:

- **Loading observable**: el botón se deshabilita Y cambia su accessible name (`crear` → `creando…`). El test hace `getByRole('button', { name: /creando/i })` y espera `toBeDisabled()`.
- **Error recuperable**: tras un fallo, el submit se re-habilita (RHF lo hace solo al resolver la promesa) y el error vive en `role="alert"`. Un formulario "atascado" en loading tras un 500 es un bug.
- **`noValidate`** en el `<form>`: la validación nativa del navegador pisaría los mensajes del schema y rompería los asserts de texto.
- Los uploads opcionales siguen el mismo principio — mutación contra la API REST de assets; su endpoint lo gobierna la skill backend.

## 3. El envelope de error `{code, message, details}`

Toda respuesta de error de la API es el envelope del PRD, contrato Zod en `@app/core/contracts`. **El frontend hace switch sobre `code`; el wording de `message` nunca es contrato** (skill backend). Reacción prescrita por código:

| `code` | Reacción del formulario | Por qué |
|---|---|---|
| `validation_error` | `setError` campo a campo desde `details` (salida de `z.flattenError` del servidor); `formErrors` → error root en `role="alert"` | El usuario corrige en el campo, no en un banner genérico. Además es señal de drift: si cliente y servidor comparten schema, este error no debería ocurrir en un form ya validado — investígalo, no lo silencies |
| Bloqueo de negocio con sugerencia (p. ej. un guardrail/linter de servidor, si el proyecto lo define) | Alert (`role="alert"`) con la explicación (`message`) + la sugerencia accionable (`details.suggestion`); **la acción siguiente queda deshabilitada** hasta que un reintento pase | Bloqueo con explicación y salida accionable, no solo aviso |
| `invalid_transition` | Toast informativo y NADA más: no tocar el form ni el store | El recurso cambió por debajo (otro cliente/proceso llegó antes); el estado real llega por SSE o re-fetch (`references/state-and-sse.md`). Parchear a mano crearía un segundo dueño del estado |
| 401 (`unauthorized`) *(módulo auth)* | Redirect a login, centralizado en `api-client` | El proxy protege páginas; un 401 en un fetch significa sesión expirada — ningún formulario debe tratarlo caso a caso |
| Resto (`internal`, red caída…) | Error root genérico en `role="alert"`, submit re-habilitado | Recuperable, no atascado |

El helper que mapea `details` de Zod a `setError` de RHF — vive en `apps/web/src/lib/form-errors.ts` y lo usan TODOS los formularios (un solo patrón):

```ts
// apps/web/src/lib/form-errors.ts
import type { FieldValues, Path, UseFormSetError } from 'react-hook-form';
import { z } from 'zod';
import type { ApiError } from '@/lib/api-client'; // lleva code/message/details del envelope (architecture.md §3.1)

// Shape de details para validation_error: lo que produce z.flattenError en el handler
const ValidationDetailsSchema = z.object({
  formErrors: z.array(z.string()).default([]),
  fieldErrors: z.record(z.string(), z.array(z.string())).default({}),
});

export function applyEnvelopeToForm<T extends FieldValues>(
  error: ApiError,
  setError: UseFormSetError<T>,
): void {
  if (error.code === 'validation_error') {
    const parsed = ValidationDetailsSchema.safeParse(error.details);
    if (parsed.success) {
      for (const [field, messages] of Object.entries(parsed.data.fieldErrors)) {
        setError(field as Path<T>, { type: 'server', message: messages[0] ?? error.message });
      }
      if (parsed.data.formErrors.length > 0) {
        setError('root.server', { type: 'server', message: parsed.data.formErrors.join(' — ') });
      }
      return;
    }
  }
  setError('root.server', { type: error.code, message: error.message });
}
```

Los errores `root.*` de RHF no sobreviven a la siguiente validación — exactamente el comportamiento deseado: el error del servidor desaparece cuando el usuario reintenta.

**Contrato del helper**: todo formulario que pueda recibir un código con UI propia (un bloqueo de negocio con sugerencia, §4) DEBE interceptarlo ANTES de llamar a `applyEnvelopeToForm` — el fallback `root.server` lo degradaría a un banner genérico.

## 4. Editores complejos: field arrays, re-validación en servidor, bloqueos

Patrones para los formularios con más lógica (editores de artefactos, wizards, formularios con listas). Regla común cuando el recurso tiene ciclo de vida en servidor: **el formulario edita el artefacto; el estado del recurso NO es suyo** — las transiciones (aprobar, publicar…) son POSTs a la API y el estado real llega por SSE (si el módulo existe) o re-fetch.

### Listas editables: `useFieldArray`

- **`useFieldArray` para toda lista que crece/decrece** (elementos de un documento, filas de un editor): los `fields` de RHF dan keys estables.
- **Los metadatos de solo lectura son RENDER del prop, no form state.** Datos que el servidor produjo y el usuario no edita (procedencia, confianza, timestamps) se leen del objeto original por índice. Meterlos en el form invitaría a mutarlos.
- **Los warnings bloqueantes del servidor deshabilitan la acción siguiente** hasta que exista una decisión explícita del usuario. El warning viene del servidor — no es un error de RHF ni se valida en cliente.

```tsx
// apps/web/src/components/items/item-editor.tsx (extracto del patrón)
export function ItemEditor({ item, warnings }: ItemEditorProps) {
  const { control, register, handleSubmit, setError, formState } = useForm<ItemFormValues>({
    resolver: zodResolver(ItemFormSchema), // derivado con .pick del contrato de core
    mode: 'onBlur',
    defaultValues: { entries: item.entries },
  });
  const entries = useFieldArray({ control, name: 'entries' });
  const [decisions, setDecisions] = useState<Record<string, Decision>>({});
  const blocked = warnings.some((w) => w.blocking && !decisions[w.code]);

  return (
    <form onSubmit={handleSubmit(save)} noValidate>
      {entries.fields.map((field, i) => (
        <fieldset key={field.id} aria-label={item.entries[i]?.title ?? `Entrada ${i + 1}`}>
          <legend className="sr-only">Entrada {i + 1}</legend>
          {/* metadatos de solo lectura: del prop `item`, no del form */}
          <label htmlFor={`entry-${i}`}>Texto</label>
          <input id={`entry-${i}`} {...register(`entries.${i}.text` as const)} />
        </fieldset>
      ))}

      <Button type="submit" disabled={formState.isSubmitting}>Guardar</Button>
      <Button type="button" disabled={blocked || formState.isSubmitting} onClick={confirm}>
        Confirmar
      </Button>
    </form>
  );
}
```

### Cálculos derivados en vivo

Si el formulario muestra un valor derivado de lo que el usuario selecciona (un coste estimado, un total), **el cálculo es una función pura de `@app/core`** aplicada sobre los valores observados (`useWatch`), nunca una fórmula re-implementada en el componente — el test calcula el valor esperado a mano contra la misma función. El resultado vive en un `role="status"` con accessible name para que el test lo encuentre y el usuario con lector de pantalla oiga el cambio.

### Re-validación de negocio en servidor

Cuando guardar dispara una validación de negocio cara o normativa (un linter, un guardrail): **el SERVIDOR la ejecuta** (lógica de core con sus propios unit tests; la UI solo reacciona a su respuesta). Jamás una validación "aproximada" en cliente: dos validadores = dos verdades. Un bloqueo (422 con código propio) renderiza explicación + sugerencia y **deshabilita la acción siguiente** hasta que un guardado posterior pase:

```tsx
const [block, setBlock] = useState<ApiError | null>(null);

const onSave = handleSubmit(async (values) => {
  setBlock(null);
  try {
    await api.post(`/api/items/${itemId}/edit`, ItemSchema, { artifact: values });
  } catch (e) {
    if (e instanceof ApiError && e.code === 'guardrail_blocked') return setBlock(e);
    if (e instanceof ApiError) return applyEnvelopeToForm(e, setError);
    throw e;
  }
});

// En el JSX:
{block && (
  <div role="alert">
    <p>{block.message}</p>
    <p>Sugerencia: {String(block.details?.suggestion)}</p> {/* accionable */}
  </div>
)}
<Button type="button" disabled={block !== null || formState.isSubmitting} onClick={confirm}>
  Confirmar
</Button>
```

Estados que los tests exigen observables en todo editor: loading deshabilita los botones, un error re-habilita con `role="alert"` visible, y la sugerencia del servidor es texto renderizado (no un tooltip que jsdom no ve).

## 5. Accesibilidad de formularios = API de test

Correlación directa con las queries de `testing/references/frontend.md` (`getByRole` > `getByLabelText` > …): cada regla de abajo es lo que hace posible una query concreta. Sin esto, el componente no se puede testear NI usar.

1. **Todo campo tiene `<label htmlFor>`** (o `aria-label` si el diseño no muestra label). Habilita `getByRole('textbox', { name: /nombre/i })` y `getByLabelText`.
2. **Grupos repetidos con `<fieldset>` + `aria-label`** (o `role="group"`): cada entrada de un field array. Los tests hacen `getByRole('group', { name: /…/i })` y luego `within(...)` — sin nombre de grupo no hay `within`.
3. **Errores de campo**: el mensaje se enlaza con `aria-describedby` y el input marca `aria-invalid`. El lector de pantalla anuncia el error al enfocar el campo; el test lo encuentra junto al input.
4. **El botón de submit cambia su accessible name en loading** (`Guardar` → `Guardando…`) además de `disabled`. Es el indicador de progreso más barato y el único que los tests asertan sin mirar píxeles.
5. **Feedback asíncrono**: errores en `role="alert"` (interrumpe, es urgente); estados informativos (total recalculado, "guardado") en `role="status"`/`aria-live="polite"`.
6. **`noValidate` siempre**: los mensajes los pone el schema Zod, con el mismo texto en cliente y servidor.

## 6. Settings: los secretos nunca se re-renderizan en claro

Si el proyecto guarda credenciales/API keys editables desde la UI (cifradas en BD, skill backend), reglas para el formulario:

- **El GET de settings NUNCA devuelve el secreto en claro y la UI NUNCA lo re-renderiza**: el campo muestra un placeholder enmascarado (p. ej. `••••••••` + últimos 4 caracteres si la API los expone). `testing/references/frontend.md` lo verifica con assert negativo (`queryByText(key)` es `null`) — si tu componente rompe ese test, es un incidente de seguridad, no un rojo más.
- El input de un secreto es **write-only**: vacío por defecto; el PATCH solo incluye el secreto si el usuario escribió un valor nuevo (enviar el placeholder machacaría la credencial real).
- Tras guardar: `role="status"` de confirmación, el input vuelve a vacío + placeholder enmascarado. Jamás "eco" del valor guardado.
- `autoComplete="new-password"` y `type="password"` en los inputs de secreto: Chrome y Safari ignoran deliberadamente `autocomplete="off"` en campos password; `new-password` es el valor que sí suprime el autocompletado del gestor (el enmascarado visual lo da `type="password"`).

## 7. Qué NO va aquí

- **Validación del lado servidor, el wrapper de handlers y la construcción del envelope** → skill **backend**, `references/api.md`. Este documento solo consume el envelope.
- **Stores, el hook SSE y por qué `invalid_transition` se resuelve con re-sync** → `references/state-and-sse.md`.
- **Los componentes visuales del form (`Button`, `Input`…), cva y tokens** → `references/components.md` y `references/design-system.md`.
- **Cómo se testean estos formularios** (msw, mocks, asserts de loading/error) → `testing/references/frontend.md`, fuente de verdad. Aquí solo se garantiza que lo observable existe.
- **El flujo completo en navegador** → `testing/references/e2e.md` y el gate CUA (`testing/references/cua.md`).
