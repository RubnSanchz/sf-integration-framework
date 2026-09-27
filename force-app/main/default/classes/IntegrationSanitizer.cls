public class IntegrationSanitizer {
    // Matched case-insensitively, so apiKey/APIKEY/apikey need a single entry.
    // Snake_case and camelCase spellings are different keys and both are listed.
    @TestVisible
    private static final List<String> SENSITIVE_KEYS = new List<String>{
        'authorization',
        'password',
        'secret',
        'token',
        'access_token',
        'accessToken',
        'refresh_token',
        'refreshToken',
        'client_secret',
        'clientSecret',
        'api_key',
        'apiKey'
    };

    @TestVisible
    private static final String TRUNCATION_SUFFIX = '...[TRUNCATED]';
    private static final String REDACTED = '[REDACTED]';
    private static final Integer DEFAULT_MAX_CHARS = 12000;

    // One alternation instead of two replaceAll per key. The keys hold no regex
    // metacharacters, so they go into the pattern as they are.
    private static final String KEY_ALTERNATION = buildAlternation();

    private static final Pattern JSON_SECRET = Pattern.compile(
        '(?i)("(?:' + KEY_ALTERNATION + ')"\\s*:\\s*")[^"]*(")'
    );

    // The lookbehind stops a generic key from matching the tail of a longer one.
    private static final Pattern QUERY_SECRET = Pattern.compile(
        '(?i)(?<![A-Za-z0-9_])((?:' + KEY_ALTERNATION + ')=)[^&\\s"]*'
    );

    private static final Pattern BEARER_TOKEN = Pattern.compile(
        '(?i)(bearer\\s+)[A-Za-z0-9\\-._~+/]+=*'
    );

    public static String sanitize(String value, Integer maxChars) {
        if (value == null) {
            return null;
        }

        String sanitized = JSON_SECRET.matcher(value).replaceAll('$1' + REDACTED + '$2');
        sanitized = QUERY_SECRET.matcher(sanitized).replaceAll('$1' + REDACTED);
        sanitized = BEARER_TOKEN.matcher(sanitized).replaceAll('$1' + REDACTED);

        Integer limitSize = maxChars == null || maxChars <= 0 ? DEFAULT_MAX_CHARS : maxChars;
        if (sanitized.length() <= limitSize) {
            return sanitized;
        }

        // The suffix counts towards the limit: the result never exceeds maxChars.
        Integer keep = limitSize - TRUNCATION_SUFFIX.length();
        return keep <= 0
            ? sanitized.substring(0, limitSize)
            : sanitized.substring(0, keep) + TRUNCATION_SUFFIX;
    }

    public static Map<String, String> sanitizeHeaders(Map<String, String> headers) {
        Map<String, String> result = new Map<String, String>();
        if (headers == null) {
            return result;
        }

        for (String key : headers.keySet()) {
            Boolean sensitive = false;
            for (String candidate : SENSITIVE_KEYS) {
                if (key != null && key.toLowerCase().contains(candidate.toLowerCase())) {
                    sensitive = true;
                    break;
                }
            }
            result.put(key, sensitive ? REDACTED : headers.get(key));
        }
        return result;
    }

    // Longest first, so that access_token= is consumed whole instead of leaving
    // "access_" behind when the generic token= alternative matches first.
    private static String buildAlternation() {
        List<String> ordered = SENSITIVE_KEYS.clone();
        for (Integer i = 0; i < ordered.size(); i++) {
            Integer longest = i;
            for (Integer j = i + 1; j < ordered.size(); j++) {
                if (ordered[j].length() > ordered[longest].length()) {
                    longest = j;
                }
            }
            String swap = ordered[i];
            ordered[i] = ordered[longest];
            ordered[longest] = swap;
        }
        return String.join(ordered, '|');
    }
}
