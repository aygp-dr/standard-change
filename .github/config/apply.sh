#!/usr/bin/env bash
# apply.sh -- apply the repository controls described in spec.org (Controls audit)
# to a GitHub repository. Idempotent: safe to re-run; converges, never duplicates.
#
#   ./.github/config/apply.sh              # DRY RUN (default): prints what would change
#   ./.github/config/apply.sh --apply      # actually writes
#   ./.github/config/apply.sh --repo o/r --apply
#
# Acceptance criterion: after --apply, `./gates/audit-controls.py` reports
# 0 findings, 0 absent, 0 unreadable.
#
# Every GET here runs in both modes (reads are free and make the diff honest).
# Every POST/PUT/PATCH runs only under --apply.
#
# KNOWN BLOCKER on aygp-dr/standard-change (private repo, free plan):
#   repos/{o}/{r}/rulesets answers 403 "Upgrade to GitHub Pro or make this
#   repository public". The ruleset section below will report that and skip.
#   Environment protection rules carry the same plan restriction on private
#   repos. This is spec.org "Availability is itself a finding" -- the script
#   surfaces it rather than laundering it as applied.

set -euo pipefail

REPO="${REPO:-aygp-dr/standard-change}"
MODE="dry-run"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Set to 1 to forbid the deployment's own author from approving it. Left 0
# because this repo has a single maintainer, and 1 would deadlock every
# production deploy -- which, per spec.org "The balance", routes traffic to
# change:emergency instead of making anything safer. Flip it the moment a
# second change authority exists.
PREVENT_SELF_REVIEW=0

while [ $# -gt 0 ]; do
  case "$1" in
    --apply)   MODE="apply" ;;
    --dry-run) MODE="dry-run" ;;
    --repo)    REPO="$2"; shift ;;
    -h|--help) sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 64 ;;
  esac
  shift
done

for f in ruleset-main.json env-staging.json env-production.json \
         env-staging-branch-policies.json variables.json; do
  [ -f "$HERE/$f" ] || { echo "missing payload: $HERE/$f" >&2; exit 66; }
  jq -e . "$HERE/$f" >/dev/null || { echo "invalid JSON: $HERE/$f" >&2; exit 65; }
done

RC=0
say()  { printf '%s\n' "$*"; }
plan() { printf '  WOULD %s\n' "$*"; }
did()  { printf '  DONE  %s\n' "$*"; }
same() { printf '  ok    %s\n' "$*"; }
warn() { printf '  N/A   %s\n' "$*" >&2; RC=2; }

# write <description> <gh args...>
write() {
  local desc="$1"; shift
  if [ "$MODE" = "dry-run" ]; then
    plan "$desc"
    printf '        gh %s\n' "$*"
  else
    gh "$@" >/dev/null && did "$desc"
  fi
}

say "repo: $REPO"
say "mode: $MODE$([ "$MODE" = dry-run ] && echo '  (no writes; pass --apply to write)')"
say ""

# ---------------------------------------------------------------- ruleset ----
say "[1/4] branch ruleset on the default branch"

rulesets=""
if raw="$(gh api "repos/$REPO/rulesets" 2>&1)"; then
  rulesets="$raw"
else
  msg="$(printf '%s' "$raw" | jq -r '.message? // empty' 2>/dev/null || true)"
  [ -n "$msg" ] || msg="$(printf '%s\n' "$raw" | sed -n '1p')"
  warn "rulesets unreadable: $msg"
  warn "the entire ruleset table is unenforceable here, not merely unconfigured"
fi

if [ -n "$rulesets" ]; then
  want_name="$(jq -r .name "$HERE/ruleset-main.json")"
  id="$(printf '%s' "$rulesets" | jq -r --arg n "$want_name" \
        'map(select(.name==$n and .source_type=="Repository")) | .[0].id // empty')"
  if [ -z "$id" ]; then
    write "create ruleset '$want_name'" \
      api --method POST "repos/$REPO/rulesets" --input "$HERE/ruleset-main.json"
  else
    cur="$(gh api "repos/$REPO/rulesets/$id")"
    # Subset semantics: every field we specify must match what is live.
    # Extra defaults GitHub echoes back are ignored, or the script would
    # report drift forever and never be idempotent.
    # Subset semantics: every field we specify must match what is live.
    # Extra defaults GitHub echoes back are ignored, or the script would
    # report drift forever and never be idempotent. Required status-check
    # contexts and required deployment environments are compared as SUPERSETS,
    # matching audit-controls.py (GATES - ctx) and spec.org "Ruleset rules to
    # spec controls": a project may require extra checks; this spec makes no
    # claim about them and must not churn them away. Caveat: if some OTHER
    # field does drift, the PUT below replaces the whole ruleset and would
    # drop those extra contexts -- add them to ruleset-main.json if the repo
    # relies on them.
    subset='def sub($h; $w): ($h * $w) == $h;
      def rulematch($h; $w):
        if $w.type == "required_status_checks" then
          sub($h.parameters; ($w.parameters | del(.required_status_checks)))
          and (([$w.parameters.required_status_checks[].context]
                - [$h.parameters.required_status_checks[]?.context]) == [])
        elif $w.type == "required_deployments" then
          (($w.parameters.required_deployment_environments
            - ($h.parameters.required_deployment_environments // [])) == [])
        else sub($h; $w) end;
      . as [$have, $want]
      | ($have.enforcement == $want.enforcement)
        and (($have.bypass_actors // []) == ($want.bypass_actors // []))
        and (($have.conditions.ref_name.include // [] | sort)
             == ($want.conditions.ref_name.include // [] | sort))
        and (($have.conditions.ref_name.exclude // [] | sort)
             == ($want.conditions.ref_name.exclude // [] | sort))
        and ([$want.rules[] | . as $w
              | [$have.rules[] | select(.type == $w.type)
                 | select(rulematch(.; $w))] | length > 0] | all)'
    if printf '%s\n%s\n' "$cur" "$(cat "$HERE/ruleset-main.json")" \
         | jq -se "$subset" >/dev/null; then
      same "ruleset '$want_name' (id $id) already satisfies the spec"
    else
      say "  drift (live -> desired), spec-relevant fields only:"
      view='{enforcement, bypass_actors, include: .conditions.ref_name.include,
             rules: (.rules | sort_by(.type))}'
      diff <(printf '%s' "$cur" | jq -S "$view") \
           <(jq -S "$view" "$HERE/ruleset-main.json") | sed 's/^/        /' || true
      write "update ruleset '$want_name' (id $id)" \
        api --method PUT "repos/$REPO/rulesets/$id" --input "$HERE/ruleset-main.json"
    fi
  fi
fi
say ""

# ----------------------------------------------------------- environments ----
say "[2/4] environments"

for env in staging production; do
  payload="$HERE/env-$env.json"
  tmp=""
  if [ "$PREVENT_SELF_REVIEW" = "1" ]; then
    tmp="$(mktemp)"
    jq '.prevent_self_review = true' "$payload" >"$tmp"
    payload="$tmp"
  fi

  if cur="$(gh api "repos/$REPO/environments/$env" 2>/dev/null)"; then
    have_pol="$(printf '%s' "$cur" | jq -c '.deployment_branch_policy')"
    want_pol="$(jq -c '.deployment_branch_policy' "$payload")"
    have_rev="$(printf '%s' "$cur" | jq -c \
      '[.protection_rules[]? | select(.type=="required_reviewers")
        | .reviewers[]? | {type: .type, id: .reviewer.id}] | sort')"
    want_rev="$(jq -c '[(.reviewers // [])[] | {type, id}] | sort' "$payload")"
    have_wait="$(printf '%s' "$cur" | jq -r \
      '[.protection_rules[]? | select(.type=="wait_timer") | .wait_timer][0] // 0')"
    want_wait="$(jq -r '.wait_timer // 0' "$payload")"
    if [ "$have_pol" = "$want_pol" ] && [ "$have_rev" = "$want_rev" ] \
       && [ "$have_wait" = "$want_wait" ]; then
      same "environment $env already matches"
    else
      say "  environment $env drift:"
      [ "$have_pol"  = "$want_pol"  ] || say "        branch policy: $have_pol -> $want_pol"
      [ "$have_rev"  = "$want_rev"  ] || say "        reviewers:     $have_rev -> $want_rev"
      [ "$have_wait" = "$want_wait" ] || say "        wait_timer:    $have_wait -> $want_wait"
      write "update environment $env" \
        api --method PUT "repos/$REPO/environments/$env" --input "$payload"
    fi
  else
    say "  environment $env: absent"
    write "create environment $env" \
      api --method PUT "repos/$REPO/environments/$env" --input "$payload"
  fi
  [ -z "$tmp" ] || rm -f "$tmp"
done

# staging uses custom_branch_policies, so the patterns are a separate resource.
if [ "$(jq -r '.deployment_branch_policy.custom_branch_policies' "$HERE/env-staging.json")" = "true" ]; then
  existing='[]'
  if out="$(gh api "repos/$REPO/environments/staging/deployment-branch-policies" 2>/dev/null)"; then
    existing="$(printf '%s' "$out" | jq -c '[.branch_policies[]?.name]')"
  elif [ "$MODE" = "apply" ]; then
    warn "staging deployment-branch-policies unreadable; skipping patterns"
    existing='SKIP'
  fi
  if [ "$existing" != "SKIP" ]; then
    while read -r name; do
      if printf '%s' "$existing" | jq -e --arg n "$name" 'index($n)' >/dev/null; then
        same "staging branch policy '$name' present"
      else
        write "add staging branch policy '$name'" \
          api --method POST "repos/$REPO/environments/staging/deployment-branch-policies" \
              -f "name=$name" -f "type=branch"
      fi
    done < <(jq -r '.policies[].name' "$HERE/env-staging-branch-policies.json")
  fi
fi
say ""

# -------------------------------------------------------------- variables ----
say "[3/4] repository variables"

have_vars='{}'
if out="$(gh api "repos/$REPO/actions/variables" --paginate 2>/dev/null)"; then
  have_vars="$(printf '%s' "$out" | jq -s 'map(.variables[]?) | map({(.name): .value}) | add // {}')"
else
  warn "actions/variables unreadable"
fi

while IFS=$'\t' read -r name value; do
  if ! printf '%s' "$have_vars" | jq -e --arg n "$name" 'has($n)' >/dev/null; then
    write "create variable $name=$value" \
      api --method POST "repos/$REPO/actions/variables" -f "name=$name" -f "value=$value"
    continue
  fi
  cur="$(printf '%s' "$have_vars" | jq -r --arg n "$name" '.[$n]')"
  if [ "$cur" = "$value" ]; then
    same "variable $name already = $value"
  else
    say "  variable $name drift: '$cur' -> '$value'"
    write "update variable $name=$value" \
      api --method PATCH "repos/$REPO/actions/variables/$name" \
          -f "name=$name" -f "value=$value"
  fi
done < <(jq -r '.variables[] | [.name, .value] | @tsv' "$HERE/variables.json")
say ""

# ------------------------------------------------------------------ audit ----
say "[4/4] verify"
if [ "$MODE" = "apply" ]; then
  "$HERE/../../gates/audit-controls.py" --repo "$REPO" || RC=$?
else
  say "  (dry run) after --apply, run: ./gates/audit-controls.py --repo $REPO"
fi

exit $RC
