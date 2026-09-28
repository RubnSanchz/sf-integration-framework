@IsTest
private class IntegrationSanitizerTest {
    @IsTest
    static void sanitizerRedactsSecretsAndTruncatesPayloads() {
        String payload = '{"access_token":"secret","password":"hidden","value":"safe"}';
        String sanitized = IntegrationSanitizer.sanitize(payload, 1000);

        System.assert(!sanitized.contains('secret'));
        System.assert(!sanitized.contains('hidden'));
        System.assert(sanitized.contains('[REDACTED]'));
        System.assert(sanitized.contains('safe'), 'Non-sensitive values must survive.');

        Map<String, String> headers = IntegrationSanitizer.sanitizeHeaders(
            new Map<String, String>{'Authorization' => 'Bearer abc', 'Accept' => 'application/json'}
        );
        System.assertEquals('[REDACTED]', headers.get('Authorization'));
        System.assertEquals('application/json', headers.get('Accept'));
    }

    @IsTest
    static void sanitizerTruncationFitsWithinTheLimit() {
        String source = '0123456789'.repeat(10);

        String truncated = IntegrationSanitizer.sanitize(source, 20);
        System.assertEquals(20, truncated.length(), 'The suffix counts towards maxChars.');
        System.assert(truncated.endsWith('...[TRUNCATED]'));
        System.assertEquals('012345', truncated.substring(0, 6));

        System.assertEquals(
            '12345',
            IntegrationSanitizer.sanitize('12345', 5),
            'A value exactly at the limit is untouched.'
        );
        System.assertEquals(
            '12345',
            IntegrationSanitizer.sanitize('1234567890', 5),
            'With no room for the suffix the value is only cut.'
        );
    }

    @IsTest
    static void sanitizerRedactsEveryKnownSecretKey() {
        for (String key : IntegrationSanitizer.SENSITIVE_KEYS) {
            String json = IntegrationSanitizer.sanitize('{"' + key + '":"leak-me"}', 1000);
            System.assert(
                !json.contains('leak-me'),
                'JSON key not redacted: ' + key + ' -> ' + json
            );

            String query = IntegrationSanitizer.sanitize('a=1&' + key + '=leak-me&b=2', 1000);
            System.assert(
                !query.contains('leak-me'),
                'Query key not redacted: ' + key + ' -> ' + query
            );
            System.assert(query.contains('b=2'), 'Redaction must stop at the separator.');
        }
    }

    @IsTest
    static void sanitizerRedactsBearerTokensInFreeText() {
        String sanitized = IntegrationSanitizer.sanitize(
            'Callout failed with header Authorization: Bearer eyJhbGciOi.Jz-9_x',
            1000
        );

        System.assert(!sanitized.contains('eyJhbGciOi'), sanitized);
        System.assert(sanitized.contains('Bearer [REDACTED]'), sanitized);
    }
}
