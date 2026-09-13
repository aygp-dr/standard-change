#!/bin/sh
# evidence.sh -- a measurement is evidence only if it names the build it was
# taken on.
#
# WHY THIS EXISTS. `staging:e2e` on a pull request is a claim about a BUILD,
# written in a medium that cannot hold one. The label says "e2e passed"; it
# does not say on what. That gap is closed today by a cleanup step -- the
# labeller withdraws every observation on `synchronize` -- and a guard whose
# soundness depends on a cleanup step firing is sound only as often as the
# cleanup fires. On #11 it did not, and `staging:e2e staging:smoke` sat on a PR
# whose head had moved from 9d85a33 to baed821, authorizing a build nobody had
# measured (issue #16).
#
# The repair is not a better cleanup. It is to stop asking a label to carry a
# fact it cannot carry. An observation is written as a PR COMMENT that names
# the environment, the instrument, the verdict and the SHA, and a guard that
# relies on it re-reads that record and checks the SHA against the head it is
# authorizing right now. A record from an older build does not go stale and
# need withdrawing -- it stays true, about the build it names, and simply
# stops matching. Nothing has to fire for that to hold.
#
#   durable label          "this PR has passed staging e2e"
#   point-in-time record   "the run at 16:06 observed e2e green on 9d85a33"
#
# The first must be maintained. The second cannot rot.
#
# The labels stay, and they stay useful: they are the CURRENT-RUN signal that
# the deployment process sets as it goes and clears as it moves on. What they
# are no longer is the thing a guard authorizes on.
#
#   evidence.sh record <pr> <env> <instrument> <pass|fail> <sha> [url]
#   evidence.sh latest <pr> <env> <instrument>      -> "<verdict> <sha> <author>"
#
# `latest` exits 1 when there is no record at all, so a caller that never ran
# the instrument fails closed rather than reading silence as consent.
#
# This script writes NO labels. The declared owner of an observation label is
# the gate that took the measurement (change/label-owners.tsv); a shared helper
# writing them would be a second writer, which is how the thrash starts.
set -eu

cmd="${1:?usage: evidence.sh record|latest ...}"
shift
repo="${GH_REPO:-${GITHUB_REPOSITORY:-aygp-dr/standard-change}}"

# One line, one grammar, versioned so it can be changed without silently
# reinterpreting old records. Machine-readable on purpose: a guard must be able
# to tell an observation from someone describing one in prose.
marker_prefix='<!-- observation v1 '

case "$cmd" in

record)
  pr="${1:?record needs <pr>}"; env_="${2:?record needs <env>}"
  inst="${3:?record needs <instrument>}"; verdict="${4:?record needs pass|fail}"
  sha="${5:-unknown}"; url="${6:-}"
  case "$verdict" in pass|fail) ;; *) echo "verdict must be pass or fail" >&2; exit 2 ;; esac
  # An observation with no build is not an observation. Recording it as
  # `unknown` rather than refusing keeps the failure visible on the PR -- and
  # `unknown` never equals a head SHA, so it authorizes nothing.
  [ -n "$sha" ] || sha=unknown

  if [ "$verdict" = pass ]; then head="**\`$env_:$inst\` PASSED on \`$sha\`**"
  else                           head="**\`$env_:$inst\` FAILED on \`$sha\`**"; fi

  gh pr comment "$pr" --repo "$repo" --body "$head

| | |
|---|---|
| environment | \`$env_\` |
| instrument | \`$inst\` |
| build observed | \`$sha\` |
| where | ${url:-\`-\`} |

This is a point-in-time observation, not a durable claim about this pull
request. It says what was true of \`$sha\`. It says nothing about any later
build, and it does not need withdrawing when the head moves: a guard that
relies on it checks the SHA above against the head it is authorizing.

${marker_prefix}env=$env_ instrument=$inst verdict=$verdict sha=$sha -->"
  echo "  #$pr evidence: $env_:$inst $verdict on $sha"
  ;;

latest)
  pr="${1:?latest needs <pr>}"; env_="${2:?latest needs <env>}"
  inst="${3:?latest needs <instrument>}"
  # Comments come back oldest-first, so the last matching marker is the most
  # recent observation by that instrument on that environment. LAST WINS, and
  # that is the point: a re-run supersedes its predecessor without anyone
  # having to withdraw anything.
  #
  # The author is carried through and reported. It is not enforced here --
  # nothing stops a person typing the marker by hand, exactly as nothing stops
  # a person adding the label by hand -- but an unattributed observation and
  # one signed by the gate should not look alike to a reader.
  line=$(gh api "repos/$repo/issues/$pr/comments" --paginate \
           --jq '.[] | . as $c | ($c.body | split("\n")[])
                 | select(startswith("'"$marker_prefix"'"))
                 | "\($c.user.login) \(.)"' 2>/dev/null \
         | grep " env=$env_ " | grep " instrument=$inst " | tail -1) || true
  [ -n "${line:-}" ] || exit 1
  author=${line%% *}
  verdict=$(printf '%s\n' "$line" | sed -n 's/.* verdict=\([^ ]*\).*/\1/p')
  sha=$(printf '%s\n' "$line" | sed -n 's/.* sha=\([^ ]*\).*/\1/p')
  [ -n "$verdict" ] && [ -n "$sha" ] || exit 1
  printf '%s %s %s\n' "$verdict" "$sha" "$author"
  ;;

*)
  echo "usage: evidence.sh record|latest ..." >&2; exit 2 ;;
esac
