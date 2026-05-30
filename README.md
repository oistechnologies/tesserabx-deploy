# tesserabx-deploy

An example **deployment repo** for running [TesseraBX](https://github.com/oistechnologies/tesserabx) in production and keeping it updated from upstream, while carrying your own add-ons and configuration.

It uses the **overlay model**: this repo holds only your deployment-specific files (add-on list, compose override, env template, CI). It never modifies upstream source. At deploy time, CI checks out upstream TesseraBX, lays your files on top, and builds. Because your customizations live in files upstream does not own, tracking upstream is conflict-free: there is never a merge to resolve.

Copy or duplicate this repo to create a deployment repo for any TesseraBX install.

---

## How it works

```
  this repo (tesserabx-deploy)                 upstream (oistechnologies/tesserabx)
  ----------------------------                 ------------------------------------
  tesserabx.version  ---------------- ref ----> checked out into WORKDIR (/opt/tesserabx)
  addons.private     ---- vendored into ------> WORKDIR/modules/<slug>/   (private add-ons)
  overlay/box.addons.json -- copied to -------> WORKDIR/box.addons.json   (public add-ons)
  overlay/compose.override.yaml -- copied to -> WORKDIR/compose.override.yaml
  TESSERABX_DOTENV secret -- written to ------> WORKDIR/.env

                          then, on the prod host:
                          docker compose up -d --build
```

The deploy is driven by a self-hosted GitHub Actions runner that lives **on the production host**, so the build and run happen in place (no container registry). It is **manual** (`workflow_dispatch`) and **floating** by default (deploys the latest upstream `main`); pinning to a tag or SHA is a one-line change.

---

## Repo layout

```
tesserabx-deploy/
  tesserabx.version            Upstream ref to deploy. "main" = floating (default).
  addons.private               Private add-ons the runner vendors before build.
  overlay/
    box.addons.json            Public / ForgeBox add-ons (installed during build).
    compose.override.yaml      Production container overrides (auto-loaded).
  scripts/
    deploy.sh                  The deploy/update logic (CI calls it; runnable by hand).
  .github/workflows/
    deploy.yml                 Manual deploy workflow for a self-hosted prod runner.
  .env.example                 Trimmed production .env template.
  .gitignore
  README.md
```

---

## Prerequisites

On the **production host**:

- Docker Engine and the `docker compose` CLI plugin.
- An external Docker network owned by your reverse proxy, named to match `PROXY_NETWORK` in your `.env`. The proxy terminates TLS; the stack speaks plain HTTP. (`docker network create <name>` if you do not already have one.)
- A **self-hosted GitHub Actions runner** registered to this repo and running as a user that can use Docker and write to `WORKDIR` (default `/opt/tesserabx`).
- Git access (SSH) from the host to the private upstream repo and any private add-on repos. Either configure the runner user's `~/.ssh`, or provide an `SSH_PRIVATE_KEY` secret (see below).

---

## One-time setup

### 1. Duplicate this repo

Fork it, or create your own repo from it. It is yours to commit to; upstream TesseraBX is consumed read-only.

### 2. Register and label the self-hosted runner

Install a self-hosted runner on the prod host (Settings > Actions > Runners > New self-hosted runner) and give it labels that match `runs-on` in [.github/workflows/deploy.yml](.github/workflows/deploy.yml). The default is:

```yaml
runs-on: [self-hosted, tesserabx-prod]
```

Add the `tesserabx-prod` label when registering, or edit the workflow to match your labels.

### 3. Set repo Variables and Secrets

Settings > Secrets and variables > Actions.

**Variables** (optional; defaults shown):

| Name | Default | Purpose |
| --- | --- | --- |
| `UPSTREAM_REPO` | `git@github.com:oistechnologies/tesserabx.git` | Upstream product repo |
| `WORKDIR` | `/opt/tesserabx` | Persistent working dir on the host |
| `COMPOSE_PROJECT_NAME` | `tesserabx` | Stable compose project name (keeps the same DB/Redis volumes across deploys) |

**Secrets:**

| Name | Required | Purpose |
| --- | --- | --- |
| `TESSERABX_DOTENV` | Yes (unless host-persisted .env) | The full production `.env` contents. Base it on [.env.example](.env.example) and the upstream `.env.example`. |
| `GH_PAT` | Recommended | A token (fine-grained PAT or GitHub App) with **read** access to the private upstream repo and any private add-on repos. The deploy clones over authenticated HTTPS, so the runner needs no SSH setup. One token covers all private repos (SSH deploy keys are single-repo). |
| `SSH_PRIVATE_KEY` | Optional | Alternative to `GH_PAT`: an SSH key with read access to those repos. Only needed if you prefer SSH over a token; then the runner host must also trust `github.com` (its `known_hosts`). |

**Authenticating to private repos.** The runner's auto-provided `GITHUB_TOKEN` only reaches *this* deploy repo, not the upstream product repo or your add-on repos. Set `GH_PAT` (recommended) so `scripts/deploy.sh` clones them over authenticated HTTPS. A fine-grained PAT with read-only "Contents" on `oistechnologies/tesserabx` and your add-on repos is enough. (The SSH path via `SSH_PRIVATE_KEY` works too, but for multiple private repos you would need a machine-user key, since a deploy key is single-repo.)

### 4. Configure your add-ons

- **Private add-ons** (for example `tesserabx-pm`): list them in [addons.private](addons.private). The runner clones each into `WORKDIR/modules/<slug>/` before the build.
- **Public / ForgeBox add-ons**: list them in [overlay/box.addons.json](overlay/box.addons.json). They are installed during the docker build.

See [Add-ons](#add-ons-private-vs-public) for why the two paths exist.

### 5. Set production overrides and the upstream ref

- Edit [overlay/compose.override.yaml](overlay/compose.override.yaml) for any production container settings (it ships with bounded log rotation).
- Leave [tesserabx.version](tesserabx.version) as `main` for floating, or set a tag/SHA to pin (see [Pinning and rollback](#pinning-and-rollback)).

---

## Deploying and updating

Both a first deploy and every subsequent update are the **same action**:

1. Go to the repo's **Actions** tab.
2. Select **Deploy TesseraBX (production)**.
3. Click **Run workflow**. Optionally set `upstream_ref` (overrides `tesserabx.version` for this run) and `worker_scale`.

Because the default is floating `main`, running the workflow pulls the newest upstream, re-vendors your add-ons, overlays your files, and rebuilds. The named volumes (`db_data`, `redis_data`) persist across rebuilds, so data is preserved. Database migrations (core and add-on) run automatically when the new `app` container boots.

### Running by hand on the host

`deploy.sh` is plain and re-runnable. On the prod host, as the runner user:

```bash
cd /path/to/tesserabx-deploy
export TESSERABX_DOTENV="$(cat /secure/path/.env)"   # or rely on ENV_FILE
./scripts/deploy.sh
```

Useful overrides: `UPSTREAM_REF_OVERRIDE=v1.4.0`, `WORKER_SCALE=3`, `WORKDIR=/opt/tesserabx`.

---

## What `scripts/deploy.sh` does

1. **Sync upstream** into `WORKDIR` (`git clone` first time, then `fetch` + `reset --hard` to the target ref). `reset --hard` only touches tracked upstream files, so your overlaid files and vendored add-ons survive.
2. **Vendor private add-ons** from [addons.private](addons.private) into `WORKDIR/modules/<slug>/` (cloned with the host's git credentials; `.git` stripped).
3. **Overlay** everything under `overlay/` onto `WORKDIR` (your `box.addons.json`, `compose.override.yaml`).
4. **Materialize `.env`** from the `TESSERABX_DOTENV` secret, or from a host-persisted `ENV_FILE`.
5. **Preflight**: verify the external `PROXY_NETWORK` exists.
6. **Pre-deploy backup**: best-effort `pg_dump` of the running database into `WORKDIR/.deploy-backups/`.
7. **Build and start**: `docker compose up -d --build --scale worker=N` with a stable `COMPOSE_PROJECT_NAME`.
8. **Health gate**: wait for the `app` container to report healthy, dumping logs and failing if it does not.

---

## Customizing the CI for your runner

Everything runner-specific is in [.github/workflows/deploy.yml](.github/workflows/deploy.yml):

- **`runs-on`**: set to your runner's labels.
- **`environment: production`**: create a GitHub Environment of that name and add required reviewers to gate each deploy behind a manual approval. Remove the line to skip the gate.
- **SSH access**: the optional "Start SSH agent" step activates only when you set the `SSH_PRIVATE_KEY` secret. If your runner host already has SSH access to the private repos, leave the secret unset and the step is skipped.
- **Trigger**: this example is manual only. To add a scheduled check, add a `schedule:` trigger; to deploy automatically when you bump the pin, add `push: { branches: [main] }`. Keep the `concurrency` block so two deploys never overlap.

---

## Add-ons: private vs public

The docker build runs `box install` for add-ons declared in `box.addons.json`, but the build has **no git credentials**, so it can only reach public / ForgeBox-resolvable endpoints. Two paths cover both cases:

| Add-on type | Where you list it | How it gets in |
| --- | --- | --- |
| Public / ForgeBox | [overlay/box.addons.json](overlay/box.addons.json) | Installed during the docker build (`save=false`, never touches upstream `box.json`) |
| Private (own repo) | [addons.private](addons.private) | Cloned by the runner onto the host before the build, then COPYed into the image |

`tesserabx-pm` is private, so it lives in `addons.private`. Do not list the same add-on in both places.

For reproducible production deploys, pin each add-on's `<ref>` to a tag rather than tracking a branch.

---

## Secrets and `.env` handling

Never commit a real `.env` (this repo's `.gitignore` blocks it). Two supported ways to get it onto the host:

- **GitHub secret (recommended for CI):** paste your complete `.env` into the `TESSERABX_DOTENV` secret. The deploy writes it to `WORKDIR/.env` (mode 600) at deploy time and excludes it from the image.
- **Host-persisted file:** keep a `.env` on the host (mode 600) and set `ENV_FILE=/secure/path/.env` for `deploy.sh`. Used only when `TESSERABX_DOTENV` is unset.

Build the file from [.env.example](.env.example) plus the full annotated list in the upstream `.env.example`. At minimum set `PROXY_NETWORK`, `DB_PASSWORD`, `JWT_SECRET`, `NOTIFICATIONS_UNSUBSCRIBE_SECRET`, `APP_BASE_URL`, the `MAIL_*` relay, and your `CBFS_*` storage.

---

## Data persistence and safety

- **Volumes persist.** `db_data` and `redis_data` survive every rebuild. The stable `COMPOSE_PROJECT_NAME` is what guarantees each deploy reuses the same volumes even though CI workspaces are ephemeral. A manual `docker volume rm` is the only thing that drops data.
- **Backups.** Each deploy takes a best-effort `pg_dump` first. Keep your own off-host backups too (set `CBFS_DEFAULT_PROVIDER` to `s3` or `b2` so the upstream nightly backup task writes offsite).
- **Do not run `git clean -fdx` in `WORKDIR`.** It would delete the vendored add-ons and the materialized `.env`.

---

## Pinning and rollback

Floating `main` is convenient but uncontrolled. For production, pin:

```bash
echo "v1.4.0" > tesserabx.version    # a tag or full SHA
git commit -am "Pin TesseraBX to v1.4.0" && git push
```

Then run the deploy. To roll back, set `tesserabx.version` to the previous tag/SHA (and revert any add-on `<ref>` bumps in `addons.private`) and run again. For a one-off without committing, use the `upstream_ref` workflow input.

---

## Optional: switch to a prebuilt image (GHCR)

This example builds on the prod host. To decouple build from deploy later: build the image in CI, push to GitHub Container Registry, and have prod pull it. The upstream `compose.yaml` already declares both `build:` and `image:`, so a small override that drops `build:` and pins `image: ghcr.io/<you>/tesserabx-app:<tag>` is enough on the prod side. That path trades the in-place build for an immutable, registry-tagged artifact with faster cutover and tag-based rollback.

---

## Troubleshooting

- **`external docker network ... does not exist`**: create the proxy network or fix `PROXY_NETWORK` in your `.env`.
- **`app did not become healthy`**: the deploy prints the last app logs. Common causes: bad `.env` (DB or Redis connection), a failed migration, or a missing/incompatible add-on.
- **Permission denied writing `WORKDIR`**: ensure the runner user owns `/opt/tesserabx` (`sudo chown -R $(whoami) /opt/tesserabx`).
- **Private repo clone fails**: the runner has no git access. Set `SSH_PRIVATE_KEY`, or configure the runner user's SSH.
- **Add-on tables missing**: the entrypoint stages and applies add-on migrations on boot; confirm the add-on was vendored (private) or installed (public), then redeploy.

---

## Duplicating for another deployment

1. Copy this repo (or use it as a template).
2. Point `UPSTREAM_REPO` (variable) at your upstream or mirror.
3. Replace the example entry in `addons.private` and `overlay/box.addons.json` with your own add-ons (or empty them for a vanilla install).
4. Set `TESSERABX_DOTENV` for the new environment.
5. Register a self-hosted runner on that environment's host and match `runs-on`.
6. Run the deploy workflow.
