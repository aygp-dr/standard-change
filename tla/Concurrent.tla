-------------------------------- MODULE Concurrent ----------------------------
(***************************************************************************)
(* StandardChange.tla revisited against what sim/ and the notes since have  *)
(* established. Three of its assumptions turned out to be load-bearing and  *)
(* wrong -- not wrong about what they modelled, but wrong as a model of the *)
(* design as it now stands:                                                 *)
(*                                                                          *)
(*   1. DeployAndMerge was ATOMIC. Deploying and merging were one step, so  *)
(*      no other change could merge in between. The berths=2 race that      *)
(*      sim/ found is not expressible there at all.                         *)
(*   2. `holder` was a single PR. Berths = 1 was baked into the state, so   *)
(*      concurrency could not be stated.                                    *)
(*   3. Guard 4b was `base[p] = mainV` -- ANY movement of trunk withdrew    *)
(*      the pass. The spec now classifies divergence and only withdraws for *)
(*      artifact/hotfix.                                                    *)
(*                                                                          *)
(* This module fixes all three. MergeGuard4b is a CONSTANT so the model can *)
(* fail: with it FALSE and Berths > 1, TLC must reproduce the defect sim/   *)
(* found by property testing. Design-level and implementation-level         *)
(* verification agreeing is the point; a model that cannot fail is not one. *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS PRs, MaxMerges, Berths,
          Guard4b,        \* withdraw a stale pass when trunk moves
          MergeGuard4b    \* re-check at the MERGE, not only at deploy

VARIABLES base, gated, stagingPass, prodLabel, emergency, approved, merged,
          mainV, holders, deploying, mergeClass, regressed, touches

vars == <<base, gated, stagingPass, prodLabel, emergency, approved, merged,
          mainV, holders, deploying, mergeClass, regressed, touches>>

Classes == {"inert", "artifact"}

TypeOK ==
    /\ base        \in [PRs -> 0..MaxMerges]
    /\ gated       \in [PRs -> BOOLEAN]
    /\ stagingPass \in [PRs -> BOOLEAN]
    /\ prodLabel   \in [PRs -> BOOLEAN]
    /\ emergency   \in [PRs -> BOOLEAN]
    /\ approved    \in [PRs -> BOOLEAN]
    /\ merged      \in [PRs -> BOOLEAN]
    /\ mainV       \in 0..MaxMerges
    /\ holders     \subseteq PRs
    /\ deploying   \subseteq PRs
    /\ mergeClass  \in [1..MaxMerges -> Classes]
    /\ regressed   \in BOOLEAN
    /\ touches     \in [PRs -> Classes]

Init ==
    /\ base        = [p \in PRs |-> 0]
    /\ gated       = [p \in PRs |-> FALSE]
    /\ stagingPass = [p \in PRs |-> FALSE]
    /\ prodLabel   = [p \in PRs |-> FALSE]
    /\ emergency   = [p \in PRs |-> FALSE]
    /\ approved    = [p \in PRs |-> FALSE]
    /\ merged      = [p \in PRs |-> FALSE]
    /\ mainV       = 0
    /\ holders     = {}
    /\ deploying   = {}
    /\ mergeClass  = [v \in 1..MaxMerges |-> "inert"]
    /\ regressed   = FALSE
    \* chosen nondeterministically, so every mix of change classes is covered
    /\ touches     \in [PRs -> Classes]

Live(p) == ~merged[p]

\* Only artifact-class merges can change what a change would ship, so only
\* they invalidate a staging pass (spec.org, Guard 4b).
ArtifactDivergence(p) ==
    \E v \in 1..MaxMerges : /\ v <= mainV
                            /\ v > base[p]
                            /\ mergeClass[v] = "artifact"

Push(p) ==
    /\ Live(p) /\ p \notin deploying
    /\ gated'       = [gated       EXCEPT ![p] = FALSE]
    /\ stagingPass' = [stagingPass EXCEPT ![p] = FALSE]
    /\ prodLabel'   = [prodLabel   EXCEPT ![p] = FALSE]
    /\ UNCHANGED <<base, emergency, approved, merged, mainV, holders,
                   deploying, mergeClass, regressed, touches>>

GatesPass(p) ==
    /\ Live(p) /\ ~gated[p]
    /\ gated' = [gated EXCEPT ![p] = TRUE]
    /\ UNCHANGED <<base, stagingPass, prodLabel, emergency, approved, merged,
                   mainV, holders, deploying, mergeClass, regressed, touches>>

Rebase(p) ==
    /\ Live(p) /\ p \notin deploying /\ base[p] < mainV
    /\ base'        = [base        EXCEPT ![p] = mainV]
    /\ gated'       = [gated       EXCEPT ![p] = FALSE]
    /\ stagingPass' = [stagingPass EXCEPT ![p] = FALSE]
    /\ prodLabel'   = [prodLabel   EXCEPT ![p] = FALSE]
    /\ UNCHANGED <<emergency, approved, merged, mainV, holders, deploying,
                   mergeClass, regressed, touches>>

MarkEmergency(p) ==
    /\ Live(p) /\ ~emergency[p]
    /\ emergency' = [emergency EXCEPT ![p] = TRUE]
    /\ UNCHANGED <<base, gated, stagingPass, prodLabel, approved, merged,
                   mainV, holders, deploying, mergeClass, regressed, touches>>

Approve(p) ==
    /\ Live(p) /\ ~approved[p]
    /\ approved' = [approved EXCEPT ![p] = TRUE]
    /\ UNCHANGED <<base, gated, stagingPass, prodLabel, emergency, merged,
                   mainV, holders, deploying, mergeClass, regressed, touches>>

\* Guard 1 is now a CAPACITY constraint, not a mutex.
ClaimBerth(p) ==
    /\ Live(p) /\ p \notin holders
    /\ Cardinality(holders) < Berths
    /\ base[p] = mainV                      \* guard 0
    /\ gated[p]
    /\ holders' = holders \cup {p}
    /\ UNCHANGED <<base, gated, stagingPass, prodLabel, emergency, approved,
                   merged, mainV, deploying, mergeClass, regressed, touches>>

StagingPassed(p) ==
    /\ Live(p) /\ p \in holders /\ gated[p] /\ ~stagingPass[p]
    /\ stagingPass' = [stagingPass EXCEPT ![p] = TRUE]
    /\ UNCHANGED <<base, gated, prodLabel, emergency, approved, merged,
                   mainV, holders, deploying, mergeClass, regressed, touches>>

Promote(p) ==
    /\ Live(p) /\ ~prodLabel[p] /\ gated[p]                  \* guard 2
    /\ \/ stagingPass[p] \/ (emergency[p] /\ approved[p])
    /\ prodLabel' = [prodLabel EXCEPT ![p] = TRUE]
    /\ UNCHANGED <<base, gated, stagingPass, emergency, approved, merged,
                   mainV, holders, deploying, mergeClass, regressed, touches>>

(***************************************************************************)
(* THE SPLIT. Deploying and merging are separate steps, so another change   *)
(* can merge while this one is in flight -- which is exactly the window     *)
(* sim/ found at berths=2 and the atomic model could not express.           *)
(***************************************************************************)
StartDeploy(p) ==
    /\ Live(p) /\ p \notin deploying /\ prodLabel[p] /\ gated[p]
    /\ \/ stagingPass[p] \/ (emergency[p] /\ approved[p])            \* guard 4
    /\ Guard4b => (emergency[p] \/ ~ArtifactDivergence(p))           \* guard 4b
    /\ deploying' = deploying \cup {p}
    /\ UNCHANGED <<base, gated, stagingPass, prodLabel, emergency, approved,
                   merged, mainV, holders, mergeClass, regressed, touches>>

CompleteMerge(p) ==
    /\ p \in deploying /\ Live(p) /\ mainV < MaxMerges
    \* GUARD 4, AGAIN. Found by TLC once deploy and merge were separate steps:
    \* a change could be marked change:emergency AFTER its staging pass was
    \* withdrawn and then merge with neither a pass nor an approval, because
    \* guard 4 had only ever been checked at StartDeploy. The same defect guard
    \* 0 had, in a new place, exposed by the same split. Third instance of the
    \* rule: a guard whose subject can change after it is checked must be
    \* re-checked at the moment it is relied on.
    /\ \/ stagingPass[p] \/ (emergency[p] /\ approved[p])
    /\ MergeGuard4b => (emergency[p] \/ ~ArtifactDivergence(p))      \* guard 4b AT MERGE
    /\ regressed'  = (regressed \/ (~emergency[p] /\ ArtifactDivergence(p)))
    /\ merged'     = [merged EXCEPT ![p] = TRUE]
    /\ mainV'      = mainV + 1
    /\ mergeClass' = [mergeClass EXCEPT ![mainV + 1] =
                        IF emergency[p] THEN "artifact" ELSE touches[p]]
    /\ holders'    = holders \ {p}
    /\ deploying'  = deploying \ {p}
    /\ UNCHANGED <<base, gated, stagingPass, prodLabel, emergency, approved, touches>>

\* Withdraw a pass main has outrun. Never takes a berth: preemption is not
\* staleness (spec.org, Guard 4b).
MainMoved ==
    /\ Guard4b
    /\ \E p \in PRs : Live(p) /\ ArtifactDivergence(p) /\ stagingPass[p]
    /\ stagingPass' = [p \in PRs |->
         IF Live(p) /\ ArtifactDivergence(p) /\ ~emergency[p] THEN FALSE
         ELSE stagingPass[p]]
    /\ prodLabel'   = [p \in PRs |->
         IF Live(p) /\ ArtifactDivergence(p) /\ ~emergency[p] /\ p \notin deploying
         THEN FALSE ELSE prodLabel[p]]
    /\ UNCHANGED <<base, gated, emergency, approved, merged, mainV, holders,
                   deploying, mergeClass, regressed, touches>>

Next ==
    \/ \E p \in PRs : Push(p) \/ GatesPass(p) \/ Rebase(p) \/ MarkEmergency(p)
                   \/ Approve(p) \/ ClaimBerth(p) \/ StagingPassed(p)
                   \/ Promote(p) \/ StartDeploy(p) \/ CompleteMerge(p)
    \/ MainMoved

Spec == Init /\ [][Next]_vars

(***************************************************************************)
(*                              INVARIANTS                                  *)
(***************************************************************************)
BerthCapacity == Cardinality(holders) <= Berths

\* Scoped to changes NOT in flight. Splitting deploy from merge makes the
\* label state TRANSIENTLY INCONSISTENT: MainMoved can withdraw a staging pass
\* while that change's deploy is already running. The atomic model let this
\* invariant be stated unconditionally; the real system does not satisfy it,
\* and did not before -- the atomicity was hiding the gap. What must hold of an
\* in-flight deploy is that it cannot MERGE, which is CompleteMerge's guard.
NoProdWithoutStaging ==
    \A p \in PRs : (prodLabel[p] /\ p \notin deploying)
                    => (stagingPass[p] \/ (emergency[p] /\ approved[p]))

NoRedGatesShipped == \A p \in PRs : merged[p] => gated[p]

NoSilentBypass ==
    \A p \in PRs : (merged[p] /\ ~stagingPass[p]) => (emergency[p] /\ approved[p])

\* The D4 property, now stated over divergence CLASS rather than over any
\* movement of trunk.
NoRegression == regressed = FALSE

Safety ==
    /\ TypeOK /\ BerthCapacity /\ NoProdWithoutStaging
    /\ NoRedGatesShipped /\ NoSilentBypass /\ NoRegression
=============================================================================
