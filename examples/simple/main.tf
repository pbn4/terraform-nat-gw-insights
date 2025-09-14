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

module "nat_gateway_insights" {
  source = "../../"

  nat_gateway_id = var.nat_gateway_id
}