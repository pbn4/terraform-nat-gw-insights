locals {
  s3_bucket_r53_resolver_query_logs_name = "r53-query-logs-${data.aws_nat_gateway.this.vpc_id}-${random_string.this.id}"
  s3_bucket_nat_gw_eni_flow_logs_name    = "eni-flow-logs-${var.nat_gateway_id}-${random_string.this.id}"
  s3_bucket_athena_results_name          = "athena-results-${var.nat_gateway_id}-${random_string.this.id}"

  s3_bucket_r53_resolver_query_logs_arn = "arn:${data.aws_partition.current.partition}:s3:::${local.s3_bucket_r53_resolver_query_logs_name}"
  s3_bucket_nat_gw_eni_flow_logs_arn    = "arn:${data.aws_partition.current.partition}:s3:::${local.s3_bucket_nat_gw_eni_flow_logs_name}"
}

data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

data "aws_region" "current" {}

data "aws_nat_gateway" "this" {
  id = var.nat_gateway_id
}

data "aws_vpc" "this" {
  id = data.aws_nat_gateway.this.vpc_id
}

resource "time_static" "current" {}

resource "random_string" "this" {
  length  = 4
  special = false
  upper   = false
}

### R53 Resolver Query Logs

data "aws_iam_policy_document" "firehose_assume_role_policy" {
  statement {
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["firehose.amazonaws.com"]
    }
    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "firehose_role" {
  name               = "${var.nat_gateway_id}-firehose-role"
  assume_role_policy = data.aws_iam_policy_document.firehose_assume_role_policy.json

  tags = var.tags
}

data "aws_iam_policy_document" "firehose_policy" {
  # Glue permissions
  statement {
    effect = "Allow"
    actions = [
      "glue:GetTable",
      "glue:GetTableVersion",
      "glue:GetTableVersions"
    ]
    resources = [
      "arn:${data.aws_partition.current.partition}:glue:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:catalog",
      "arn:${data.aws_partition.current.partition}:glue:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:database/${aws_glue_catalog_database.nat_analysis.name}",
      "arn:${data.aws_partition.current.partition}:glue:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:table/${aws_glue_catalog_database.nat_analysis.name}/${aws_glue_catalog_table.r53_resolver_query_logs.name}"
    ]
  }

  statement {
    effect = "Allow"
    actions = [
      "s3:AbortMultipartUpload",
      "s3:GetBucketLocation",
      "s3:GetObject",
      "s3:ListBucket",
      "s3:ListBucketMultipartUploads",
      "s3:PutObject"
    ]
    resources = [
      local.s3_bucket_r53_resolver_query_logs_arn,
      "${local.s3_bucket_r53_resolver_query_logs_arn}/*"
    ]
  }
}

resource "aws_iam_policy" "firehose_policy" {
  name   = "${var.nat_gateway_id}-firehose-policy"
  policy = data.aws_iam_policy_document.firehose_policy.json

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "firehose_policy_attachment" {
  role       = aws_iam_role.firehose_role.name
  policy_arn = aws_iam_policy.firehose_policy.arn
}

module "s3_bucket_r53_resolver_query_logs" {
  source  = "terraform-aws-modules/s3-bucket/aws"
  version = "5.7.0"

  force_destroy = true

  bucket = local.s3_bucket_r53_resolver_query_logs_name

  lifecycle_rule = [
    {
      id      = "r53-resolver-query-logs-expiration"
      enabled = true

      expiration = {
        days = var.logs_retention_days
      }
    }
  ]

  tags = var.tags
}

resource "aws_kinesis_firehose_delivery_stream" "r53_firehose" {
  name        = "${data.aws_nat_gateway.this.vpc_id}-r53-query-logs"
  destination = "extended_s3"

  extended_s3_configuration {
    role_arn            = aws_iam_role.firehose_role.arn
    bucket_arn          = module.s3_bucket_r53_resolver_query_logs.s3_bucket_arn
    prefix              = "AWSLogs/${data.aws_caller_identity.current.account_id}/vpcdnsquerylogs/${data.aws_nat_gateway.this.vpc_id}/year=!{timestamp:yyyy}/month=!{timestamp:MM}/day=!{timestamp:dd}/"
    error_output_prefix = "errors/AWSLogs/${data.aws_caller_identity.current.account_id}/vpcdnsquerylogs/${data.aws_nat_gateway.this.vpc_id}/year=!{timestamp:yyyy}/month=!{timestamp:MM}/day=!{timestamp:dd}/!{firehose:error-output-type}/"

    buffering_size     = 128 # MB
    buffering_interval = 300 # seconds
    compression_format = "UNCOMPRESSED"

    data_format_conversion_configuration {
      enabled = true

      input_format_configuration {
        deserializer {
          open_x_json_ser_de {}
        }
      }

      output_format_configuration {
        serializer {
          parquet_ser_de {}
        }
      }

      schema_configuration {
        role_arn      = aws_iam_role.firehose_role.arn
        database_name = aws_glue_catalog_database.nat_analysis.name
        table_name    = aws_glue_catalog_table.r53_resolver_query_logs.name
        region        = data.aws_region.current.region
      }
    }
  }

  tags = merge(var.tags, {
    LogDeliveryEnabled = "true"
  })
}

resource "aws_route53_resolver_query_log_config" "this" {
  name            = "${data.aws_nat_gateway.this.vpc_id}-r53-query-log-config"
  destination_arn = aws_kinesis_firehose_delivery_stream.r53_firehose.arn

  tags = var.tags
}

resource "aws_route53_resolver_query_log_config_association" "this" {
  resolver_query_log_config_id = aws_route53_resolver_query_log_config.this.id
  resource_id                  = data.aws_vpc.this.id
}

### NAT Gateway ENI Flow Logs

data "aws_iam_policy_document" "s3_bucket_nat_gw_eni_flow_logs_logs_delivery_policy" {
  statement {
    sid    = "AWSLogDeliveryWrite"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["delivery.logs.${data.aws_partition.current.dns_suffix}"]
    }

    actions = ["s3:PutObject"]

    resources = ["${local.s3_bucket_nat_gw_eni_flow_logs_arn}/AWSLogs/*"]

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }

    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:${data.aws_partition.current.partition}:logs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:*"]
    }
  }

  statement {
    sid    = "AWSLogDeliveryAclCheck"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["delivery.logs.${data.aws_partition.current.dns_suffix}"]
    }

    actions = ["s3:GetBucketAcl"]

    resources = [local.s3_bucket_nat_gw_eni_flow_logs_arn]

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:${data.aws_partition.current.partition}:logs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:*"]
    }
  }
}

module "s3_bucket_nat_gw_eni_flow_logs" {
  source  = "terraform-aws-modules/s3-bucket/aws"
  version = "5.7.0"

  force_destroy = true

  bucket = local.s3_bucket_nat_gw_eni_flow_logs_name

  attach_policy = true
  policy        = data.aws_iam_policy_document.s3_bucket_nat_gw_eni_flow_logs_logs_delivery_policy.json

  lifecycle_rule = [
    {
      id      = "r53-resolver-query-logs-expiration"
      enabled = true

      expiration = {
        days = var.logs_retention_days
      }
    }
  ]

  tags = var.tags
}

resource "aws_flow_log" "this" {
  log_destination      = module.s3_bucket_nat_gw_eni_flow_logs.s3_bucket_arn
  log_destination_type = "s3"
  traffic_type         = "ALL"
  eni_id               = data.aws_nat_gateway.this.network_interface_id

  destination_options {
    file_format        = "parquet"
    per_hour_partition = true
  }

  tags = var.tags
}

### S3 Bucket for Athena Results

module "s3_bucket_athena_results" {
  source  = "terraform-aws-modules/s3-bucket/aws"
  version = "5.7.0"

  force_destroy = true

  bucket = local.s3_bucket_athena_results_name

  lifecycle_rule = [
    {
      id      = "athena-results-expiration"
      enabled = true

      expiration = {
        days = 30 # Keep Athena results for 30 days
      }
    }
  ]

  tags = var.tags
}

### Glue Database

resource "aws_glue_catalog_database" "nat_analysis" {
  name = "${var.nat_gateway_id}-insights-nat-analysis"

  tags = var.tags
}

resource "aws_glue_catalog_table" "r53_resolver_query_logs" {
  name          = "${var.nat_gateway_id}-insights-r53-resolver-query-logs"
  database_name = aws_glue_catalog_database.nat_analysis.name

  table_type = "EXTERNAL_TABLE"

  parameters = {
    comment                     = "R53 Resolver Query Logs"
    EXTERNAL                    = "TRUE"
    "skip.header.line.count"    = "1"
    "projection.enabled"        = "true"
    "projection.year.type"      = "integer",
    "projection.year.digits"    = "4",
    "projection.year.range"     = "2023,2050",
    "projection.month.type"     = "integer",
    "projection.month.digits"   = "2",
    "projection.month.range"    = "01,12",
    "projection.day.type"       = "integer",
    "projection.day.digits"     = "2",
    "projection.day.range"      = "01,31",
    "storage.location.template" = "s3://${module.s3_bucket_r53_resolver_query_logs.s3_bucket_id}/AWSLogs/${data.aws_caller_identity.current.account_id}/vpcdnsquerylogs/${data.aws_nat_gateway.this.vpc_id}/year=$${year}/month=$${month}/day=$${day}/"
  }

  storage_descriptor {
    location      = "s3://${module.s3_bucket_r53_resolver_query_logs.s3_bucket_id}/AWSLogs/${data.aws_caller_identity.current.account_id}/vpcdnsquerylogs/${data.aws_nat_gateway.this.vpc_id}/"
    input_format  = "org.apache.hadoop.hive.ql.io.parquet.MapredParquetInputFormat"
    output_format = "org.apache.hadoop.hive.ql.io.parquet.MapredParquetOutputFormat"

    ser_de_info {
      name                  = "parquet"
      serialization_library = "org.apache.hadoop.hive.ql.io.parquet.serde.ParquetHiveSerDe"
    }

    columns {
      name = "version"
      type = "string"
    }
    columns {
      name = "query_timestamp"
      type = "timestamp"
    }
    columns {
      name = "query_name"
      type = "string"
    }
    columns {
      name = "query_type"
      type = "string"
    }
    columns {
      name = "query_class"
      type = "string"
    }
    columns {
      name = "rcode"
      type = "string"
    }
    columns {
      name = "answers"
      type = "array<string>"
    }
    columns {
      name = "srcaddr"
      type = "string"
    }
  }

  partition_keys {
    name = "year"
    type = "string"
  }
  partition_keys {
    name = "month"
    type = "string"
  }
  partition_keys {
    name = "day"
    type = "string"
  }
}

resource "aws_glue_catalog_table" "nat_gw_eni_flow_logs" {
  name          = "${var.nat_gateway_id}-insights-nat-gw-eni-flow-logs"
  database_name = aws_glue_catalog_database.nat_analysis.name

  table_type = "EXTERNAL_TABLE"

  parameters = {
    comment                     = "VPC Flow Logs"
    EXTERNAL                    = "TRUE"
    "skip.header.line.count"    = "1"
    "projection.enabled"        = "true"
    "projection.year.type"      = "integer",
    "projection.year.digits"    = "4",
    "projection.year.range"     = "2023,2050",
    "projection.month.type"     = "integer",
    "projection.month.digits"   = "2",
    "projection.month.range"    = "01,12",
    "projection.day.type"       = "integer",
    "projection.day.digits"     = "2",
    "projection.day.range"      = "01,31",
    "projection.hour.type"      = "integer",
    "projection.hour.digits"    = "2",
    "projection.hour.range"     = "00,23",
    "storage.location.template" = "s3://${module.s3_bucket_nat_gw_eni_flow_logs.s3_bucket_id}/AWSLogs/${data.aws_caller_identity.current.account_id}/vpcflowlogs/${data.aws_region.current.region}/$${year}/$${month}/$${day}/$${hour}/"
  }

  storage_descriptor {
    location = "s3://${module.s3_bucket_nat_gw_eni_flow_logs.s3_bucket_id}/AWSLogs/${data.aws_caller_identity.current.account_id}/vpcflowlogs/${data.aws_region.current.region}/"

    input_format  = "org.apache.hadoop.hive.ql.io.parquet.MapredParquetInputFormat"
    output_format = "org.apache.hadoop.hive.ql.io.parquet.MapredParquetOutputFormat"

    ser_de_info {
      name                  = "parquet"
      serialization_library = "org.apache.hadoop.hive.ql.io.parquet.serde.ParquetHiveSerDe"
    }

    columns {
      name = "version"
      type = "int"
    }
    columns {
      name = "account_id"
      type = "string"
    }
    columns {
      name = "interface_id"
      type = "string"
    }
    columns {
      name = "srcaddr"
      type = "string"
    }
    columns {
      name = "dstaddr"
      type = "string"
    }
    columns {
      name = "srcport"
      type = "int"
    }
    columns {
      name = "dstport"
      type = "int"
    }
    columns {
      name = "protocol"
      type = "bigint"
    }
    columns {
      name = "packets"
      type = "bigint"
    }
    columns {
      name = "bytes"
      type = "bigint"
    }
    columns {
      name = "start"
      type = "bigint"
    }
    columns {
      name = "end"
      type = "bigint"
    }
    columns {
      name = "action"
      type = "string"
    }
    columns {
      name = "log_status"
      type = "string"
    }
  }

  partition_keys {
    name = "year"
    type = "string"
  }
  partition_keys {
    name = "month"
    type = "string"
  }
  partition_keys {
    name = "day"
    type = "string"
  }
  partition_keys {
    name = "hour"
    type = "string"
  }
}

### Athena Workgroup

resource "aws_athena_workgroup" "nat_insights" {
  name        = "${var.nat_gateway_id}-nat-insights-workgroup"
  description = "Athena workgroup for NAT Gateway insights analysis"

  configuration {
    enforce_workgroup_configuration    = true
    publish_cloudwatch_metrics_enabled = true

    result_configuration {
      output_location = "s3://${module.s3_bucket_athena_results.s3_bucket_id}/"

      encryption_configuration {
        encryption_option = "SSE_S3"
      }
    }
  }

  tags = var.tags
}

### Athena Saved Queries

resource "aws_athena_named_query" "egress_traffic_with_dns" {
  name        = "01-egress-traffic-with-dns"
  description = "NAT Gateway egress traffic with DNS resolution showing domain names for internet destinations. Edit the date parameters in the query to analyze different time periods."
  database    = aws_glue_catalog_database.nat_analysis.name
  workgroup   = aws_athena_workgroup.nat_insights.name

  query = templatefile("${path.module}/queries/egress_traffic_with_dns.sql", {
    nat_gw_eni_flow_logs_table    = aws_glue_catalog_table.nat_gw_eni_flow_logs.name
    r53_resolver_query_logs_table = aws_glue_catalog_table.r53_resolver_query_logs.name
    year                          = formatdate("YYYY", time_static.current.rfc3339)
    month                         = formatdate("MM", time_static.current.rfc3339)
    day                           = formatdate("DD", time_static.current.rfc3339)
    hour                          = formatdate("hh", time_static.current.rfc3339)
  })
}

resource "aws_athena_named_query" "ingress_traffic_with_dns" {
  name        = "02-ingress-traffic-with-dns"
  description = "NAT Gateway ingress traffic with DNS resolution showing domain names for internet sources. Edit the date parameters in the query to analyze different time periods."
  database    = aws_glue_catalog_database.nat_analysis.name
  workgroup   = aws_athena_workgroup.nat_insights.name

  query = templatefile("${path.module}/queries/ingress_traffic_with_dns.sql", {
    nat_gw_eni_flow_logs_table    = aws_glue_catalog_table.nat_gw_eni_flow_logs.name
    r53_resolver_query_logs_table = aws_glue_catalog_table.r53_resolver_query_logs.name
    year                          = formatdate("YYYY", time_static.current.rfc3339)
    month                         = formatdate("MM", time_static.current.rfc3339)
    day                           = formatdate("DD", time_static.current.rfc3339)
    hour                          = formatdate("hh", time_static.current.rfc3339)
  })
}

resource "aws_athena_named_query" "egress_traffic_summary" {
  name        = "03-egress-traffic-summary"
  description = "NAT Gateway egress traffic summary showing top internet destinations by data volume. Edit the date parameters in the query to analyze different time periods."
  database    = aws_glue_catalog_database.nat_analysis.name
  workgroup   = aws_athena_workgroup.nat_insights.name

  query = templatefile("${path.module}/queries/egress_traffic_summary.sql", {
    nat_gw_eni_flow_logs_table = aws_glue_catalog_table.nat_gw_eni_flow_logs.name
    year                       = formatdate("YYYY", time_static.current.rfc3339)
    month                      = formatdate("MM", time_static.current.rfc3339)
    day                        = formatdate("DD", time_static.current.rfc3339)
    hour                       = formatdate("hh", time_static.current.rfc3339)
  })
}

resource "aws_athena_named_query" "ingress_traffic_summary" {
  name        = "04-ingress-traffic-summary"
  description = "NAT Gateway ingress traffic summary showing top internet sources by data volume. Edit the date parameters in the query to analyze different time periods."
  database    = aws_glue_catalog_database.nat_analysis.name
  workgroup   = aws_athena_workgroup.nat_insights.name

  query = templatefile("${path.module}/queries/ingress_traffic_summary.sql", {
    nat_gw_eni_flow_logs_table = aws_glue_catalog_table.nat_gw_eni_flow_logs.name
    year                       = formatdate("YYYY", time_static.current.rfc3339)
    month                      = formatdate("MM", time_static.current.rfc3339)
    day                        = formatdate("DD", time_static.current.rfc3339)
    hour                       = formatdate("hh", time_static.current.rfc3339)
  })
}

resource "aws_athena_named_query" "debug_route53_ip_domain_mapping" {
  name        = "05-debug-route53-ip-domain-mapping"
  description = "Debug query to analyze Route53 IP to domain name mappings and query frequency. Edit the date parameters in the query to analyze different time periods."
  database    = aws_glue_catalog_database.nat_analysis.name
  workgroup   = aws_athena_workgroup.nat_insights.name

  query = templatefile("${path.module}/queries/debug_route53_ip_domain_mapping.sql", {
    r53_resolver_query_logs_table = aws_glue_catalog_table.r53_resolver_query_logs.name
    year                          = formatdate("YYYY", time_static.current.rfc3339)
    month                         = formatdate("MM", time_static.current.rfc3339)
    day                           = formatdate("DD", time_static.current.rfc3339)
  })
}

resource "aws_athena_named_query" "debug_route53_logs" {
  name        = "06-debug-route53-logs"
  description = "Debug query to inspect raw Route53 resolver query logs. Edit the date parameters in the query to analyze different time periods."
  database    = aws_glue_catalog_database.nat_analysis.name
  workgroup   = aws_athena_workgroup.nat_insights.name

  query = templatefile("${path.module}/queries/debug_route53_logs.sql", {
    r53_resolver_query_logs_table = aws_glue_catalog_table.r53_resolver_query_logs.name
    year                          = formatdate("YYYY", time_static.current.rfc3339)
    month                         = formatdate("MM", time_static.current.rfc3339)
    day                           = formatdate("DD", time_static.current.rfc3339)
  })
}