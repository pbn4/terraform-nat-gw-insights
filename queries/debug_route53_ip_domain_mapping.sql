WITH date_params AS (
    -- Define date parameters once for reuse
    SELECT 
        '${year}' as query_year,
        '${month}' as query_month,
        '${day}' as query_day
)
SELECT 
    query_name as domain_name,
    json_extract_scalar(answer_json, '$.rdata') as resolved_ipv4_address,
    -- Count occurrences for frequency analysis
    COUNT(*) as query_count
FROM 
    "${r53_resolver_query_logs_table}"
CROSS JOIN UNNEST(answers) AS t(answer_json)
CROSS JOIN date_params
WHERE 
    -- Filter for recent data (adjust date range as needed)
    year = date_params.query_year 
    AND month = date_params.query_month 
    AND day = date_params.query_day
    -- Only include successful DNS queries
    AND rcode = 'NOERROR'
    -- Focus on A records (IPv4 addresses)
    AND query_type = 'A'
    -- Exclude internal/private domains if needed
    AND query_name NOT LIKE '%.local'
    AND query_name NOT LIKE '%.internal'
    -- Only include A record answers (not CNAME, MX, etc.)
    AND json_extract_scalar(answer_json, '$.type') = 'A'
    -- Only include valid IPv4 addresses (basic validation)
    AND json_extract_scalar(answer_json, '$.rdata') IS NOT NULL
    AND json_extract_scalar(answer_json, '$.rdata') != ''
GROUP BY 
    query_name, 
    json_extract_scalar(answer_json, '$.rdata')
ORDER BY 
    query_count DESC
