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
    -- Get egress traffic from flow logs
    SELECT 
        dstaddr as internet_destination_ip,
        srcaddr as private_source_ip,
        SUM(bytes) as total_bytes_egress,
        SUM(packets) as total_packets_egress,
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
        dstaddr, srcaddr
)
SELECT 
    ft.internet_destination_ip,
    -- Get the most recent domain name for this IP
    (SELECT domain_name 
     FROM dns_resolutions dr 
     WHERE dr.resolved_ip = ft.internet_destination_ip 
     ORDER BY dr.dns_timestamp DESC 
     LIMIT 1) as resolved_domain_name,
    COUNT(DISTINCT ft.private_source_ip) as unique_private_sources,
    SUM(ft.total_bytes_egress) as total_bytes_egress,
    SUM(ft.total_packets_egress) as total_packets_egress,
    SUM(ft.total_flows) as total_flows,
    -- Calculate traffic rate
    ROUND(SUM(ft.total_bytes_egress) / 1024.0 / 1024.0, 2) as total_mb_egress,
    ROUND(SUM(ft.total_bytes_egress) / 1024.0 / 1024.0 / 1024.0, 2) as total_gb_egress,
    -- Show if we have DNS resolution for this IP
    CASE 
        WHEN (SELECT COUNT(*) FROM dns_resolutions dr WHERE dr.resolved_ip = ft.internet_destination_ip) > 0 
        THEN 'DNS_RESOLVED' 
        ELSE 'NO_DNS_DATA' 
    END as dns_status
FROM 
    flow_traffic ft
GROUP BY 
    ft.internet_destination_ip
ORDER BY 
    total_bytes_egress DESC
LIMIT 100;
