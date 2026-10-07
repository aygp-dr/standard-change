#!/bin/sh
# deploy.sh <env> [sha] -- install a build into a jail and start it.
#
# Promotion here is "install this commit into that jail", which is WEAKER than
# promoting an image digest: the artifact is rebuilt from source in each
# environment rather than carried across. Recorded rather than glossed
# (spec.org, Cloud mirror). What the jail does give is attestation -- the host
# runs it, so jls is evidence, not a self-report.
set -eu
env="$1"; sha="${2:-$(git rev-parse --short HEAD)}"
case "$env" in
  staging)      jail=sc-staging ;;
  production)   jail="sc-prod-1 sc-prod-2" ;;   # two replicas: convergence means something
  *) echo "usage: deploy.sh {staging|production} [sha]" >&2; exit 2 ;;
esac
root=$(cd "$(dirname "$0")/../.." && pwd)

# GUARD THE ACT, NOT ONLY THE DECISION. (issue #32)
#
# The same hole as targets/node/deploy.sh, and the reason change/authorize.sh
# is a script both targets call rather than a block of logic pasted into each:
# one implementation, two callers, which is the opposite of the divergence
# scenarios.org D9 warned a window check inside every target would cause.
#
# Note this target's environments are `staging` and `production` -- there is
# no dev block here, so every deploy through it is a protected one.
#
# UNPIPEABLE: command substitution and `|| exit $?`, never `authorize.sh | sed`.
authorisation=$("$root/change/authorize.sh" "$env" "$sha") || exit $?

i=0
for j in $jail; do
  i=$((i+1))
  jr="/usr/local/bastille/jails/$j/root"
  sudo install -d "$jr/opt/app" "$jr/usr/local/etc/nginx"
  sudo install -m755 "$root/targets/bastille/app.py" "$jr/opt/app/app.py"
  sudo install -m644 "$root/router/routes.json" "$jr/opt/app/routes.json"
  sudo install -m644 "$root/targets/bastille/nginx.conf.tmpl" "$jr/usr/local/etc/nginx/nginx.conf"

  # the build this estate serves -- written by the JAIL at deploy, read by guard 5
  # `authorisation` names the entitlement this deploy used, so a break-glass is
  # visible in the record rather than being an env var nobody sees (issue #32).
  printf '{"sha":"%s","env":"%s","replica":%d,"authorisation":"%s"}\n' \
    "$sha" "$env" "$i" "$authorisation" \
    | sudo tee "$jr/var/run/version.json" >/dev/null

  sudo jexec "$j" sh -c 'pkill -f "python3.11 app.py" 2>/dev/null; pkill nginx 2>/dev/null; true'
  sleep 1
  n=1
  for app in core plp pdp checkout mock; do
    routes=$(jq -c --arg a "$app" '[.[]|select(.app==$a)|.routes[]]' "$root/router/routes.json")
    sudo jexec "$j" sh -c "cd /opt/app && APP=$app PORT=800$n BUILD_SHA=$sha DEPLOY_ENV=$env \
        ROUTES='$routes' nohup python3.11 app.py >/var/log/$app.log 2>&1 &"
    n=$((n+1))
  done
  sudo jexec "$j" sh -c 'nginx -c /usr/local/etc/nginx/nginx.conf' || true
  echo "  $j <- $sha ($env, replica $i)"
done
