# mossyleaf accounts — running on a server

This folder is all a server needs: `compose.yaml` runs the image `docker.io/injust/mossyleaf-accounts` (Authentik server + worker, with the blueprints, email templates and branding baked in) and PostgreSQL 18. Everything Authentik needs (groups, OIDC providers and applications, flows, brand, emails) is declared in the blueprints and applied on start. No source checkout on the server.

It runs in its own directory on the server (`DEPLOY_DIR`), behind the shared Caddy edge proxy, at `https://accounts.mossyleaf.studio`, `https://accounts.injustmusic.com` and `https://accounts.duprat.cloud` (one brand per context, see the [README](../README.md#contexts)).

## Prerequisites

- Docker Engine with the Compose plugin (`docker compose version`). Authentik takes about 1 GB of RAM (server + worker).
- An SMTP account for invitation and password emails.
- DNS for `accounts.mossyleaf.studio`, `accounts.injustmusic.com` and `accounts.duprat.cloud` pointing at the server.
- An SMTP account allowed to send from `accounts@injustmusic.com` and `accounts@duprat.cloud` too (SPF/DKIM of those domains): the injust and personal emails use them as sender.

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
| `PROXY_NETWORK` | External Docker network of the reverse proxy (`web` on duprat.cloud) |
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
| `INJUST_CLIENT_SECRET` | `openssl rand -hex 32`, same value in injust's `OIDC_CLIENT_SECRET` |
| `INJUST_URL` | The app's public origin, without a trailing slash (its redirect URIs are built from it) |
| `INJUST_ACCOUNTS_DOMAIN` / `PERSONAL_ACCOUNTS_DOMAIN` | Sign-in host of the injust and personal contexts (default `accounts.injustmusic.com` / `accounts.duprat.cloud`) |
| `INJUST_EMAIL_FROM` / `PERSONAL_EMAIL_FROM` | Sender address of their emails, a bare address (default `accounts@injustmusic.com` / `accounts@duprat.cloud`); they reuse the `AUTHENTIK_EMAIL__*` SMTP settings |

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

The server container joins the external Docker network named by `PROXY_NETWORK` in `.env` (`web` on duprat.cloud, the network Caddy is on) with the alias `mossyleaf-accounts` and publishes no port. Authentik needs `Host`, the `X-Forwarded-*` headers and WebSocket upgrades; Caddy's `reverse_proxy` sends all of them. Caddy's address is in Authentik's default trusted proxy ranges (private networks), so the forwarded headers are honoured.

The site block lives in the `duprat-cloud` repo (`proxy/conf/Caddyfile`); Caddy fetches and renews the certificates for every name itself:

```caddyfile
accounts.mossyleaf.studio, accounts.injustmusic.com, accounts.duprat.cloud {
	import app mossyleaf-accounts:9000 20MB
}
```

Apply it with `make deploy-proxy` in `duprat-cloud`. The DNS records of the new names must point at the server first, or the certificate request fails (Caddy retries).

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
make invite REMOTE=1 CONTEXT=injust EMAIL=ada@example.com NAME="Ada Lovelace"     # GROUPS defaults to injust
make invite REMOTE=1 CONTEXT=personal EMAIL=ada@example.com NAME="Ada Lovelace"   # GROUPS defaults to muhmeal
```

`CONTEXT` (`mossyleaf` by default, `injust` or `personal`) picks the brand: the link points at that context's domain and the email has its look and sender. `GROUPS` defaults to the context's apps.

`TIMEZONE` (default `Europe/Paris`, sent as the `zoneinfo` claim) and `LOCALE` (default `fr`, language of the email and of the account pages) are optional. `WORKSPACE` is the exact name of the MossyTrunk workspace the person joins on their first MossyTrunk sign-in (sent as the `mossytrunk_workspace` claim); without it they get a workspace of their own. It is only read on that first sign-in. Running it again for an existing email only adds the groups (and sets `WORKSPACE` when given) and sends a fresh link (the previous one stops working).

On the server (the script is in the image): `docker compose exec -T -e INVITE_EMAIL=ada@example.com -e INVITE_NAME="Ada Lovelace" -e INVITE_GROUPS="mossydew" -e INVITE_CONTEXT=mossyleaf -e INVITE_SECURE=1 worker sh -c 'ak shell < /mossyleaf/invite.py'`

From the admin interface: **Directory › Users › Create** (username = email, name, email), open the user, **Groups › Add to existing group**, then **Recovery › Email recovery link** and pick the `<context>-invitation-email` stage (`mossyleaf`, `injust` or `personal`). The link uses the host the admin interface is open on, so open it on that context's domain.

Removing access to an app = removing the user from its group. **Deactivate** blocks every app at once.

## Adding a new app

In `blueprints/mossyleaf-apps.yaml`, copy the MossyDew block (group, provider, application, binding) and change the slug, name, redirect URIs and the `!Env` secret name. The app then signs in through whichever context domain it points at (its issuer follows the host). Add the secret to the server `.env` and to `.env.dist`, push to `main`, then `make deploy` once CI has published the image. The app gets its discovery document at `https://accounts.mossyleaf.studio/application/o/<slug>/.well-known/openid-configuration`.

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
