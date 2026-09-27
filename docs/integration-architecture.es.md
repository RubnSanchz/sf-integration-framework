[English](integration-architecture.md) | [Español](integration-architecture.es.md)

# Arquitectura

> La versión en inglés es la canónica. Si esta traducción difiere del original, prevalece [integration-architecture.md](integration-architecture.md).

## Principios de diseño

### Operación lógica != intento HTTP

`IntegrationTransaction__c` representa una operación lógica de integración de negocio. Su `IdempotencyKey__c` permanece estable entre reintentos. `IntegrationAttempt__c` representa un intento físico de ejecución.

### Outbox transaccional

El uso recomendado es crear la transacción del framework en la misma transacción de Salesforce que la mutación de negocio. El trabajo HTTP saliente ocurre solo después del commit.

### Claim antes de ejecutar

La fase de claim se ejecuta en su propio Queueable y bloquea la transacción con `FOR UPDATE`, la pasa a `PROCESSING`, incrementa el contador de intentos y establece un lease. Después encadena el Queueable de callout.

Esta separación es intencionada: realizar DML y luego intentar un callout en la misma transacción Apex puede fallar por trabajo pendiente/sin confirmar (uncommitted work).

### Reconstrucción de la petición

El framework no depende de un cuerpo de petición persistido como fuente de verdad para los reintentos. `IntegrationOperationHandler.buildRequest()` reconstruye la petición saliente a partir del estado persistido de Salesforce.

Esto permite que el logging de payloads siga siendo opcional sin hacer imposible la recuperación.

## Máquina de estados

Dos campos responden a dos preguntas distintas. `Status__c` dice qué ocurrió. `Disposition__c` dice qué hace el framework a continuación.

```text
                  +----------+
                  | PENDING  |   Disposition NONE: nunca ejecutada
                  +----+-----+
                       | claim (AttemptCount++, lease, número de intento entregado al worker)
                       v
                 +-----------+
                 |PROCESSING |
                 +-----+-----+
                       |
        +--------------+--------------+
        |              |              |
        v              v              v
    SUCCESS          ERROR         UNKNOWN
    NONE           RETRY | TERMINAL | MANUAL
                                  RETRY | RECONCILE | TERMINAL | MANUAL
                       |              |
                       +---- Disposition RETRY y NextRetryAt vencido ----+
                                      |
                                      v
                               se vuelve a reclamar
```

Una transacción nunca vuelve a `PENDING`. `PENDING` significa "nunca ejecutada", y todo lo que el framework pretende volver a ejecutar lo dice mediante `Disposition__c = RETRY` más un `NextRetryAt__c`, sea cual sea su estado. Eso es lo que permite que un resultado incierto siga siendo `UNKNOWN` y esté programado a la vez, en vez de reescribirlo como `PENDING` y perder esa información.

Hay trabajo pendiente cuando:

```text
(Status__c = PENDING AND Disposition__c = NONE)
OR (Disposition__c = RETRY AND (NextRetryAt__c = null OR NextRetryAt__c <= now))
```

`ERROR` significa que Salesforce recibió información suficiente para clasificar un fallo.

`UNKNOWN` significa que Salesforce no puede inferir con seguridad si el efecto secundario remoto ocurrió. El reintento automático solo se habilita cuando la definición de integración indica explícitamente que la API remota es idempotente.

Las disposiciones:

| Valor | Significado |
| --- | --- |
| `NONE` | Nada que hacer por parte del framework: o nunca se ejecutó, o terminó con éxito. |
| `RETRY` | Se volverá a enviar cuando venza `NextRetryAt__c`. Sin fecha significa "en cuanto se pueda". |
| `RECONCILE` | El resultado es incierto y aún no se ha evaluado. El scheduler de recuperación lo evalúa en su siguiente pasada y lo convierte en `RETRY` o en `MANUAL`. |
| `MANUAL` | Nada automático va a resolverlo. Necesita a un administrador. |
| `TERMINAL` | Terminó sin éxito y no queda nada que intentar. |

Un administrador vuelve a encolar una transacción aparcada poniendo `Disposition__c` a `RETRY`, con fecha para retrasarla o sin fecha para que se despache en la siguiente pasada.

## Fallos previos al callout

Todo lo que puede fallar entre reclamar una transacción y enviar la petición se clasifica como `ERROR`, nunca como `UNKNOWN`: ninguna petición salió de la org, así que el lado remoto no ha podido actuar. Cada causa tiene su propio código, porque se resuelven de forma distinta: `CONFIGURATION_ERROR`, `HANDLER_ERROR`, `REQUEST_BUILD_ERROR`, `INVALID_REQUEST` y `HANDLER_DML`.

`buildRequest()` se ejecuta dentro de un savepoint con un contador de DML. Si escribe algo, la escritura se deshace y el intento se rechaza como `HANDLER_DML` sin hacer el callout. Ese DML haría que el callout siguiente fallara con "uncommitted work pending", que en tiempo de ejecución es indistinguible de una llamada remota genuinamente incierta.

## Leases, fencing y trabajo obsoleto

Una transacción reclamada (claimed) recibe `ProcessingStartedAt__c` y `LeaseExpiresAt__c`, y al worker se le entrega el número de intento que reservó su claim.

Ese número es el fence. El job de ejecución solo actúa mientras el `AttemptCount__c` almacenado siga coincidiendo, comprobado al entrar y otra vez con `FOR UPDATE` después del callout. Tres desenlaces:

- Número de intento distinto al entrar: el worker se retira en silencio, sin escribir ni enviar nada.
- Lease ya expirado al entrar: no se hace el callout. Como no se envió nada no hay efecto remoto, así que este reintento no exige idempotencia remota. El intento se registra como `LEASE_EXPIRED`.
- Pérdida de propiedad con el callout en vuelo: la respuesta se registra como un intento `UNKNOWN` / `SUPERSEDED` con el código HTTP real, y la transacción se deja intacta para quien la posea ahora.

La recuperación considera obsoleta una transacción `PROCESSING` con el lease expirado. Escribe un `IntegrationAttempt__c` sintético con resultado `UNKNOWN` y código `STALE_LEASE`, y mueve la transacción a `UNKNOWN` con `RETRY` y una fecha de backoff solo cuando el reintento está habilitado, la idempotencia remota está habilitada y el presupuesto de reintentos no se ha agotado. Si no, pasa a `RECONCILE`, y de ahí a `MANUAL` en cuanto el scheduler de recuperación confirma que nada automático puede resolverlo.

## Política de reintentos

`MaxRetries__c` significa reintentos adicionales tras la primera ejecución. `RetryBaseDelaySeconds__c` usa backoff exponencial con tope:

```text
retardo = base * 2^(intento - 1)
```

El exponente está limitado para evitar un crecimiento entero sin cota.

## Punto de extensión

Cada integración aporta un `IntegrationOperationHandler`:

- `buildRequest()` reconstruye la petición sin DML.
- `extractExternalId()` extrae el identificador remoto tras el éxito.
- `handleSuccess()` realiza post-procesado local opcional.

Si el post-procesado falla después de que la API remota ya haya tenido éxito, el DML local se revierte a un savepoint y la transacción pasa a `UNKNOWN`. Esto evita declarar incorrectamente como fallido un efecto secundario remoto.

## Preocupaciones deliberadamente separadas

El estado de recuperación operativa no es logging de diagnóstico. El framework puede integrarse más adelante con Nebula Logger mediante un adaptador, pero las decisiones de reintento nunca deben depender de registros de log.
