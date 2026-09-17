terraform {
  required_version = ">= 1.6"
  required_providers {
    yandex = {
      source = "yandex-cloud/yandex"
      # Pinned exactly, plus the committed lockfile: a floating provider can
      # plan a destroy+recreate of the fleet.
      version = "0.127.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "4.1.0"
    }
  }
}

provider "yandex" {
  # null in CI (YC_TOKEN via OIDC); a laptop run points this at an SA key.
  service_account_key_file = var.service_account_key_file
  cloud_id                 = var.cloud_id
  folder_id                = var.folder_id
  zone                     = var.zone
}
