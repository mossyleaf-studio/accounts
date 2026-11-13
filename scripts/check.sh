#!/usr/bin/env sh
# Smoke test of a running stack (make up): the blueprints applied, every app
# has its OpenID configuration, the sign-in page and the brand are served.
set -eu

BASE="http://localhost:${AUTHENTIK_PORT:-9000}"
APPS="mossydew mossytrunk mossyleaf-studio muhmeal injust"
# One brand per context, reached by Host (local domains from compose.yaml).
PORT="${AUTHENTIK_PORT:-9000}"
BRANDS="localhost:$PORT=mossyleaf injust.localhost:$PORT=Injust personal.localhost:$PORT=duprat.cloud"
ATTEMPTS="${CHECK_ATTEMPTS:-60}"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

blueprint_status() {
  docker compose exec -T worker ak shell -c "
from authentik.blueprints.models import BlueprintInstance
for b in BlueprintInstance.objects.filter(path__startswith='custom').order_by('path'):
    print('STATUS', b.status, b.path)
" 2>/dev/null | grep '^STATUS' || true
}

echo "Waiting for the blueprints..."
i=0
while :; do
  statuses=$(blueprint_status)
  total=$(printf '%s\n' "$statuses" | grep -c '^STATUS' || true)
  ok=$(printf '%s\n' "$statuses" | grep -c '^STATUS successful' || true)
  if [ "$total" -ge 2 ] && [ "$ok" -eq "$total" ]; then
    break
  fi
  if printf '%s\n' "$statuses" | grep -q '^STATUS error'; then
    printf '%s\n' "$statuses" >&2
    fail "a blueprint failed to apply (make logs)"
  fi
  i=$((i + 1))
  [ "$i" -lt "$ATTEMPTS" ] || { printf '%s\n' "$statuses" >&2; fail "blueprints not applied in time"; }
  sleep 5
done
printf '%s\n' "$statuses" | sed 's/^STATUS /  /'

for app in $APPS; do
  issuer=$(curl -sf "$BASE/application/o/$app/.well-known/openid-configuration" | sed -n 's/.*"issuer": *"\([^"]*\)".*/\1/p')
  [ -n "$issuer" ] || fail "no OpenID configuration for $app"
  echo "  $app: $issuer"
done

page=$(curl -sf "$BASE/if/flow/mossyleaf-authentication/") || fail "sign-in page not served"
printf '%s' "$page" | grep -q 'ShadyDOM.force' || fail "sign-in flow is not in compatibility mode (password managers)"
echo "  sign-in page: compatibility mode"

curl -sf "$BASE/static/dist/custom/branding.css" | grep -q -- '--ml-paper' || fail "branding.css not served"
curl -sf -o /dev/null "$BASE/static/dist/custom/logo.svg" || fail "logo.svg not served"
echo "  brand assets served"

for brand in $BRANDS; do
  host=${brand%%=*}
  title=${brand#*=}
  curl -sf -H "Host: $host" "$BASE/if/flow/mossyleaf-authentication/" | grep -q "<title>$title</title>" || fail "$host does not serve the $title brand"
  # Forgot password must stop at the email step on every brand, never jump to the new password.
  jar=$(mktemp)
  curl -sf -c "$jar" -b "$jar" -H "Host: $host" "$BASE/api/v3/flows/executor/mossyleaf-recovery/?query=" >/dev/null
  step=$(curl -sfL -c "$jar" -b "$jar" -H "Host: $host" -H 'Content-Type: application/json' \
    -d '{"component":"ak-stage-identification","uid_field":"nobody@example.com"}' \
    "$BASE/api/v3/flows/executor/mossyleaf-recovery/?query=" | sed -n 's/.*"component": *"\([^"]*\)".*/\1/p')
  rm -f "$jar"
  [ "$step" = "ak-stage-email" ] || fail "$host recovery goes to '$step' instead of the email step"
  echo "  $host: $title brand, recovery by email"
done

echo "OK"
