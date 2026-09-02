variable "customer_number" {
  description = "netcup customer number (SCP). Can also be supplied via the NETCUP_CUSTOMER_NUMBER environment variable instead."
  type        = string
  default     = null
}

variable "scp_user_id" {
  description = "Numeric id of the SCP user that will own the firewall policy. Find it in the netcup SCP under Account > Users, or via `data.netcup_scp_user`. Required for the module to manage the firewall policy; leave null to skip firewall provisioning (guided by the `next_step` output)."
  type        = number
  default     = null
}

variable "server_id" {
  description = "Numeric id of the netcup server to adopt. Exactly one of server_id / server_name must be set."
  type        = number
  default     = null

  validation {
    condition     = (var.server_id != null || var.server_name != null) && (var.server_id == null || var.server_name == null)
    error_message = "Set exactly one of server_id or server_name (neither or both is invalid)."
  }
}

variable "server_name" {
  description = "Exact SCP name of the netcup server to adopt (resolved to an id via data source lookup). Exactly one of server_id / server_name must be set."
  type        = string
  default     = null
}

variable "allow_main_box_ipv4" {
  description = "IPv4 address of your main box; tang (TCP/80) accepts challenges from this address only."
  type        = string

  validation {
    condition     = can(cidrhost("${var.allow_main_box_ipv4}/32", 0))
    error_message = "Must be a single IPv4 address (a /32 is appended automatically when building the firewall source)."
  }
}

variable "allow_main_box_ipv6" {
  description = "Optional IPv6 address of your main box; also allowed to reach tang (TCP/80)."
  type        = string
  default     = null

  validation {
    condition     = var.allow_main_box_ipv6 == null || can(cidrhost("${var.allow_main_box_ipv6}/128", 0))
    error_message = "Must be a single IPv6 address (a /128 is appended automatically when building the firewall source)."
  }
}

variable "hostname" {
  description = "Hostname to set on the adopted server (SCP hostname attribute)."
  type        = string
}

locals {
  server_id_by_name = var.server_name != null ? [
    for s in data.netcup_scp_servers.all[0].scp_servers : s.id if s.name == var.server_name
  ] : []

  resolved_server_id = var.server_id != null ? var.server_id : (
    length(local.server_id_by_name) == 1 ? local.server_id_by_name[0] : null
  )
}
