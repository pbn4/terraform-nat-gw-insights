WITH date_params AS (
    -- Define date parameters once for reuse
    SELECT 
        '${year}' as query_year,
        '${month}' as query_month,
        '${day}' as query_day,
        '${hour}' as query_hour
)
SELECT 
    srcaddr as internet_source_ip,
    COUNT(DISTINCT dstaddr) as unique_private_destinations,
    SUM(bytes) as total_bytes_ingress,
    SUM(packets) as total_packets_ingress,
    COUNT(*) as total_flows,
    -- Calculate traffic rate
    ROUND(SUM(bytes) / 1024.0 / 1024.0, 2) as total_mb_ingress,
    ROUND(SUM(bytes) / 1024.0 / 1024.0 / 1024.0, 2) as total_gb_ingress
FROM 
    "${nat_gw_eni_flow_logs_table}"
CROSS JOIN date_params
WHERE 
    year = date_params.query_year 
    AND month = date_params.query_month 
    AND day = date_params.query_day
    AND hour = date_params.query_hour
    AND action = 'ACCEPT'
    -- INGRESS: exclude private source IPs
    AND NOT (
        (srcaddr LIKE '10.%') OR 
        (srcaddr LIKE '172.1%' AND CAST(SPLIT_PART(srcaddr, '.', 2) AS INT) BETWEEN 16 AND 31) OR 
        (srcaddr LIKE '192.168.%')
    )
    AND NOT (srcaddr LIKE '169.254.%')
    AND NOT (srcaddr LIKE '224.%')
    AND NOT (srcaddr LIKE '239.%')
GROUP BY 
    srcaddr
ORDER BY 
    total_bytes_ingress DESC
LIMIT 100;
