# AGENTS.md — conventions for coding agents working in this repo

Public repo: `terraform-piercloud-tang` — an OpenTofu module that turns a
netcup VPS into a tang/clevis NBDE anchor (network-bound disk unlock) with an
Gatus availability monitor (config-as-file, Renovate-pinned image). Written fresh for this repo; follows the
house conventions of its author's other repos.

## Purpose and shape

- Standard OpenTofu module layout: the root IS the module (`versions.tf`,
  `variables.tf`, `main.tf`, `outputs.tf`); `examples/` holds a runnable
  quickstart; `scripts/` numbered human-run scripts; `docs/` usage +
  invariants. No `modules/` wrapper (registry doc generation).
- Provider: community `rixlhq/netcup` (`~> 1.2`); OpenTofu `>= 1.10`,
  pinned via `.opentofu-version`.
- The module **adopts** an existing netcup server (the SCP API cannot create
  or delete servers); the user orders the box manually.

## The two hard invariants (never violate, never weaken)

1. **Tang keys never enter Terraform state.** The keypair is generated on the
   box by `scripts/010-provision.sh`, never in `.tf` code. Never add resources,
   provisioners, or data flows that could put key material into state, plan
   output, or CI logs. CI greps tracked code files for key material patterns.
2. **The anchor is a key-holder, never an access-path.** It holds no
   credential that reaches the user's main box: no SSH keys, no tokens, no
   agent sockets. The only cross-box interaction is answering clevis
   challenges on TCP/80 from the main box IP. Do not add SSH/TLS/token inputs
   or egress to the module; administration is user-direct (SCP console or the
   user's own SSH key added via netcup SCP).

## Scripts invariants

`scripts/` files are numbered (`NN-name.sh`, numbers never reused), run by a
human on the target box (netcup SCP remote console or the user's own SSH),
idempotent (safe to re-run at any state), and contain no secrets — one-time
values are printed to the console for the human to save. After first
provision, verify live twice (re-run convergence + two successful clevis
boots). See `scripts/README.md`.

## Release discipline

- All changes land via **pull request**, squash-merged (the only allowed
  merge method); main stays linear.
- `CHANGELOG.md` follows Keep a Changelog; edits land **only** on
  `release/from-v*` branches or the release PR — a PR that touches
  `CHANGELOG.md` off a release branch fails `validate-package-version`.
- Every PR body ends with a `## Release notes` section (one line per
  user-facing change; "Initial module skeleton — no Breaking" is fine).
- `package.json` is the version manifest read by the release pipeline
  (`cad0p/semver-calver-release`, actions pinned `@v1`): automatic calver
  prereleases on push to main, curated stable releases via `release/from-v*`
  draft PRs. Releases are tagged `vX.Y.Z` (+ floating `v0`/`v0.0` during
  0.x; `v1` after 1.0.0).

## OpenTofu conventions

- `.opentofu-version` pins the toolchain version; CI uses it.
- `tofu fmt -check -recursive` must pass; run `tofu fmt` before committing.
- CI is cred-free: `tofu init -backend=false && tofu validate` must pass
  without any provider credentials — keep data sources behind `count` guards
  so validate stays credential-free. **Never add `tofu plan` to CI** (it
  would need live credentials).
- Prefer `check` blocks for module-level assertions the user can see at plan
  time.

## Public-safety rules for content

- Nothing sensitive in committed files: no credentials, no hostnames/IPs of
  real deployments, no internal strategy. This is a public repo — write for
  the public reader.
- Scripts print one-time values (thumbprint, generated passwords) to the
  console only; never log them to files that could be committed.
