public class IntegrationHandlerFactory {
    public static IntegrationOperationHandler create(String className) {
        if (String.isBlank(className)) {
            throw new IntegrationHandlerException('HandlerClass__c is required.');
        }

        Type handlerType = Type.forName(className);
        if (handlerType == null) {
            throw new IntegrationHandlerException('Handler class not found: ' + className);
        }

        Object instance = handlerType.newInstance();
        if (!(instance instanceof IntegrationOperationHandler)) {
            throw new IntegrationHandlerException(
                className + ' must implement IntegrationOperationHandler.'
            );
        }
        return (IntegrationOperationHandler) instance;
    }

    public class IntegrationHandlerException extends Exception {}
}
