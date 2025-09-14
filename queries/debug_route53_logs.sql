WITH date_params AS (
    -- Define date parameters once for reuse
    SELECT 
        '${year}' as query_year,
        '${month}' as query_month,
        '${day}' as query_day
)
SELECT 
    *
FROM 
    "${r53_resolver_query_logs_table}"
CROSS JOIN date_params
WHERE 
    -- Filter for recent data (adjust date range as needed)
    year = date_params.query_year 
    AND month = date_params.query_month 
    AND day = date_params.query_day
ORDER BY 
    query_timestamp DESC
LIMIT 1000;
