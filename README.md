# EKS Terraform Project

Production EKS 1.34 cluster with Terraform.

## Stack
- EKS 1.34 (terraform-aws-modules/eks v21.19.0)
- Karpenter v1.9.0
- Istio 1.28.0
- AWS Load Balancer Controller v2.11.0
- kube-prometheus-stack 84.5.0
- cert-manager v1.17.7

## Daily Usage
```bash
terraform init    # First time only
terraform plan    # Review changes
terraform apply   # Spin up cluster
terraform destroy # ALWAYS run at end of session
```
