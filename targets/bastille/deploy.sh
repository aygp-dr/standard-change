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
i=0
for j in $jail; do
  i=$((i+1))
  jr="/usr/local/bastille/jails/$j/root"
  sudo install -d "$jr/opt/app" "$jr/usr/local/etc/nginx"
  sudo install -m755 "$root/targets/bastille/app.py" "$jr/opt/app/app.py"
  sudo install -m644 "$root/router/routes.json" "$jr/opt/app/routes.json"
  sudo install -m644 "$root/targets/bastille/nginx.conf.tmpl" "$jr/usr/local/etc/nginx/nginx.conf"

  # the build this estate serves -- written by the JAIL at deploy, read by guard 5
  printf '{"sha":"%s","env":"%s","replica":%d}\n' "$sha" "$env" "$i" \
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
