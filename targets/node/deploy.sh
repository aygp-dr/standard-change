#!/bin/sh
# deploy.sh <env> <sha> -- install a build into a node block and start it.
#
# targets/bastille installs targets/bastille/app.py into a jail: a Python
# stand-in that is not any of the apps. Every unit test, lint rule and local
# e2e run exercises apps/*/src/server.js, which that target never installs
# anywhere -- so the deployed thing was never the tested thing, and the estate
# served JSON to a browser because app.py does not content-negotiate.
#
# This target deploys THE APPS. A deployment is a git worktree pinned to a SHA
# with the block's node processes started from it. Weaker attestation than a
# jail (no jls), stronger correspondence: it is the code under test.
#
# PORT TIER. The number tells you what an environment is, so protected
# environments must live in the protected tier -- 9000-9099 is dev and dev is
# disposable by definition. An earlier cut of this file put production on
# blocks 1 and 2 (:9010/:9020), which is a production environment inside the
# tier whose defining property is that anyone may reclaim it.
#
#   staging           block 20  :9200
#   production-blue   block 21  :9210
#   production-green  block 22  :9220
set -eu
env="${1:?usage: deploy.sh <staging|production-blue|production-green> <sha>}"
sha="${2:?}"
root=$(cd "$(dirname "$0")/../.." && pwd)
case "$env" in
  staging)          block=20 ;;
  production-blue)  block=21 ;;
  production-green) block=22 ;;
  *) echo "usage: deploy.sh {staging|production-blue|production-green} <sha>" >&2; exit 2 ;;
esac
base=$((9000 + block * 10))
wt="$root/deployments/$env"

# The SHA must exist. targets/bastille accepted `deadbee` and stamped it into
# version.json, which is how guard 5 came to pass on a commit never built.
# A deployment that cannot name a real tree is not a deployment.
full=$(git -C "$root" rev-parse --verify "${sha}^{commit}" 2>/dev/null) || {
  echo "  refused: $sha is not a commit in this repository" >&2; exit 3; }
short=$(echo "$full" | cut -c1-7)

for p in $(seq "$base" $((base + 5))); do
  pid=$(sockstat -4l 2>/dev/null | awk -v p=":$p" '$6 ~ p"$" {print $3}' | head -1)
  [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
done
sleep 1

if [ -d "$wt" ]; then
  git -C "$wt" checkout -q --detach "$full"
else
  git -C "$root" worktree add -q --detach "$wt" "$full"
fi

printf '{"sha":"%s","env":"%s","block":%d}\n' "$short" "$env" "$block" > "$wt/version.json"
( cd "$wt" && sh router/generate.sh >/dev/null 2>&1 || true )

n=1
for app in core plp pdp checkout; do
  ( cd "$wt" && BUILD_SHA="$short" BLOCK="$env" PORT=$((base + n)) BIND=0.0.0.0 \
      nohup node "apps/$app/src/server.js" > "$wt/.$app.log" 2>&1 & )
  n=$((n + 1))
done
( cd "$wt" && BUILD_SHA="$short" BLOCK="$env" PORT=$((base + 5)) BIND=0.0.0.0 \
    nohup node external/mock/src/server.js > "$wt/.mock.log" 2>&1 & )
sleep 1
( cd "$wt" && BUILD_SHA="$short" BLOCK="$env" BASE_PORT="$base" BIND=0.0.0.0 \
    nohup node router/server.js > "$wt/.router.log" 2>&1 & )
sleep 2
echo "  $env <- $short  (block $block, :$base)"
