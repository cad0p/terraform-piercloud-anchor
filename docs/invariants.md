# Invariants

The two hard invariants of this module. They are stated in user terms in the
README; this file carries the verbatim statements and the rationale.

## Invariant 1 — tang keys never enter Terraform state

> The tang private key **never** enters tf state or plan output. The keypair
> is generated **on the box** by `scripts/010-provision.sh` — never by the
> module — so state holds server configuration only.

**Rationale.** Terraform/OpenTofu state is a plaintext file that tends to
travel: local disks, CI caches, backends. If the tang private key lived in
state, every state copy would be a copy of the unlock key. Keeping generation
on the box confines the key to the anchor's disk (where it *must* live for
tangd to answer) and makes the state safe to store anywhere. Enforced by:
key generation existing only in the script (never in `.tf` code), a CI grep
for private key material over tracked files, and the script's key-leak
assertion (fails loudly if state/plan files in the working directory match
the on-box key material).

## Invariant 2 — the anchor is a key-holder, never an access-path

> The anchor holds **no credential that reaches the user's main box** — no
> SSH keys, no Teleport tokens, no API tokens, no agent sockets. Its only
> cross-box interaction is answering clevis's TCP/80 challenges (firewall-
> scoped to the main box IP; no SSH inbound from the main box either). Admin
> of the anchor itself is **user-direct only** (their own SSH key from their
> own device, or netcup console/rescue). *You administer the anchor; the
> anchor administers nothing.*

**Rationale.** The anchor is the deliberately weakest link: unencrypted,
always-on, holds an unlock key, different jurisdiction, cheapest box. If it
were an SSH path into the main box, anchor compromise would mean full server
access, and the "can unlock a disk image but never obtain one" property would
collapse. With the invariant, the worst an attacker gets from the anchor is
the ability to answer a boot-time challenge (and tang's ECDH design means
they'd need the booting box's cooperation anyway) — not a foothold inside
your main box. Enforced by: the module's variable set (no SSH key inputs,
no token inputs), the firewall policy (single TCP/80 ingress rule), and
inspection of the module surface.
