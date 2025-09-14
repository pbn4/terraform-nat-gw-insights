WITH date_params AS (
    -- Define date parameters once for reuse
    SELECT 
        '${year}' as query_year,
        '${month}' as query_month,
        '${day}' as query_day,
        '${hour}' as query_hour
)
SELECT 
    dstaddr as internet_destination_ip,
    COUNT(DISTINCT srcaddr) as unique_private_sources,
    SUM(bytes) as total_bytes_egress,
    SUM(packets) as total_packets_egress,
    COUNT(*) as total_flows,
    -- Calculate traffic rate
    ROUND(SUM(bytes) / 1024.0 / 1024.0, 2) as total_mb_egress,
    ROUND(SUM(bytes) / 1024.0 / 1024.0 / 1024.0, 2) as total_gb_egress
FROM 
    "${nat_gw_eni_flow_logs_table}"
CROSS JOIN date_params
WHERE 
    year = date_params.query_year 
    AND month = date_params.query_month 
    AND day = date_params.query_day
    AND hour = date_params.query_hour
    AND action = 'ACCEPT'
    -- EGRESS: exclude private destination IPs
    AND NOT (
        (dstaddr LIKE '10.%') OR 
        (dstaddr LIKE '172.1%' AND CAST(SPLIT_PART(dstaddr, '.', 2) AS INT) BETWEEN 16 AND 31) OR 
        (dstaddr LIKE '192.168.%')
    )
    AND NOT (dstaddr LIKE '169.254.%')
    AND NOT (dstaddr LIKE '224.%')
    AND NOT (dstaddr LIKE '239.%')
GROUP BY 
    dstaddr
ORDER BY 
    total_bytes_egress DESC
LIMIT 100;
