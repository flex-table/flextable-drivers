# flextable-drivers

Per-OS **build** of the native database drivers FlexTable downloads at runtime
(Oracle Instant Client first; more engines later). This repo produces **unsigned**
per-`(os, arch)` bundles as workflow artifacts. It does **not** sign or publish
anything.

## Security model - this repo is SECRET-FREE by design

FlexTable uses **build-in-public / sign-in-app**:

| Stage | Where | Holds |
|---|---|---|
| **Build** (unsigned per-OS bundles) | **this public repo** | **NO secrets** - no signing seed, no R2 credentials, nothing |
| **Sign + publish** (ed25519 manifest -> R2) | the **private app repo** | `DB_DRIVERS_SIGNING_SEED`, `R2_ACCESS_KEY_ID` / `R2_SECRET_ACCESS_KEY` / `R2_ACCOUNT_ID` |

So a compromise of this repo leaks nothing that can sign or publish: the worst case
is a tampered bundle, which the app rejects because the manifest signature (made in
the private repo) won't match. **Never add a signing seed or a credential here** -
`.gitignore` blocks the obvious paths, but the rule is the guard, not the file.

Why a separate repo from `flextable-cli-tools`: license isolation. Oracle Instant
Client is **OTN-licensed**; keeping its build out of the freely-redistributable
backup-tools repo (and its bytes out of that manifest) keeps the license story clean.

## What it builds

Bundles are named `<namespace>-<major>-<os>-<arch>` and match the app's install
contract (single top-level dir = bundle root; the app copies its contents into
`tools/<namespace>-<major>/`). Sources + pinned SHA-256 per target live in
[`config/`](config/) (e.g. `config/oracle-instantclient.json`).

Oracle Instant Client (`oracle-instantclient`, major `23` - the client is
backward-compatible, so one major, not per-server-version):

This repo is **public**, so every leg runs on a FREE GitHub-hosted runner - no
self-hosted runner needed (hosted macOS is only billed 10x on *private* repos).

| Target | Runner (GitHub-hosted, free for public repo) | Status |
|---|---|---|
| `macos-arm64` | `macos-14` (Apple Silicon) | pinned (Basic 23.3 arm64) |
| `linux-x86_64` | `ubuntu-latest` | TODO: pin the Oracle IC linux URL + sha |
| `windows-x86_64` | `windows-latest` | TODO: pin the Oracle IC windows URL + sha |
| `macos-x86_64` | `macos-13` (Intel) | backfill later |

## How to build (generic + incremental)

`Actions -> build -> Run workflow` (`workflow_dispatch`) with:
- `namespace` - the engine, e.g. `oracle-instantclient` (matches `config/<namespace>.json`)
- `targets` - `all`, or a comma list like `linux-x86_64,windows-x86_64`

The `plan` job derives the matrix from the config (skipping any target still marked
TODO); the `build` job calls the reusable
[`build-bundle.yml`](.github/workflows/build-bundle.yml) once per selected target, each
on its own OS (native libs can't be cross-built), and uploads the bundle as an artifact.
The private app repo then downloads the artifacts, signs the manifest, and publishes to
R2 (`flextable-db-drivers`, served `drivers.flextable.dev`).

## Incremental by design - never rebuild what exists

Building a new engine or backfilling one target must NOT touch what's already published:

- **Build side:** dispatch names ONE `namespace` + only the `targets` you want, so no
  existing engine/target is rebuilt.
- **Publish side:** the app repo signs with `build_manifest.py --merge-from-url`, which
  verifies the LIVE manifest then non-destructively overlays only the new
  `(namespace, major, os, arch)` leaves - existing leaves (other engines, other targets)
  survive untouched.

**Add a new engine:** drop a `config/<engine>.json` (pinned url + sha256 per target); if
its sourcing differs from the Instant Client shape, extend the `scripts/bundle_*`; then
dispatch `namespace=<engine>`. Nothing already built is re-run.

## Scripts are shared, not forked

The per-OS `scripts/bundle_{macos,linux,windows}` are parameterized by `BUNDLE_NAMESPACE`
and consumed through the reusable `build-bundle.yml`, so the sibling `flextable-cli-tools`
repo can call the SAME reusable workflow
(`uses: flex-table/flextable-drivers/.github/workflows/build-bundle.yml@main`) rather than
duplicating build logic.
