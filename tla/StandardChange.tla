---------------------------- MODULE StandardChange ----------------------------
(***************************************************************************)
(* The promotion pipeline of spec.org, as a state machine.                 *)
(*                                                                         *)
(* The question this module exists to answer is scenario D4: can a change  *)
(* reach production carrying a tree that predates something already on     *)
(* main, thereby reverting it, while every gate is green?                  *)
(*                                                                         *)
(* Guard4b is a CONSTANT so the model can FAIL. With Guard4b = FALSE this  *)
(* is spec.org 0.2 and TLC finds the D4 counterexample; with TRUE it is    *)
(* 0.3 and NoRegression holds. A model that can only pass proves nothing   *)
(* (see spec.org, Verification contract).                                  *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS PRs,          \* the set of open pull requests, e.g. {p1, p2}
          ProdFirst,    \* guard: must a change reach production before main?
          MaxMerges,    \* bound on main's version, to keep the model finite
          Guard4b,      \* TRUE = main-moved.yml installed (spec 0.3)
          LockOwned,    \* TRUE = only the operator that claimed may release
          Operators,    \* the set of drivers acting on one forge, e.g. {o1, o2}
          NoOp,         \* model value: "the lock has no owner"
          NoPR          \* model value: "staging is held by nobody"

ASSUME NoPR \notin PRs
ASSUME NoOp \notin Operators

VARIABLES
    base,         \* base[p]: the version of main that p is rebased onto
    gated,        \* gated[p]: all gates green on p's head SHA
    stagingPass,  \* stagingPass[p]: authorizing e2e passed on this head
    prodLabel,    \* prodLabel[p]: deploy:production present
    emergency,    \* emergency[p]: change:emergency present
    approved,     \* approved[p]: a change authority approved
    inProd,       \* inProd[p]: production has CONVERGED on this change
    merged,       \* merged[p]: landed on main
    mainV,        \* how many changes have merged
    holder,       \* the PR carrying deploy:staging, or NoPR
    lockOwner,    \* WHICH OPERATOR claimed it, or NoOp. See D21.
    swept,        \* a lock was released by somebody who did not hold it
    regressed,    \* set TRUE if a merge ever reverted an earlier one
    draft         \* draft[p]: the AUTHOR says p is not ready

vars == <<base, gated, stagingPass, prodLabel, emergency, approved,
          inProd, merged, mainV, holder, lockOwner, swept, regressed, draft>>

TypeOK ==
    /\ base        \in [PRs -> 0..MaxMerges]
    /\ gated       \in [PRs -> BOOLEAN]
    /\ stagingPass \in [PRs -> BOOLEAN]
    /\ prodLabel   \in [PRs -> BOOLEAN]
    /\ emergency   \in [PRs -> BOOLEAN]
    /\ approved    \in [PRs -> BOOLEAN]
    /\ inProd      \in [PRs -> BOOLEAN]
    /\ merged      \in [PRs -> BOOLEAN]
    /\ mainV       \in 0..MaxMerges
    /\ holder      \in PRs \cup {NoPR}
    /\ lockOwner   \in Operators \cup {NoOp}
    /\ swept       \in BOOLEAN
    /\ regressed   \in BOOLEAN
    /\ draft       \in [PRs -> BOOLEAN]

Init ==
    /\ base        = [p \in PRs |-> 0]
    /\ gated       = [p \in PRs |-> FALSE]
    /\ stagingPass = [p \in PRs |-> FALSE]
    /\ prodLabel   = [p \in PRs |-> FALSE]
    /\ emergency   = [p \in PRs |-> FALSE]
    /\ approved    = [p \in PRs |-> FALSE]
    /\ inProd      = [p \in PRs |-> FALSE]
    /\ merged      = [p \in PRs |-> FALSE]
    /\ mainV       = 0
    /\ holder      = NoPR
    /\ lockOwner   = NoOp
    /\ swept       = FALSE
    /\ regressed   = FALSE
    \* Nondeterministic: some changes are opened as drafts and some are not.
    /\ draft       \in [PRs -> BOOLEAN]

Live(p) == ~merged[p]

(***************************************************************************)
(* Author pushes a commit. The labeller's SHA binding withdraws any        *)
(* staging verdict, and the gates must run again.                          *)
(***************************************************************************)
Push(p) ==
    /\ Live(p)
    /\ gated'       = [gated       EXCEPT ![p] = FALSE]
    /\ stagingPass' = [stagingPass EXCEPT ![p] = FALSE]
    /\ prodLabel'   = [prodLabel   EXCEPT ![p] = FALSE]
    \* A push withdraws the convergence observation too. inProd is about a
    \* BUILD, and after a push it describes one nobody is proposing to merge --
    \* labeller.yml withdraws production:healthy on synchronize for this reason.
    /\ inProd'      = [inProd      EXCEPT ![p] = FALSE]
    /\ UNCHANGED <<base, emergency, approved, merged, mainV, holder, lockOwner, swept, regressed, draft>>

GatesPass(p) ==
    /\ Live(p) /\ ~gated[p]
    /\ gated' = [gated EXCEPT ![p] = TRUE]
    /\ UNCHANGED <<base, stagingPass, prodLabel, emergency, approved,
                   merged, mainV, holder, lockOwner, swept, regressed, inProd, draft>>

Rebase(p) ==
    /\ Live(p) /\ base[p] < mainV
    /\ base'        = [base        EXCEPT ![p] = mainV]
    \* a rebase is a new tree: verdicts do not survive it
    /\ gated'       = [gated       EXCEPT ![p] = FALSE]
    /\ stagingPass' = [stagingPass EXCEPT ![p] = FALSE]
    /\ prodLabel'   = [prodLabel   EXCEPT ![p] = FALSE]
    /\ UNCHANGED <<emergency, approved, merged, mainV, holder, lockOwner, swept, regressed, inProd, draft>>

MarkEmergency(p) ==
    /\ Live(p) /\ ~emergency[p]
    /\ emergency' = [emergency EXCEPT ![p] = TRUE]
    /\ UNCHANGED <<base, gated, stagingPass, prodLabel, approved,
                   merged, mainV, holder, lockOwner, swept, regressed, inProd, draft>>

Approve(p) ==
    /\ Live(p) /\ ~approved[p]
    /\ approved' = [approved EXCEPT ![p] = TRUE]
    /\ UNCHANGED <<base, gated, stagingPass, prodLabel, emergency,
                   merged, mainV, holder, lockOwner, swept, regressed, inProd, draft>>

(***************************************************************************)
(* Guard 0 (up to date with main) and guard 1 (staging is a singleton).    *)
(***************************************************************************)
(***************************************************************************)
(* READINESS. draft[p] is the AUTHOR'S OWN STATEMENT that p is unfinished,  *)
(* and it is the only input to any guard in this model that the pipeline    *)
(* does not derive, measure or infer -- it believes it.                     *)
(*                                                                         *)
(* Only MarkReady clears it, and nothing sets it back: `gh pr ready` is an  *)
(* act by the author. A pipeline that could undraft a change would be       *)
(* overriding the one signal it does not have to interpret.                 *)
(*                                                                         *)
(* Note there is NO emergency exemption. itil:emergency is a statement      *)
(* about URGENCY; draft is a statement about READINESS. An urgent           *)
(* unfinished change is still unfinished, and shipping it is one author     *)
(* action away.                                                            *)
(***************************************************************************)
MarkReady(p) ==
    /\ Live(p) /\ draft[p]
    /\ draft' = [draft EXCEPT ![p] = FALSE]
    /\ UNCHANGED <<base, gated, stagingPass, prodLabel, emergency, approved,
                   inProd, merged, mainV, holder, lockOwner, swept, regressed>>

ClaimStaging(p, o) ==
    /\ Live(p)
    /\ ~draft[p]                \* the author says it is ready
    /\ holder = NoPR            \* guard 1
    /\ base[p] = mainV          \* guard 0
    /\ gated[p]
    /\ holder' = p
    /\ lockOwner' = o
    /\ UNCHANGED <<base, gated, stagingPass, prodLabel, emergency, approved,
                   merged, mainV, swept, regressed, inProd, draft>>

(***************************************************************************)
(* SWEEP -- a DIFFERENT operator clears the lock. Scenario D21, observed    *)
(* 2026-09-14: aygp-dr removed a deploy:staging that jwalsh was holding,    *)
(* and six seconds of its own log call it "releasing the estate", meaning   *)
(* its own. The lock is a LABEL, and `gh pr edit --remove-label` is the     *)
(* same call whether you release your own or take someone else's.          *)
(*                                                                         *)
(* LockOwned is a CONSTANT so the model can FAIL. With LockOwned = FALSE    *)
(* this action is enabled and TLC finds the sweep; with it TRUE the release *)
(* is restricted to the operator that claimed, and the trace disappears.    *)
(* An invariant whose guard cannot be switched off has not been shown to do *)
(* anything.                                                               *)
(***************************************************************************)
SweepStaging(o) ==
    /\ ~LockOwned
    /\ holder # NoPR
    /\ lockOwner # o           \* somebody else's lock
    /\ holder' = NoPR
    /\ lockOwner' = NoOp
    /\ swept' = TRUE
    /\ UNCHANGED <<base, gated, stagingPass, prodLabel, emergency, approved,
                   merged, mainV, regressed, inProd, draft>>

StagingPassed(p) ==
    /\ Live(p) /\ holder = p /\ gated[p] /\ ~stagingPass[p]
    /\ stagingPass' = [stagingPass EXCEPT ![p] = TRUE]
    /\ UNCHANGED <<base, gated, prodLabel, emergency, approved,
                   merged, mainV, holder, lockOwner, swept, regressed, inProd, draft>>

(***************************************************************************)
(* Promotion. Guard 2 (gates green on this head) has no emergency bypass.  *)
(***************************************************************************)
Promote(p) ==
    /\ Live(p) /\ ~prodLabel[p]
    /\ gated[p]                                     \* guard 2, no bypass
    /\ \/ stagingPass[p]                            \* the normal path
       \/ (emergency[p] /\ approved[p])             \* break glass
    /\ prodLabel' = [prodLabel EXCEPT ![p] = TRUE]
    /\ UNCHANGED <<base, gated, stagingPass, emergency, approved,
                   merged, mainV, holder, lockOwner, swept, regressed, inProd, draft>>

(***************************************************************************)
(* SPLIT, 2026-09-13. These were one atomic step, DeployAndMerge, and that  *)
(* is why this spec proved nothing about the ordering: a model in which     *)
(* merging IMPLIES deploying cannot express a merge that skipped one.       *)
(*                                                                          *)
(* The implementation never fused them. Production deploy and merge are two *)
(* acts, and `gh pr merge` performs the second alone -- which is exactly    *)
(* what happened to PR #12, a security fix that landed on main while every  *)
(* production replica still served the vulnerable build.                    *)
(*                                                                          *)
(* Eighth model/implementation divergence in this project, and the sharpest:*)
(* the others were disagreements, this was an inexpressible defect.         *)
(***************************************************************************)
DeployProduction(p) ==
    /\ Live(p) /\ ~draft[p] /\ ~inProd[p] /\ prodLabel[p] /\ gated[p]
    /\ \/ stagingPass[p] \/ (emergency[p] /\ approved[p])        \* guard 4
    /\ inProd' = [inProd EXCEPT ![p] = TRUE]
    /\ UNCHANGED <<base, gated, stagingPass, prodLabel, emergency, approved,
                   merged, mainV, holder, lockOwner, swept, regressed, draft>>

(***************************************************************************)
(* The merge is SETTLEMENT, not authorization. regressed records the D4     *)
(* failure: a non-emergency change landing on a main it does not contain    *)
(* silently reverts whatever it is missing.                                 *)
(*                                                                          *)
(* ProdFirst is a CONSTANT so the model can FAIL. With ProdFirst = FALSE,   *)
(* TLC finds a merge with inProd = FALSE -- the #12 trace -- in a handful   *)
(* of states. An invariant whose guard cannot be switched off has not been  *)
(* shown to do anything.                                                    *)
(*                                                                          *)
(* KNOWN GAP, recorded 2026-09-14, NOT modelled here.                       *)
(*                                                                          *)
(* inProd[p] is a BOOLEAN, so this model says only "production is serving   *)
(* this, or it is not". spec.org Guard 6 now requires deploys(c) to be      *)
(* THREE-valued: a non-empty deploy set (compare), a PROVABLY empty one     *)
(* (exempt), and INDETERMINATE (abstain, and block).                        *)
(*                                                                          *)
(* This model cannot express the third, so the negative run above cannot    *)
(* catch the defect that both real implementations actually had: the exempt *)
(* branch is evaluated BEFORE reachability, so the guard answers "nothing   *)
(* to check" without having looked. A boolean makes that collapse the       *)
(* natural encoding, which is the same reason both implementations wrote it *)
(* that way.                                                                *)
(*                                                                          *)
(* The three-valued case IS covered, in sim/: test_scenarios.py has all     *)
(* three rows and a mutation that removes guard 6 kills exactly the three   *)
(* refusals while leaving the permit alive. That is weaker than TLC -- it   *)
(* is example-based, not exhaustive -- and it is stated here so the TLA+    *)
(* badge is not read as covering something it does not.                     *)
(*                                                                          *)
(* Closing it needs deploys to become a per-PR variable with three values,  *)
(* which widens the state space; deferred deliberately, not overlooked.     *)
(***************************************************************************)
Merge(p) ==
    /\ Live(p) /\ gated[p]
    /\ \/ stagingPass[p] \/ (emergency[p] /\ approved[p])        \* guard 4
    /\ ProdFirst => inProd[p]                     \* gates/production-first.sh
    /\ Guard4b => (emergency[p] \/ base[p] = mainV)              \* guard 4b
    /\ mainV < MaxMerges
    /\ regressed' = (regressed \/ (~emergency[p] /\ base[p] < mainV))
    /\ merged'    = [merged EXCEPT ![p] = TRUE]
    /\ mainV'     = mainV + 1
    /\ holder'    = IF holder = p THEN NoPR ELSE holder
    /\ lockOwner' = IF holder = p THEN NoOp ELSE lockOwner
    /\ UNCHANGED <<base, gated, stagingPass, prodLabel, emergency, approved, inProd,
                   swept, draft>>

(***************************************************************************)
(* main-moved.yml: withdraw verdicts main has outrun, and free the queue.  *)
(* This is the amendment scenario D4 forced.                               *)
(***************************************************************************)
MainMoved ==
    /\ Guard4b
    /\ \E p \in PRs : Live(p) /\ base[p] < mainV /\ (stagingPass[p] \/ prodLabel[p] \/ holder = p)
    /\ stagingPass' = [p \in PRs |-> IF Live(p) /\ base[p] < mainV THEN FALSE ELSE stagingPass[p]]
    /\ prodLabel'   = [p \in PRs |-> IF Live(p) /\ base[p] < mainV THEN FALSE ELSE prodLabel[p]]
    \* A convergence observation is about a BUILD. When main outruns a change,
    \* what production converged on is no longer what this change would ship,
    \* so the observation is withdrawn -- labeller.yml does exactly this on
    \* synchronize. Without it, inProd from an old head keeps authorizing.
    /\ inProd'      = [p \in PRs |-> IF Live(p) /\ base[p] < mainV THEN FALSE ELSE inProd[p]]
    /\ holder'      = IF holder # NoPR /\ base[holder] < mainV THEN NoPR ELSE holder
    /\ lockOwner'   = IF holder # NoPR /\ base[holder] < mainV THEN NoOp ELSE lockOwner
    /\ UNCHANGED <<base, gated, emergency, approved, merged, mainV, swept, regressed, draft>>

Next ==
    \/ \E p \in PRs : Push(p) \/ GatesPass(p) \/ Rebase(p) \/ MarkEmergency(p)
                   \/ Approve(p) \/ StagingPassed(p)
                   \/ Promote(p) \/ DeployProduction(p) \/ Merge(p)
                   \/ MarkReady(p)
    \/ \E p \in PRs, o \in Operators : ClaimStaging(p, o)
    \/ \E o \in Operators : SweepStaging(o)
    \/ MainMoved

Spec == Init /\ [][Next]_vars

(***************************************************************************)
(*                              INVARIANTS                                 *)
(***************************************************************************)

(* D21: a lock that can be released by somebody who does not hold it is not *)
(* a lock.                                                                  *)
(*                                                                          *)
(* THE FIRST VERSION OF THIS INVARIANT COULD NOT FAIL, and that is worth    *)
(* keeping in the file. It read                                             *)
(*                                                                          *)
(*     NoSweptLock == (holder # NoPR) => (lockOwner # NoOp)                 *)
(*                                                                          *)
(* which is vacuous: a sweep sets holder' = NoPR, so the antecedent is      *)
(* false in exactly the state the property was written to catch. The        *)
(* negative run passed. A check that cannot fail produces no verdict --     *)
(* spec.org defect class 7, in the model whose job is to catch it.          *)
(*                                                                          *)
(* The property is about a TRANSITION, not a state, so the transition is    *)
(* recorded. Same idiom as `regressed`.                                     *)
NoSweptLock == ~swept

\* Guard 1. Staging is held by at most one PR -- structural here, but stated
\* so that weakening `holder` to a set later cannot break it unnoticed.
AtMostOneHolder == holder = NoPR \/ holder \in PRs

\* Guard 4. Nothing reaches production without a staging pass on this head,
\* or an approved emergency.
NoProdWithoutStaging ==
    \A p \in PRs : prodLabel[p] => (stagingPass[p] \/ (emergency[p] /\ approved[p]))

\* Guard 2. Red gates never ship. This one has NO emergency bypass.
NoRedGatesShipped == \A p \in PRs : merged[p] => gated[p]

\* Staging cannot be bypassed except by an approved emergency.
NoSilentBypass ==
    \A p \in PRs : (merged[p] /\ ~stagingPass[p]) => (emergency[p] /\ approved[p])

\* PRODUCTION FIRST. Nothing lands on main that production has not converged
\* on. The merge is settlement: trunk trailing production is intended, trunk
\* running AHEAD of it is not. This is gates/production-first.sh.
NoMergeBeforeProduction == \A p \in PRs : merged[p] => inProd[p]

\* THE D4 PROPERTY. A non-emergency change never lands on a main it does not
\* contain -- i.e. no deployment silently reverts an earlier one.
NoRegression == regressed = FALSE

(***************************************************************************)
(* A draft never reaches an environment. Holding the berth counts: staging  *)
(* is where the observations that authorize production are taken, so a      *)
(* draft that gets that far has already collected its own authorization.    *)
(***************************************************************************)
NoDraftDeployed ==
    \A p \in PRs : draft[p] => (holder # p /\ ~inProd[p])

Safety ==
    /\ TypeOK /\ AtMostOneHolder /\ NoProdWithoutStaging
    /\ NoRedGatesShipped /\ NoSilentBypass /\ NoRegression
    /\ NoMergeBeforeProduction /\ NoDraftDeployed
=============================================================================
