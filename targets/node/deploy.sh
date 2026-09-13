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
#   dev-<n>           block n   :900n0   n = 0..9, disposable
#   staging           block 20  :9200
#   production-blue   block 21  :9210
#   production-green  block 22  :9220
#
# DEV BLOCKS GO THROUGH HERE TOO, as of 2026-09-13. They did not, and the
# consequence was that every worktree and every agent hand-rolled its own
# `node apps/<x>/src/server.js &` loop -- a second implementation of deployment,
# the same defect class as deploy-run duplicating the control flow. It drifted
# immediately: some callers forgot router/generate.sh, some forgot BIND, and
# none of them registered the block, which is why ports.tsv claimed three
# allocations with nothing listening.
#
# One script deploys every environment. What differs between dev and production
# is the port block and who may deploy there, not how.
set -eu
env="${1:?usage: deploy.sh <dev-0..dev-9|staging|production-blue|production-green> <sha>}"
sha="${2:?}"
root=$(cd "$(dirname "$0")/../.." && pwd)
case "$env" in
  dev-[0-9])        block=${env#dev-} ;;
  staging)          block=20 ;;
  production-blue)  block=21 ;;
  production-green) block=22 ;;
  *) echo "usage: deploy.sh {dev-0..dev-9|staging|production-blue|production-green} <sha>" >&2; exit 2 ;;
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
  # A DEPLOYMENT WORKTREE IS NOT A WORKING COPY. This script generates
  # router/routes.json into it (below) and git then sees a tracked file as
  # locally modified, so the NEXT deploy's checkout aborts with "your local
  # changes would be overwritten" -- the deployer blocking itself with its own
  # output. Hit on 2026-09-13 deploying #38 to staging.
  #
  # Discarding is right here and nowhere else: nothing in a deployment worktree
  # is authored, every tracked file comes from the SHA being deployed, and
  # anything that differs is this script's own leftovers. Untracked files (the
  # per-app logs, version.json) are deliberately left alone -- they are the
  # record of the run that just happened, and -d would delete them.
  git -C "$wt" checkout -q --force -- . 2>/dev/null || true
  git -C "$wt" checkout -q --detach "$full"
else
  git -C "$root" worktree add -q --detach "$wt" "$full"
fi

# AN ENVIRONMENT MUST OUTLIVE THE SHELL THAT DEPLOYED IT.
#
# These were started with `nohup node ... &`, and nohup only ignores SIGHUP. It
# does NOT leave the process group or start a new session, so anything that
# signals the caller's process group takes the whole estate with it. On
# 2026-09-13 staging came up on 266c3a0, served correctly, and went dark the
# moment the backgrounded deploy command was reaped -- ports 9200-9205 all
# refused, zero processes, while the worktree sat there fully checked out
# looking deployed. The deploy had already reported success, and was right to:
# it HAD deployed. The environment then died with its parent.
#
# daemon(8) is the FreeBSD answer (setsid is util-linux and is not here): -f
# redirects stdio, and it forks into a session of its own so the process is
# reparented to init and survives the caller entirely.
# The variables are EXPORTED inside the subshell rather than written as
# assignment-prefixes on the call. A prefix in front of a shell FUNCTION does
# not reliably survive into what that function execs, and daemon(8) execs: the
# first attempt logged `core listening on 0 (block ?, sha dev)` and the router
# died on a missing BASE_PORT. Export, then daemon inherits.
spawn() { # spawn <logfile> <command...>
  _log="$1"; shift
  daemon -f -o "$_log" "$@"
}

printf '{"sha":"%s","env":"%s","block":%d}\n' "$short" "$env" "$block" > "$wt/version.json"
( cd "$wt" && sh router/generate.sh >/dev/null 2>&1 || true )

n=1
for app in core plp pdp checkout; do
  ( cd "$wt" && export BUILD_SHA="$short" BLOCK="$env" PORT=$((base + n)) BIND=0.0.0.0
    spawn "$wt/.$app.log" node "apps/$app/src/server.js" )
  n=$((n + 1))
done
( cd "$wt" && export BUILD_SHA="$short" BLOCK="$env" PORT=$((base + 5)) BIND=0.0.0.0
  spawn "$wt/.mock.log" node external/mock/src/server.js )
sleep 1
( cd "$wt" && export BUILD_SHA="$short" BLOCK="$env" BASE_PORT="$base" BIND=0.0.0.0
  spawn "$wt/.router.log" node router/server.js )
# Register the block. ports.sh allocates by editing a file and never asks what
# is bound, so a block whose process died stayed "held" forever and a block
# started outside the registry was invisible. Deploying IS the allocation:
# the row is written by the thing that actually started the processes.
if [ "$block" -lt 10 ]; then
  wt=$(git -C "$root" rev-parse --show-toplevel 2>/dev/null || echo "$root")
  br=$(git -C "$root" rev-parse --abbrev-ref HEAD 2>/dev/null || echo detached)
  python3 - "$root/ports.tsv" "$block" "$wt" "$br" <<'PORTS'
import sys, pathlib, datetime
f, blk, wt, br = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4]
rows = [l for l in f.read_text().split("\n") if l.strip()] if f.exists() else ["block\tworktree\tbranch\tallocated_at"]
# TWO invariants, and only the first was enforced: a block is held by at most
# one worktree, AND a worktree holds at most one block. Dropping rows by block
# alone let this worktree accumulate rows for blocks 0 and 6, after which
# change/ports.sh's `b=$(awk ...)` returned the two-line string "0\n6" and
# `$((BASE0 + 10 * b))` died with "variable conversion error" -- gmake .env
# broken by a registry that two writers disagreed about.
hdr, body = rows[0], [r for r in rows[1:]
                      if r.split("\t")[0] != blk and r.split("\t")[1] != wt]
body.append("\t".join([blk, wt, br, datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")]))
f.write_text("\n".join([hdr] + body) + "\n")
PORTS
fi

sleep 2
echo "  $env <- $short  (block $block, :$base)"
