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

# ─────────────────────────────────────────
# AWS Load Balancer Controller v2.11.0
# Helm chart version: 1.11.0
# ─────────────────────────────────────────

# Create IAM policy from downloaded JSON
resource "aws_iam_policy" "lbc" {
  name        = "${var.cluster_name}-lbc-policy"
  description = "IAM policy for AWS Load Balancer Controller"
  policy      = file("${path.module}/helm-values/lbc-iam-policy.json")
}

# IAM role using Pod Identity (EKS Pod Identity — modern approach)
resource "aws_iam_role" "lbc" {
  name = "${var.cluster_name}-lbc-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "pods.eks.amazonaws.com"
      }
      Action = [
        "sts:AssumeRole",
        "sts:TagSession"
      ]
    }]
  })

  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "lbc" {
  policy_arn = aws_iam_policy.lbc.arn
  role       = aws_iam_role.lbc.name
}

# Pod Identity Association — links the IAM role to the LBC service account
resource "aws_eks_pod_identity_association" "lbc" {
  cluster_name    = module.eks.cluster_name
  namespace       = "kube-system"
  service_account = "aws-load-balancer-controller"
  role_arn        = aws_iam_role.lbc.arn
}

# Install LBC via Helm
resource "helm_release" "lbc" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  namespace  = "kube-system"
  version    = "1.11.0"

  set {
    name  = "clusterName"
    value = module.eks.cluster_name
  }

  set {
    name  = "serviceAccount.create"
    value = "true"
  }

  set {
    name  = "serviceAccount.name"
    value = "aws-load-balancer-controller"
  }

  set {
    name  = "region"
    value = var.aws_region
  }

  set {
    name  = "vpcId"
    value = module.vpc.vpc_id
  }

  depends_on = [
    module.eks,
    aws_eks_pod_identity_association.lbc
  ]
}

# ─────────────────────────────────────────
# cert-manager v1.17.7
# Must be installed before Istio
# ─────────────────────────────────────────
resource "helm_release" "cert_manager" {
  name             = "cert-manager"
  repository       = "https://charts.jetstack.io"
  chart            = "cert-manager"
  namespace        = "cert-manager"
  version          = "1.17.7"
  create_namespace = true
  wait             = true

  set {
    name  = "crds.enabled"
    value = "true"
  }

  depends_on = [module.eks]
}

# ─────────────────────────────────────────
# Istio 1.28.0
# ─────────────────────────────────────────

# Istio base — installs CRDs and cluster-wide resources
resource "helm_release" "istio_base" {
  name             = "istio-base"
  repository       = "https://istio-release.storage.googleapis.com/charts"
  chart            = "base"
  namespace        = "istio-system"
  version          = "1.28.0"
  create_namespace = true
  wait             = true

  set {
    name  = "defaultRevision"
    value = "default"
  }

  depends_on = [
    module.eks,
    helm_release.cert_manager
  ]
}

# Istiod — Istio control plane
resource "helm_release" "istiod" {
  name       = "istiod"
  repository = "https://istio-release.storage.googleapis.com/charts"
  chart      = "istiod"
  namespace  = "istio-system"
  version    = "1.28.0"
  wait       = true

  set {
    name  = "pilot.resources.requests.cpu"
    value = "100m"
  }

  set {
    name  = "pilot.resources.requests.memory"
    value = "128Mi"
  }

  depends_on = [helm_release.istio_base]
}
