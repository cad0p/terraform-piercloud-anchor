provider "netcup" {
  customer_number = var.customer_number
}

# Server id comes either directly from var.server_id, or from an exact-name
# lookup in the account server list. The exactly-one-of rule is enforced by
# a variable validation (see variables.tf); the account-level ambiguity
# (zero or several servers with the same name) is caught by the check block.
data "netcup_scp_servers" "all" {
  count = var.server_name != null ? 1 : 0
}

data "netcup_scp_server_interfaces" "anchor" {
  count     = local.resolved_server_id != null ? 1 : 0
  server_id = local.resolved_server_id
}

# Adopt (do not create) the existing server and patch its mutable attributes.
# Servers cannot be created or deleted through the SCP API — the user orders
# the box manually; this resource adopts it and keeps its config in sync.
resource "netcup_scp_server" "anchor" {
  count = local.resolved_server_id != null ? 1 : 0

  server_id       = local.resolved_server_id
  hostname        = var.hostname
  os_optimization = "LINUX"
  autostart       = true
}

# Account-level firewall policy: tang (TCP/80) is reachable only from the
# main box. Egress is explicitly ACCEPT-all: some SCP firewall implementations
# have a DROP_ALL egress implicit rule; we never want the anchor to be
# cut off from answering clevis challenges.
resource "netcup_scp_user_firewall_policy" "tang" {
  count = var.scp_user_id != null ? 1 : 0

  user_id     = var.scp_user_id
  name        = "piercloud-anchor-${var.hostname}"
  description = "tang (TCP/80) from the main box only; egress open. Managed by terraform-piercloud-anchor."

  rules = concat(
    [
      {
        action            = "ACCEPT"
        direction         = "INGRESS"
        protocol          = "TCP"
        destination_ports = "80"
        sources           = ["${var.allow_main_box_ipv4}/32"]
      },
    ],
    var.allow_main_box_ipv6 != null ? [
      {
        action            = "ACCEPT"
        direction         = "INGRESS"
        protocol          = "TCP"
        destination_ports = "80"
        sources           = ["${var.allow_main_box_ipv6}/128"]
      },
    ] : [],
    [
      {
        action    = "ACCEPT"
        direction = "EGRESS"
        protocol  = "TCP"
      },
    ],
  )
}

# Attach the policy to the anchor's first network interface.
resource "netcup_scp_server_interface_firewall" "anchor" {
  count = var.scp_user_id != null && local.resolved_server_id != null && local.interface_mac != null ? 1 : 0

  # attach (enabled firewall management only)

  server_id = local.resolved_server_id
  mac       = local.interface_mac
  active    = true

  user_policy_ids = [netcup_scp_user_firewall_policy.tang[0].id]
}

locals {
  # First interface of the adopted server; sorted for determinism.
  # try() guards the empty-interface-list case (an unguarded [0] crashes
  # plan with "Invalid index ... empty set"); the firewall resource's count
  # re-checks for a non-null MAC before consuming it.
  interface_mac = var.scp_user_id != null && local.resolved_server_id != null ? (
    try(sort([for i in data.netcup_scp_server_interfaces.anchor[0].scp_server_interfaces : i.mac])[0], null)
  ) : null
}

check "server_id_resolution" {
  assert {
    condition     = local.resolved_server_id != null
    error_message = "server_id could not be resolved: set var.server_id directly, or set var.server_name to the exact SCP name of the server to adopt (exactly one of the two)."
  }
}

check "server_name_unique" {
  assert {
    condition = var.server_name == null || length(local.server_id_by_name) == 1
    error_message = format(
      "Server name %q matched %d servers in your netcup account; it must match exactly one. Rename the server in the SCP or use var.server_id instead.",
      var.server_name != null ? var.server_name : "", length(local.server_id_by_name),
    )
  }
}
