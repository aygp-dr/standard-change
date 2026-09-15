#!/bin/sh
# generate.sh -- read an adoption profile, emit the controls its answers
# support, and REFUSE the ones they do not.
#
#   ./adopt/generate.sh <profile.tsv>            print the plan, write nothing
#   ./adopt/generate.sh <profile.tsv> <outdir>   write the starting pipeline
#   ./adopt/generate.sh --selftest               prove this script can refuse
#
# THE POINT OF THIS FILE IS THE REFUSALS.
#
# It would be easy, and it would be wrong, to emit every guard and let the
# adopter delete the ones that do not apply. A guard 6 emitted for a team with
# no observable production is a check that CANNOT FAIL -- spec.org defect class
# 7 -- and it is worse than no guard at all, because it is green, it is in the
# required set, and it reads to everyone as a control that is working.
#
# So every control below has a precondition expressed in the profile's own
# vocabulary, and a control whose precondition does not hold is not emitted in
# a weakened form and not emitted with a TODO. It is refused, by name, with the
# answer that caused the refusal written down where the adopter will read it.
#
# THIS SCRIPT IS SUBJECT TO ITS OWN RULE. `--selftest` runs the planner against
# profiles whose answers must produce refusals, and asserts they do. It also
# runs with ADOPT_DEFECT=1, which removes the observability precondition, and
# requires the refusal to DISAPPEAR -- because a selftest that passes against
# the broken planner too has established nothing (issue #16, and the
# gate-selftest discipline generally).
#
# Exit codes are docs/exit-codes.org's:
#   0 proceed   1 refused (a profile that supports nothing)   2 usage
#   4 I could not check (the profile is incomplete or malformed)
set -eu

ME=$(basename "$0")
DEFECT="${ADOPT_DEFECT:-0}"

usage() {
  echo "usage: $ME <profile.tsv> [outdir]" >&2
  echo "       $ME --selftest" >&2
  exit 2
}

# --------------------------------------------------------------------------
# The key space. Every one of these must be answered. There is no default that
# is safe across all sixteen questions, and a defaulted answer is an answer
# nobody gave -- which is how a guard gets emitted that nobody chose.
# --------------------------------------------------------------------------
REQUIRED='profile.name
profile.date
gates.selftest
change.unit
change.state.owner
deploy.unit
deploy.unit.derivable
deploy.source
forge.verdicts.per_commit
forge.verdicts.revocable
forge.trunk_moved_event
forge.approver_distinct
forge.reaches_estate
path.environments
path.authorizing
path.shared
path.lease
production.observable
production.build_id
production.replicas
production.rollback
address.namespace.shared
freeze.holder
freeze.declarer
emergency.declarer
schedule.store
facts.ownership_declared'

# key<space>allowed values. A key absent from this list takes any value.
ENUMS='gates.selftest yes no
change.unit pull-request branch ticket none
change.state.owner automation human none
deploy.unit repo directory-group package
deploy.unit.derivable yes no
deploy.source branch-head trunk-after-merge
forge.verdicts.per_commit yes no none
forge.verdicts.revocable yes no none
forge.trunk_moved_event yes no none
forge.approver_distinct enforced conventional none
forge.reaches_estate yes no
path.shared yes no
path.lease native derived none
production.observable yes no
production.build_id header manifest api none
production.rollback switch redeploy none
address.namespace.shared yes no
freeze.holder estate-record trunk-file change none
emergency.declarer person derived none
schedule.store cas calendar none
facts.ownership_declared yes no'

# --------------------------------------------------------------------------
# Reading the profile
# --------------------------------------------------------------------------
WORK=''
cleanup() { [ -n "$WORK" ] && rm -rf "$WORK"; }
trap cleanup EXIT INT TERM

load_profile() {  # load_profile <path>
  [ -f "$1" ] || { echo "$ME: no such profile: $1" >&2; exit 4; }
  awk -F'\t' '
    /^[ \t]*#/ { next }
    NF < 2     { next }
    {
      k = $1; v = $2
      gsub(/^[ \t]+|[ \t]+$/, "", k)
      gsub(/^[ \t]+|[ \t]+$/, "", v)
      if (k != "") print k " " v
    }' "$1" > "$WORK/answers"

  # MISSING AND MALFORMED ARE NOT THE SAME AS `no`, and both exit 4.
  # An incomplete profile is a question nobody answered. Reading it as a `no`
  # would silently refuse controls the team may well be able to support, and
  # reading it as a `yes` would emit controls they cannot. Neither is a verdict.
  printf '%s\n' "$REQUIRED" > "$WORK/required"
  pf_missing=''
  for pf_k in $REQUIRED; do
    if [ -z "$(awk -v k="$pf_k" '$1==k{print "1"; exit}' "$WORK/answers")" ]; then
      pf_missing="$pf_missing $pf_k"
    fi
  done
  if [ -n "$pf_missing" ]; then
    echo "$ME: the profile does not answer:" >&2
    for pf_k in $pf_missing; do echo "    $pf_k" >&2; done
    echo "  An unanswered question is not a 'no'. See adopt/PROFILE.org." >&2
    exit 4
  fi

  # Unknown keys are an error too: a typo'd key is an answer that silently
  # went nowhere, and the question it was meant for is now unanswered above.
  pf_extra=$(awk 'NR == FNR { ok[$1] = 1; next } !($1 in ok) { print $1 }' \
    "$WORK/required" "$WORK/answers")
  if [ -n "$pf_extra" ]; then
    echo "$ME: the profile has keys that are not questions:" >&2
    echo "$pf_extra" | sed 's/^/    /' >&2
    exit 4
  fi

  echo "$ENUMS" | while read -r pf_line; do
    pf_key=${pf_line%% *}
    pf_allowed=${pf_line#* }
    pf_got=$(p "$pf_key")
    pf_ok=0
    for pf_a in $pf_allowed; do [ "$pf_got" = "$pf_a" ] && pf_ok=1; done
    if [ "$pf_ok" = 0 ]; then
      echo "$ME: $pf_key = '$pf_got' is not one of: $pf_allowed" >&2
      exit 4
    fi
  done || exit 4
}

p() {  # p <key> -- the answer, or the empty string
  awk -v k="$1" '$1==k { $1=""; sub(/^ /,""); print; exit }' "$WORK/answers"
}

# --------------------------------------------------------------------------
# The plan. Three verdicts and they must not read alike.
#
#   EMIT      the answers support this control as specified
#   DEGRADED  emitted, in a named weaker mode, with the weakness printed at
#             runtime by the emitted script itself -- not only here, because a
#             caveat that lives in a generator's output is a caveat nobody
#             reads twice
#   REFUSE    not emitted. The reason names the answer that caused it.
# --------------------------------------------------------------------------
plan() {  # plan <verdict> <control> <mode> <reason>
  printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "$WORK/plan"
}

planned() {  # planned <control> -- true if EMIT or DEGRADED
  awk -F'\t' -v c="$2" '$2==c && ($1=="EMIT" || $1=="DEGRADED") { print "1"; exit }' \
    "$WORK/plan" | grep -q 1
}

is_planned() {  # is_planned <control>
  awk -F'\t' -v c="$1" '$2==c && ($1=="EMIT" || $1=="DEGRADED") { n=1 } END { exit !n }' \
    "$WORK/plan"
}

mode_of() {  # mode_of <control>
  awk -F'\t' -v c="$1" '$2==c { print $3; exit }' "$WORK/plan"
}

# --------------------------------------------------------------------------
# The planner. One block per control, in dependency order.
# --------------------------------------------------------------------------
do_plan() {
  : > "$WORK/plan"

  # --- A. the precondition ------------------------------------------------
  if [ "$(p gates.selftest)" != yes ]; then
    plan REFUSE 'everything' '-' \
      'gates.selftest=no. A gate that cannot be shown to reject a failing input produces no verdict, so no guard built on it would mean anything. Write one failing fixture per gate first. (spec.org class 7)'
    return 0
  fi
  plan EMIT 'gate-selftest' 'required' \
    'the licence to believe any other verdict here. Runs every emitted guard against its fail fixture and requires a refusal.'

  # --- B. what a change is ------------------------------------------------
  if [ "$(p deploy.unit.derivable)" = yes ]; then
    plan EMIT 'manifest' "$(p deploy.unit)" \
      'the deploy set is derived from the diff, never asserted. Three-valued: a non-empty set, PROVABLY empty, or indeterminate.'
  else
    plan REFUSE 'manifest' '-' \
      'deploy.unit.derivable=no. An asserted manifest is a wish, and the build ships whatever someone typed. It also makes deploys(c) two-valued, which is what breaks guard 6.'
  fi

  if [ "$(p change.unit)" = none ]; then
    plan DEGRADED 'evidence' 'git-ref' \
      'change.unit=none, so records live in refs/adopt/ under compare-and-swap rather than on a change. Sound, and invisible until someone runs the command.'
  elif [ "$(p forge.reaches_estate)" = no ]; then
    plan EMIT 'evidence' 'carried' \
      'forge.reaches_estate=no, so the gates run where they can reach the estate and carry their verdict back as a record naming the build. This is why fact ownership below is a correctness concern and not tidiness.'
  else
    plan EMIT 'evidence' 'check-run' \
      'the runner reaches the estate, so verdicts are reported natively. Prefer this: it is the half of the model with fewer moving parts.'
  fi

  # --- guard 0 ------------------------------------------------------------
  if [ "$(p deploy.source)" = branch-head ]; then
    if [ "$(p path.shared)" = yes ]; then
      plan EMIT 'guard0' 'safety' \
        'B(c) = T at berth claim. Deploying a tree behind the trunk would silently revert whatever merged since.'
    else
      plan DEGRADED 'guard0' 'hygiene' \
        'path.shared=no, so nothing else can have merged under you and guard 0 protects nothing. Emitted as a rebase-hygiene check that reports rather than blocks.'
    fi
  else
    plan REFUSE 'guard0' '-' \
      'deploy.source=trunk-after-merge. B(c) = T has no content when the thing deployed IS T. (spec.org, Guard 4b, case A4)'
  fi

  # --- guard 1 ------------------------------------------------------------
  if [ "$(p path.shared)" != yes ]; then
    plan REFUSE 'guard1' '-' \
      'path.shared=no. A berth on an uncontended path is the queue paying for a safety production does not gain, which is spec.org The balance test for ceremony.'
  elif [ "$(p path.lease)" = none ]; then
    plan REFUSE 'guard1' '-' \
      'path.shared=yes but path.lease=none. A singleton enforced by convention is a convention: the second claimant silently replaces the first. Answer path.lease=derived for a CAS lease over a git ref, which needs no platform support.'
  else
    plan EMIT 'guard1' "$(p path.lease)" \
      'an exclusive lease with an owner and a deadline, readable by others, plus a reaper for the deadline. Capability C3.'
  fi

  # --- guard 2 ------------------------------------------------------------
  if [ "$(p forge.verdicts.per_commit)" = yes ]; then
    plan EMIT 'guard2' 'forge' \
      'every gate green on THIS content hash, plus the self-test, read from the platform. Takes the LATEST run per gate name: superseded is not current.'
  else
    plan DEGRADED 'guard2' 'local-rerun' \
      'no content-hash-bound verdicts, so the suite is re-run at the moment of reliance and its result recorded against the SHA measured. Slower, not weaker -- it never reads a stored verdict.'
  fi

  # --- guard 3 ------------------------------------------------------------
  case "$(p freeze.holder)" in
    change)
      plan REFUSE 'guard3' '-' \
        'freeze.holder=change. The write that closes the estate to everyone is then the write that exempts its own carrier: the one change that must not proceed becomes the only one that may. Record it on something that cannot be deployed.' ;;
    none)
      plan REFUSE 'guard3' '-' \
        'freeze.holder=none. There is nowhere to record that ordinary change is suspended, so there is no freeze to check.' ;;
    *)
      if [ "$(p freeze.declarer)" = none ]; then
        plan DEGRADED 'guard3' "$(p freeze.holder)-advisory" \
          'no declared writer, so anyone may lift it. Emitted, and the script says it is advisory on every run.'
      else
        plan EMIT 'guard3' "$(p freeze.holder)" \
          'no lock, no freeze, re-read at entry AND again before cutover. The second read is untested here [H] and is the one this repo has honestly not closed.'
      fi ;;
  esac

  # --- guard 4 ------------------------------------------------------------
  g4_auth=$(p path.authorizing)
  g4_prod=$(echo "$(p path.environments)" | awk -F, '{print $NF}')
  if [ "$g4_auth" = none ] || [ "$g4_auth" = "$g4_prod" ]; then
    plan REFUSE 'guard4' '-' \
      "path.authorizing=$g4_auth. There is no staged(H(c)) to read, so the predicate collapses to guard 2 plus a human approval. Say that, rather than shipping a guard 4 that reads a record nobody writes."
  else
    plan EMIT 'guard4' "$g4_auth" \
      "no production without an observation from $g4_auth naming THIS head. The authorizing run is the one against the deployed environment, never the in-runner run."
  fi

  case "$(p forge.approver_distinct)" in
    enforced)
      plan EMIT 'guard4-approval' 'enforced' \
        'the platform refuses the call when approver and author collapse. That refusal, not our script, is what makes the separation real.' ;;
    conventional)
      plan DEGRADED 'guard4-approval' 'decorative' \
        'nothing enforces the separation, so the approval is a convention wearing a control name. Emitted, and it prints that on every run.' ;;
    *)
      plan REFUSE 'guard4-approval' '-' \
        'forge.approver_distinct=none. Your emergency path has one human in it and it is the person who wants to ship.' ;;
  esac

  # --- guard 4b -----------------------------------------------------------
  g4b_rev=$(p forge.verdicts.revocable)
  if [ "$(p deploy.source)" = branch-head ]; then
    if [ "$g4b_rev" = yes ]; then
      plan EMIT 'guard4b' 'revoke' \
        'classify what merged under you, and withdraw the pass when the class is artifact or hotfix. Re-evaluated AT RELIANCE, not at request. Capabilities C4 and C5.'
    else
      plan DEGRADED 'guard4b' 'rederive' \
        'verdicts cannot be revoked, so this never reads a persisted pass at all -- it re-derives the divergence at every reliance point. A verdict you cannot revoke is one that outlives its own truth.'
    fi
  elif [ "$g4b_rev" = yes ] || [ "$(p forge.trunk_moved_event)" = yes ]; then
    plan DEGRADED 'guard4b' 'artifact' \
      'deploying the trunk, so the subject is not your base against the tip but the tip you BUILT from against the tip now. Narrower, still worth having.'
  else
    plan REFUSE 'guard4b' '-' \
      'deploy.source=trunk-after-merge with no revocation and no trunk-moved event. There is no subject left to re-derive and nothing to withdraw.'
  fi

  # --- guard 5 ------------------------------------------------------------
  # THE PRECONDITION THE SELFTEST ATTACKS. ADOPT_DEFECT=1 removes it, and the
  # selftest requires the refusal below to disappear when it does -- otherwise
  # the selftest is not testing this line.
  g5_ok=0
  if [ "$DEFECT" = 1 ]; then
    g5_ok=1
  elif [ "$(p production.observable)" = yes ] && [ "$(p production.build_id)" != none ]; then
    g5_ok=1
  fi
  if [ "$g5_ok" = 0 ]; then
    plan REFUSE 'guard5' '-' \
      'production.observable=no, or production.build_id=none. A check that cannot read the identity of the build being served is a liveness check wearing guard 5 name: it goes green whenever anything answers, so it can never fail for the reason guard 5 exists. Defect class 7.'
  else
    g5_rep=$(p production.replicas)
    case "$g5_rep" in
      1) plan DEGRADED 'guard5' 'single' \
           'one replica, so UNCONVERGED is unstateable -- you cannot observe a mixed fleet of one. One sample, and the convergence branch is removed rather than left unreachable.' ;;
      *) plan EMIT 'guard5' "$(p production.build_id)" \
           'N samples per route, one request each, cache-busted, and EVERY one must report the expected build. Convergence, not liveness.' ;;
    esac
    if [ "$(p production.rollback)" = none ]; then
      plan DEGRADED 'guard5-rollback' 'manual' \
        'no rollback primitive, so the failure path names the SHA a person must restore and stops. spec.org axiom A5, deployment is undoable, is the one axiom none of the guards encodes.'
    else
      plan EMIT 'guard5-rollback' "$(p production.rollback)" \
        'the failure path has somewhere to go.'
    fi
  fi

  # --- guard 6 ------------------------------------------------------------
  # THE MOST IMPORTANT REFUSAL IN THIS FILE. Three preconditions, each of which
  # has been got wrong here at least once.
  g6_why=''
  if ! is_planned guard5; then
    g6_why="guard 5 is not emitted, so there is no observation of what production is serving to compare against. spec.org: guard 6 cannot be tested without a real estate, and a pipeline that can only test it against an in-process double has not tested it."
  elif [ "$(p deploy.source)" != branch-head ]; then
    g6_why="deploy.source=trunk-after-merge. Production-first says do not merge onto a trunk production is not yet serving -- but if the merge is what PRODUCES the deployable, the ordering is inverted by construction and the check can only ever be green."
  elif [ "$(p deploy.unit.derivable)" != yes ]; then
    g6_why="deploy.unit.derivable=no. deploys(c) would be two-valued, so 'provably empty' and 'could not tell' collapse -- and the collapse is exactly how this guard failed here: 484 runs, never once triggered."
  fi
  if [ -n "$g6_why" ]; then
    plan REFUSE 'guard6' '-' "$g6_why"
  else
    plan EMIT 'guard6' 'three-valued' \
      'do not merge something new onto a trunk production is not serving. deploys(c) is three-valued: non-empty compares, PROVABLY empty exempts and names its oracle, indeterminate ABSTAINS with exit 4. Absence of evidence that it deploys something is not evidence that it deploys nothing.'
  fi

  # --- the estate ---------------------------------------------------------
  case "$(p emergency.declarer)" in
    person)
      plan EMIT 'emergency' 'declared' \
        'a person declares it, always. Exempt from the freeze and the queue, NOT from having a window, and never from guard 2 or guard 5.' ;;
    derived)
      plan REFUSE 'emergency' '-' \
        'emergency.declarer=derived. A pipeline that can infer an emergency can grant itself the bypass, which makes it the default path with extra steps.' ;;
    *)
      plan REFUSE 'emergency' '-' \
        'emergency.declarer=none. No bypass at all, which is a coherent and safe answer -- recorded so nobody adds one later by accident.' ;;
  esac

  if [ "$(p address.namespace.shared)" = yes ]; then
    plan EMIT 'address-tiers' 'ports' \
      'the address says what an environment is, so may-this-promote is answerable without consulting a policy file. Everything else about the numbering is arbitrary.'
  else
    plan REFUSE 'address-tiers' '-' \
      'address.namespace.shared=no. Each environment has its own address, so addresses are not scarce and the tier model buys nothing. This is the most estate-specific control here and it does not travel.'
  fi

  plan EMIT 'environments' 'registry' \
    'declared and running are separate registries. A declared, inactive environment still owns its address, and promotes=no is a fact about what reads its verdict, not a policy toggle.'

  case "$(p schedule.store)" in
    cas)
      plan EMIT 'windows' 'cas' \
        'compare-and-swap first, human-readable calendar second. Four closure codes and they are a closed set: passed, failed, cancelled, expired.' ;;
    calendar)
      plan DEGRADED 'windows' 'advisory' \
        'a calendar is last-write-wins, so two bookings of one slot both succeed and neither is told -- and the thing double-booked is the path to production. Emitted advisory, and it says so at every booking.' ;;
    *)
      plan REFUSE 'windows' '-' \
        'schedule.store=none. Costs less than expected: the guards do not read a calendar. What you lose is the FORFEIT record, and forfeits are this repo dominant cost -- about half of thirty windows expired unattempted.' ;;
  esac

  if [ "$(p facts.ownership_declared)" = yes ]; then
    plan EMIT 'fact-owners' 'declared' \
      'one writer per fact, two verbs. Clearing is not asserting, so may-add and may-remove are separate permissions.'
  else
    plan DEGRADED 'fact-owners' 'starter' \
      'not declared yet. A starter declaration is emitted with one row per fact these controls create, and it must be completed: two writers is how the same value flipped five times in twenty minutes.'
  fi
}

# --------------------------------------------------------------------------
# Reporting
# --------------------------------------------------------------------------
report() {
  awk -F'\t' '
    BEGIN { e = 0; d = 0; r = 0 }
    {
      mark = ($1 == "EMIT") ? "emit" : ($1 == "DEGRADED" ? "DEGR" : "REFUSE")
      if ($1 == "EMIT") e++; else if ($1 == "DEGRADED") d++; else r++
      printf "%-7s %-18s %-14s\n", mark, $2, ($3 == "-" ? "" : $3)
      n = split($4, w, " ")
      line = "                                     "
      out = ""
      for (i = 1; i <= n; i++) {
        if (length(out) + length(w[i]) > 74) { print "        " out; out = "" }
        out = (out == "") ? w[i] : out " " w[i]
      }
      if (out != "") print "        " out
      print ""
    }
    END { printf "  %d emitted, %d degraded, %d refused\n", e, d, r }
  ' "$WORK/plan"
}

refusals() {
  awk -F'\t' '$1 == "REFUSE" { print "REFUSED: " $2; print "  " $4; print "" }' \
    "$WORK/plan"
}

# --------------------------------------------------------------------------
# Emission
# --------------------------------------------------------------------------
emit_lib() {  # emit_lib <outdir>
  mkdir -p "$1/lib"
  cat > "$1/lib/tri.sh" <<'LIB'
#!/bin/sh
# tri.sh -- the utilities without which every call site re-invents the same bug.
#
# These are docs/interfaces.org's seven required utilities. They are here
# rather than inline in each guard because the collapse they prevent is the
# single most repeated defect in the pipeline they came from.

# tri <command...> -- run, and print yes | no | unknown.
#
# THE RULE: every read has THREE answers. `I could not check` must refuse
# DIFFERENTLY from `it is false`, and an implementation that cannot express the
# third value is unusable. Exit 0 is yes, 1 is no, anything else is unknown --
# so a command that dies, times out or is not installed lands on unknown rather
# than on no.
tri() {
  if "$@" >/dev/null 2>&1; then echo yes
  else
    case $? in 1) echo no ;; *) echo unknown ;; esac
  fi
}

# at <sha> <record> -- does this record name this build?
#
# "Staging passed" is not a fact. "Staging passed at a013270" is. A record from
# an older build does not go stale and need withdrawing: it stays true, about
# the build it names, and simply stops matching. Nothing has to fire.
at() {
  at_want=$1; at_rec=$2
  [ -n "$at_want" ] && [ "$at_want" != unknown ] || return 2
  case "$at_rec" in *"$at_want"*) return 0 ;; *) return 1 ;; esac
}

# indent <command...> -- format the output, return the COMMAND's status.
#
# `cmd | sed` makes $? sed's. This shipped an UNHEALTHY estate as `passed`, and
# was then rebuilt from scratch eight hours later in the script written to
# replace the one that had it -- knowing the rule did not prevent writing the
# code, because piping to trim output is the obvious thing to type.
indent() {
  in_out=$("$@" 2>&1); in_rc=$?
  printf '%s\n' "$in_out" | sed 's/^/  /'
  return $in_rc
}

# cas <ref> <expected-sha> <file> -- compare-and-swap a git ref.
#
# Any state two actors can write. Last-write-wins on the path to production
# means two bookings of one slot both succeed and neither is told.
cas() {
  cas_blob=$(git hash-object -w --stdin < "$3") || return 2
  git update-ref "$1" "$cas_blob" "${2:-}" 2>/dev/null || return 9
}

# owner <fact> <add|remove> <actor> -- may this actor write this fact?
#
# TWO VERBS, SEPARATELY. Clearing is not asserting: automation may clear a
# working label at settlement, and only a person may withdraw an acceptance,
# because withdrawing means `I looked again and I no longer think so`.
owner() {
  ow_f=$1; ow_verb=$2; ow_who=$3
  ow_row=$(awk -F'\t' -v f="$ow_f" '$1==f{print; exit}' "${FACT_OWNERS:-fact-owners.tsv}")
  [ -n "$ow_row" ] || return 2
  ow_col=$(printf '%s' "$ow_row" | cut -f2)
  case "$ow_verb" in
    add)    ow_allow=$(printf '%s' "$ow_row" | cut -f3) ;;
    remove) ow_allow=$(printf '%s' "$ow_row" | cut -f4) ;;
    *) return 2 ;;
  esac
  [ "$ow_who" = "$ow_col" ] && return 0
  [ "$ow_allow" = yes ] && return 0
  return 1
}

# probe <url> -- FOUR outcomes, not two: up <sha> | up - | refused | timeout.
#
# Collapsing unreachable into unhealthy produces confident wrong answers, and
# they are wrong in the direction of destroying someone else's measurement.
probe() {
  pr_bust="$(date +%s)-$$"
  pr_resp=$(curl -sS -o /dev/null --max-time 10 -H 'Cache-Control: no-cache' \
    -w '%{http_code} %header{x-build-sha}' "$1?_cb=$pr_bust" 2>/dev/null) || {
      case $? in 28) echo timeout; return 0 ;; *) echo refused; return 0 ;; esac; }
  pr_code=${pr_resp%% *}; pr_sha=${pr_resp##* }
  [ "$pr_code" = 000 ] && { echo refused; return 0; }
  [ "$pr_code" = 200 ] || { echo "up -"; return 0; }
  echo "up ${pr_sha:--}"
}

# when <iso-instant> -- render relative to now. A window's REMAINING time only
# means something once it has started.
when() {
  wh_t=$(date -u -d "$1" +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%s 2>/dev/null) || {
    echo unknown; return 0; }
  wh_n=$(date -u +%s); wh_d=$((wh_t - wh_n))
  if [ "$wh_d" -lt 0 ]; then echo "$((-wh_d / 60))m ago"; else echo "in $((wh_d / 60))m"; fi
}
LIB
}

emit_adapter() {  # emit_adapter <outdir>
  mkdir -p "$1/adapters"
  cat > "$1/adapters/adapter.sh" <<'ADP'
#!/bin/sh
# adapter.sh -- the ONLY file that knows what platform you are on.
#
# EVERY FUNCTION HERE RETURNS `unknown` UNTIL YOU WRITE IT, AND `unknown`
# BLOCKS. That is deliberate and it is the correct first state: a pipeline
# whose guards are green before anyone has connected them to a platform has
# guards that cannot fail, and a green result from one of those means nothing.
#
# So the first thing you will do with this directory is run ./selftest.sh and
# watch every guard refuse with exit 4. Then implement these one at a time and
# watch them stop refusing for a reason you can name.
#
# Contract for every function: print the answer on stdout, and NEVER print a
# guess. Where you cannot determine the answer, print `unknown`. Do not print
# an empty string for `I could not reach the API` -- empty is a real answer for
# some of these (an unheld berth, a change that deploys nothing) and conflating
# them is how the guard that reads it fails open.

a_head()            { echo unknown; }   # head content hash of the change
a_base()            { echo unknown; }   # the change's base content hash
a_trunk_tip()       { echo unknown; }   # trunk tip content hash
a_author()          { echo unknown; }   # the change's author identity

# pass | fail | unknown, for the whole suite at <sha>
a_suite_verdict()   { echo unknown; }
# pass | fail | unknown -- the SELF-TEST at <sha>. Separate on purpose: a suite
# whose self-test did not pass returns no verdict that run, it does not return
# a pass.
a_selftest_verdict() { echo unknown; }

# THE THREE-VALUED ONE. Print the units, or the literal `NONE` when the diff
# was READ and touches nothing deployable, or `unknown`.
#
# `NONE` is a positive claim that something looked. Returning the empty string
# because an API call failed is the defect this whole directory exists for:
# here, `groups.sh "$pr" 2>/dev/null || true` produced the empty set when the
# forge could not answer, and guard 6 exempted the change. 484 runs, never once
# triggered.
a_deploys()         { echo unknown; }

# "<verdict> <sha> <instrument>" for the latest observation, or `unknown`.
# <env> <instrument>
a_observation()     { echo unknown; }

a_berth_holder()    { echo unknown; }   # holder id, `FREE`, or unknown
a_freeze()          { echo unknown; }   # `open`, `frozen <reason>`, or unknown
a_emergency()       { echo unknown; }   # yes | no | unknown
# `approved <login>` | `none` | `unknown`, for <sha>
a_approval()        { echo unknown; }
a_served_build()    { echo unknown; }   # the sha <url> is serving, or unknown
ADP
}

# guard_head <file> <name> <one-line purpose>
guard_head() {
  cat > "$1" <<GH
#!/bin/sh
# $2 -- $3
#
# Generated by adopt/generate.sh from a profile. Exit codes are
# docs/exit-codes.org's: 0 proceed, 1 refused, 2 usage, 3 freeze,
# 4 I COULD NOT CHECK (blocks), 5 queue busy, 6 behind trunk, 8 trunk moved.
#
# 4 BLOCKS. It is not a soft warning, and it must never become a reason to
# substitute a different measurement.
set -eu
ROOT=\$(cd "\$(dirname "\$0")/.." && pwd)
. "\$ROOT/lib/tri.sh"
. "\${ADOPT_ADAPTER:-\$ROOT/adapters/adapter.sh}"
GH
  chmod +x "$1"
}

emit_guards() {  # emit_guards <outdir>
  eg_out=$1
  mkdir -p "$eg_out/guards"

  if is_planned guard0; then
    guard_head "$eg_out/guards/guard0.sh" guard0.sh 'B(c) = T -- the change contains the trunk tip'
    cat >> "$eg_out/guards/guard0.sh" <<'G0'

base=$(a_base); tip=$(a_trunk_tip)
case "$base$tip" in *unknown*)
  echo "guard0: INDETERMINATE -- could not read the base or the trunk tip."
  echo "        Not 'up to date'. Not 'behind'. Blocking."
  exit 4 ;;
esac
[ "$base" = "$tip" ] && { echo "guard0: ok, base is the trunk tip"; exit 0; }
echo "guard0: REFUSED -- behind the trunk. Deploying this tree would revert"
echo "        whatever merged since. Rebase and re-request."
exit 6
G0
  fi

  if is_planned guard1; then
    guard_head "$eg_out/guards/guard1.sh" guard1.sh 'the berth is a singleton'
    cat >> "$eg_out/guards/guard1.sh" <<'G1'

me=${1:?usage: guard1.sh <change-id>}
holder=$(a_berth_holder)
[ "$holder" = unknown ] && {
  echo "guard1: INDETERMINATE -- could not read the berth. Blocking."; exit 4; }
[ "$holder" = FREE ] || [ "$holder" = "$me" ] && {
  echo "guard1: ok, the berth is available"; exit 0; }
echo "guard1: REFUSED -- the path to production is held by $holder."
echo "        Wait. Nothing about your change has changed, and when the berth"
echo "        frees you will be behind the trunk by exactly that merge."
exit 5
G1
  fi

  guard_head "$eg_out/guards/guard2.sh" guard2.sh 'every gate green on THIS content hash'
  if [ "$(mode_of guard2)" = local-rerun ]; then
    cat >> "$eg_out/guards/guard2.sh" <<'G2L'

# DEGRADED MODE: local-rerun. The platform cannot bind a verdict to a content
# hash, so nothing stored is trusted -- the suite runs now, against the head
# now, and the verdict is recorded against the SHA it measured.
echo "guard2: local-rerun mode (no content-hash-bound verdicts available)."
head=$(a_head)
[ "$head" = unknown ] && { echo "guard2: INDETERMINATE -- no head. Blocking."; exit 4; }
"$ROOT/selftest.sh" >/dev/null 2>&1 || {
  echo "guard2: REFUSED -- the self-test did not pass, so the suite returns NO"
  echo "        verdict this run. Not a pass. Not a fail. Nothing to rely on."
  exit 1; }
indent "${SUITE_CMD:-make test}" || {
  echo "guard2: REFUSED -- the suite failed on $head"; exit 1; }
echo "guard2: ok, suite green on $head, measured now"
G2L
  else
    cat >> "$eg_out/guards/guard2.sh" <<'G2F'

head=$(a_head)
[ "$head" = unknown ] && { echo "guard2: INDETERMINATE -- no head. Blocking."; exit 4; }

# THE SELF-TEST IS READ SEPARATELY AND FIRST. A suite whose self-test did not
# pass produces no verdict that run, and `no verdict` is not `pass`.
self=$(a_selftest_verdict "$head")
case "$self" in
  unknown) echo "guard2: INDETERMINATE -- could not read the self-test. Blocking."; exit 4 ;;
  pass) : ;;
  *) echo "guard2: REFUSED -- the self-test is $self on $head, so no gate result"
     echo "        from this run means anything."; exit 1 ;;
esac

# DID NOT RUN IS NOT RED, and both are `not green`. Your adapter must keep them
# apart: a job that was never started reports the same conclusion as a gate
# that genuinely failed on more platforms than not, and an hour of dead CI
# looks exactly like a real self-test failure.
v=$(a_suite_verdict "$head")
case "$v" in
  pass) echo "guard2: ok, every gate green on $head (self-test green too)"; exit 0 ;;
  fail) echo "guard2: REFUSED -- a gate is red on $head"; exit 1 ;;
  *) echo "guard2: INDETERMINATE -- the suite verdict on $head is '$v'."
     echo "        Not green, not red, absent. Blocking, and NOT re-running the"
     echo "        gates here and calling that guard 2."; exit 4 ;;
esac
G2F
  fi

  if is_planned guard3; then
    guard_head "$eg_out/guards/guard3.sh" guard3.sh 'no lock, no freeze'
    case "$(mode_of guard3)" in *advisory)
      cat >> "$eg_out/guards/guard3.sh" <<'G3A'

echo "guard3: ADVISORY -- freeze.declarer=none, so anyone may lift this and"
echo "        nothing records who did. It reports. It does not block."
G3A
      ;;
    esac
    cat >> "$eg_out/guards/guard3.sh" <<'G3'

state=$(a_freeze)
case "$state" in
  unknown)
    echo "guard3: INDETERMINATE -- could not read the estate state."
    echo "        'I could not read it' is not 'it is clear'. Blocking."
    exit 4 ;;
  open) ;;
  *) echo "guard3: REFUSED -- $state"; exit 3 ;;
esac

# The estate's emergency is a different fact from this change's class. An
# emergency running outside the pipeline means production is being rewritten
# under you, so your authorizing observation describes a world that no longer
# exists -- a different reason to stop, with a different recovery ("wait and
# then re-verify", not "wait").
emg=$(a_emergency)
case "$emg" in
  unknown) echo "guard3: INDETERMINATE -- could not read the emergency flag."; exit 4 ;;
  yes) echo "guard3: REFUSED -- an emergency is in flight on the estate."; exit 3 ;;
esac
echo "guard3: ok, the estate is open to ordinary change"
G3
    if ! is_planned guard3-recheck; then
      cat >> "$eg_out/guards/guard3.sh" <<'G3N'
# NOT CLOSED, AND SAID OUT LOUD [H]: run this AGAIN immediately before cutover.
# Nothing re-reads the freeze between the authorizing deploy and the switch, so
# a change that entered a legally open estate keeps going into a closed one.
G3N
    fi
  fi

  if is_planned guard4; then
    guard_head "$eg_out/guards/guard4.sh" guard4.sh 'staged(H(c)) or (emergency and approved)'
    cat >> "$eg_out/guards/guard4.sh" <<G4A

AUTH_ENV="\${AUTH_ENV:-$(mode_of guard4)}"
G4A
    cat >> "$eg_out/guards/guard4.sh" <<'G4'
REPEATABLE="${REPEATABLE_OBSERVATIONS:-e2e smoke}"
ATTESTED="${ATTESTED_OBSERVATIONS:-uat}"

head=$(a_head)
[ "$head" = unknown ] && { echo "guard4: INDETERMINATE -- no head. Blocking."; exit 4; }

rc=0
for inst in $REPEATABLE $ATTESTED; do
  rec=$(a_observation "$AUTH_ENV" "$inst")
  if [ "$rec" = unknown ]; then
    echo "guard4: INDETERMINATE -- could not read the $inst observation."
    echo "        Blocking: no record and no reachable record read alike."
    exit 4
  fi
  verdict=${rec%% *}; rest=${rec#* }; sha=${rest%% *}
  if [ "$verdict" != pass ]; then
    echo "guard4: REFUSED -- the latest $inst on $AUTH_ENV is '$verdict'"; rc=1
  elif ! at "$head" "$sha"; then
    echo "guard4: REFUSED -- $inst passed, on $sha. The head is $head."
    echo "        That measurement is about a different build. A record does"
    echo "        not go stale: it stays true about the build it names and"
    echo "        stops matching, which is the whole reason it is a record and"
    echo "        not a flag."
    rc=1
  else
    echo "guard4: ok  $inst on $AUTH_ENV, recorded at $sha"
  fi
done
[ "$rc" = 0 ] || exit 1
echo "guard4: authorized -- the stack of named observations all name $head"
G4
  fi

  if is_planned guard4-approval; then
    guard_head "$eg_out/guards/guard4-approval.sh" guard4-approval.sh \
      'an approver who is not the author'
    if [ "$(mode_of guard4-approval)" = decorative ]; then
      cat >> "$eg_out/guards/guard4-approval.sh" <<'GAD'

echo "guard4-approval: DECORATIVE -- forge.approver_distinct=conventional."
echo "        Nothing enforces that approver and author differ. This check"
echo "        reads a claim, it does not verify a separation, and the only"
echo "        honest thing it can do is say so on every run."
GAD
    fi
    cat >> "$eg_out/guards/guard4-approval.sh" <<'GA'

head=$(a_head); who=$(a_author)
case "$head$who" in *unknown*)
  echo "guard4-approval: INDETERMINATE -- no head or no author."; exit 4 ;;
esac
ap=$(a_approval "$head")
case "$ap" in
  unknown) echo "guard4-approval: INDETERMINATE -- could not read approvals."; exit 4 ;;
  none)    echo "guard4-approval: REFUSED -- nothing approved $head"; exit 1 ;;
esac
# ASK THE PLATFORM WHO APPROVED. Never trust the exit code of the command that
# posted the approval: an approval by the author counts for nothing even if the
# platform somehow let it through.
by=${ap#approved }
[ "$by" = "$who" ] && {
  echo "guard4-approval: REFUSED -- $head was approved by its own author ($who)."
  exit 1; }
echo "guard4-approval: ok, $head approved by $by, who is not $who"
GA
  fi

  if is_planned guard4b; then
    guard_head "$eg_out/guards/guard4b.sh" guard4b.sh \
      'classify what moved under you, AT RELIANCE'
    cat >> "$eg_out/guards/guard4b.sh" <<G4BM

MODE="$(mode_of guard4b)"
G4BM
    cat >> "$eg_out/guards/guard4b.sh" <<'G4B'

# CALL THIS AT EVERY POINT THAT RELIES ON IT, not once when the change was
# requested. That sentence is the entire guard: a guard whose subject can
# change after it is checked must be re-checked at the moment it is relied on.
[ "$MODE" = rederive ] && {
  echo "guard4b: rederive mode -- verdicts here cannot be revoked, so this"
  echo "         reads NO persisted pass. It re-derives, every time."; }

base=$(a_base); tip=$(a_trunk_tip)
case "$base$tip" in *unknown*)
  echo "guard4b: INDETERMINATE -- could not read the base or the tip."; exit 4 ;;
esac
[ "$base" = "$tip" ] && { echo "guard4b: ok, nothing moved"; exit 0; }

# CLASSIFY. Collapsing these is what charges the queue for a docs merge: `you
# are behind` and `you are about to revert something` are different facts.
#   inert     docs, notes             -- affects neither what ships nor how you
#                                        are verified
#   pipeline  gates, workflows        -- you would be verified by the OLD gates
#   artifact  the deployables         -- your tree would REVERT what shipped
#   hotfix    an artifact, urgently   -- as above, and someone is waiting
class=$("$ROOT/classify.sh" "$base" "$tip" 2>/dev/null || echo unknown)
case "$class" in
  unknown) echo "guard4b: INDETERMINATE -- could not classify the divergence."; exit 4 ;;
  inert)   echo "guard4b: ok, the trunk moved by an inert change"; exit 0 ;;
  pipeline)
    echo "guard4b: REFUSED -- the trunk moved by a '$class' change, so your"
    echo "         tree would be verified by the gates as they were."; exit 8 ;;
  *)
    echo "guard4b: REFUSED -- the trunk moved by a '$class' change. Deploying"
    echo "         this tree would revert what shipped. Any pass already"
    echo "         issued against it is withdrawn."; exit 8 ;;
esac
G4B
    cat > "$eg_out/classify.sh" <<'CLS'
#!/bin/sh
# classify.sh <base> <tip> -- inert | pipeline | artifact | hotfix | unknown
#
# EDIT THE GLOBS. This is the one generated file that is entirely about YOUR
# repository layout, and getting it wrong is not safe in either direction:
# too broad and every docs merge costs the queue a rebase, too narrow and a
# change to the gates goes out verified by the gates it changed.
set -eu
base=${1:?}; tip=${2:?}
files=$(git diff --name-only "$base" "$tip" 2>/dev/null) || { echo unknown; exit 0; }
[ -n "$files" ] || { echo inert; exit 0; }
class=inert
for f in $files; do
  case "$f" in
    *.org|*.md|docs/*|notes/*)        [ "$class" = inert ] && class=inert ;;
    .github/*|gates/*|guards/*|lib/*) class=pipeline ;;
    *) echo artifact; exit 0 ;;
  esac
done
echo "$class"
CLS
    chmod +x "$eg_out/classify.sh"
  fi

  if is_planned guard5; then
    guard_head "$eg_out/guards/guard5.sh" guard5.sh \
      'served_build(production) = H(c) -- convergence, not liveness'
    eg_samples=5
    [ "$(mode_of guard5)" = single ] && eg_samples=1
    cat >> "$eg_out/guards/guard5.sh" <<G5M

SAMPLES="\${HEALTH_SAMPLES:-$eg_samples}"
MODE="$(p production.build_id)"
REPLICAS="$(p production.replicas)"
G5M
    cat >> "$eg_out/guards/guard5.sh" <<'G5'

base=${1:?usage: guard5.sh <base-url> <expected-sha>}
want=${2:?}

# ONE REQUEST, BOTH FACTS. Two requests per sample -- one for the status code,
# one for the build id -- can hit an old replica and then a new one, and the
# pair passes while the estate is mixed.
#
# N SAMPLES, ALL OF THEM. One sample cannot tell `converged` from `I happened
# to reach a new replica`: a fleet 10% migrated passes a single sample 10% of
# the time, which is not a bug you find by re-running.
seen=''; bad=0; n=1
while [ "$n" -le "$SAMPLES" ]; do
  r=$(probe "$base")
  case "$r" in
    refused|timeout)
      echo "guard5: INDETERMINATE -- $r. The estate was never observed, which"
      echo "        is not the same as observing it to be unhealthy. Blocking,"
      echo "        and NOT withdrawing anyone else's measurement."
      exit 4 ;;
  esac
  sha=${r##* }
  case " $seen " in *" $sha "*) : ;; *) seen="$seen $sha" ;; esac
  [ "$sha" = "$want" ] || bad=$((bad + 1))
  n=$((n + 1))
done

distinct=$(printf '%s' "$seen" | wc -w | tr -d ' ')
if [ "$bad" -gt 0 ]; then
  echo "guard5: UNHEALTHY -- $bad/$SAMPLES samples are not serving $want (saw:$seen)"
  exit 7
fi
G5
    if [ "$(mode_of guard5)" != single ]; then
      cat >> "$eg_out/guards/guard5.sh" <<'G5C'
if [ "$distinct" -gt 1 ]; then
  echo "guard5: UNCONVERGED -- more than one build is being served (saw:$seen)"
  echo "        This is a distinct verdict from UNHEALTHY on purpose: the"
  echo "        estate is mid-roll, not broken, and the recovery is to wait."
  exit 7
fi
G5C
    else
      cat >> "$eg_out/guards/guard5.sh" <<'G5S'
# NO CONVERGENCE BRANCH. production.replicas=1, so a mixed fleet is unobservable
# and UNCONVERGED is unstateable. The branch is removed rather than left here
# unreachable: an unreachable branch is a check that cannot fail wearing a
# comment.
: "$distinct"
G5S
    fi
    cat >> "$eg_out/guards/guard5.sh" <<'G5E'
echo "guard5: ok, $SAMPLES/$SAMPLES samples on $want"
G5E
    if [ "$(mode_of guard5-rollback)" = manual ]; then
      cat >> "$eg_out/guards/guard5.sh" <<'G5R'
# THE FAILURE PATH IS A REFUSAL, NOT AN ACTION. production.rollback=none, so
# there is nothing to roll back TO automatically. spec.org records "deployment
# is undoable" as axiom A5 -- an axiom none of the six guards encodes, and one
# that an expand/contract migration or a published artifact falsifies outright.
# On failure, print the SHA a person must restore and stop.
G5R
    fi
  fi

  if is_planned guard6; then
    guard_head "$eg_out/guards/guard6.sh" guard6.sh \
      'production-first -- do not merge onto a trunk production is not serving'
    cat >> "$eg_out/guards/guard6.sh" <<'G6'

# deploys(c) IS THREE-VALUED AND NEVER A SET THAT MAY BE EMPTY.
#
# This is the whole guard. Both independent implementations of it got the
# comparison right and the SET wrong: each derived the deploy set and then
# treated an EMPTY set as EXEMPT. One of them ran 484 times without ever
# triggering, because a forge that could not answer produced the empty set.
#
#   a non-empty set   compare, and refuse unless production serves the trunk
#   PROVABLY empty    exempt -- and say which oracle proved it
#   indeterminate     ABSTAIN, exit 4, block
#
# `Exempt` requires positive evidence that the change deploys nothing. The
# absence of evidence that it deploys something is INDETERMINATE, and
# indeterminate is not exempt.
#
# ORDER MATTERS AS MUCH AS THE PREDICATE. The exempt branch must not be
# evaluated before reachability, or the guard answers "nothing to check"
# without ever having tried to look -- which is how the rebuild's own
# "ABSTAINS when production cannot be reached" case returned exempt.
units=$(a_deploys)

if [ "$units" = unknown ]; then
  echo "guard6: ABSTAIN -- could not determine what this change deploys."
  echo "        This is NOT 'it deploys nothing'. Blocking."
  exit 4
fi
if [ "$units" = NONE ]; then
  echo "guard6: exempt -- the diff was read and touches nothing deployable."
  echo "        Oracle: a_deploys, from the diff, not from a label."
  exit 0
fi

tip=$(a_trunk_tip)
[ "$tip" = unknown ] && {
  echo "guard6: ABSTAIN -- could not read the trunk tip."; exit 4; }

served=$(a_served_build "${FRONT_URL:?guard6 needs FRONT_URL}")
[ "$served" = unknown ] && {
  echo "guard6: ABSTAIN -- could not read what production is serving."
  echo "        Unreachable is not falsified, and it is not exempt either."
  exit 4; }

at "$tip" "$served" && {
  echo "guard6: ok, production is serving the trunk tip"; exit 0; }

echo "guard6: REFUSED -- this change deploys [$units] and production is"
echo "        serving $served while the trunk is at $tip. Merging now would"
echo "        put the trunk ahead of the estate: it would assert a change no"
echo "        replica is serving."
echo
echo "        Red here is NORMAL for most of a change's life. Deploy first,"
echo "        let guard 5 observe convergence, then merge. The merge is"
echo "        settlement, not authorization."
exit 1
G6
  fi
}

emit_fixtures() {  # emit_fixtures <outdir>
  ef_out=$1
  for ef_g in guard0 guard1 guard2 guard3 guard4 guard4-approval guard4b guard5 guard6; do
    is_planned "$ef_g" || continue
    mkdir -p "$ef_out/fixtures/$ef_g/fail" "$ef_out/fixtures/$ef_g/pass"
  done

  # Every fixture is an ADAPTER, because the adapter is the only thing a guard
  # reads. A fixture that patched the guard would be testing a different guard.
  if is_planned guard6; then
    cat > "$ef_out/fixtures/guard6/fail/adapter.sh" <<'F6F'
#!/bin/sh
# guard 6 MUST refuse: the change deploys something and production is serving
# a different build from the trunk tip.
FRONT_URL=http://fixture.invalid
a_deploys()      { echo "web"; }
a_trunk_tip()    { echo "bbbbbbb"; }
a_served_build() { echo "aaaaaaa"; }
a_head()         { echo "bbbbbbb"; }
F6F
    cat > "$ef_out/fixtures/guard6/pass/adapter.sh" <<'F6P'
#!/bin/sh
FRONT_URL=http://fixture.invalid
a_deploys()      { echo "web"; }
a_trunk_tip()    { echo "bbbbbbb"; }
a_served_build() { echo "bbbbbbb"; }
a_head()         { echo "bbbbbbb"; }
F6P
    # THE THIRD ROW, and the one both real implementations got wrong. A
    # conforming implementation must have a test that fails when the guard is
    # removed, for ALL THREE values of deploys(c) -- the rebuild's selftest had
    # exactly the right two cases and the guard exempted its way past both.
    mkdir -p "$ef_out/fixtures/guard6/abstain"
    cat > "$ef_out/fixtures/guard6/abstain/adapter.sh" <<'F6A'
#!/bin/sh
# guard 6 MUST abstain with 4, not exempt with 0.
FRONT_URL=http://fixture.invalid
a_deploys()      { echo unknown; }
a_trunk_tip()    { echo "bbbbbbb"; }
a_served_build() { echo unknown; }
a_head()         { echo "bbbbbbb"; }
F6A
  fi

  if is_planned guard4; then
    cat > "$ef_out/fixtures/guard4/fail/adapter.sh" <<'F4F'
#!/bin/sh
# guard 4 MUST refuse: the observation is a pass, on a DIFFERENT build. This is
# the case a label cannot express and a record can.
a_head()        { echo "bbbbbbb"; }
a_observation() { echo "pass aaaaaaa e2e"; }
F4F
    cat > "$ef_out/fixtures/guard4/pass/adapter.sh" <<'F4P'
#!/bin/sh
a_head()        { echo "bbbbbbb"; }
a_observation() { echo "pass bbbbbbb e2e"; }
F4P
  fi

  if is_planned guard5; then
    # The guard's OWN argv. guard5 takes a base URL and the build it expects,
    # so the fixture has to name a build for the fixture's probe to agree with.
    echo 'http://fixture.invalid bbbbbbb' > "$ef_out/fixtures/guard5/args"
    cat > "$ef_out/fixtures/guard5/fail/adapter.sh" <<'F5F'
#!/bin/sh
# guard 5 MUST report UNHEALTHY, not pass. probe is overridden rather than the
# guard, because the guard's subject is what the estate says about itself.
probe() { echo "up aaaaaaa"; }
F5F
    cat > "$ef_out/fixtures/guard5/pass/adapter.sh" <<'F5P'
#!/bin/sh
probe() { echo "up bbbbbbb"; }
F5P
  fi

  if is_planned guard2; then
    cat > "$ef_out/fixtures/guard2/fail/adapter.sh" <<'F2F'
#!/bin/sh
# guard 2 MUST refuse: the SELF-TEST is red, so the green gates below it are
# worth nothing this run.
a_head()             { echo "bbbbbbb"; }
a_selftest_verdict() { echo fail; }
a_suite_verdict()    { echo pass; }
F2F
    cat > "$ef_out/fixtures/guard2/pass/adapter.sh" <<'F2P'
#!/bin/sh
a_head()             { echo "bbbbbbb"; }
a_selftest_verdict() { echo pass; }
a_suite_verdict()    { echo pass; }
F2P
  fi

  if is_planned guard3; then
    cat > "$ef_out/fixtures/guard3/fail/adapter.sh" <<'F3F'
#!/bin/sh
a_freeze()    { echo "frozen end-of-quarter"; }
a_emergency() { echo no; }
F3F
    cat > "$ef_out/fixtures/guard3/pass/adapter.sh" <<'F3P'
#!/bin/sh
a_freeze()    { echo open; }
a_emergency() { echo no; }
F3P
  fi

  if is_planned guard0; then
    printf '#!/bin/sh\na_base() { echo "aaaaaaa"; }\na_trunk_tip() { echo "bbbbbbb"; }\n' \
      > "$ef_out/fixtures/guard0/fail/adapter.sh"
    printf '#!/bin/sh\na_base() { echo "bbbbbbb"; }\na_trunk_tip() { echo "bbbbbbb"; }\n' \
      > "$ef_out/fixtures/guard0/pass/adapter.sh"
  fi

  if is_planned guard1; then
    printf '#!/bin/sh\na_berth_holder() { echo "other-change"; }\n' \
      > "$ef_out/fixtures/guard1/fail/adapter.sh"
    printf '#!/bin/sh\na_berth_holder() { echo FREE; }\n' \
      > "$ef_out/fixtures/guard1/pass/adapter.sh"
  fi

  if is_planned guard4-approval; then
    printf '#!/bin/sh\na_head() { echo b; }\na_author() { echo alex; }\na_approval() { echo "approved alex"; }\n' \
      > "$ef_out/fixtures/guard4-approval/fail/adapter.sh"
    printf '#!/bin/sh\na_head() { echo b; }\na_author() { echo alex; }\na_approval() { echo "approved sam"; }\n' \
      > "$ef_out/fixtures/guard4-approval/pass/adapter.sh"
  fi

  if is_planned guard4b; then
    printf '#!/bin/sh\na_base() { echo "aaaaaaa"; }\na_trunk_tip() { echo "bbbbbbb"; }\n' \
      > "$ef_out/fixtures/guard4b/fail/adapter.sh"
    printf '#!/bin/sh\na_base() { echo "bbbbbbb"; }\na_trunk_tip() { echo "bbbbbbb"; }\n' \
      > "$ef_out/fixtures/guard4b/pass/adapter.sh"
  fi
}

emit_selftest() {  # emit_selftest <outdir>
  cat > "$1/selftest.sh" <<'ST'
#!/bin/sh
# selftest.sh -- prove every emitted guard CAN fail, then that it passes.
#
# RUN THIS BEFORE TRUSTING ANY GUARD RESULT. A guard that does not reject its
# fixtures/<guard>/fail/ input produced no verdict this run, and its PASS is
# void. That is not a slogan: three tests in the repository this came from
# passed while asserting nothing, and all three were found by mutation rather
# than by reading.
#
# It also refuses to be vacuous itself: a guard with no fixture directory is a
# FINDING, not a skip.
set -eu
ROOT=$(cd "$(dirname "$0")" && pwd)
rc=0; n=0

for g in "$ROOT"/guards/*.sh; do
  [ -f "$g" ] || continue
  name=$(basename "$g" .sh)
  fx="$ROOT/fixtures/$name"
  if [ ! -d "$fx/fail" ]; then
    echo "  FINDING $name has no fail fixture -- it produces no verdict"
    rc=1; continue
  fi
  n=$((n + 1))

  # The guard's argv, from the fixture. A fixture whose inputs do not reach the
  # guard tests nothing -- and this is not hypothetical: the first version of
  # this file invoked every guard with the same two placeholder arguments, so
  # guard 5 was handed an expected build nobody was serving and rejected its
  # PASS fixture too. A guard that refuses everything is as useless as one that
  # accepts everything, and only running both directions tells them apart.
  args='x y'
  [ -f "$fx/args" ] && args=$(cat "$fx/args")

  # The NEGATIVE direction first, always. A suite that has only ever been run
  # against inputs it accepts is a suite nobody has tested.
  # shellcheck disable=SC2086
  if ADOPT_ADAPTER="$fx/fail/adapter.sh" "$g" $args >/dev/null 2>&1; then
    echo "  FAIL    $name ACCEPTED its fail fixture. Its pass means nothing."
    rc=1
  else
    echo "  ok      $name rejects its fail fixture"
  fi

  if [ -d "$fx/pass" ]; then
    # shellcheck disable=SC2086
    if ADOPT_ADAPTER="$fx/pass/adapter.sh" "$g" $args >/dev/null 2>&1; then
      echo "  ok      $name accepts its pass fixture"
    else
      echo "  FAIL    $name rejects its pass fixture too -- it refuses everything"
      rc=1
    fi
  fi

  # The third value, where the guard has one. Exit 4 is not exit 0 and not
  # exit 1, and a guard that answers `exempt` when it could not look is the
  # defect this whole directory exists to prevent.
  if [ -d "$fx/abstain" ]; then
    ec=0
    # shellcheck disable=SC2086
    ADOPT_ADAPTER="$fx/abstain/adapter.sh" "$g" $args >/dev/null 2>&1 || ec=$?
    case $ec in
      4) echo "  ok      $name abstains (4) when it cannot determine its subject" ;;
      0) echo "  FAIL    $name EXEMPTED itself when it could not look. Class 7."; rc=1 ;;
      *) echo "  FAIL    $name refused (not 4) when it could not look -- wrong code"; rc=1 ;;
    esac
  fi
done

echo "  selftest: $n guards, $( [ "$rc" = 0 ] && echo 'both directions confirmed' || echo 'FINDINGS' )"
exit $rc
ST
  chmod +x "$1/selftest.sh"
}

emit_declarations() {  # emit_declarations <outdir>
  ed_out=$1
  {
    echo '# THE ENVIRONMENT DECLARATION. One row per environment that EXISTS AS A NAME.'
    echo '#'
    echo '# Declared and running are SEPARATE registries. This is the map of what is'
    echo '# named; whatever records what is actually up is the other one. Merging them'
    echo '# means a typo can look like an outage and an outage can look like a config'
    echo '# change.'
    echo '#'
    echo '# promotes=no is not a policy toggle. An environment cannot promote because'
    echo '# nothing downstream reads its verdict. Setting it to yes would not grant the'
    echo '# power, it would only make the file lie.'
    printf '# name\ttier\taddress\tactivated\tpromotes\tnote\n'
    ed_auth=$(p path.authorizing)
    ed_last=$(echo "$(p path.environments)" | awk -F, '{print $NF}')
    echo "$(p path.environments)" | tr ',' '\n' | while read -r ed_e; do
      [ -n "$ed_e" ] || continue
      ed_pro=no
      ed_note='not on the path to production -- nothing downstream reads its verdict'
      if [ "$ed_e" = "$ed_auth" ]; then
        ed_pro=yes
        ed_note='THE AUTHORIZING ENVIRONMENT. guard 4 reads observations from here and nowhere else'
      fi
      if [ "$ed_e" = "$ed_last" ]; then
        ed_pro=terminal
        ed_note='production. Nothing is downstream, so promotes is terminal rather than yes'
      fi
      printf '%s\tprotected\tTODO\tyes\t%s\t%s\n' "$ed_e" "$ed_pro" "$ed_note"
    done
  } > "$ed_out/environments.tsv"

  {
    echo '# THE FACT OWNERSHIP DECLARATION. Machine-readable on purpose.'
    echo '#'
    echo '# Prose cannot stop the failure this exists for: one actor reads the system,'
    echo '# sees a fact it thinks should be set, and sets it -- while another, equally'
    echo '# reasonably, withdraws it. Neither is wrong about the world. The fact has no'
    echo '# owner. One value here flipped five times in twenty minutes that way.'
    echo '#'
    echo '# TWO VERBS, SEPARATELY. Clearing is not asserting.'
    printf '# fact\towner\thuman_add\thuman_rm\tnotes\n'
    printf 'manifest\tautomation\tno\tno\tderived from the diff, recomputed every push\n'
    printf 'class\tautomation\tno\tno\tderived. An EMERGENCY is not derivable and is not this fact\n'
    printf 'emergency\thuman\tyes\tyes\ta declaration about the world, never a property of a diff\n'
    printf 'freeze\thuman\tyes\tyes\ta property of the ESTATE. Never recorded on a change\n'
    printf 'observation\tthe instrument\tno\tno\tthe gate that took the measurement records it, and only it\n'
    printf 'acceptance\tthe person\tyes\tyes\tthe one observation a human may add: for UAT the person IS the instrument\n'
    printf 'berth\tautomation\tno\tyes\ta human may release a stuck lease. Only release.\n'
  } > "$ed_out/fact-owners.tsv"
}

do_emit() {  # do_emit <outdir>
  de_out=$1
  mkdir -p "$de_out"
  emit_lib "$de_out"
  emit_adapter "$de_out"
  emit_guards "$de_out"
  emit_fixtures "$de_out"
  emit_selftest "$de_out"
  emit_declarations "$de_out"
  cp "$WORK/answers" "$de_out/profile.answers"
  {
    echo "PLAN for profile '$(p profile.name)', generated $(date -u +%FT%TZ)"
    echo
    report
  } > "$de_out/PLAN.txt"
  {
    echo "REFUSALS for profile '$(p profile.name)'"
    echo
    echo "Each of these is a control your answers cannot sustain. They are not"
    echo "TODOs. Emitting any of them would produce a check that cannot fail,"
    echo "which is worse than no check: it is green, it is in the required set,"
    echo "and it reads to everyone as a control that is working."
    echo
    refusals
  } > "$de_out/REFUSALS.txt"
  chmod +x "$de_out"/guards/*.sh 2>/dev/null || true
}

# --------------------------------------------------------------------------
# The generator's own self-test. Both directions.
# --------------------------------------------------------------------------
mkprofile() {  # mkprofile <path> <key=value>...
  mp_path=$1; shift
  cat > "$mp_path" <<'BASE'
profile.name	selftest
profile.date	1970-01-01
gates.selftest	yes
change.unit	pull-request
change.state.owner	automation
deploy.unit	repo
deploy.unit.derivable	yes
deploy.source	branch-head
forge.verdicts.per_commit	yes
forge.verdicts.revocable	yes
forge.trunk_moved_event	yes
forge.approver_distinct	enforced
forge.reaches_estate	yes
path.environments	staging,production
path.authorizing	staging
path.shared	yes
path.lease	derived
production.observable	yes
production.build_id	header
production.replicas	3
production.rollback	switch
address.namespace.shared	yes
freeze.holder	estate-record
freeze.declarer	release-manager
emergency.declarer	person
schedule.store	cas
facts.ownership_declared	yes
BASE
  for mp_kv in "$@"; do
    mp_k=${mp_kv%%=*}; mp_v=${mp_kv#*=}
    awk -F'\t' -v k="$mp_k" -v v="$mp_v" \
      'BEGIN{OFS="\t"} $1==k{$2=v} {print $1,$2}' "$mp_path" > "$mp_path.n"
    mv "$mp_path.n" "$mp_path"
  done
}

verdict_of() {  # verdict_of <control>
  awk -F'\t' -v c="$1" '$2==c{print $1; exit}' "$WORK/plan"
}

st_case() {  # st_case <name> <control> <expected verdict> <profile overrides...>
  st_name=$1; st_ctl=$2; st_want=$3; shift 3
  mkprofile "$WORK/st.tsv" "$@"
  load_profile "$WORK/st.tsv"
  do_plan
  st_got=$(verdict_of "$st_ctl")
  [ -z "$st_got" ] && st_got=ABSENT
  if [ "$st_got" = "$st_want" ]; then
    printf '  ok      %-46s %s\n' "$st_name" "$st_got"
    return 0
  fi
  printf '  FAIL    %-46s got %s, want %s\n' "$st_name" "$st_got" "$st_want"
  return 1
}

selftest() {
  st_rc=0
  echo "adopt/generate.sh selftest"
  echo

  # --- the refusals that matter -------------------------------------------
  st_case 'no observable production: guard 5 refused' guard5 REFUSE \
    production.observable=no || st_rc=1
  st_case 'no observable production: guard 6 refused' guard6 REFUSE \
    production.observable=no || st_rc=1
  st_case 'no build id: guard 5 refused' guard5 REFUSE \
    production.build_id=none || st_rc=1
  st_case 'no build id: guard 6 refused' guard6 REFUSE \
    production.build_id=none || st_rc=1
  st_case 'trunk-after-merge: guard 0 refused' guard0 REFUSE \
    deploy.source=trunk-after-merge || st_rc=1
  st_case 'trunk-after-merge: guard 6 refused' guard6 REFUSE \
    deploy.source=trunk-after-merge || st_rc=1
  st_case 'underivable manifest: guard 6 refused' guard6 REFUSE \
    deploy.unit.derivable=no || st_rc=1
  st_case 'unshared path: the berth is ceremony' guard1 REFUSE \
    path.shared=no || st_rc=1
  st_case 'shared path, no lease: berth refused' guard1 REFUSE \
    path.lease=none || st_rc=1
  st_case 'freeze on a change: refused' guard3 REFUSE \
    freeze.holder=change || st_rc=1
  st_case 'derived emergency: refused' emergency REFUSE \
    emergency.declarer=derived || st_rc=1
  st_case 'unshared addresses: tier model refused' address-tiers REFUSE \
    address.namespace.shared=no || st_rc=1
  st_case 'authorizing = production: guard 4 refused' guard4 REFUSE \
    path.authorizing=production || st_rc=1
  st_case 'no approver identity: rung refused' guard4-approval REFUSE \
    forge.approver_distinct=none || st_rc=1
  st_case 'no calendar: windows refused' windows REFUSE \
    schedule.store=none || st_rc=1

  # --- and the positive direction, or the refusals prove nothing -----------
  st_case 'a profile that supports it emits guard 6' guard6 EMIT || st_rc=1
  st_case 'a profile that supports it emits guard 5' guard5 EMIT || st_rc=1
  st_case 'a profile that supports it emits the berth' guard1 EMIT || st_rc=1
  st_case 'unrevocable verdicts degrade guard 4b' guard4b DEGRADED \
    forge.verdicts.revocable=no || st_rc=1
  st_case 'one replica degrades guard 5 to single-sample' guard5 DEGRADED \
    production.replicas=1 || st_rc=1
  st_case 'a calendar degrades windows to advisory' windows DEGRADED \
    schedule.store=calendar || st_rc=1

  # --- no self-test, no pipeline ------------------------------------------
  st_case 'no gate self-test: NOTHING is emitted' guard2 ABSENT \
    gates.selftest=no || st_rc=1
  st_case 'no gate self-test: the refusal is total' everything REFUSE \
    gates.selftest=no || st_rc=1

  echo
  # --- THE NEGATIVE DIRECTION ON THE SELFTEST ITSELF ----------------------
  #
  # Everything above could pass against a planner that refuses guard 6
  # unconditionally, or one whose observability check is dead code. So: remove
  # the observability precondition and require the refusal to DISAPPEAR. If it
  # does not, these cases are not testing that line and they establish nothing.
  DEFECT=1
  mkprofile "$WORK/st.tsv" production.observable=no
  load_profile "$WORK/st.tsv"
  do_plan
  st_got=$(verdict_of guard6)
  DEFECT="${ADOPT_DEFECT:-0}"
  if [ "$st_got" = EMIT ]; then
    echo "  ok      with the observability precondition removed, guard 6 IS"
    echo "          emitted for a profile with no observable production --"
    echo "          so the cases above are testing that line, not a constant."
  else
    echo "  FAIL    removing the observability precondition changed nothing."
    echo "          The refusals above are not evidence about it."
    st_rc=1
  fi

  echo
  if [ "$st_rc" = 0 ]; then
    echo "  generate.sh: both directions confirmed"
  else
    echo "  generate.sh: FINDINGS"
  fi
  return $st_rc
}

# --------------------------------------------------------------------------
main() {
  WORK=$(mktemp -d "${TMPDIR:-/tmp}/adopt.XXXXXX")

  if [ "${1:-}" = --selftest ]; then
    selftest
    exit $?
  fi
  [ $# -ge 1 ] || usage
  case "$1" in -*) usage ;; esac

  load_profile "$1"
  do_plan

  if [ $# -lt 2 ]; then
    echo "PLAN for profile '$(p profile.name)'. Nothing written."
    echo
    report
    echo
    echo "  Re-run with an output directory to write the pipeline."
    echo "  Read the REFUSED rows first: they are the controls you do not get."
    is_planned gate-selftest || exit 1
    exit 0
  fi

  case "$2" in
    .|./|"$PWD") echo "$ME: refusing to write into the working directory" >&2; exit 2 ;;
  esac
  do_emit "$2"
  echo "wrote $2"
  echo
  report
  echo
  echo "  Next: every adapter function returns 'unknown' and unknown BLOCKS."
  echo "  Run $2/selftest.sh and watch each guard refuse. That is the correct"
  echo "  first state. Implement $2/adapters/adapter.sh one function at a time."
  is_planned gate-selftest || exit 1
}

main "$@"
