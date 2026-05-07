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
