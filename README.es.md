[English](README.md) | [Español](README.es.md)

# sf-integration-framework

Framework de integración reutilizable para Salesforce. Proporciona transacciones de integración duraderas, claves de idempotencia estables, registros de auditoría por intento, ejecución HTTP asíncrona, primitivas de reintento/backoff y recuperación de trabajo obsoleto.

El proyecto está estructurado como un proyecto Salesforce DX y está pensado para distribuirse como **paquete 2GP Unlocked**.

> Estado: desarrollo temprano `0.1.x`. Las APIs públicas todavía pueden cambiar.

> La versión en inglés es la canónica. Si esta traducción difiere del original, prevalece [README.md](README.md).

## Qué problema resuelve

Un cambio de negocio y una integración saliente no deberían depender de una única ejecución HTTP frágil. El framework persiste primero la operación lógica y la ejecuta de forma asíncrona:

```text
Transacción de negocio
      |
      +-- DML de negocio
      +-- IntegrationTransaction__c (PENDING)
                |
              COMMIT
                |
        Queueable de claim
                |
       PROCESSING + lease
                |
           Callout HTTP
                |
       IntegrationAttempt__c
                |
      SUCCESS / ERROR / UNKNOWN
```

`IntegrationTransaction__c` es estado operativo. `IntegrationAttempt__c` es el histórico de intentos físicos de ejecución. El logging de diagnóstico es deliberadamente una preocupación separada.

## Capacidades principales

- Clave de operación/idempotencia estable entre reintentos.
- Ciclo de vida `PENDING`, `PROCESSING`, `SUCCESS`, `ERROR` y `UNKNOWN`, con `Disposition__c` registrando por separado qué pasa a continuación.
- Fencing por número de intento: un worker con el lease expirado no puede enviar una segunda petición de un trabajo que ya es de otro.
- Claim pesimista mediante `FOR UPDATE`.
- Leases de procesamiento para detectar jobs asíncronos abandonados.
- Queueables separados para claim/DML y ejecución HTTP, evitando errores de callout por trabajo sin confirmar (uncommitted work).
- Códigos de estado HTTP reintentables configurables y backoff exponencial.
- Reintento automático de resultados inciertos solo cuando la idempotencia remota está habilitada explícitamente.
- Persistencia configurable de request/response con saneamiento y truncado.
- Callouts basados en Named Credentials; sin secretos en Apex ni en Custom Metadata.
- Handlers de operación enchufables que reconstruyen las peticiones a partir del estado de negocio persistido.
- Jobs programados de despacho (dispatcher) y recuperación.

## Estructura del repositorio

```text
force-app/main/default/
|-- classes/
|   |-- api/          superficie que toca el consumidor
|   |-- pipeline/     queueables y schedulables
|   |-- services/     las clases que hacen el DML
|   |-- policy/       lógica de decisión pura, sin DML
|   |-- support/      cliente http, sanitizer, factoría, constantes
|   `-- tests/
|-- objects/
|   |-- IntegrationTransaction__c/
|   |-- IntegrationAttempt__c/
|   `-- IntegrationDefinition__mdt/
`-- permissionsets/
config/
`-- project-scratch-def.json
docs/
|-- integration-architecture.md
|-- integration-architecture.es.md
|-- integration-security.md
`-- integration-security.es.md
```

## Requisitos

- Salesforce CLI (`sf`).
- Una org con Dev Hub habilitado para crear versiones de paquete 2GP.
- Una org de destino para la instalación.
- Named Credentials / External Credentials configuradas en cada org de destino para integraciones reales.

## Desarrollo local

```bash
git clone https://github.com/RubnSanchz/sf-integration-framework.git
cd sf-integration-framework

sf org login web --alias my-devhub --set-default-dev-hub
sf org create scratch \
  --definition-file config/project-scratch-def.json \
  --alias sif-scratch \
  --duration-days 7

sf project deploy start --target-org sif-scratch
sf apex run test --target-org sif-scratch --test-level RunLocalTests --wait 20
```

## Despliegue manual sin instalar el paquete

El repositorio también incluye `manifest/package.xml` para que el framework pueda desplegarse directamente en una org sin crear ni instalar antes un paquete Unlocked.

Autentica la org de destino:

```bash
sf org login web --alias target-org
```

Valida primero el despliegue:

```bash
sf project deploy validate \
  --manifest manifest/package.xml \
  --target-org target-org \
  --test-level RunLocalTests \
  --wait 30
```

Despliégalo:

```bash
sf project deploy start \
  --manifest manifest/package.xml \
  --target-org target-org \
  --test-level RunLocalTests \
  --wait 30
```

El manifest contiene las clases Apex del framework, los objetos personalizados, el tipo de Custom Metadata y el permission set empaquetado. Intencionadamente **no** incluye Named Credentials, External Credentials, principals, tokens ni secretos específicos de cada entorno.

Tras el despliegue, configura la org de destino exactamente igual que tras instalar el paquete: crea las Named Credentials/External Credentials y los registros `IntegrationDefinition__mdt` necesarios.

## Crear el paquete Unlocked

El paquete se crea una sola vez en el Dev Hub elegido:

```bash
sf package create \
  --name sf-integration-framework \
  --package-type Unlocked \
  --path force-app \
  --target-dev-hub my-devhub
```

Salesforce CLI añade el alias/ID del paquete a `sfdx-project.json`. Haz commit de ese alias generado antes de crear versiones distribuibles.

Crea una versión del paquete:

```bash
sf package version create \
  --package sf-integration-framework \
  --installation-key-bypass \
  --code-coverage \
  --wait 20 \
  --target-dev-hub my-devhub
```

Tras validar una versión, promociónala:

```bash
sf package version promote \
  --package <04t-package-version-id> \
  --target-dev-hub my-devhub
```

## Instalar en una org

```bash
sf package install \
  --package <04t-package-version-id-or-alias> \
  --target-org <org-alias> \
  --wait 20 \
  --publish-wait 20
```

Después:

1. Asigna `SF Integration Framework Admin` a los administradores que necesiten inspeccionar o gestionar los registros del framework **y a cualquier usuario cuyas transacciones registren trabajo de integración**. Registrar inserta un `IntegrationTransaction__c`, que falla con "fields being inaccessible" si el usuario en ejecución no tiene acceso a los campos.
2. Configura la Named Credential y la External Credential de la org de destino.
3. Crea un registro `IntegrationDefinition__mdt` por cada integración.
4. Implementa una clase Apex que implemente `IntegrationOperationHandler`.
5. Programa los jobs de dispatcher/recuperación si quieres recuperación automática y drenado del trabajo pendiente.


### Usar el paquete desde tu propio repositorio

Tu repositorio no contiene el código de este paquete. Instalas una versión, igual que harías con cualquier otra dependencia.

Tu repositorio contiene solo lo tuyo:

- las clases Apex que implementan `IntegrationOperationHandler`
- tu Named Credential y External Credential
- tus registros de `IntegrationDefinition__mdt`

Si construyes tu propio paquete, declara este como dependencia en lugar de copiarlo:

```json
"packageDirectories": [
  {
    "path": "force-app",
    "default": true,
    "dependencies": [
      { "package": "sf-integration-framework@0.1.0-1" }
    ]
  }
]
```

Para scratch orgs, instalar este paquete forma parte de preparar la org, no de desplegar tu código:

```bash
sf package install --package <id-de-version-04t> --target-org <alias-scratch> --wait 20
```

**No copies el código de este paquete en tu repositorio.** Los componentes se instalan como metadata ordinaria y editable, así que una copia en tu repositorio acabará desplegándose encima por tu propio pipeline y se desviará de la versión instalada. Terminarías manteniendo dos fuentes de verdad para las mismas clases.

Si necesitas cambiar el framework, haz fork del repositorio, construye tu propia versión del paquete e instálala. Si solo quieres el código en local para leerlo, clona el repositorio en el tag correspondiente a tu versión instalada, o añade las clases a tu `.forceignore` para que tu pipeline no las despliegue nunca.

## Configurar una integración

`IntegrationDefinition__mdt.DeveloperName` es la clave de integración que se usa desde Apex.

Campos importantes:

| Campo | Propósito |
| --- | --- |
| `NamedCredential__c` | Nombre API de la Named Credential usada como `callout:<nombre>` |
| `HandlerClass__c` | Clase Apex que implementa `IntegrationOperationHandler` |
| `TimeoutMs__c` | Timeout HTTP |
| `ProcessingLeaseSeconds__c` | Lease máximo de procesamiento esperado antes de que la recuperación considere el trabajo obsoleto |
| `MaxRetries__c` | Reintentos adicionales tras el primer intento |
| `RetryBaseDelaySeconds__c` | Retardo base para el backoff exponencial |
| `RetryableStatusCodes__c` | Códigos HTTP separados por comas; por defecto `408,429,500,502,503,504` |
| `IdempotencyEnabled__c` | Si el sistema remoto garantiza un procesamiento seguro frente a duplicados para la clave configurada |
| `IdempotencyHeader__c` | Nombre de la cabecera, por defecto `Idempotency-Key` |
| `RetryEnabled__c` | Interruptor general de reintentos para esta integración |
| `RetentionDays__c` | Días que se conserva una transacción con éxito antes de que la purga la borre; por defecto 30 |
| `MaxPayloadChars__c` | Los payloads persistidos se truncan a esta longitud |
| `LogRequestBody__c` / `LogResponseBody__c` | Persistencia de payloads mediante opt-in explícito |

La definición se valida la primera vez que se lee, y una inválida hace fallar la
transacción a la que pertenece en vez de comportarse mal más adelante. Las reglas:
`TimeoutMs__c` entre 1 y 120000; `ProcessingLeaseSeconds__c` al menos el timeout
más 30 segundos, porque un lease más corto que su propio callout permite que la
recuperación reclame trabajo que sigue en marcha; `MaxPayloadChars__c` entre 1 y
32768; `MaxRetries__c` no negativo; `RetryBaseDelaySeconds__c` al menos 1.

**No** habilites `IdempotencyEnabled__c` solo porque Salesforce genere una clave. La API remota debe consumir y aplicar realmente esa clave.

## Implementar un handler

```apex
public class InvoiceIntegrationHandler implements IntegrationOperationHandler {
    public IntegrationRequest buildRequest(IntegrationTransaction__c tx) {
        Factura__c invoice = [
            SELECT Id, Amount__c
            FROM Factura__c
            WHERE Id = :tx.RecordId__c
        ];

        return new IntegrationRequest(
            tx.IntegrationKey__c,
            tx.Operation__c,
            'POST',
            '/v1/invoices'
        ).withBody(JSON.serialize(invoice));
    }

    public String extractExternalId(IntegrationResponse response) {
        Map<String, Object> body =
            (Map<String, Object>) JSON.deserializeUntyped(response.body);
        return (String) body.get('id');
    }

    public void handleSuccess(
        IntegrationTransaction__c tx,
        IntegrationResponse response
    ) {
        // Post-procesado local opcional tras el éxito de la llamada remota.
    }
}
```

`buildRequest()` debe ser de solo lectura. No hagas DML ahí: el framework realiza intencionadamente el callout HTTP antes de cualquier DML en el Queueable de ejecución.

## Registrar trabajo de forma transaccional

Llama al framework en la misma transacción de Salesforce que el cambio de negocio:

```apex
update invoice;

IntegrationRequest request = new IntegrationRequest(
    'CORE_INVOICE',
    'CREATE',
    'POST',
    '/v1/invoices'
).forRecord(invoice);

IntegrationFramework.registerAndEnqueue(request);
```

Si la transacción de Salesforce envolvente hace rollback, la transacción de integración y el trabajo encolado hacen rollback con ella.

## Programar la recuperación

Ejemplo desde Execute Anonymous:

```apex
System.schedule(
    'SIF Dispatcher',
    '0 0/5 * * * ?',
    new IntegrationDispatchScheduler()
);

System.schedule(
    'SIF Recovery',
    '0 2/5 * * * ?',
    new IntegrationRecoveryScheduler()
);
```

System.schedule(
    'SIF Purge',
    '0 0 3 * * ?',
    new IntegrationPurgeBatch()
);
```

El dispatcher recoge el trabajo que nunca se ha ejecutado y aquel cuyo `Disposition__c` es `RETRY` con `NextRetryAt__c` vencido. La recuperación se ocupa solo de lo que nunca llegó a un final normal: leases de procesamiento expirados y resultados inciertos pendientes de evaluar. Solo reencola automáticamente el trabajo incierto cuando la idempotencia remota está configurada.

### Leer y dirigir una transacción

`Status__c` dice qué ocurrió. `Disposition__c` dice qué hará el framework a continuación:

| `Disposition__c` | Qué significa | Qué hace un administrador |
| --- | --- | --- |
| `NONE` | Nunca se ejecutó, o terminó con éxito. | Nada. |
| `RETRY` | Se volverá a enviar cuando venza `NextRetryAt__c`. | Nada, salvo que lo quieras antes: borra la fecha. |
| `RECONCILE` | El resultado es incierto y aún no se ha evaluado. La siguiente pasada de recuperación lo convierte en `RETRY` o en `MANUAL`. | Esperar a la siguiente pasada de recuperación. |
| `MANUAL` | Nada automático va a resolverlo. Normalmente una definición rota, un handler que no puede construir su petición, o un resultado incierto sobre una API no idempotente. | Comprobar el sistema remoto, corregir la causa y poner `RETRY` para reencolar o `TERMINAL` para cerrarla. |
| `TERMINAL` | Terminó sin éxito y no queda nada que intentar. | Nada, o `RETRY` para forzar otro intento. |

Para reencolar a mano una transacción aparcada, pon `Disposition__c` a `RETRY`. Deja `NextRetryAt__c` vacío para que se despache en la siguiente pasada, o ponle fecha para retrasarla. No hace falta tocar nada más: `Status__c` sigue registrando lo que de verdad ocurrió.

### Evitar que las tablas crezcan sin fin

`IntegrationPurgeBatch` borra las transacciones que terminaron con éxito hace más tiempo que el `RetentionDays__c` de su integración, y sus intentos caen en cascada por la relación master-detail. No borra nada más: un fallo, un resultado incierto o cualquier cosa pendiente de una persona son evidencia, y conservarlos es justo para lo que existe el outbox.

Cada registro cuenta 2 KB contra el almacenamiento de datos, contenga lo que contenga, así que una operación de negocio que necesitó tres intentos ocupa cuatro registros, unos 8 KB. A mil operaciones diarias son unos 8 MB al día, 240 MB al mes, y por eso esto se programa en vez de quedar como opcional.

Los registros borrados permanecen 15 días en la papelera y siguen contando contra el almacenamiento hasta entonces. Para liberarlo de inmediato, a cambio de que el borrado sea irrecuperable:

```apex
System.schedule('SIF Purge', '0 0 3 * * ?', new IntegrationPurgeBatch(200, true));
```

Una transacción cuyo `IntegrationDefinition__mdt` ya no resuelve nunca se purga. Que falte la definición es un problema de configuración, no un permiso para borrar su historial.

## Seguridad

- No se almacenan credenciales, tokens ni contraseñas en la Custom Metadata del paquete.
- Las Named Credentials/External Credentials siguen siendo la frontera de autenticación.
- Los handlers de operación no pueden sobrescribir las cabeceras de autorización ni host.
- La persistencia de cuerpos de request y response es opt-in.
- Los payloads persistidos se redactan y truncan.
- Trata `IntegrationTransaction__c` e `IntegrationAttempt__c` como datos operativos/de auditoría y aplica las políticas de retención de la org.

Consulta [docs/integration-security.es.md](docs/integration-security.es.md).

## Alcance actual / limitaciones

- Todavía no se incluye interfaz de usuario.
- Todavía no se incluye una estrategia genérica de endpoint de reconciliación; el trabajo `UNKNOWN` no idempotente queda para reconciliación manual o específica de cada integración.
- Las definiciones de Named Credential no se empaquetan intencionadamente porque la configuración de endpoint/autenticación es específica de cada entorno.
- Nebula Logger no es una dependencia. Se puede añadir más adelante un adaptador de logging sin acoplar el modelo de estado operativo al logging de diagnóstico.

## Licencia

Todavía no se ha seleccionado una licencia de código abierto.
