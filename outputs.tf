output "athena_saved_queries" {
  description = "AWS Athena saved queries for NAT Gateway insights with inline SQL content"
  value = {
    egress_traffic_with_dns = {
      id   = aws_athena_named_query.egress_traffic_with_dns.id
      name = aws_athena_named_query.egress_traffic_with_dns.name
    }
    ingress_traffic_with_dns = {
      id   = aws_athena_named_query.ingress_traffic_with_dns.id
      name = aws_athena_named_query.ingress_traffic_with_dns.name
    }
    egress_traffic_summary = {
      id   = aws_athena_named_query.egress_traffic_summary.id
      name = aws_athena_named_query.egress_traffic_summary.name
    }
    ingress_traffic_summary = {
      id   = aws_athena_named_query.ingress_traffic_summary.id
      name = aws_athena_named_query.ingress_traffic_summary.name
    }
    debug_route53_ip_domain_mapping = {
      id   = aws_athena_named_query.debug_route53_ip_domain_mapping.id
      name = aws_athena_named_query.debug_route53_ip_domain_mapping.name
    }
    debug_route53_logs = {
      id   = aws_athena_named_query.debug_route53_logs.id
      name = aws_athena_named_query.debug_route53_logs.name
    }
  }
}

output "athena_database_name" {
  description = "Name of the Athena database for NAT Gateway insights"
  value       = aws_glue_catalog_database.nat_analysis.name
}

output "athena_table_names" {
  description = "Names of the Athena tables for NAT Gateway insights"
  value = {
    nat_gw_eni_flow_logs    = aws_glue_catalog_table.nat_gw_eni_flow_logs.name
    r53_resolver_query_logs = aws_glue_catalog_table.r53_resolver_query_logs.name
  }
}

output "athena_workgroup" {
  description = "Athena workgroup for NAT Gateway insights"
  value = {
    id   = aws_athena_workgroup.nat_insights.id
    name = aws_athena_workgroup.nat_insights.name
    arn  = aws_athena_workgroup.nat_insights.arn
  }
}

output "athena_results_bucket" {
  description = "S3 bucket for Athena query results"
  value = {
    id   = module.s3_bucket_athena_results.s3_bucket_id
    arn  = module.s3_bucket_athena_results.s3_bucket_arn
    name = local.s3_bucket_athena_results_name
  }
}
