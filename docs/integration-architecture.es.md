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

```text
                  +----------+
                  | PENDING  |
                  +----+-----+
                       | claim
                       v
                 +-----------+
                 |PROCESSING |
                 +-----+-----+
                       |
        +--------------+--------------+
        |              |              |
        v              v              v
    SUCCESS          ERROR         UNKNOWN
                       |              |
                       | reintento    | recuperación
                       | vencido      | idempotente
                       +-------> PENDING <------+
```

`ERROR` significa que Salesforce recibió información suficiente para clasificar un fallo. Un valor en `NextRetryAt__c` significa que el framework lo considera candidato a reintento.

`UNKNOWN` significa que Salesforce no puede inferir con seguridad si el efecto secundario remoto ocurrió. El reintento automático solo se habilita cuando la definición de integración indica explícitamente que la API remota es idempotente.

## Leases y trabajo obsoleto

Una transacción reclamada (claimed) recibe `ProcessingStartedAt__c` y `LeaseExpiresAt__c`. La recuperación considera obsoleta una transacción `PROCESSING` con el lease expirado.

Para el trabajo obsoleto, el scheduler de recuperación escribe un `IntegrationAttempt__c` sintético con resultado `UNKNOWN`. Devuelve el trabajo a `PENDING` solo cuando el reintento está habilitado, la idempotencia remota está habilitada y el presupuesto de reintentos no se ha agotado.

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
