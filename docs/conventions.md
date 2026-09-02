# Repo conventions (for contributors and coding agents)

This file holds the engineering conventions of this repo. The two hard
invariants live in [invariants.md](invariants.md); the scripts rules live in
[scripts/README.md](../scripts/README.md). The user-facing entry point is the
[README](../README.md).

## Shape

- Standard OpenTofu module layout: the root IS the module (`versions.tf`,
  `variables.tf`, `main.tf`, `outputs.tf`); `examples/` holds a runnable
  quickstart; `scripts/` numbered human-run scripts; `docs/` this folder.
  No `modules/` wrapper (registry doc generation requirement).
- Provider: community `rixlhq/netcup` (`~> 1.2`); OpenTofu `>= 1.10`,
  pinned via `.opentofu-version`.
- The module **adopts** an existing netcup server (the SCP API cannot create
  or delete servers); the user orders the box manually.

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
- Dependency pins are kept fresh by Renovate (see `renovate.json`): the
  `@v1` action pins, the Gatus image pin inside `010-provision.sh` (marked
  with a `# renovate:` directive), and `.opentofu-version`. Minor/patch
  bumps automerge once CI is green; **major bumps always land as PRs for
  human review**. A Renovate bump of the Gatus image reaches deployed
  anchors when the user re-runs `scripts/010-provision.sh` (the script
  recreates the container when the pinned image changed).

## OpenTofu conventions

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
