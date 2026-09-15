#!/bin/sh
# oracle.sh -- where a gate's EXPECTATIONS come from.  (issue #14)
#
# A gate that sends its REQUESTS to $ROUTER_URL and takes its EXPECTATIONS
# from the tree the script happens to live in is testing one build against
# another build's contract, and the working directory decides the verdict.
# Observed: the identical gate against the identical estate reported
# 24 checks / staging:e2e-failed from the main checkout and
# 27 checks / staging:e2e from the PR's worktree.
#
# That instance was wrong in the SAFE direction, which is luck. The same
# mechanism passes green when the runner's tree knows about FEWER routes than
# the deployed build: every route the build added goes unchecked and the gate
# reports success because it did not know to look. A gate that can pass
# because it did not look is worse than one that fails.
#
# The principle -- the one guard 5 got wrong -- is: prefer a fact the system
# reports about itself over a fact the caller supplies about it.
#
# Resolution order:
#
#   1. ESTATE. GET /__estate.json. The router publishes the route table it is
#      actually routing on, stamped with its build. That is the oracle, and
#      the gate then checks the claim: a build that declares a route it does
#      not serve fails the ownership loop, which is a finding worth having
#      rather than one to paper over.
#
#   2. TREE == BUILD. The estate serves no manifest -- it predates this file --
#      but its x-build-sha is this tree's HEAD. Then the tree IS the build and
#      its routes.json is the build's routes.json. Same oracle, established
#      rather than assumed.
#
#   3. REFUSE. Anything else: exit 4 and record nothing. Not a verdict of
#      failure -- an admission that this run cannot say anything about that
#      estate in either direction. The estate is untouched by our ignorance
#      of it, and a gate that cannot name its oracle has not measured.
#
# ORACLE_MODE=tree forces (2) without the check, for the case where you know
# what you are doing and need to look anyway. A run on a forced oracle prints
# its findings and records NO label: a caller-supplied oracle can inform you,
# it cannot convict.
#
# Sourced by gates/e2e.sh.  Runnable on its own as a probe:
#
#   ./gates/oracle.sh http://127.0.0.1:9010
#
set -eu

ORACLE_MANIFEST_PATH='/__estate.json'
# The repo root. Callers that have already cd'd there set it; standing alone,
# derive it from this script. Never from the caller's cwd by accident -- that
# is the class of mistake this whole file exists to close.
ORACLE_ROOT="${ORACLE_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"

# oracle_resolve <base-url>
#   sets ORACLE       file holding the route table (same shape as router/routes.json)
#        ORACLE_FROM  estate | tree | tree-forced
#        ORACLE_SHA   the build the oracle describes, or '-'
#        ORACLE_WHY   one line, for the gate's output
#   returns 0, or 4 having printed why it will not proceed.
oracle_resolve() {
  _base="$1"
  _root="$ORACLE_ROOT"
  _tree="$_root/router/routes.json"
  # mktemp -t takes a PREFIX on FreeBSD and requires trailing X's on GNU
  # coreutils, where it dies with "too few X's in template". This gate runs on
  # hydra AND on ubuntu-latest, and on ubuntu the failure landed before the
  # REFUSED diagnostic could print -- so the gate exited 4 having run ZERO
  # checks while looking like a clean refusal. Found in review, not by CI.
  ORACLE=$(mktemp "${TMPDIR:-/tmp}/oracle.XXXXXX") || return 4
  ORACLE_FROM=''; ORACLE_SHA='-'; ORACLE_WHY=''
  _dep=$(curl -sI --max-time 5 "$_base/" 2>/dev/null | tr -d '\r' \
           | awk 'tolower($1)=="x-build-sha:"{print $2}' | head -1)
  _head=$(git -C "$_root" rev-parse --short HEAD 2>/dev/null || echo '')

  # 0. the escape hatch, checked FIRST so that it reproduces the old behaviour
  # exactly -- including the blindness. A forced oracle that quietly upgraded
  # itself to the estate's would be unable to show anyone what it is for.
  if [ "${ORACLE_MODE:-}" = tree ]; then
    cp "$_tree" "$ORACLE" 2>/dev/null || { echo "oracle: no $_tree in this tree" >&2; return 4; }
    ORACLE_FROM=tree-forced
    ORACLE_SHA="${_dep:--}"
    ORACLE_WHY="this tree at ${_head:-unknown}, FORCED (ORACLE_MODE=tree); the estate reports ${_dep:-nothing}"
    return 0
  fi

  # 1. what the estate says about itself.
  #
  # Check the SHAPE, not just that some JSON came back with a `routes` key. On
  # a router that predates the manifest this path falls through to the default
  # app, and core's 404 body is {app, path, found, block, sha, routes:[...]} --
  # a routes array, of strings, describing one app. Accepting that produced an
  # 8-app oracle out of a 5-app estate and jq errors instead of a refusal:
  # exactly the class of mistake this file exists to stop, one level down.
  # Only the router answers with served_by=router and a list of app objects.
  _m=$(curl -s --max-time 5 "$_base$ORACLE_MANIFEST_PATH" 2>/dev/null || true)
  if printf '%s' "$_m" | jq -e '
        (.served_by? == "router")
        and (.routes | type == "array" and length > 0
             and all(.[]; type == "object" and has("app") and (.routes | type == "array")))
      ' >/dev/null 2>&1; then
    printf '%s' "$_m" | jq '.routes' > "$ORACLE"
    ORACLE_FROM=estate
    ORACLE_SHA=$(printf '%s' "$_m" | jq -r '.sha // "-"')
    ORACLE_WHY="$ORACLE_MANIFEST_PATH at build $ORACLE_SHA ($(jq -r 'length' "$ORACLE") apps)"
    return 0
  fi

  # 2. no manifest. The tree may still be the build -- but it has to prove it.
  cp "$_tree" "$ORACLE" 2>/dev/null || { echo "oracle: no $_tree in this tree" >&2; return 4; }

  if [ -n "$_dep" ] && [ -n "$_head" ] && oracle_same_sha "$_dep" "$_head"; then
    ORACLE_FROM=tree
    ORACLE_SHA="$_dep"
    ORACLE_WHY="this tree, which IS the deployed build ($_dep); estate serves no $ORACLE_MANIFEST_PATH"
    return 0
  fi

  rm -f "$ORACLE"; ORACLE=''
  echo "REFUSED: this gate cannot establish an oracle for $_base" >&2
  echo "  the estate serves no $ORACLE_MANIFEST_PATH (a build older than issue #14)," >&2
  echo "  and it reports build '${_dep:-nothing at all}' while this tree is at '${_head:-unknown}'." >&2
  echo "  Testing that build against this tree's routes.json is how the same gate" >&2
  echo "  returned 24 checks from one directory and 27 from another. No verdict." >&2
  echo "  Fix it by deploying a build that publishes its routes, by checking out" >&2
  echo "  '${_dep:-that sha}', or -- to look without convicting -- ORACLE_MODE=tree." >&2
  return 4
}

# Short shas of different lengths are the same sha if one prefixes the other.
oracle_same_sha() {
  case "$1" in "$2"*) return 0 ;; esac
  case "$2" in "$1"*) return 0 ;; esac
  return 1
}

# What the tree would have asserted that the build does not own, and vice
# versa. Printed, never fatal: it is the line that would have saved an hour.
oracle_tree_delta() {   # <oracle-file>
  jq -n --slurpfile a "$1" --slurpfile b "$ORACLE_ROOT/router/routes.json" '
    def flat: .[0] | map(.app as $x | (.routes // []) | map("\($x) \(.)")) | add // [];
    { estate_only: (($a|flat) - ($b|flat)), tree_only: (($b|flat) - ($a|flat)) }' \
    2>/dev/null || echo '{"estate_only":[],"tree_only":[]}'
}

# Standalone probe. e2e.sh sets ORACLE_LIB=1 before sourcing.
if [ "${ORACLE_LIB:-0}" != 1 ]; then
  [ $# -ge 1 ] || { echo "usage: oracle.sh <base-url>" >&2; exit 2; }
  oracle_resolve "$1" || exit $?
  echo "oracle: $ORACLE_FROM -- $ORACLE_WHY"
  jq -r '.[] | "  \(.app)\t\(.routes | join(" "))"' "$ORACLE"
  oracle_tree_delta "$ORACLE" | jq -c .
  rm -f "$ORACLE"
fi
