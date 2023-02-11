terraform {
  cloud {
    organization = "bingnet"  # customize to your tf cloud org name

    workspaces {
      name = "linode-lke-lab"  # unique remote state workspace for this tf plan
    }
  }

  required_providers {
     local = {
      version = "~> 2.1"
    }
    linode = {
      source  = "linode/linode"
      version = "1.29.4"
    }
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = "1.13.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "2.5.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "2.0.1"
    }
  }
}

provider "linode" {
  token = var.token
}

resource "linode_lke_cluster" "linode_lke" {
    label       = var.label
    k8s_version = var.k8s_version
    region      = var.region
    tags        = var.tags

    dynamic "pool" {
        for_each = var.pools
        content {
            type  = pool.value["type"]
            count = pool.value["count"]
        }
    }
}

provider "helm" {
  kubernetes {
    host                   = yamldecode(base64decode(linode_lke_cluster.linode_lke.kubeconfig)).clusters[0].cluster.server
    token                  = yamldecode(base64decode(linode_lke_cluster.linode_lke.kubeconfig)).users[0].user.token
    cluster_ca_certificate = base64decode(yamldecode(base64decode(linode_lke_cluster.linode_lke.kubeconfig)).clusters[0].cluster.certificate-authority-data)
  }
}

provider "kubernetes" {
  host                   = yamldecode(base64decode(linode_lke_cluster.linode_lke.kubeconfig)).clusters[0].cluster.server
  token                  = yamldecode(base64decode(linode_lke_cluster.linode_lke.kubeconfig)).users[0].user.token
  cluster_ca_certificate = base64decode(yamldecode(base64decode(linode_lke_cluster.linode_lke.kubeconfig)).clusters[0].cluster.certificate-authority-data)
}

provider "kubectl" {     # duplcates config of provider "kubernetes" for cert-manager module
  host                   = yamldecode(base64decode(linode_lke_cluster.linode_lke.kubeconfig)).clusters[0].cluster.server
  token                  = yamldecode(base64decode(linode_lke_cluster.linode_lke.kubeconfig)).users[0].user.token
  cluster_ca_certificate = base64decode(yamldecode(base64decode(linode_lke_cluster.linode_lke.kubeconfig)).clusters[0].cluster.certificate-authority-data)
  load_config_file       = false
}

module "cert_manager" {
  source        = "terraform-iaac/cert-manager/kubernetes"

  cluster_issuer_email                   = var.email
  cluster_issuer_name                    = "cert-manager-global"
  cluster_issuer_private_key_secret_name = "cert-manager-global-secret"
  additional_set = [{
    name = "enableCertificateOwnerRef"
    value = "true"
  }]
}

resource "helm_release" "trust_manager" {
  depends_on   = [module.cert_manager]
  chart      = "trust-manager"
  repository = "https://charts.jetstack.io"
  name       = "trust-manager"
  namespace  = module.cert_manager.namespace
}

resource "helm_release" "ingress-nginx" {
  depends_on   = [module.cert_manager]
  name       = "ingress-nginx-release"
  repository = "https://kubernetes.github.io/ingress-nginx"
  chart      = "ingress-nginx"
}

resource "helm_release" "ziti-console" {
  depends_on = [helm_release.ingress-nginx]
  name = "ziti-console-release"
  chart = "./charts/ziti-console"
  values = ["${file("ziti-console-release-values.yaml")}"]
}

resource "helm_release" "ziti-controller" {
  depends_on = [helm_release.trust_manager]
  namespace = "ziti-controller"
  create_namespace = true
  name = "ziti-controller-release"
  chart = "./charts/ziti-controller"
  set {
    name = "advertisedHost"
    value = "ziti.lke.bingnet.cloud"
  }
  set {
    name = "persistence.storageClass"
    value = "linode-block-storage"
  }
}

