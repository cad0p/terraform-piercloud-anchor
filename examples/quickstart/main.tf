# Adopt an existing netcup server and turn it into a tang/clevis NBDE anchor.
#
# Prerequisites:
#   - a netcup server ordered in the SCP (any Debian-family image installed)
#   - SCP API credentials in the environment (NETCUP_* — see ../../docs/usage.md)
#   - your main box's public IP(s)
#
# Replace the placeholder values below, or pass them with -var / a tfvars file.

terraform {
  required_version = ">= 1.10"

  required_providers {
    netcup = {
      source  = "rixlhq/netcup"
      version = "~> 1.2"
    }
  }
}

provider "netcup" {}

module "tang_anchor" {
  source = "../../"

  server_id           = 1234567        # or server_name = "SCPI-1234567"
  allow_main_box_ipv4 = "203.0.113.10" # your main box's IPv4
  allow_main_box_ipv6 = null           # optional: your main box's IPv6
  hostname            = "tang-anchor-01"
  scp_user_id         = 1234 # SCP user id owning the firewall policy
}

output "anchor_ipv4" {
  value = module.tang_anchor.ipv4
}

output "next_step" {
  value = module.tang_anchor.next_step
}
