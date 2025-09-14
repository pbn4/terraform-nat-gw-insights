terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

module "this" {
  source  = "pbn4/nat-gw-insights/aws"

  nat_gateway_id = var.nat_gateway_id
}