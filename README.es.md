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
- Ciclo de vida `PENDING`, `PROCESSING`, `SUCCESS`, `ERROR` y `UNKNOWN`.
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

1. Asigna `SF Integration Framework Admin` a los administradores que necesiten inspeccionar o gestionar los registros del framework.
2. Configura la Named Credential y la External Credential de la org de destino.
3. Crea un registro `IntegrationDefinition__mdt` por cada integración.
4. Implementa una clase Apex que implemente `IntegrationOperationHandler`.
5. Programa los jobs de dispatcher/recuperación si quieres recuperación automática y drenado del trabajo pendiente.

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
| `LogRequestBody__c` / `LogResponseBody__c` | Persistencia de payloads mediante opt-in explícito |

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

El dispatcher drena el trabajo `PENDING` y los reintentos vencidos. La recuperación identifica leases de procesamiento expirados y solo reencola automáticamente el trabajo incierto cuando la idempotencia remota está configurada.

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
