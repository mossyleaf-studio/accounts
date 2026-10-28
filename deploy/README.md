# mossyleaf accounts — running on a server

This folder is all a server needs: `compose.yaml` runs the image `docker.io/injust/mossyleaf-accounts` (Authentik server + worker, with the blueprints, email templates and branding baked in) and PostgreSQL 18. Everything Authentik needs (groups, OIDC providers and applications, flows, brand, emails) is declared in the blueprints and applied on start. No source checkout on the server.

It runs in its own directory on the server (`DEPLOY_DIR`), behind a shared nginx container, at `https://accounts.mossyleaf.studio`.

## Prerequisites

- Docker Engine with the Compose plugin (`docker compose version`). Authentik takes about 1 GB of RAM (server + worker).
- An SMTP account for invitation and password emails.
- DNS for `accounts.mossyleaf.studio` pointing at the server (already covered by `*.mossyleaf.studio`).

## First install

From a dev machine (copies `compose.yaml`, `.env.dist` and this README):

```bash
make deploy-files
```

On the server:

```bash
cd "$DEPLOY_DIR"
cp .env.dist .env
chmod 600 .env
```

Fill `.env`:

| Variable | Value |
|---|---|
| `IMAGE` / `TAG` | Image to run; `make deploy` sets `TAG` to the commit it deploys |
| `PROXY_NETWORK` | External Docker network of the nginx reverse proxy (`docker network ls`) |
| `PG_PASS` | `openssl rand -base64 36 \| tr -d '\n'` |
| `AUTHENTIK_SECRET_KEY` | `openssl rand -base64 60 \| tr -d '\n'` |
| `AUTHENTIK_WEB__BASE_URL` | `https://accounts.mossyleaf.studio` |
| `AUTHENTIK_BOOTSTRAP_EMAIL` / `AUTHENTIK_BOOTSTRAP_PASSWORD` | Email and password of the first admin, `akadmin` (only read on the very first start; clear the password afterwards) |
| `AUTHENTIK_EMAIL__HOST` / `PORT` / `USERNAME` / `PASSWORD` | SMTP server and credentials |
| `AUTHENTIK_EMAIL__USE_TLS` / `USE_SSL` | `true`/`false` for STARTTLS on 587, `false`/`true` for 465 |
| `AUTHENTIK_EMAIL__FROM` | Sender, e.g. `mossyleaf <accounts@mossyleaf.studio>` |
| `MOSSYDEW_CLIENT_SECRET` | `openssl rand -hex 32`, same value in MossyDew's `OIDC_CLIENT_SECRET` |
| `MOSSYTRUNK_CLIENT_SECRET` | `openssl rand -hex 32`, same value in MossyTrunk's `OIDC_CLIENT_SECRET` |
| `MOSSYLEAF_STUDIO_CLIENT_SECRET` | `openssl rand -hex 32`, same value in mossyleaf.studio's `OIDC_CLIENT_SECRET` |
| `MUHMEAL_CLIENT_SECRET` | `openssl rand -hex 32`, same value in muhmeal's `OIDC_CLIENT_SECRET` |
| `MUHMEAL_URL` | The app's public origin, without a trailing slash (its redirect URIs are built from it) |

Never change `AUTHENTIK_SECRET_KEY` or `PG_PASS` after the first start: sessions, tokens and the database depend on them. Keep a copy of `.env` with the backups. Changing a client secret means updating the app at the same time.

## Start

```bash
docker compose pull
docker compose up -d
docker compose logs -f server worker
```

The first start runs the migrations (about a minute) then the worker applies the blueprints. Check they all succeeded:

```bash
docker compose exec -T worker ak shell -c "from authentik.blueprints.models import BlueprintInstance as B; [print(b.status, b.path) for b in B.objects.filter(path__startswith='custom')]"
```

Both `custom/mossyleaf-*.yaml` lines must say `successful`. `curl -s https://accounts.mossyleaf.studio/application/o/mossydew/.well-known/openid-configuration` must return JSON once the proxy is set up.

## Reverse proxy

The server container joins the external Docker network named by `PROXY_NETWORK` in `.env` (the one the nginx container is on) with the alias `mossyleaf-accounts` and publishes no port. Authentik needs `Host`, the `X-Forwarded-*` headers and WebSocket upgrades. The nginx container's address is in Authentik's default trusted proxy ranges (private networks), so the forwarded headers are honoured.

1. Expand the shared certificate with the new name. List the current names, then rerun certbot the way it is usually run on the server with every existing `-d` plus the new one:

   ```bash
   certbot certificates
   certbot certonly --expand --cert-name <cert name> -d <every existing name> -d accounts.mossyleaf.studio
   ```

2. Add to the nginx configuration (copy the `listen`/`ssl_*` lines of the `mossydew.mossyleaf.studio` block if they differ, including its port 80 redirect):

   ```nginx
   map $http_upgrade $mossyleaf_accounts_connection {
       default upgrade;
       ''      '';
   }

   server {
       listen 443 ssl;
       http2 on;
       server_name accounts.mossyleaf.studio;

       ssl_certificate /etc/nginx/ssl/live/<cert name>/fullchain.pem;
       ssl_certificate_key /etc/nginx/ssl/live/<cert name>/privkey.pem;

       client_max_body_size 20m;

       location / {
           proxy_pass http://mossyleaf-accounts:9000;
           proxy_http_version 1.1;
           proxy_set_header Host $host;
           proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
           proxy_set_header X-Forwarded-Proto $scheme;
           proxy_set_header X-Forwarded-Host $host;
           proxy_set_header Upgrade $http_upgrade;
           proxy_set_header Connection $mossyleaf_accounts_connection;
       }
   }
   ```

3. Check and reload:

   ```bash
   docker exec <nginx container> nginx -t
   docker exec <nginx container> nginx -s reload
   ```

## First admin

`akadmin` is created on the first start from `AUTHENTIK_BOOTSTRAP_EMAIL` / `AUTHENTIK_BOOTSTRAP_PASSWORD`. Sign in at `https://accounts.mossyleaf.studio/` with `akadmin` (or the email) and that password, then:

- open **Admin interface** (`/if/admin/`), check **System › System tasks** and **Customization › Blueprints**;
- change the password (or invite yourself as a regular user, see below, and add yourself to `authentik Admins`), then remove `AUTHENTIK_BOOTSTRAP_PASSWORD` from `.env`;
- add yourself to the `mossydew` / `mossytrunk` groups if you use the apps: admins are not exempt from the group rule.

If `AUTHENTIK_BOOTSTRAP_PASSWORD` was left empty, open `https://accounts.mossyleaf.studio/if/flow/initial-setup/` right after the first start to set the admin password.

## Inviting users

There is no public sign-up. An invitation is a user without a password, in the app groups, who receives a one-week link to choose a password (≥ 12 characters).

From a dev machine:

```bash
make invite REMOTE=1 EMAIL=ada@example.com NAME="Ada Lovelace" GROUPS="mossydew mossytrunk" WORKSPACE="Atelier Mousse"
```

`TIMEZONE` (default `Europe/Paris`, sent as the `zoneinfo` claim) and `LOCALE` (default `fr`, language of the email and of the account pages) are optional. `WORKSPACE` is the exact name of the MossyTrunk workspace the person joins on their first MossyTrunk sign-in (sent as the `mossytrunk_workspace` claim); without it they get a workspace of their own. It is only read on that first sign-in. Running it again for an existing email only adds the groups (and sets `WORKSPACE` when given) and sends a fresh link (the previous one stops working).

On the server (the script is in the image): `docker compose exec -T -e INVITE_EMAIL=ada@example.com -e INVITE_NAME="Ada Lovelace" -e INVITE_GROUPS="mossydew" -e INVITE_HOST=accounts.mossyleaf.studio -e INVITE_SECURE=1 worker sh -c 'ak shell < /mossyleaf/invite.py'`

From the admin interface: **Directory › Users › Create** (username = email, name, email), open the user, **Groups › Add to existing group**, then **Recovery › Email recovery link** and pick the `mossyleaf-invitation-email` stage.

Removing access to an app = removing the user from its group. **Deactivate** blocks every app at once.

## Adding a new app

In `blueprints/mossyleaf-apps.yaml`, copy the MossyDew block (group, provider, application, binding) and change the slug, name, redirect URIs and the `!Env` secret name. Add the secret to the server `.env` and to `.env.dist`, push to `main`, then `make deploy` once CI has published the image. The app gets its discovery document at `https://accounts.mossyleaf.studio/application/o/<slug>/.well-known/openid-configuration`.

## Backup / restore

The state is the PostgreSQL database plus `data/` (uploaded media; small). The blueprints, templates and branding are in git and in every published image.

```bash
docker compose exec -T postgresql pg_dump -U authentik -Fc authentik > accounts-$(date +%F).dump
tar czf accounts-data-$(date +%F).tgz data .env
```

Restore on a fresh install (same `.env`):

```bash
docker compose up -d postgresql
docker compose exec -T postgresql pg_restore -U authentik -d authentik --clean --if-exists < accounts-YYYY-MM-DD.dump
tar xzf accounts-data-YYYY-MM-DD.tgz
docker compose up -d
```

## Update / rollback

Every push to `main` runs `make check` on a fresh stack built from the image and, only if it passes, publishes `docker.io/injust/mossyleaf-accounts:<short sha>` and `:latest` (GitHub Actions, [`.github/workflows/ci.yml`](../.github/workflows/ci.yml)). Then, from a dev machine on that commit:

```bash
make deploy      # uses DEPLOY_HOST, DEPLOY_DIR and REMOTE_DOCKER from the root .env
```

It refuses a commit whose image is not published, sets `IMAGE`/`TAG` in the server `.env`, pulls, restarts and reapplies the blueprints (so a `branding.css`-only change shows up too); migrations run on start. The image is public: the server pulls it without `docker login`.

Updating Authentik: read the release notes (`https://docs.goauthentik.io/releases/<year.month>/`) first and upgrade one minor version at a time (2026.8 → 2026.11 → …). Back up, bump `AUTHENTIK_TAG` in the `Dockerfile`, push, then `make deploy`. Migrations only move forward: rolling back across an Authentik version means restoring the database dump taken before the update, then running the previous tag (`make deploy TAG=<previous sha>`).

A blueprint with a YAML syntax error stops the server at start (the migrations import the blueprints): CI catches it, and `make up check` does locally.

## Operations

```bash
docker compose ps
docker compose logs -f server worker
docker compose exec -T worker ak apply_blueprint custom/mossyleaf-accounts.yaml custom/mossyleaf-apps.yaml   # reapply now (make deploy does it)
docker compose exec -T worker ak test_email you@example.com                                                     # check SMTP
docker compose down        # stop, data kept
```
