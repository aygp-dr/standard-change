------------------------------- MODULE Labels -------------------------------
(***************************************************************************)
(* The LABEL NAMESPACE as a state machine, transcribed from the scripts.    *)
(*                                                                         *)
(* StandardChange.tla models the promotion guards and Concurrent.tla the    *)
(* berths; neither can say what a PR's labels ARE, because both fold the   *)
(* three axes README.org keeps separate into a handful of booleans:        *)
(*                                                                         *)
(*   CLASS      itil:standard | itil:normal | itil:emergency               *)
(*   LIFECYCLE  change:requested -> change:scheduled -> change:complete    *)
(*   ACTION     deploy:staging (the berth), deploy:production            *)
(*   plus OBSERVATIONS on the head, READINESS (draft), the BOOKING that    *)
(*   entitles a change to the berth, and the ESTATE (freeze, emergency),   *)
(*   which is a property of the world and not of any PR.                   *)
(*                                                                         *)
(* Every action names the script or workflow it was read from. Where the   *)
(* declaration (change/label-owners.tsv) and a script disagree, the SCRIPT *)
(* is modelled and the disagreement is listed in                           *)
(* docs/label-state-machine.org -- a model of the declaration would verify *)
(* a pipeline nobody runs.                                                  *)
(*                                                                         *)
(* Eleven CONSTANTS, one per rule, so the model can FAIL eleven ways. Each *)
(* is flipped to FALSE by tla/check.sh and TLC must then name the invariant*)
(* that rule protects. sim/label_sim.py is the same machine in Python and  *)
(* sim/cross_check.py requires the two to agree, rule by rule.             *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS PRs,
          \* --- the nine rules, each switchable so its invariant can fail ---
          DraftGuard,        \* preflight: a draft is refused before the class is read
          WindowGuard,       \* preflight: no reservation, no deployment, no exemption
          FreezeGuard,       \* preflight: freeze stops everything but an emergency
          EstateGuard,       \* preflight: an emergency in flight stops standard and normal
          BerthGuard,        \* guard 1: deploy:staging is a singleton across the repo
          ClassGuard,        \* preflight.sh:187: two classes is an undefined class -- refused
          LifecycleExclusive,\* schedule.sh: booking removes change:requested
          ReapFreesBerth,    \* reap.sh: a lapsed window releases deploy:staging it still held
          SettleClears,      \* settle.sh:244-252: cleanup clears every transient label
          ReapSparesInFlight,\* a lapsed window is not reaped while its change is deploying
          RecordOnMerge      \* the path that merges also records (complete, PIR)

Classes   == {"standard", "normal", "emergency"}
Lifecycle == {"requested", "scheduled", "complete"}
Bookings  == {"none", "queued", "designated"}
Verdicts  == {"none", "pass", "fail"}

VARIABLES
    class,        \* class[p] \subseteq Classes: the itil:* labels present
    life,         \* life[p]  \subseteq Lifecycle: the change:* labels present
    draft,        \* draft[p]: the author's own statement that p is not ready
    release,      \* release[p]: the human's intent label, consumed by watch.sh
    booking,      \* booking[p] \in Bookings: how the window was obtained
    berth,        \* berth[p]: deploy:staging present -- the berth claim guard 1 reads
    prodAct,      \* prodAct[p]: deploy:production present
    verdict,      \* verdict[p] \in Verdicts: the staging instrument's last word
    uat,          \* uat[p]: staging:uat -- a person accepted THIS head
    healthy,      \* healthy[p]: production:healthy -- guard 5 converged on THIS head
    closed,       \* closed[p]: change:failed or change:backed-out (abort.sh)
    served,       \* served[p]: production converged on THIS head (a fact, not the label)
    merged,       \* merged[p]: the forge records MERGED
    pir,          \* pir[p]: the post-implementation review is posted (settle.sh:150-168)
    cleaned,      \* cleaned[p]: settle.sh's cleanup ran (settle.sh:244-252)
    freeze,       \* ESTATE: the freeze label on the estate issue
    estateEmg,    \* ESTATE: the emergency label on the estate issue
    badClaim,     \* history: a claim that a rule should have refused was made
    badClass      \* history: a berth was claimed with an undefined class

vars == <<class, life, draft, release, booking, berth, prodAct,
          verdict, uat, healthy, closed, served, merged, pir, cleaned,
          freeze, estateEmg, badClaim, badClass>>

TypeOK ==
    /\ class     \in [PRs -> SUBSET Classes]
    /\ life      \in [PRs -> SUBSET Lifecycle]
    /\ draft     \in [PRs -> BOOLEAN]
    /\ release   \in [PRs -> BOOLEAN]
    /\ booking   \in [PRs -> Bookings]
    /\ berth     \in [PRs -> BOOLEAN]
    /\ prodAct   \in [PRs -> BOOLEAN]
    /\ verdict   \in [PRs -> Verdicts]
    /\ uat       \in [PRs -> BOOLEAN]
    /\ healthy   \in [PRs -> BOOLEAN]
    /\ closed    \in [PRs -> BOOLEAN]
    /\ served    \in [PRs -> BOOLEAN]
    /\ merged    \in [PRs -> BOOLEAN]
    /\ pir       \in [PRs -> BOOLEAN]
    /\ cleaned   \in [PRs -> BOOLEAN]
    /\ freeze    \in BOOLEAN
    /\ estateEmg \in BOOLEAN
    /\ badClaim  \in BOOLEAN
    /\ badClass  \in BOOLEAN

Init ==
    /\ class     = [p \in PRs |-> {}]
    /\ life      = [p \in PRs |-> {}]
    /\ draft     \in [PRs -> BOOLEAN]        \* some PRs open as drafts
    /\ release   = [p \in PRs |-> FALSE]
    /\ booking   = [p \in PRs |-> "none"]
    /\ berth     = [p \in PRs |-> FALSE]
    /\ prodAct   = [p \in PRs |-> FALSE]
    /\ verdict   = [p \in PRs |-> "none"]
    /\ uat       = [p \in PRs |-> FALSE]
    /\ healthy   = [p \in PRs |-> FALSE]
    /\ closed    = [p \in PRs |-> FALSE]
    /\ served    = [p \in PRs |-> FALSE]
    /\ merged    = [p \in PRs |-> FALSE]
    /\ pir       = [p \in PRs |-> FALSE]
    /\ cleaned   = [p \in PRs |-> FALSE]
    /\ freeze    = FALSE
    /\ estateEmg = FALSE
    /\ badClaim  = FALSE
    /\ badClass  = FALSE

\* Open: still a candidate for the pipeline. A merged change is not, and
\* neither is one that settle.sh has marked complete.
Open(p)      == ~closed[p] /\ ~merged[p] /\ "complete" \notin life[p]
Active(p)    == life[p] \ {"complete"}      \* the lifecycle states that are not terminal
IsEmergency(p) == "emergency" \in class[p]
Holder       == {p \in PRs : berth[p]}

(***************************************************************************)
(* CLASS. labeller.yml:44-48 derives standard or normal from the diff on   *)
(* every push and never reads itil:emergency -- by design: the class       *)
(* designation is a derivation and the emergency is a declaration. So a    *)
(* declared emergency that receives a push carries TWO classes, and        *)
(* preflight.sh:187 refuses that as an undefined class: "recovery: a       *)
(* person removes the class that is wrong. Not the pipeline." That is the  *)
(* rule, and ClassGuard is it. ResolveClass is the person's act.           *)
(***************************************************************************)
Label(p) ==
    /\ Open(p)
    /\ \E c \in {"standard", "normal"} :
         class' = [class EXCEPT ![p] = (@ \ {"standard", "normal"}) \cup {c}]
    /\ UNCHANGED <<life, draft, release, booking, berth, prodAct,
                   verdict, uat, healthy, closed, served, merged, pir, cleaned, freeze, estateEmg, badClaim, badClass>>

\* A person declares an emergency (label-owners.tsv: itil:emergency, human).
DeclareEmergency(p) ==
    /\ Open(p) /\ ~IsEmergency(p)
    /\ class' = [class EXCEPT ![p] = @ \cup {"emergency"}]
    /\ UNCHANGED <<life, draft, release, booking, berth, prodAct,
                   verdict, uat, healthy, closed, served, merged, pir, cleaned, freeze, estateEmg, badClaim, badClass>>

\* A person removes the derived class that is wrong (preflight.sh:190).
ResolveClass(p) ==
    /\ Open(p) /\ IsEmergency(p) /\ Cardinality(class[p]) > 1
    /\ class' = [class EXCEPT ![p] = {"emergency"}]
    /\ UNCHANGED <<life, draft, release, booking, berth, prodAct,
                   verdict, uat, healthy, closed, served, merged, pir, cleaned, freeze, estateEmg, badClaim, badClass>>

\* gh pr ready -- the author's act, and the only thing that clears draft.
MarkReady(p) ==
    /\ Open(p) /\ draft[p]
    /\ draft' = [draft EXCEPT ![p] = FALSE]
    /\ UNCHANGED <<class, life, release, booking, berth, prodAct, 
                   verdict, uat, healthy, closed, served, merged, pir, cleaned, freeze, estateEmg, badClaim, badClass>>

\* A person adds release -- intent (README.org, Adding a label and removing it).
AddRelease(p) ==
    /\ Open(p) /\ ~release[p]
    /\ release' = [release EXCEPT ![p] = TRUE]
    /\ UNCHANGED <<class, life, draft, booking, berth, prodAct, 
                   verdict, uat, healthy, closed, served, merged, pir, cleaned, freeze, estateEmg, badClaim, badClass>>

(***************************************************************************)
(* change/watch.sh:37-38 -- consume the trigger FIRST, then record the ask. *)
(*                                                                         *)
(* Under LifecycleExclusive the ask is not re-recorded on a change that is *)
(* already scheduled. watch.sh:38 adds change:requested unconditionally,   *)
(* so a booked change whose release is consumed carries requested AND      *)
(* scheduled -- the script implements LifecycleExclusive = FALSE here.     *)
(***************************************************************************)
Watch(p) ==
    /\ Open(p) /\ release[p]
    /\ release' = [release EXCEPT ![p] = FALSE]
    /\ life'    = [life EXCEPT ![p] =
                     IF LifecycleExclusive /\ "scheduled" \in @ THEN @ ELSE @ \cup {"requested"}]
    /\ UNCHANGED <<class, draft, booking, berth, prodAct, 
                   verdict, uat, healthy, closed, served, merged, pir, cleaned, freeze, estateEmg, badClaim, badClass>>

\* A person adds change:requested directly (label-owners.tsv: human).
Request(p) ==
    /\ Open(p) /\ "requested" \notin life[p] /\ "scheduled" \notin life[p]
    /\ life' = [life EXCEPT ![p] = @ \cup {"requested"}]
    /\ UNCHANGED <<class, draft, release, booking, berth, prodAct, 
                   verdict, uat, healthy, closed, served, merged, pir, cleaned, freeze, estateEmg, badClaim, badClass>>

(***************************************************************************)
(* change/schedule.sh block:257 -- book a window, queued or --at.          *)
(* --add-label change:scheduled --remove-label change:requested.           *)
(***************************************************************************)
Book(p) ==
    /\ Open(p) /\ "scheduled" \notin life[p]
    /\ \E b \in {"queued", "designated"} : booking' = [booking EXCEPT ![p] = b]
    /\ life' = [life EXCEPT ![p] =
                  IF LifecycleExclusive THEN (@ \ {"requested"}) \cup {"scheduled"}
                                        ELSE @ \cup {"scheduled"}]
    /\ UNCHANGED <<class, draft, release, berth, prodAct, 
                   verdict, uat, healthy, closed, served, merged, pir, cleaned, freeze, estateEmg, badClaim, badClass>>

(***************************************************************************)
(* change/schedule.sh cancel:303 -- a person un-books. change:scheduled     *)
(* cleared; the change is approved and unbooked.                            *)
(***************************************************************************)
Cancel(p) ==
    /\ ~closed[p] /\ "scheduled" \in life[p] /\ ~berth[p]
    /\ life'    = [life    EXCEPT ![p] = @ \ {"scheduled"}]
    /\ booking' = [booking EXCEPT ![p] = "none"]
    /\ UNCHANGED <<class, draft, release, berth, prodAct, 
                   verdict, uat, healthy, closed, served, merged, pir, cleaned, freeze, estateEmg, badClaim, badClass>>

(***************************************************************************)
(* change/reap.sh:74-78 -- the window lapsed. change:scheduled removed and  *)
(* NOT replaced (asking is a person's act); deploy:staging released if the  *)
(* dead window still held it. Nothing was attempted, so no closure code.   *)
(***************************************************************************)
Reap(p) ==
    \* reap.sh:10-14 reads only the window's end time. It does not look at
    \* deploy:production, so a window that lapses while its change is
    \* deploying is reaped mid-flight -- ReapSparesInFlight = FALSE is the
    \* script. It does not look at MERGED either: a merged, unsettled change
    \* whose window lapses loses change:scheduled, its last lifecycle label.
    /\ ~closed[p] /\ "scheduled" \in life[p]
    /\ (ReapSparesInFlight => ~prodAct[p])
    /\ life'    = [life    EXCEPT ![p] = @ \ {"scheduled"}]
    /\ booking' = [booking EXCEPT ![p] = "none"]
    /\ berth'   = [berth   EXCEPT ![p] = IF ReapFreesBerth THEN FALSE ELSE @]
    /\ UNCHANGED <<class, draft, release, prodAct, verdict, uat, healthy,
                   closed, served, merged, pir, cleaned, freeze, estateEmg, badClaim, badClass>>

(***************************************************************************)
(* gates/preflight.sh, then change/activate.sh:265-268 -- the window opens, *)
(* the guards are re-evaluated, the berth is claimed and release:start is   *)
(* written. Each rule here is a preflight refusal in the script; with its   *)
(* constant off, the refusal is skipped and badClaim records that a claim   *)
(* was made which the rule would have refused.                              *)
(***************************************************************************)
Refused(p) ==
    \/ draft[p]
    \/ booking[p] = "none"
    \/ (freeze /\ ~IsEmergency(p))
    \/ (estateEmg /\ ~IsEmergency(p))
    \/ (Holder \ {p}) # {}

Permitted(p) ==
    /\ (ClassGuard  => Cardinality(class[p]) <= 1)
    /\ (DraftGuard  => ~draft[p])
    /\ (WindowGuard => booking[p] # "none")
    /\ (FreezeGuard => (freeze => IsEmergency(p)))
    /\ (EstateGuard => (estateEmg => IsEmergency(p)))
    /\ (BerthGuard  => (Holder \ {p}) = {})

Activate(p) ==
    \* activate.sh can be run by hand on any open change; whether it is BOOKED
    \* is preflight's question (WindowGuard), not a precondition of the script.
    /\ Open(p) /\ ~berth[p]
    /\ Permitted(p)
    /\ berth'    = [berth   EXCEPT ![p] = TRUE]
    /\ badClaim' = (badClaim \/ Refused(p))
    /\ badClass' = (badClass \/ Cardinality(class[p]) > 1)
    /\ UNCHANGED <<class, life, draft, release, booking, prodAct,
                   verdict, uat, healthy, closed, served, merged, pir, cleaned, freeze, estateEmg>>

\* gates/e2e.sh --pr and gates/smoke.sh --pr -- the instrument labels its own
\* result; a new verdict replaces the old one (exclusion group staging-verdict).
Observe(p) ==
    /\ Open(p) /\ berth[p]
    /\ \E v \in {"pass", "fail"} : verdict' = [verdict EXCEPT ![p] = v]
    /\ UNCHANGED <<class, life, draft, release, booking, berth, prodAct,
                   uat, healthy, closed, served, merged, pir, cleaned, freeze, estateEmg, badClaim, badClass>>

\* change/observe.sh:44 -- a person accepts staging; the person is the instrument.
Accept(p) ==
    /\ Open(p) /\ berth[p] /\ verdict[p] = "pass" /\ ~uat[p]
    /\ uat' = [uat EXCEPT ![p] = TRUE]
    /\ UNCHANGED <<class, life, draft, release, booking, berth, prodAct,
                   verdict, healthy, closed, served, merged, pir, cleaned, freeze, estateEmg, badClaim, badClass>>

(***************************************************************************)
(* promote.yml:26 -- deploy:production on the staging verdict, or on an     *)
(* approved emergency (the break-glass path of StandardChange.tla).         *)
(***************************************************************************)
Promote(p) ==
    /\ Open(p) /\ berth[p] /\ ~prodAct[p]
    /\ \/ (verdict[p] = "pass" /\ uat[p])
       \/ IsEmergency(p)
    /\ prodAct' = [prodAct EXCEPT ![p] = TRUE]
    /\ UNCHANGED <<class, life, draft, release, booking, berth, 
                   verdict, uat, healthy, closed, served, merged, pir, cleaned, freeze, estateEmg, badClaim, badClass>>

\* gates/health.sh --pr:99 -- guard 5 converged on this head.
Converge(p) ==
    /\ Open(p) /\ prodAct[p] /\ ~healthy[p]
    /\ healthy' = [healthy EXCEPT ![p] = TRUE]
    /\ served'  = [served  EXCEPT ![p] = TRUE]
    /\ UNCHANGED <<class, life, draft, release, booking, berth, prodAct,
                   verdict, uat, closed, merged, pir, cleaned, freeze, estateEmg, badClaim, badClass>>

(***************************************************************************)
(* SETTLEMENT is four writes in a stated order, and two paths reach the    *)
(* merge.                                                                  *)
(*                                                                         *)
(*   merge-on-healthy.yml -> change/release.sh   the AUTOMATIC path: fires  *)
(*     on the production:healthy label, re-derives guard 5, merges, and    *)
(*     clears deploy:*, staging:passed and production:healthy. It sets no  *)
(*     change:complete and posts no PIR -- the workflow says so itself:    *)
(*     "Settle from a host that can see the estate".                       *)
(*   change/settle.sh   the RECORDING path, run by a person or the settle  *)
(*     skill: change:complete (:105), merge if not already MERGED (:127),  *)
(*     the PIR (:150-168), then cleanup (:244-252) which clears every      *)
(*     transient label, change:complete included.                          *)
(*                                                                         *)
(* RecordOnMerge = TRUE says the merging path also records. The tree      *)
(* implements FALSE: after the automatic merge, the record exists only if  *)
(* someone runs settle.sh, and nothing on the PR says so.                  *)
(***************************************************************************)
MergeOnHealthy(p) ==
    /\ Open(p) /\ healthy[p] /\ ~merged[p]
    /\ merged'  = [merged  EXCEPT ![p] = TRUE]
    /\ berth'   = [berth   EXCEPT ![p] = FALSE]
    /\ prodAct' = [prodAct EXCEPT ![p] = FALSE]
    /\ healthy' = [healthy EXCEPT ![p] = FALSE]
    /\ IF RecordOnMerge
       THEN /\ life'    = [life    EXCEPT ![p] = {}]
            /\ pir'     = [pir     EXCEPT ![p] = TRUE]
            /\ cleaned' = [cleaned EXCEPT ![p] = TRUE]
            /\ release' = [release EXCEPT ![p] = FALSE]
            /\ verdict' = [verdict EXCEPT ![p] = "none"]
            /\ uat'     = [uat     EXCEPT ![p] = FALSE]
            /\ booking' = [booking EXCEPT ![p] = "none"]
       ELSE UNCHANGED <<life, pir, cleaned, release, verdict, uat, booking>>
    /\ UNCHANGED <<class, draft, closed, served, freeze, estateEmg, badClaim, badClass>>

\* settle.sh:70 re-measures production against the head; :105 writes complete.
Complete(p) ==
    /\ ~closed[p] /\ served[p] /\ "complete" \notin life[p] /\ ~pir[p]
    /\ life' = [life EXCEPT ![p] = @ \cup {"complete"}]
    /\ UNCHANGED <<class, draft, release, booking, berth, prodAct, verdict, uat,
                   healthy, closed, served, merged, pir, cleaned, freeze, estateEmg, badClaim, badClass>>

\* settle.sh:124-140 -- merge unless the forge already says MERGED; a refused
\* merge stops settlement (exit 8), which the model expresses by not firing.
SettleMerge(p) ==
    /\ "complete" \in life[p] /\ ~merged[p]
    /\ merged' = [merged EXCEPT ![p] = TRUE]
    /\ UNCHANGED <<class, life, draft, release, booking, berth, prodAct, verdict, uat,
                   healthy, closed, served, pir, cleaned, freeze, estateEmg, badClaim, badClass>>

\* settle.sh:150-168 -- the PIR, posted while the labels are still there to read.
Pir(p) ==
    /\ "complete" \in life[p] /\ merged[p] /\ ~pir[p]
    /\ pir' = [pir EXCEPT ![p] = TRUE]
    /\ UNCHANGED <<class, life, draft, release, booking, berth, prodAct, verdict, uat,
                   healthy, closed, served, merged, cleaned, freeze, estateEmg, badClaim, badClass>>

\* settle.sh:244-252 -- cleanup. Every transient label, change:complete included.
Cleanup(p) ==
    /\ pir[p] /\ ~cleaned[p]
    /\ cleaned' = [cleaned EXCEPT ![p] = TRUE]
    /\ IF SettleClears
       THEN /\ life'    = [life    EXCEPT ![p] = {}]
            /\ berth'   = [berth   EXCEPT ![p] = FALSE]
            /\ prodAct' = [prodAct EXCEPT ![p] = FALSE]
            /\ release' = [release EXCEPT ![p] = FALSE]
            /\ verdict' = [verdict EXCEPT ![p] = "none"]
            /\ uat'     = [uat     EXCEPT ![p] = FALSE]
            /\ healthy' = [healthy EXCEPT ![p] = FALSE]
            /\ booking' = [booking EXCEPT ![p] = "none"]
       ELSE UNCHANGED <<life, berth, prodAct, release, verdict, uat, healthy, booking>>
    /\ UNCHANGED <<class, draft, closed, served, merged, pir, freeze, estateEmg, badClaim, badClass>>

(***************************************************************************)
(* change/abort.sh:95-114 -- the change did not make it. Observations,      *)
(* release, release:start, deploy:staging and change:scheduled cleared; a  *)
(* closure code written. deploy:production is NOT in abort's list (it was   *)
(* never on a change abort closes), so the model does not clear it either.  *)
(***************************************************************************)
Abort(p) ==
    /\ Open(p) /\ ("scheduled" \in life[p] \/ berth[p])
    /\ closed'  = [closed  EXCEPT ![p] = TRUE]
    /\ life'    = [life    EXCEPT ![p] = @ \ {"scheduled"}]
    /\ berth'   = [berth   EXCEPT ![p] = FALSE]
    /\ release' = [release EXCEPT ![p] = FALSE]
    /\ verdict' = [verdict EXCEPT ![p] = "none"]
    /\ uat'     = [uat     EXCEPT ![p] = FALSE]
    /\ healthy' = [healthy EXCEPT ![p] = FALSE]
    /\ served'  = [served  EXCEPT ![p] = FALSE]
    /\ UNCHANGED <<class, draft, booking, prodAct, merged, pir, cleaned, freeze, estateEmg, badClaim, badClass>>

(***************************************************************************)
(* labeller.yml:101 on synchronize -- a push withdraws every observation    *)
(* about the old head. The lifecycle and the booking are about the change, *)
(* not the build, and survive.                                              *)
(***************************************************************************)
Push(p) ==
    /\ Open(p) /\ (verdict[p] # "none" \/ uat[p] \/ healthy[p])
    /\ verdict' = [verdict EXCEPT ![p] = "none"]
    /\ uat'     = [uat     EXCEPT ![p] = FALSE]
    /\ healthy' = [healthy EXCEPT ![p] = FALSE]
    /\ served'  = [served  EXCEPT ![p] = FALSE]
    /\ UNCHANGED <<class, life, draft, release, booking, berth, prodAct,
                   closed, merged, pir, cleaned, freeze, estateEmg, badClaim, badClass>>

\* The estate: a person toggles freeze and emergency on issue #1.
Freeze   == /\ freeze' = ~freeze
            /\ UNCHANGED <<class, life, draft, release, booking, berth, prodAct,
                           verdict, uat, healthy, closed, served, merged, pir, cleaned, estateEmg, badClaim, badClass>>
Estate   == /\ estateEmg' = ~estateEmg
            /\ UNCHANGED <<class, life, draft, release, booking, berth, prodAct,
                           verdict, uat, healthy, closed, served, merged, pir, cleaned, freeze, badClaim, badClass>>

Next ==
    \/ \E p \in PRs : Label(p) \/ DeclareEmergency(p) \/ ResolveClass(p) \/ MarkReady(p)
                   \/ AddRelease(p) \/ Watch(p) \/ Request(p) \/ Book(p)
                   \/ Cancel(p) \/ Reap(p) \/ Activate(p) \/ Observe(p)
                   \/ Accept(p) \/ Promote(p) \/ Converge(p)
                   \/ MergeOnHealthy(p) \/ Complete(p) \/ SettleMerge(p)
                   \/ Pir(p) \/ Cleanup(p)
                   \/ Abort(p) \/ Push(p)
    \/ Freeze \/ Estate

Spec == Init /\ [][Next]_vars

(***************************************************************************)
(*                              INVARIANTS                                 *)
(* One per rule. tla/check.sh flips each constant and TLC must name the    *)
(* invariant below it; sim/cross_check.py requires label_sim.py to agree.  *)
(***************************************************************************)

\* preflight.sh:187: nothing deploys with an undefined class       [ClassGuard]
\* Two classes IS reachable -- a declared emergency plus a re-derived class --
\* and that is by design; what may not happen is a berth claim on top of it.
\* The class can change AFTER the claim (a person declares mid-flight), so the
\* property is about the moment of reliance, as for the freeze: badClass.
NoDeployWithTwoClasses == badClass = FALSE

\* exclusion group `lifecycle`: at most one ACTIVE change:*       [LifecycleExclusive]
\* change:complete is terminal, not active: settle.sh writes it at :105 while
\* change:scheduled is still on, and clears both at :244-252.
OneLifecycle == \A p \in PRs : Cardinality(Active(p)) <= 1

\* a draft never holds the berth or reaches production            [DraftGuard]
NoDraftDeployed == \A p \in PRs : draft[p] => (~berth[p] /\ ~prodAct[p])

\* no reservation, no deployment                                  [WindowGuard]
NoUnbookedDeploy == \A p \in PRs : (berth[p] \/ prodAct[p]) => booking[p] # "none"

\* a berth is held by at most one change                          [BerthGuard]
AtMostOneHolder == Cardinality(Holder) <= 1

\* no claim was made that a rule should have refused              [FreezeGuard, EstateGuard]
NoRefusedClaim == badClaim = FALSE

\* a held berth has a live window behind it                       [ReapFreesBerth]
BerthHasCause == \A p \in PRs : berth[p] => "scheduled" \in life[p]

\* cleanup released everything transient, change:complete included [SettleClears]
CleanIsClean ==
    \A p \in PRs : cleaned[p] =>
        (life[p] = {} /\ ~berth[p] /\ ~prodAct[p] /\ ~release[p]
         /\ verdict[p] = "none" /\ ~uat[p] /\ ~healthy[p] /\ booking[p] = "none")

\* a merged change that has lost its last lifecycle label has its record [RecordOnMerge]
MergedHasRecord == \A p \in PRs : (merged[p] /\ life[p] = {}) => pir[p]

Safety ==
    /\ TypeOK /\ NoDeployWithTwoClasses /\ OneLifecycle /\ NoDraftDeployed
    /\ NoUnbookedDeploy /\ AtMostOneHolder /\ NoRefusedClaim /\ BerthHasCause
    /\ CleanIsClean /\ MergedHasRecord
=============================================================================
