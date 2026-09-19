[English](integration-security.md) | [Español](integration-security.es.md)

# Modelo de seguridad

> La versión en inglés es la canónica. Si esta traducción difiere del original, prevalece [integration-security.md](integration-security.md).

## Credenciales

El framework referencia las Named Credentials por su nombre API. Los secretos nunca se almacenan en `IntegrationDefinition__mdt`, constantes Apex, `IntegrationTransaction__c` ni `IntegrationAttempt__c`.

Cada org suscriptora/de destino es responsable de crear la Named Credential y la External Credential/principal asociada. Esto permite que el mismo paquete use endpoints y credenciales distintos por entorno.

Salesforce no empaqueta material sensible del principal, como tokens de acceso y certificados, junto con la metadata de credenciales; esos valores deben rellenarse en la org de destino.

## Cabeceras

Los handlers pueden aportar cabeceras de aplicación, pero el cliente HTTP rechaza la sobrescritura de:

- `Authorization`
- `Proxy-Authorization`
- `Host`

La autenticación debe permanecer bajo control de la Named Credential.

## Persistencia de payloads

Los cuerpos de request y response están deshabilitados por defecto. Solo se persisten cuando los flags correspondientes están habilitados en `IntegrationDefinition__mdt`.

Antes de persistir, el framework:

- redacta las claves habituales de token/contraseña;
- trunca el contenido a `MaxPayloadChars__c`;
- nunca almacena cabeceras de la petición como parte de un intento.

Esto es defensa en profundidad, no un sustituto de clasificar los datos que maneja cada integración. Una org debería evitar habilitar el logging completo de payloads para APIs sensibles salvo que exista una necesidad definida y una política de retención.

## Compartición y acceso

Los servicios operativos usan semántica de sharing explícita/heredada en lugar de depender de un sharing por defecto accidental. El DML interno del framework lo realizan intencionadamente servicios Apex; los administradores reciben un permission set empaquetado para inspeccionar/gestionar registros directamente.

El código consumidor debería exponer la funcionalidad del framework a los usuarios finales solo a través de su propia frontera de autorización.

## Frontera de confianza de la idempotencia

`IdempotencyEnabled__c = true` es una afirmación de seguridad/fiabilidad sobre el **sistema remoto**, no sobre Salesforce.

Habilítalo solo cuando la API remota garantice que peticiones repetidas con la misma clave configurada no repiten el efecto secundario de negocio. Si esa garantía no existe, las operaciones inciertas permanecen en `UNKNOWN` para reconciliación/revisión manual en lugar de reintentarse a ciegas.

## Retención de datos

`IntegrationAttempt__c` puede crecer rápidamente en orgs de alto volumen. Define políticas de retención/archivado antes de habilitar el logging detallado de payloads o de desplegar el framework a escala.

## Consideraciones del paquete

El paquete inicial no tiene namespace y está pensado para distribución privada/reutilizable como paquete 2GP Unlocked. Si el proyecto llegara a plantearse una distribución Managed 2GP/AppExchange, las decisiones de namespace y de superficie de API deberían revisarse antes de esa migración.
