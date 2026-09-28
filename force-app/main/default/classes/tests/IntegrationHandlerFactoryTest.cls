@IsTest
public class IntegrationHandlerFactoryTest {
    // Resolvable by name and instantiable, but not a handler. Public so that
    // Type.forName can reach it.
    public class NotAHandler {
        public NotAHandler() {}
    }

    private static String rejectionMessage(String className) {
        try {
            IntegrationHandlerFactory.create(className);
            return null;
        } catch (IntegrationHandlerFactory.IntegrationHandlerException ex) {
            return ex.getMessage();
        }
    }

    @IsTest
    static void aBlankHandlerClassIsRejected() {
        System.assert(rejectionMessage(null).contains('HandlerClass__c'), 'null');
        System.assert(rejectionMessage('').contains('HandlerClass__c'), 'empty');
        System.assert(rejectionMessage('   ').contains('HandlerClass__c'), 'blank');
    }

    @IsTest
    static void aClassThatDoesNotExistIsRejectedByName() {
        String message = rejectionMessage('NoSuchClassAnywhere');

        System.assertNotEquals(null, message);
        System.assert(
            message.contains('NoSuchClassAnywhere'),
            'The message has to name the class, it is the only clue an admin gets: ' + message
        );
    }

    @IsTest
    static void aClassThatDoesNotImplementTheInterfaceIsRejected() {
        String message = rejectionMessage('IntegrationHandlerFactoryTest.NotAHandler');

        System.assertNotEquals(null, message, 'Resolving by name is not enough.');
        System.assert(message.contains('IntegrationOperationHandler'), message);
    }

    @IsTest
    static void aValidHandlerIsInstantiated() {
        IntegrationOperationHandler handler =
            IntegrationHandlerFactory.create(IntegrationTestDataFactory.HANDLER_CLASS);

        System.assertNotEquals(null, handler);
        System.assertEquals(
            true,
            handler instanceof IntegrationExecutionJobTest.TestHandler,
            'The factory returns the configured class, not a wrapper.'
        );
    }
}
