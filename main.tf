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

# ─────────────────────────────────────────
# EKS Cluster — terraform-aws-modules/eks v21.19.0
# ─────────────────────────────────────────
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "21.19.0"

  name               = var.cluster_name
  kubernetes_version = var.cluster_version

  # Networking
  vpc_id                   = module.vpc.vpc_id
  subnet_ids               = module.vpc.private_subnets
  control_plane_subnet_ids = module.vpc.private_subnets

  # Public endpoint — needed for kubectl access from WSL2
  endpoint_public_access = true

  # Gives your Terraform IAM user admin access to the cluster
  # Required to deploy resources into the cluster via Terraform
  enable_cluster_creator_admin_permissions = true

  # EKS Managed Add-ons
  addons = {
    coredns = {
      most_recent = true
    }
    kube-proxy = {
      most_recent = true
    }
    vpc-cni = {
      most_recent    = true
      before_compute = true
    }
    eks-pod-identity-agent = {
      most_recent    = true
      before_compute = true
    }
  }

  # Initial node group — runs Karpenter controller
  # Karpenter itself runs on these nodes, then manages all other nodes
  eks_managed_node_groups = {
    initial = {
      ami_type       = "AL2023_x86_64_STANDARD"
      instance_types = ["t3.medium"]

      min_size     = 1
      max_size     = 2
      desired_size = 1

      # Prevents Karpenter from managing its own controller nodes
      labels = {
        "karpenter.sh/controller" = "true"
      }

      taints = {
        addons = {
          key    = "CriticalAddonsOnly"
          value  = "true"
          effect = "NO_SCHEDULE"
        }
      }
    }
  }

  # Tag node security group for Karpenter discovery
  node_security_group_tags = {
    "karpenter.sh/discovery" = var.cluster_name
  }

  tags = local.tags
}

# ─────────────────────────────────────────
# Karpenter v1.9.0
# Uses EKS module built-in karpenter sub-module
# ─────────────────────────────────────────
module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "21.19.0"

  cluster_name = module.eks.cluster_name

  # Pod Identity association for the Karpenter controller
  create_pod_identity_association = true

  # IAM role for nodes that Karpenter provisions
  node_iam_role_use_name_prefix = false
  node_iam_role_name            = "${var.cluster_name}-karpenter-node"

  tags = local.tags
}

# Karpenter Helm chart — installs the controller
resource "helm_release" "karpenter" {
  name             = "karpenter"
  namespace        = "kube-system"
  repository       = "oci://public.ecr.aws/karpenter"
  chart            = "karpenter"
  version          = "1.9.0"
  create_namespace = false
  wait             = true
  wait_for_jobs    = true

  values = [
    <<-EOT
    settings:
      clusterName: ${module.eks.cluster_name}
      interruptionQueue: ${module.karpenter.queue_name}
    controller:
      resources:
        requests:
          cpu: 1
          memory: 1Gi
        limits:
          cpu: 1
          memory: 1Gi
    EOT
  ]

  depends_on = [
    module.eks,
    module.karpenter
  ]
}

# Apply EC2NodeClass
resource "kubectl_manifest" "karpenter_ec2nodeclass" {
  yaml_body = templatefile("${path.module}/modules/karpenter/ec2nodeclass.yaml", {
    cluster_name = var.cluster_name
  })

  depends_on = [helm_release.karpenter]
}

# Apply NodePool
resource "kubectl_manifest" "karpenter_nodepool" {
  yaml_body = templatefile("${path.module}/modules/karpenter/nodepool.yaml", {
    cluster_name = var.cluster_name
  })

  depends_on = [kubectl_manifest.karpenter_ec2nodeclass]
}
