terraform {
  required_version = ">= 1.6"
  required_providers {
    yandex = {
      source = "yandex-cloud/yandex"
      # Pinned exactly, for the reason variables.tf spells out for image_id: a
      # floating constraint decides what to install at `init` time, so two runs
      # of the same config can plan differently, and a provider whose defaults
      # or schema moved plans a destroy+recreate of the whole fleet. The
      # lockfile is committed for the same reason — pin plus lockfile is the
      # pair; either alone still floats.
      version = "0.127.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "4.1.0"
    }
  }
}

provider "yandex" {
  # null in CI. The workflow exchanges a GitHub OIDC token for a short-lived
  # Yandex IAM token and exports it as YC_TOKEN, which the provider picks up
  # from the environment when no key file is given — nothing long-lived is
  # stored anywhere. A laptop run still points this at a downloaded SA key.
  service_account_key_file = var.service_account_key_file
  cloud_id                 = var.cloud_id
  folder_id                = var.folder_id
  zone                     = var.zone
}
