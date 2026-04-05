# infrastructure/vault/main.tf
#
# VAULT CONFIGURATION — Terraform
# ═══════════════════════════════════════════════════════════════════════════
# Configures Vault for GitOps multi-cluster:
#   - KV v2 secret engine per environment
#   - Kubernetes auth per cluster (each cluster authenticates independently)
#   - Policies for External Secrets Operator per environment
#   - AppRole auth for CI/CD pipelines
#   - Audit logging (required for compliance)
# ═══════════════════════════════════════════════════════════════════════════

terraform {
  required_version = ">= 1.6"

  required_providers {
    vault = {
      source  = "hashicorp/vault"
      version = "~> 3.25"
    }
  }

  backend "s3" {
    bucket         = "your-terraform-state"
    key            = "vault/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "terraform-locks"
  }
}

provider "vault" {
  address = var.vault_address
  # Auth via AppRole (not root token — never use root in automation)
  auth_login {
    path = "auth/approle/login"
    parameters = {
      role_id   = var.vault_role_id
      secret_id = var.vault_secret_id
    }
  }
}

# ── Variables ──────────────────────────────────────────────────────────────────
variable "vault_address" {
  description = "Vault server address"
  type        = string
}

variable "vault_role_id" {
  description = "AppRole role_id for Terraform auth"
  type        = string
  sensitive   = true
}

variable "vault_secret_id" {
  description = "AppRole secret_id for Terraform auth"
  type        = string
  sensitive   = true
}

variable "clusters" {
  description = "Map of cluster names to their Kubernetes API server addresses"
  type        = map(string)
  default = {
    management = "https://management-cluster.internal.example.com"
    dev        = "https://dev-cluster.internal.example.com"
    staging    = "https://staging-cluster.internal.example.com"
    prod       = "https://prod-cluster.internal.example.com"
  }
}

# ── Audit Logging ──────────────────────────────────────────────────────────────
# Every secret access is logged — required for SOC2/PCI compliance
resource "vault_audit" "file" {
  type = "file"
  path = "file"
  options = {
    file_path   = "/vault/logs/audit.log"
    log_raw     = "false"   # Never log raw secret values
    hmac_accessor = "true"
  }
}

resource "vault_audit" "syslog" {
  type = "syslog"
  path = "syslog"
  options = {
    facility = "AUTH"
    tag      = "vault"
  }
}

# ── KV v2 Secret Engines ───────────────────────────────────────────────────────
# Separate mount per environment for blast-radius control
resource "vault_mount" "kv" {
  for_each = toset(["secret", "secret-dev", "secret-staging", "secret-prod"])

  path        = each.value
  type        = "kv"
  description = "KV v2 secrets — ${each.value}"

  options = {
    version = "2"
  }
}

# ── Kubernetes Auth — one per cluster ─────────────────────────────────────────
resource "vault_auth_backend" "kubernetes" {
  for_each = var.clusters

  type = "kubernetes"
  path = "kubernetes-${each.key}"
  description = "Kubernetes auth for ${each.key} cluster"
}

# Each cluster's auth backend needs the cluster's CA and host
# These are populated after cluster creation via a separate script
resource "vault_kubernetes_auth_backend_config" "clusters" {
  for_each = var.clusters

  backend            = vault_auth_backend.kubernetes[each.key].path
  kubernetes_host    = each.value
  # CA cert and token reviewer SA token are injected via CI after cluster bootstrap
  # kubernetes_ca_cert = data.vault_generic_secret.cluster_ca[each.key].data["ca"]
}

# ── Vault Roles for External Secrets Operator ─────────────────────────────────
# ESO on each cluster gets read-only access to its environment's secrets

locals {
  env_to_cluster = {
    dev     = "dev"
    staging = "staging"
    prod    = "prod"
  }
}

resource "vault_kubernetes_auth_backend_role" "external_secrets" {
  for_each = local.env_to_cluster

  backend                          = vault_auth_backend.kubernetes[each.value].path
  role_name                        = "external-secrets"
  bound_service_account_names      = ["external-secrets"]
  bound_service_account_namespaces = ["external-secrets"]
  token_ttl                        = 3600     # 1 hour
  token_max_ttl                    = 86400    # 24 hours max
  token_policies                   = [vault_policy.external_secrets[each.key].name]
}

resource "vault_policy" "external_secrets" {
  for_each = local.env_to_cluster

  name = "external-secrets-${each.key}"

  policy = <<-EOT
    # External Secrets Operator — read-only access to ${each.key} secrets

    # Environment-specific secrets (most apps use this path)
    path "secret-${each.key}/data/*" {
      capabilities = ["read"]
    }

    path "secret-${each.key}/metadata/*" {
      capabilities = ["read", "list"]
    }

    # Shared secrets (common across environments, e.g., internal CA cert)
    path "secret/data/shared/*" {
      capabilities = ["read"]
    }

    # Allow ESO to renew its own token
    path "auth/token/renew-self" {
      capabilities = ["update"]
    }

    path "auth/token/lookup-self" {
      capabilities = ["read"]
    }
  EOT
}

# ── ArgoCD Vault Role ─────────────────────────────────────────────────────────
# ArgoCD bootstrap script reads cluster credentials from Vault
resource "vault_kubernetes_auth_backend_role" "argocd" {
  backend                          = vault_auth_backend.kubernetes["management"].path
  role_name                        = "argocd"
  bound_service_account_names      = ["argocd-server", "argocd-application-controller"]
  bound_service_account_namespaces = ["argocd"]
  token_ttl                        = 1800
  token_policies                   = [vault_policy.argocd.name]
}

resource "vault_policy" "argocd" {
  name = "argocd"

  policy = <<-EOT
    # ArgoCD — read cluster registration secrets and its own admin password
    path "secret/data/argocd/*" {
      capabilities = ["read"]
    }

    path "secret/data/clusters/*" {
      capabilities = ["read"]
    }

    path "secret/data/github/*" {
      capabilities = ["read"]
    }
  EOT
}

# ── CI/CD AppRole ─────────────────────────────────────────────────────────────
# GitHub Actions uses AppRole auth to interact with Vault during pipelines
resource "vault_auth_backend" "approle" {
  type = "approle"
  path = "approle"
}

resource "vault_approle_auth_backend_role" "cicd" {
  backend               = vault_auth_backend.approle.path
  role_name             = "cicd"
  token_policies        = [vault_policy.cicd.name]
  token_ttl             = 900    # 15 min — short-lived for CI tokens
  token_max_ttl         = 1800
  secret_id_ttl         = 600   # Secret ID expires after 10 min
  secret_id_num_uses    = 1     # One-time use (prevents replay)
  bind_secret_id        = true
}

resource "vault_policy" "cicd" {
  name = "cicd"

  policy = <<-EOT
    # CI/CD pipeline — write image tags, read signing keys
    # Deliberately minimal — CI should not read app secrets

    path "secret/data/cicd/*" {
      capabilities = ["read"]
    }

    # Allow CI to read the cosign signing key for image signing
    path "secret/data/cosign/private-key" {
      capabilities = ["read"]
    }
  EOT
}

# ── Outputs ───────────────────────────────────────────────────────────────────
output "external_secrets_role_names" {
  description = "Vault role names for External Secrets Operator per environment"
  value       = { for env, _ in local.env_to_cluster : env => vault_kubernetes_auth_backend_role.external_secrets[env].role_name }
}

output "cicd_role_id" {
  description = "AppRole role_id for CI/CD pipelines"
  value       = vault_approle_auth_backend_role.cicd.role_id
  sensitive   = true
}
