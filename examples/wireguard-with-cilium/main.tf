provider "aws" {
  region = var.region
}

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  token                  = data.aws_eks_cluster_auth.this.token
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
    token                  = data.aws_eks_cluster_auth.this.token
  }
}

provider "kubectl" {
  apply_retry_count      = 10
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  load_config_file       = false
  token                  = data.aws_eks_cluster_auth.this.token
}

data "aws_eks_cluster_auth" "this" {
  name = module.eks.cluster_name
}

data "aws_availability_zones" "available" {}

locals {
  name   = basename(path.cwd)

  vpc_cidr = "10.0.0.0/16"
  azs      = slice(data.aws_availability_zones.available.names, 0, 3)


  tags = {
    Blueprint  = local.name
    GithubRepo = "github.com/weavegitops/terraform-aws-eks-blueprints"
    creator = var.creator_email
    environment = "demo3"
    customer ="weaveworks-cx"
    deployed = "Terraform"
    projectGid = "99999"
    region = var.region
    sshKeyName = "sademo"
    version = var.kubernetes_version
    eksClusterName = var.cluster_name
  }
}

################################################################################
# Cluster
################################################################################

#tfsec:ignore:aws-eks-enable-control-plane-logging
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 19.9"

  cluster_name                   = var.cluster_name
  cluster_version                = var.kubernetes_version
  cluster_endpoint_public_access = true

  # EKS Addons
  cluster_addons = {
    coredns    = {}
    kube-proxy = {}
    vpc-cni    = {}
  }

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  eks_managed_node_groups = {
    initial = {
      instance_types = ["m5.large"]

      # BottleRocket ships with kernel 5.10 so there is no need
      # to do anything special
      ami_type = "BOTTLEROCKET_x86_64"
      platform = "bottlerocket"

      min_size     = var.node_group_min
      max_size     = var.node_group_max
      desired_size = var.node_group_desired
    }
  }

  tags = local.tags
}

################################################################################
# Kubernetes Addons
################################################################################

module "eks_blueprints_kubernetes_addons" {
  source = "../../modules/kubernetes-addons"

  eks_cluster_id       = module.eks.cluster_name
  eks_cluster_endpoint = module.eks.cluster_endpoint
  eks_oidc_provider    = module.eks.oidc_provider
  eks_cluster_version  = module.eks.cluster_version

  # Wait on the `kube-system` profile before provisioning addons
  data_plane_wait_arn = join(",", [for group in module.eks.eks_managed_node_groups : group.node_group_arn])

  # Add-ons
  enable_cilium           = true
  cilium_enable_wireguard = true

  tags = local.tags
}

#---------------------------------------------------------------
# Sample App for Testing
#---------------------------------------------------------------

resource "kubectl_manifest" "server" {
  count = var.enable_example ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "Pod"
    metadata = {
      name = "server"
      labels = {
        blog = "wireguard"
        name = "server"
      }
    }
    spec = {
      containers = [
        {
          name  = "server"
          image = "nginx"
        }
      ]
      topologySpreadConstraints = [
        {
          maxSkew           = 1
          topologyKey       = "kubernetes.io/hostname"
          whenUnsatisfiable = "DoNotSchedule"
          labelSelector = {
            matchLabels = {
              blog = "wireguard"
            }
          }
        }
      ]
    }
  })

  depends_on = [
    module.eks_blueprints_kubernetes_addons
  ]
}

resource "kubectl_manifest" "service" {
  count = var.enable_example ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "Service"
    metadata = {
      name = "server"
    }
    spec = {
      selector = {
        name = "server"
      }
      ports = [
        {
          port = 80
        }
      ]
    }
  })
}

resource "kubectl_manifest" "client" {
  count = var.enable_example ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "Pod"
    metadata = {
      name = "client"
      labels = {
        blog = "wireguard"
        name = "client"
      }
    }
    spec = {
      containers = [
        {
          name    = "client"
          image   = "busybox"
          command = ["watch", "wget", "server"]
        }
      ]
      topologySpreadConstraints = [
        {
          maxSkew           = 1
          topologyKey       = "kubernetes.io/hostname"
          whenUnsatisfiable = "DoNotSchedule"
          labelSelector = {
            matchLabels = {
              blog = "wireguard"
            }
          }
        }
      ]
    }
  })

  depends_on = [
    kubectl_manifest.server[0]
  ]
}

################################################################################
# Supporting Resources
################################################################################

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 3.0"

  name = var.cluster_name
  cidr = local.vpc_cidr

  azs             = local.azs
  private_subnets = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 4, k)]
  public_subnets  = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 8, k + 48)]

  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true

  # Manage so we can name
  manage_default_network_acl    = true
  default_network_acl_tags      = { Name = "${var.cluster_name}-default" }
  manage_default_route_table    = true
  default_route_table_tags      = { Name = "${var.cluster_name}-default" }
  manage_default_security_group = true
  default_security_group_tags   = { Name = "${var.cluster_name}-default" }

  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
  }

  tags = local.tags
}
