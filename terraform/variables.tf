# --- Yandex Cloud auth / placement ------------------------------------------
variable "service_account_key_file" {
  type        = string
  description = "Path to a Yandex service-account key JSON (yc iam key create --service-account-name ...)."
}

variable "cloud_id" {
  type = string
}

variable "folder_id" {
  type = string
}

variable "zone" {
  type        = string
  default     = "ru-central1-a"
  description = "Single zone for the whole fleet — cross-zone RTT would be a hidden variable."
}

variable "platform_id" {
  type        = string
  default     = "standard-v3" # Ice Lake; keep every role on ONE platform
  description = "CPU platform. Identical across all roles so the proxy host isn't a different microarch."
}

# --- image ------------------------------------------------------------------
variable "image_source_url" {
  type        = string
  description = "Object Storage URL of the NixOS qcow2 built by `make image` (e.g. https://storage.yandexcloud.net/<bucket>/zoxy-benchmark/nixos.qcow2)."
}

variable "disk_size" {
  type    = number
  default = 20
}

# --- access -----------------------------------------------------------------
variable "ssh_public_key" {
  type        = string
  description = "SSH public key contents; injected for the `bench` user on every host."
}

variable "allowed_ssh_cidr" {
  type        = string
  default     = "0.0.0.0/0"
  description = "Narrow this to your IP/32 in practice."
}

# --- fleet sizing -----------------------------------------------------------
# core_fraction is pinned to 100 everywhere in main.tf — a fractional vCPU
# shares a physical core and makes the numbers meaningless.
variable "proxy_cores" {
  type    = number
  default = 8
}
variable "proxy_memory" {
  type    = number
  default = 16
}

variable "loadgen_count" {
  type        = number
  default     = 2
  description = "Number of generator hosts. k6 burns far more CPU per request than a fast proxy spends serving it, so ONE equal-sized generator cannot saturate haproxy/envoy/zoxy — keep >=2, and bump further if the self-check voids high-rate cells."
}
variable "loadgen_cores" {
  type    = number
  default = 8
}
variable "loadgen_memory" {
  type    = number
  default = 16
}

variable "backend_count" {
  type        = number
  default     = 4
  description = "Origins. Must be >= the largest backend_counts entry in scenarios/matrix.yaml (run.sh fails fast otherwise), and aggregate backend capacity must exceed the proxy's; the self-check voids cells where a backend saturates first."
}
variable "backend_cores" {
  type    = number
  default = 4
}
variable "backend_memory" {
  type    = number
  default = 8
}
