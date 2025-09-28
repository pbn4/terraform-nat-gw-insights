WITH date_params AS (
    -- Define date parameters once for reuse
    SELECT 
        '${year}' as query_year,
        '${month}' as query_month,
        '${day}' as query_day,
        '${hour}' as query_hour
),
dns_resolutions AS (
    -- Get DNS A record resolutions from Route53 logs
    SELECT 
        json_extract_scalar(answer_json, '$.rdata') as resolved_ip,
        query_name as domain_name,
        query_timestamp as dns_timestamp
    FROM 
        "${r53_resolver_query_logs_table}"
    CROSS JOIN UNNEST(answers) AS t(answer_json)
    CROSS JOIN date_params
    WHERE 
        year = date_params.query_year 
        AND month = date_params.query_month 
        AND day = date_params.query_day
        AND rcode = 'NOERROR'
        AND query_type = 'A'
        AND json_extract_scalar(answer_json, '$.type') = 'A'
        AND json_extract_scalar(answer_json, '$.rdata') IS NOT NULL
        AND json_extract_scalar(answer_json, '$.rdata') != ''
),
flow_traffic AS (
    -- Get ingress traffic from flow logs
    SELECT 
        srcaddr as internet_source_ip,
        dstaddr as private_destination_ip,
        SUM(bytes) as total_bytes_ingress,
        SUM(packets) as total_packets_ingress,
        COUNT(*) as total_flows
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
            (srcaddr LIKE '172.%' AND CAST(SPLIT_PART(srcaddr, '.', 2) AS INT) BETWEEN 16 AND 31) OR 
            (srcaddr LIKE '192.168.%')
        )
        AND NOT (srcaddr LIKE '169.254.%')
        AND NOT (srcaddr LIKE '224.%')
        AND NOT (srcaddr LIKE '239.%')
    GROUP BY 
        srcaddr, dstaddr
)
SELECT 
    ft.internet_source_ip,
    -- Get the most recent domain name for this IP
    (SELECT domain_name 
     FROM dns_resolutions dr 
     WHERE dr.resolved_ip = ft.internet_source_ip 
     ORDER BY dr.dns_timestamp DESC 
     LIMIT 1) as resolved_domain_name,
    COUNT(DISTINCT ft.private_destination_ip) as unique_private_destinations,
    SUM(ft.total_bytes_ingress) as total_bytes_ingress,
    SUM(ft.total_packets_ingress) as total_packets_ingress,
    SUM(ft.total_flows) as total_flows,
    -- Calculate traffic rate
    ROUND(SUM(ft.total_bytes_ingress) / 1024.0 / 1024.0, 2) as total_mb_ingress,
    ROUND(SUM(ft.total_bytes_ingress) / 1024.0 / 1024.0 / 1024.0, 2) as total_gb_ingress,
    -- Show if we have DNS resolution for this IP
    CASE 
        WHEN (SELECT COUNT(*) FROM dns_resolutions dr WHERE dr.resolved_ip = ft.internet_source_ip) > 0 
        THEN 'DNS_RESOLVED' 
        ELSE 'NO_DNS_DATA' 
    END as dns_status
FROM 
    flow_traffic ft
GROUP BY 
    ft.internet_source_ip
ORDER BY 
    total_bytes_ingress DESC
LIMIT 100;
