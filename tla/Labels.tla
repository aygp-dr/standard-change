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
(* Nine CONSTANTS, one per rule, so the model can FAIL nine ways. Each is  *)
(* flipped to FALSE by tla/check.sh and TLC must then name the invariant   *)
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
          ClassExclusive,    \* labeller: at most one itil:* -- declaring an emergency replaces
          LifecycleExclusive,\* schedule.sh: booking removes change:requested
          ReapFreesBerth,    \* reap.sh: a lapsed window releases deploy:staging it still held
          SettleClears       \* settle.sh: completion clears every transient label

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
    freeze,       \* ESTATE: the freeze label on the estate issue
    estateEmg,    \* ESTATE: the emergency label on the estate issue
    badClaim      \* history: a claim that a rule should have refused was made

vars == <<class, life, draft, release, booking, berth, prodAct, 
          verdict, uat, healthy, closed, freeze, estateEmg, badClaim>>

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
    /\ freeze    \in BOOLEAN
    /\ estateEmg \in BOOLEAN
    /\ badClaim  \in BOOLEAN

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
    /\ freeze    = FALSE
    /\ estateEmg = FALSE
    /\ badClaim  = FALSE

Open(p)      == ~closed[p] /\ "complete" \notin life[p]
IsEmergency(p) == "emergency" \in class[p]
Holder       == {p \in PRs : berth[p]}

(***************************************************************************)
(* labeller.yml:44-48 -- derive the class from the diff. standard and       *)
(* normal replace each other; the labeller never writes emergency.          *)
(*                                                                         *)
(* ClassExclusive is the exclusion group `class` in label-owners.tsv: at   *)
(* most one itil:*. With it, the labeller leaves a declared emergency      *)
(* alone. WITHOUT it, the labeller re-derives standard or normal on the    *)
(* next push beside itil:emergency -- which is what labeller.yml does      *)
(* today: lines 44-48 never read itil:emergency. The script implements     *)
(* ClassExclusive = FALSE. Recorded in docs/label-state-machine.org.       *)
(***************************************************************************)
Label(p) ==
    /\ Open(p)
    /\ (ClassExclusive => ~IsEmergency(p))
    /\ \E c \in {"standard", "normal"} :
         class' = [class EXCEPT ![p] = (@ \ {"standard", "normal"}) \cup {c}]
    /\ UNCHANGED <<life, draft, release, booking, berth, prodAct, 
                   verdict, uat, healthy, closed, freeze, estateEmg, badClaim>>

(***************************************************************************)
(* A person declares an emergency (label-owners.tsv: itil:emergency, human).*)
(* With ClassExclusive the person also drops the derived class; without it  *)
(* the PR carries two classes, which is the #2 defect the exclusion group   *)
(* was written for.                                                         *)
(***************************************************************************)
DeclareEmergency(p) ==
    /\ Open(p) /\ ~IsEmergency(p)
    /\ class' = [class EXCEPT ![p] =
                   IF ClassExclusive THEN {"emergency"} ELSE @ \cup {"emergency"}]
    /\ UNCHANGED <<life, draft, release, booking, berth, prodAct, 
                   verdict, uat, healthy, closed, freeze, estateEmg, badClaim>>

\* gh pr ready -- the author's act, and the only thing that clears draft.
MarkReady(p) ==
    /\ Open(p) /\ draft[p]
    /\ draft' = [draft EXCEPT ![p] = FALSE]
    /\ UNCHANGED <<class, life, release, booking, berth, prodAct, 
                   verdict, uat, healthy, closed, freeze, estateEmg, badClaim>>

\* A person adds release -- intent (README.org, Adding a label and removing it).
AddRelease(p) ==
    /\ Open(p) /\ ~release[p]
    /\ release' = [release EXCEPT ![p] = TRUE]
    /\ UNCHANGED <<class, life, draft, booking, berth, prodAct, 
                   verdict, uat, healthy, closed, freeze, estateEmg, badClaim>>

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
                   verdict, uat, healthy, closed, freeze, estateEmg, badClaim>>

\* A person adds change:requested directly (label-owners.tsv: human).
Request(p) ==
    /\ Open(p) /\ "requested" \notin life[p] /\ "scheduled" \notin life[p]
    /\ life' = [life EXCEPT ![p] = @ \cup {"requested"}]
    /\ UNCHANGED <<class, draft, release, booking, berth, prodAct, 
                   verdict, uat, healthy, closed, freeze, estateEmg, badClaim>>

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
                   verdict, uat, healthy, closed, freeze, estateEmg, badClaim>>

(***************************************************************************)
(* change/schedule.sh cancel:303 -- a person un-books. change:scheduled     *)
(* cleared; the change is approved and unbooked.                            *)
(***************************************************************************)
Cancel(p) ==
    /\ Open(p) /\ "scheduled" \in life[p] /\ ~berth[p]
    /\ life'    = [life    EXCEPT ![p] = @ \ {"scheduled"}]
    /\ booking' = [booking EXCEPT ![p] = "none"]
    /\ UNCHANGED <<class, draft, release, berth, prodAct, 
                   verdict, uat, healthy, closed, freeze, estateEmg, badClaim>>

(***************************************************************************)
(* change/reap.sh:74-78 -- the window lapsed. change:scheduled removed and  *)
(* NOT replaced (asking is a person's act); deploy:staging released if the  *)
(* dead window still held it. Nothing was attempted, so no closure code.   *)
(***************************************************************************)
Reap(p) ==
    /\ Open(p) /\ "scheduled" \in life[p] /\ ~prodAct[p]
    /\ life'    = [life    EXCEPT ![p] = @ \ {"scheduled"}]
    /\ booking' = [booking EXCEPT ![p] = "none"]
    /\ berth'   = [berth   EXCEPT ![p] = IF ReapFreesBerth THEN FALSE ELSE @]
    /\ UNCHANGED <<class, draft, release, prodAct, verdict, uat, healthy,
                   closed, freeze, estateEmg, badClaim>>

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
    /\ UNCHANGED <<class, life, draft, release, booking, prodAct,
                   verdict, uat, healthy, closed, freeze, estateEmg>>

\* gates/e2e.sh --pr and gates/smoke.sh --pr -- the instrument labels its own
\* result; a new verdict replaces the old one (exclusion group staging-verdict).
Observe(p) ==
    /\ Open(p) /\ berth[p]
    /\ \E v \in {"pass", "fail"} : verdict' = [verdict EXCEPT ![p] = v]
    /\ UNCHANGED <<class, life, draft, release, booking, berth, prodAct,
                   uat, healthy, closed, freeze, estateEmg, badClaim>>

\* change/observe.sh:44 -- a person accepts staging; the person is the instrument.
Accept(p) ==
    /\ Open(p) /\ berth[p] /\ verdict[p] = "pass" /\ ~uat[p]
    /\ uat' = [uat EXCEPT ![p] = TRUE]
    /\ UNCHANGED <<class, life, draft, release, booking, berth, prodAct,
                   verdict, healthy, closed, freeze, estateEmg, badClaim>>

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
                   verdict, uat, healthy, closed, freeze, estateEmg, badClaim>>

\* gates/health.sh --pr:99 -- guard 5 converged on this head.
Converge(p) ==
    /\ Open(p) /\ prodAct[p] /\ ~healthy[p]
    /\ healthy' = [healthy EXCEPT ![p] = TRUE]
    /\ UNCHANGED <<class, life, draft, release, booking, berth, prodAct,
                   verdict, uat, closed, freeze, estateEmg, badClaim>>

(***************************************************************************)
(* change/settle.sh:105 then :244-252 -- change:complete, then every        *)
(* transient label cleared. The order is the content: complete is set from  *)
(* the health observation, and the berth is released by the clearing.       *)
(***************************************************************************)
Settle(p) ==
    /\ Open(p) /\ healthy[p]
    /\ life'    = [life EXCEPT ![p] =
                     IF SettleClears THEN {"complete"} ELSE @ \cup {"complete"}]
    /\ berth'   = [berth   EXCEPT ![p] = IF SettleClears THEN FALSE ELSE @]
    /\ prodAct' = [prodAct EXCEPT ![p] = IF SettleClears THEN FALSE ELSE @]
    /\ release' = [release EXCEPT ![p] = IF SettleClears THEN FALSE ELSE @]
    /\ verdict' = [verdict EXCEPT ![p] = IF SettleClears THEN "none" ELSE @]
    /\ uat'     = [uat     EXCEPT ![p] = IF SettleClears THEN FALSE ELSE @]
    /\ healthy' = [healthy EXCEPT ![p] = IF SettleClears THEN FALSE ELSE @]
    /\ booking' = [booking EXCEPT ![p] = IF SettleClears THEN "none" ELSE @]
    /\ UNCHANGED <<class, draft, closed, freeze, estateEmg, badClaim>>

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
    /\ UNCHANGED <<class, draft, booking, prodAct, freeze, estateEmg, badClaim>>

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
    /\ UNCHANGED <<class, life, draft, release, booking, berth, prodAct,
                   closed, freeze, estateEmg, badClaim>>

\* The estate: a person toggles freeze and emergency on issue #1.
Freeze   == /\ freeze' = ~freeze
            /\ UNCHANGED <<class, life, draft, release, booking, berth, prodAct,
                           verdict, uat, healthy, closed, estateEmg, badClaim>>
Estate   == /\ estateEmg' = ~estateEmg
            /\ UNCHANGED <<class, life, draft, release, booking, berth, prodAct,
                           verdict, uat, healthy, closed, freeze, badClaim>>

Next ==
    \/ \E p \in PRs : Label(p) \/ DeclareEmergency(p) \/ MarkReady(p)
                   \/ AddRelease(p) \/ Watch(p) \/ Request(p) \/ Book(p)
                   \/ Cancel(p) \/ Reap(p) \/ Activate(p) \/ Observe(p)
                   \/ Accept(p) \/ Promote(p) \/ Converge(p) \/ Settle(p)
                   \/ Abort(p) \/ Push(p)
    \/ Freeze \/ Estate

Spec == Init /\ [][Next]_vars

(***************************************************************************)
(*                              INVARIANTS                                 *)
(* One per rule. tla/check.sh flips each constant and TLC must name the    *)
(* invariant below it; sim/cross_check.py requires label_sim.py to agree.  *)
(***************************************************************************)

\* exclusion group `class`: at most one itil:*                    [ClassExclusive]
OneClass == \A p \in PRs : Cardinality(class[p]) <= 1

\* exclusion group `lifecycle`: at most one ACTIVE change:*       [LifecycleExclusive]
OneLifecycle == \A p \in PRs : Cardinality(life[p]) <= 1

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

\* completion released everything transient                       [SettleClears]
CompleteIsClean ==
    \A p \in PRs : "complete" \in life[p] =>
        (~berth[p] /\ ~prodAct[p] /\ ~release[p]
         /\ verdict[p] = "none" /\ ~uat[p] /\ ~healthy[p] /\ booking[p] = "none")

Safety ==
    /\ TypeOK /\ OneClass /\ OneLifecycle /\ NoDraftDeployed /\ NoUnbookedDeploy
    /\ AtMostOneHolder /\ NoRefusedClaim /\ BerthHasCause /\ CompleteIsClean
=============================================================================
