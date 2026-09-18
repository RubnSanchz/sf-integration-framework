public class IntegrationSanitizer {
    @TestVisible
    private static final List<String> SENSITIVE_KEYS = new List<String>{
        'authorization',
        'access_token',
        'refresh_token',
        'client_secret',
        'password',
        'api_key',
        'apikey'
    };

    public static String sanitize(String value, Integer maxChars) {
        if (value == null) {
            return null;
        }

        String sanitized = value;
        for (String key : SENSITIVE_KEYS) {
            sanitized = sanitized.replaceAll(
                '(?i)(["\\']?' + key + '["\\']?\\s*[:=]\\s*["\\']?)[^"\\',}\\s]+',
                '$1[REDACTED]'
            );
        }

        Integer limitSize = maxChars == null || maxChars <= 0 ? 12000 : maxChars;
        if (sanitized.length() > limitSize) {
            return sanitized.substring(0, limitSize) + '...[TRUNCATED]';
        }
        return sanitized;
    }

    public static Map<String, String> sanitizeHeaders(Map<String, String> headers) {
        Map<String, String> result = new Map<String, String>();
        if (headers == null) {
            return result;
        }

        for (String key : headers.keySet()) {
            Boolean sensitive = false;
            for (String candidate : SENSITIVE_KEYS) {
                if (key != null && key.toLowerCase().contains(candidate)) {
                    sensitive = true;
                    break;
                }
            }
            result.put(key, sensitive ? '[REDACTED]' : headers.get(key));
        }
        return result;
    }
}
