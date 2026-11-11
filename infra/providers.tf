terraform {
  required_version = ">= 0.14.0"

  required_providers {
    openstack = {
      source  = "terraform-provider-openstack/openstack"
      version = "~> 1.53.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "openstack" {
  application_credential_id     = var.openstack_application_credential_id
  application_credential_secret = var.openstack_application_credential_secret
  auth_url                      = var.openstack_auth_url
  region                        = var.openstack_region
}

resource "random_password" "vm" {
  length           = 10
  special          = true
  override_special = "!@#$%&*+-_="
}
