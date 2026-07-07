variable "service_account_key_file" {
  type        = string
  description = "yc iam key create ... --output sa-key.json"
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
  description = "Single zone for all three hosts — cross-zone RTT would be a hidden variable."
}

variable "platform_id" {
  type        = string
  default     = "standard-v3" # keep every role on ONE platform
}

variable "ssh_public_key" {
  type = string
}

variable "allowed_cidr" {
  type        = string
  default     = "0.0.0.0/0"
  description = "CIDR allowed to reach ssh/grafana/prometheus — narrow to YOUR.IP/32"
}

variable "docker_version" {
  type        = string
  default     = "28.0" # apt version prefix pinned by cloud-init; same compose CLI everywhere
}

variable "disk_size" {
  type    = number
  default = 30
}

# Sizing: proxy is the SUT box; backend gets 2x its cores so the origin is
# never the bottleneck; loadgen is the biggest because open-loop generation +
# prometheus + grafana live there.
variable "proxy_cores" {
  type    = number
  default = 4
}
variable "proxy_memory" {
  type    = number
  default = 8
}
variable "backend_cores" {
  type    = number
  default = 8
}
variable "backend_memory" {
  type    = number
  default = 8
}
variable "loadgen_cores" {
  type    = number
  default = 16
}
variable "loadgen_memory" {
  type    = number
  default = 16
}
