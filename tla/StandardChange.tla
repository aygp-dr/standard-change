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
          NoPR          \* model value: "staging is held by nobody"

ASSUME NoPR \notin PRs

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
    regressed     \* set TRUE if a merge ever reverted an earlier one

vars == <<base, gated, stagingPass, prodLabel, emergency, approved,
          inProd, merged, mainV, holder, regressed>>

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
    /\ regressed   \in BOOLEAN

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
    /\ regressed   = FALSE

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
    /\ UNCHANGED <<base, emergency, approved, merged, mainV, holder, regressed>>

GatesPass(p) ==
    /\ Live(p) /\ ~gated[p]
    /\ gated' = [gated EXCEPT ![p] = TRUE]
    /\ UNCHANGED <<base, stagingPass, prodLabel, emergency, approved,
                   merged, mainV, holder, regressed, inProd>>

Rebase(p) ==
    /\ Live(p) /\ base[p] < mainV
    /\ base'        = [base        EXCEPT ![p] = mainV]
    \* a rebase is a new tree: verdicts do not survive it
    /\ gated'       = [gated       EXCEPT ![p] = FALSE]
    /\ stagingPass' = [stagingPass EXCEPT ![p] = FALSE]
    /\ prodLabel'   = [prodLabel   EXCEPT ![p] = FALSE]
    /\ UNCHANGED <<emergency, approved, merged, mainV, holder, regressed, inProd>>

MarkEmergency(p) ==
    /\ Live(p) /\ ~emergency[p]
    /\ emergency' = [emergency EXCEPT ![p] = TRUE]
    /\ UNCHANGED <<base, gated, stagingPass, prodLabel, approved,
                   merged, mainV, holder, regressed, inProd>>

Approve(p) ==
    /\ Live(p) /\ ~approved[p]
    /\ approved' = [approved EXCEPT ![p] = TRUE]
    /\ UNCHANGED <<base, gated, stagingPass, prodLabel, emergency,
                   merged, mainV, holder, regressed, inProd>>

(***************************************************************************)
(* Guard 0 (up to date with main) and guard 1 (staging is a singleton).    *)
(***************************************************************************)
ClaimStaging(p) ==
    /\ Live(p)
    /\ holder = NoPR            \* guard 1
    /\ base[p] = mainV          \* guard 0
    /\ gated[p]
    /\ holder' = p
    /\ UNCHANGED <<base, gated, stagingPass, prodLabel, emergency, approved,
                   merged, mainV, regressed, inProd>>

StagingPassed(p) ==
    /\ Live(p) /\ holder = p /\ gated[p] /\ ~stagingPass[p]
    /\ stagingPass' = [stagingPass EXCEPT ![p] = TRUE]
    /\ UNCHANGED <<base, gated, prodLabel, emergency, approved,
                   merged, mainV, holder, regressed, inProd>>

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
                   merged, mainV, holder, regressed, inProd>>

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
    /\ Live(p) /\ ~inProd[p] /\ prodLabel[p] /\ gated[p]
    /\ \/ stagingPass[p] \/ (emergency[p] /\ approved[p])        \* guard 4
    /\ inProd' = [inProd EXCEPT ![p] = TRUE]
    /\ UNCHANGED <<base, gated, stagingPass, prodLabel, emergency, approved,
                   merged, mainV, holder, regressed>>

(***************************************************************************)
(* The merge is SETTLEMENT, not authorization. regressed records the D4     *)
(* failure: a non-emergency change landing on a main it does not contain    *)
(* silently reverts whatever it is missing.                                 *)
(*                                                                          *)
(* ProdFirst is a CONSTANT so the model can FAIL. With ProdFirst = FALSE,   *)
(* TLC finds a merge with inProd = FALSE -- the #12 trace -- in a handful   *)
(* of states. An invariant whose guard cannot be switched off has not been  *)
(* shown to do anything.                                                    *)
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
    /\ UNCHANGED <<base, gated, stagingPass, prodLabel, emergency, approved, inProd>>

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
    /\ UNCHANGED <<base, gated, emergency, approved, merged, mainV, regressed>>

Next ==
    \/ \E p \in PRs : Push(p) \/ GatesPass(p) \/ Rebase(p) \/ MarkEmergency(p)
                   \/ Approve(p) \/ ClaimStaging(p) \/ StagingPassed(p)
                   \/ Promote(p) \/ DeployProduction(p) \/ Merge(p)
    \/ MainMoved

Spec == Init /\ [][Next]_vars

(***************************************************************************)
(*                              INVARIANTS                                 *)
(***************************************************************************)

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

Safety ==
    /\ TypeOK /\ AtMostOneHolder /\ NoProdWithoutStaging
    /\ NoRedGatesShipped /\ NoSilentBypass /\ NoRegression
    /\ NoMergeBeforeProduction
=============================================================================
