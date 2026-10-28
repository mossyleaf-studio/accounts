# mossyleaf accounts

Single sign-on for the mossyleaf apps at **https://accounts.mossyleaf.studio**: a self-hosted [Authentik](https://goauthentik.io) **2026.8.3** where MossyDew and MossyTrunk are OpenID Connect clients. One account per person, one group per app, no public sign-up.

Everything is configuration: the image `docker.io/injust/mossyleaf-accounts` is Authentik's official image with this repository's blueprints, email templates and branding copied in. The blueprints declare the groups, OIDC providers, applications, access bindings, flows and brand, so a fresh install is ready on its first start, and updating the server is pulling a newer tag.

| Path | What |
|---|---|
| `Dockerfile` | The image: `ghcr.io/goauthentik/server` (version in `AUTHENTIK_TAG`) plus `blueprints/`, `templates/`, `branding/` and `scripts/invite.py` |
| `compose.yaml` | Local stack: the image built from the Dockerfile as Authentik server (http://localhost:9000) + worker, PostgreSQL 18, Mailpit (http://localhost:8027) |
| `compose.override.yaml` | Local only: mounts `blueprints/`, `templates/` and `branding/` over the image's copies, so edits need no rebuild |
| `.github/workflows/ci.yml` | On every push: builds the image, starts it on a fresh stack, runs `make check`, keeps the sign-in screenshots; on `main` it then publishes the tested image to Docker Hub |
| `blueprints/mossyleaf-accounts.yaml` | Sign-in, recovery and password-change flows, invitation email, password policy, brand |
| `blueprints/mossyleaf-apps.yaml` | Groups `mossydew` / `mossytrunk`, their OIDC providers and applications, group bindings, `zoneinfo` and `mossytrunk_workspace` claims |
| `branding/` | Logo, favicon, background, `branding.css` (the brand's custom CSS) and self-hosted fonts, served at `/static/dist/custom/` |
| `templates/email/` | Invitation and password-reset emails (HTML + text, French or English from the user's locale) |
| `scripts/invite.py` | Creates or updates a user, adds groups and emails the invitation (run by `make invite`) |
| `deploy/` | Server compose file, `.env.dist` and the [server README](deploy/README.md) |

## Local use

```bash
make up                 # build the image, http://localhost:9000, admin: akadmin / admin-password
make invite EMAIL=ada@example.com NAME="Ada Lovelace" GROUPS="mossydew mossytrunk"
open http://localhost:8027   # Mailpit: the invitation link
make apply              # reapply the blueprints now (needed after editing branding/branding.css)
make check              # smoke test: blueprints applied, OpenID configurations, sign-in page, brand
make shots              # sign-in page screenshots (phone + desktop) into shots/
make logs / make down
```

The worker reapplies a blueprint whenever its YAML changes; `branding.css` is read by the brand blueprint (`!File`), so a CSS-only change needs `make apply` (`make deploy` runs it on the server). To try the image exactly as CI publishes it, without the source mounts: `COMPOSE_FILE=compose.yaml make up check`.

Local client secrets: `mossydew-local-secret` and `mossytrunk-local-secret` (override with `MOSSYDEW_CLIENT_SECRET` / `MOSSYTRUNK_CLIENT_SECRET` in a root `.env`).

## Contract with the apps

| | MossyDew | MossyTrunk | muhmeal |
|---|---|---|---|
| `client_id` | `mossydew` | `mossytrunk` | `muhmeal` |
| `client_secret` | `MOSSYDEW_CLIENT_SECRET` | `MOSSYTRUNK_CLIENT_SECRET` | `MUHMEAL_CLIENT_SECRET` |
| Redirect URIs (strict) | `https://mossydew.mossyleaf.studio/login/check`, `http://localhost:8090/login/check` | `https://mossytrunk.mossyleaf.studio/login/check`, `http://localhost:8080/login/check` | `$MUHMEAL_URL/login/check` |
| Post-logout redirect URIs (strict) | `https://mossydew.mossyleaf.studio/`, `http://localhost:8090/` | `https://mossytrunk.mossyleaf.studio/`, `http://localhost:8080/` | `$MUHMEAL_URL/` |
| Group allowed to sign in | `mossydew` | `mossytrunk` | `muhmeal` |

Endpoints (`<slug>` = `mossydew` or `mossytrunk`; locally `http://localhost:9000` instead of the host):

- Discovery: `https://accounts.mossyleaf.studio/application/o/<slug>/.well-known/openid-configuration`
- Issuer: `https://accounts.mossyleaf.studio/application/o/<slug>/`
- Authorize: `https://accounts.mossyleaf.studio/application/o/authorize/`
- Token: `https://accounts.mossyleaf.studio/application/o/token/`
- Userinfo: `https://accounts.mossyleaf.studio/application/o/userinfo/`
- End session: `https://accounts.mossyleaf.studio/application/o/<slug>/end-session/`
- JWKS: `https://accounts.mossyleaf.studio/application/o/<slug>/jwks/` (ID tokens are RS256)

Flow: authorization code with PKCE S256 (confidential client, `client_secret_basic` or `client_secret_post`), scopes `openid email profile`; add `offline_access` to also get a refresh token (30 days). Access tokens last 1 hour. No consent screen.

Userinfo (and ID token) claims, as observed locally:

```json
{
  "sub": "05017b12731d24a6d10cf9bac65724200ad3986da59b482a2e107055f8e7d7e5",
  "email": "ada@example.com",
  "email_verified": false,
  "name": "Ada Lovelace",
  "given_name": "Ada Lovelace",
  "preferred_username": "ada@example.com",
  "nickname": "ada@example.com",
  "groups": ["mossydew"],
  "zoneinfo": "Europe/Paris"
}
```

- `sub` is a hash of the user id and the install's identifier: stable, identical in every app, kept by a database restore (a brand-new install gives new values). Use it as the account key, not the email (users can change their email).
- `email_verified` is always `false` with Authentik's default mapping, even though every account proved its email by choosing its password from an emailed link.
- `zoneinfo` comes from the user attribute `timezone` (set by `make invite`, editable in the admin user form); absent when unset.
- MossyTrunk also receives `mossytrunk_workspace`, from the user attribute of the same name (`make invite … WORKSPACE="Atelier Mousse"`, editable in the admin user form): the workspace their first MossyTrunk sign-in joins. Absent when unset, and MossyTrunk then opens a workspace of their own.
- A user outside the app's group gets Authentik's "Permission denied" page and the app never receives a code.

Logout (RP-initiated): redirect the browser to `/application/o/<slug>/end-session/?id_token_hint=<id token>&post_logout_redirect_uri=https://<app host>/&state=<optional>`. `id_token_hint` is **required** whenever `post_logout_redirect_uri` is sent (Authentik answers "invalid request" otherwise), and the URI must be one of the registered post-logout URIs above. It signs the user out of Authentik too (the next sign-in asks for the password again), then redirects to `post_logout_redirect_uri?state=…`. Without `post_logout_redirect_uri` the user ends on the sign-in page.

## Accounts

- **Invitation**: `make invite` (or the admin interface, see the server README) creates the user without a password, adds the groups and emails a link valid 7 days. The link opens a confirmation step (so mail scanners cannot burn it), then asks for a password (at least 12 characters), signs the user in and shows their application dashboard.
- **Forgot password**: "Forgot username or password?" on the sign-in page asks for the email and sends a link valid 30 minutes, same 12-character rule.
- **Sessions** last 30 days, so phones stay signed in.
- **Account page** (`/if/user/`): name, email, language, password (12-character rule), sessions, and optional two-factor devices: passkeys/WebAuthn, TOTP apps, recovery codes. Two-factor is never forced; a user with a device is asked for it after the password, and a passkey can also be used straight from the sign-in field.

## Branding

`branding.css` maps the mossyleaf tokens (accent `#5b7f3a`, paper `#f7f8f1` sheet on a `#1e2f17` moss ground, Patua One for titles, Inter for text) onto Authentik's PatternFly variables: the form is a herbarium sheet held by two strips of tape, centered on the page. Authentik injects the brand CSS into the page and into every web component, so plain selectors such as `.pf-c-login__main` work; rules that compete with Authentik's own scoped rules use `:not(#_)` to win on specificity. The theme is pinned to light. `logo.svg` is a hand-drawn leaf with the wordmark converted to outlines from Patua One; `favicon.svg` is the leaf; `background.svg` is a moss-green glow with pressed leaf and fern silhouettes.

The sign-in, recovery and password-change flows run in Authentik's compatibility mode (light DOM instead of shadow DOM) so password managers can fill and save the username and password fields.

### Third-party assets

| Asset | Licence |
|---|---|
| Patua One (LatinoType), `branding/fonts/patua-one-*.woff2`, also outlined in `logo.svg` | SIL Open Font License 1.1, `branding/fonts/LICENSE-patua-one.txt` (via `@fontsource/patua-one` 5.3.0) |
| Inter (The Inter Project Authors), `branding/fonts/inter-*.woff2` | SIL Open Font License 1.1, `branding/fonts/LICENSE-inter.txt` (via `@fontsource-variable/inter` 5.3.0) |
| Authentik `ghcr.io/goauthentik/server` (base of the image) | MIT (open-source edition; no enterprise features used) |
| PostgreSQL `postgres:18-alpine` | PostgreSQL License |
| Mailpit `axllent/mailpit` (local only) | MIT |

## Server

See [deploy/README.md](deploy/README.md): first install, `.env`, nginx block and certificate, first admin, invitations, new apps, backups, updates. Push to `main`, wait for CI to publish the image, then `make deploy` runs that commit's tag on the server. `make deploy-files` / `make deploy` reach the server through `$(DEPLOY_HOST):$(DEPLOY_DIR)`, set in a root `.env` (gitignored):

```bash
DEPLOY_HOST=user@server
DEPLOY_DIR=/path/to/mossyleaf-accounts
REMOTE_DOCKER=docker   # optional, default: docker
```
