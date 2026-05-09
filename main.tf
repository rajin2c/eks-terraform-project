# ─────────────────────────────────────────
# Data Sources
# ─────────────────────────────────────────
data "aws_availability_zones" "available" {
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

data "aws_caller_identity" "current" {}

# ─────────────────────────────────────────
# Local Values
# ─────────────────────────────────────────
locals {
  # Use first 2 AZs in the region
  azs = slice(data.aws_availability_zones.available.names, 0, 2)

  tags = {
    Project     = "eks-terraform"
    Environment = var.environment
    ManagedBy   = "terraform"
    Owner       = "rajin"
  }
}

# ─────────────────────────────────────────
# VPC — terraform-aws-modules/vpc v6.6.1
# ─────────────────────────────────────────
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "6.6.1"

  name = "${var.cluster_name}-vpc"
  cidr = var.vpc_cidr

  # 2 AZs — enough for dev/learning (use 3 for production)
  azs             = local.azs
  private_subnets = [for k, v in local.azs : cidrsubnet(var.vpc_cidr, 4, k)]
  public_subnets  = [for k, v in local.azs : cidrsubnet(var.vpc_cidr, 8, k + 48)]

  # Single NAT GW — saves cost (use one_nat_gateway_per_az for production)
  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true
  enable_dns_support   = true

  # Required tags for EKS to discover subnets for load balancers
  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
    # Required for Karpenter node discovery
    "karpenter.sh/discovery" = var.cluster_name
  }

  tags = local.tags
}
