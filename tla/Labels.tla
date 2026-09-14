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
(*   ACTION     deploy:staging (the berth), <env>:deployed, deploy:production *)
(*   plus OBSERVATIONS on the head (<env>:healthy, e2e/smoke, uat),        *)
(*   READINESS (draft), a person's staging:hold, the BOOKING that entitles *)
(*   a change to the berth, and the ESTATE (freeze, emergency), which is a  *)
(*   property of the world and not of any PR.                              *)
(*                                                                         *)
(* Every action names the script or workflow it was read from. Where the   *)
(* declaration (change/label-owners.tsv) and a script disagree, the SCRIPT *)
(* is modelled and the disagreement is listed in                           *)
(* docs/label-state-machine.org.                                           *)
(*                                                                         *)
(* Fourteen CONSTANTS, one per rule, so the model can FAIL fourteen ways.  *)
(* Each is flipped to FALSE by tla/check.sh and TLC must name the invariant *)
(* that rule protects. sim/label_sim.py is the same machine in Python and  *)
(* sim/cross_check.py requires the two to agree, rule by rule.             *)
(*                                                                         *)
(* THE FRAMES ARE GENERATED. Every action's UNCHANGED tuple is exactly the *)
(* variables it does not prime, written by tla/frames.py from the `vars`   *)
(* tuple; edit an action, run `python3 tla/frames.py`, and the frame is    *)
(* recomputed. Twenty-six variables by hand is how the previous cut got    *)
(* duplicated names and a missing history variable.                        *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS PRs,
          \* --- the fourteen rules, each switchable so its invariant can fail ---
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
          RecordOnMerge,     \* the path that merges also records (complete, PIR)
          EmergencyPreempts, \* a declared, ready emergency evicts a standard or normal holder
          HoldGuard,         \* staging:hold (a person's intent) stops promotion, at the moment of promoting
          HealthyBeforeVerdict \* an instrument measures staging only once staging:healthy is recorded

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
    berth,        \* berth[p]: deploy:staging -- the berth claim guard 1 reads
    stgDeployed,  \* stgDeployed[p]: staging:deployed -- the deployer says the install finished
    stgHealthy,   \* stgHealthy[p]: staging:healthy -- guard 5's instrument on staging, THIS head
    hold,         \* hold[p]: staging:hold -- a person says: not to production yet
    prodAct,      \* prodAct[p]: deploy:production -- the intent to deploy, landed by promote.yml
    prodDeployed, \* prodDeployed[p]: production:deployed -- the install finished
    verdict,      \* verdict[p] \in Verdicts: the staging instruments' last word (e2e, smoke)
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
    badClass,     \* history: a berth was claimed with an undefined class
    badPromote,   \* history: deploy:production landed under a staging:hold
    badVerdict,   \* history: an instrument recorded a staging verdict before staging:healthy
    emgWaited     \* history: a declared, ready emergency was kept out of staging by a holder

vars == <<class, life, draft, release, booking, berth, stgDeployed, stgHealthy, hold,
          prodAct, prodDeployed, verdict, uat, healthy, closed, served, merged, pir,
          cleaned, freeze, estateEmg, badClaim, badClass, badPromote, badVerdict, emgWaited>>

TypeOK ==
    /\ class     \in [PRs -> SUBSET Classes]
    /\ life      \in [PRs -> SUBSET Lifecycle]
    /\ draft     \in [PRs -> BOOLEAN]
    /\ release   \in [PRs -> BOOLEAN]
    /\ booking   \in [PRs -> Bookings]
    /\ berth     \in [PRs -> BOOLEAN]
    /\ stgDeployed \in [PRs -> BOOLEAN]
    /\ stgHealthy \in [PRs -> BOOLEAN]
    /\ hold      \in [PRs -> BOOLEAN]
    /\ prodAct   \in [PRs -> BOOLEAN]
    /\ prodDeployed \in [PRs -> BOOLEAN]
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
    /\ badPromote \in BOOLEAN
    /\ badVerdict \in BOOLEAN
    /\ emgWaited \in BOOLEAN

Init ==
    /\ class     = [p \in PRs |-> {}]
    /\ life      = [p \in PRs |-> {}]
    /\ draft     \in [PRs -> BOOLEAN]        \* some PRs open as drafts
    /\ release   = [p \in PRs |-> FALSE]
    /\ booking   = [p \in PRs |-> "none"]
    /\ berth     = [p \in PRs |-> FALSE]
    /\ stgDeployed = [p \in PRs |-> FALSE]
    /\ stgHealthy = [p \in PRs |-> FALSE]
    /\ hold      = [p \in PRs |-> FALSE]
    /\ prodAct   = [p \in PRs |-> FALSE]
    /\ prodDeployed = [p \in PRs |-> FALSE]
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
    /\ badPromote = FALSE
    /\ badVerdict = FALSE
    /\ emgWaited = FALSE

\* Open: still a candidate for the pipeline. A merged change is not, and
\* neither is one that settle.sh has marked complete.
Open(p)      == ~closed[p] /\ ~merged[p] /\ "complete" \notin life[p]
Active(p)    == life[p] \ {"complete"}      \* the lifecycle states that are not terminal
IsEmergency(p) == "emergency" \in class[p]
Holder       == {p \in PRs : berth[p]}

(***************************************************************************)
(* CLASS. labeller.yml:44-48 derives standard or normal from the diff on   *)
(* every push and never reads itil:emergency -- by design: the class is a  *)
(* derivation and the emergency is a declaration. A declared emergency     *)
(* that receives a push carries two classes, and preflight.sh:187 refuses  *)
(* that as an undefined class: "a person removes the class that is wrong.  *)
(* Not the pipeline." ClassGuard is that rule; ResolveClass the person.    *)
(***************************************************************************)
Label(p) ==
    /\ Open(p)
    /\ \E c \in {"standard", "normal"} :
         class' = [class EXCEPT ![p] = (@ \ {"standard", "normal"}) \cup {c}]
    /\ UNCHANGED <<life, draft, release, booking, berth, stgDeployed, stgHealthy, hold,
                   prodAct, prodDeployed, verdict, uat, healthy, closed, served,
                   merged, pir, cleaned, freeze, estateEmg, badClaim, badClass,
                   badPromote, badVerdict, emgWaited>>

\* A person declares an emergency (label-owners.tsv: itil:emergency, human).
DeclareEmergency(p) ==
    /\ Open(p) /\ ~IsEmergency(p)
    /\ class' = [class EXCEPT ![p] = @ \cup {"emergency"}]
    /\ UNCHANGED <<life, draft, release, booking, berth, stgDeployed, stgHealthy, hold,
                   prodAct, prodDeployed, verdict, uat, healthy, closed, served,
                   merged, pir, cleaned, freeze, estateEmg, badClaim, badClass,
                   badPromote, badVerdict, emgWaited>>

\* A person removes the derived class that is wrong (preflight.sh:190).
ResolveClass(p) ==
    /\ Open(p) /\ IsEmergency(p) /\ Cardinality(class[p]) > 1
    /\ class' = [class EXCEPT ![p] = {"emergency"}]
    /\ UNCHANGED <<life, draft, release, booking, berth, stgDeployed, stgHealthy, hold,
                   prodAct, prodDeployed, verdict, uat, healthy, closed, served,
                   merged, pir, cleaned, freeze, estateEmg, badClaim, badClass,
                   badPromote, badVerdict, emgWaited>>

\* gh pr ready -- the author's act, and the only thing that clears draft.
MarkReady(p) ==
    /\ Open(p) /\ draft[p]
    /\ draft' = [draft EXCEPT ![p] = FALSE]
    /\ UNCHANGED <<class, life, release, booking, berth, stgDeployed, stgHealthy, hold,
                   prodAct, prodDeployed, verdict, uat, healthy, closed, served,
                   merged, pir, cleaned, freeze, estateEmg, badClaim, badClass,
                   badPromote, badVerdict, emgWaited>>

\* A person adds release -- intent (README.org, Adding a label and removing it).
AddRelease(p) ==
    /\ Open(p) /\ ~release[p]
    /\ release' = [release EXCEPT ![p] = TRUE]
    /\ UNCHANGED <<class, life, draft, booking, berth, stgDeployed, stgHealthy, hold,
                   prodAct, prodDeployed, verdict, uat, healthy, closed, served,
                   merged, pir, cleaned, freeze, estateEmg, badClaim, badClass,
                   badPromote, badVerdict, emgWaited>>

(***************************************************************************)
(* change/watch.sh:37-38 -- consume the trigger FIRST, then record the ask. *)
(* Under LifecycleExclusive the ask is not re-recorded on a change that is *)
(* already scheduled; watch.sh:38 adds change:requested unconditionally,   *)
(* so the script implements LifecycleExclusive = FALSE here (#88).         *)
(***************************************************************************)
Watch(p) ==
    /\ Open(p) /\ release[p]
    /\ release' = [release EXCEPT ![p] = FALSE]
    /\ life'    = [life EXCEPT ![p] =
                     IF LifecycleExclusive /\ "scheduled" \in @ THEN @ ELSE @ \cup {"requested"}]
    /\ UNCHANGED <<class, draft, booking, berth, stgDeployed, stgHealthy, hold,
                   prodAct, prodDeployed, verdict, uat, healthy, closed, served,
                   merged, pir, cleaned, freeze, estateEmg, badClaim, badClass,
                   badPromote, badVerdict, emgWaited>>

\* A person adds change:requested directly (label-owners.tsv: human).
Request(p) ==
    /\ Open(p) /\ "requested" \notin life[p] /\ "scheduled" \notin life[p]
    /\ life' = [life EXCEPT ![p] = @ \cup {"requested"}]
    /\ UNCHANGED <<class, draft, release, booking, berth, stgDeployed, stgHealthy,
                   hold, prodAct, prodDeployed, verdict, uat, healthy, closed, served,
                   merged, pir, cleaned, freeze, estateEmg, badClaim, badClass,
                   badPromote, badVerdict, emgWaited>>

\* change/schedule.sh block:257 -- book a window, queued or --at.
Book(p) ==
    /\ Open(p) /\ "scheduled" \notin life[p]
    /\ \E b \in {"queued", "designated"} : booking' = [booking EXCEPT ![p] = b]
    /\ life' = [life EXCEPT ![p] =
                  IF LifecycleExclusive THEN (@ \ {"requested"}) \cup {"scheduled"}
                                        ELSE @ \cup {"scheduled"}]
    /\ UNCHANGED <<class, draft, release, berth, stgDeployed, stgHealthy, hold,
                   prodAct, prodDeployed, verdict, uat, healthy, closed, served,
                   merged, pir, cleaned, freeze, estateEmg, badClaim, badClass,
                   badPromote, badVerdict, emgWaited>>

\* change/schedule.sh cancel:303 -- a person un-books; still approved, unbooked.
Cancel(p) ==
    /\ ~closed[p] /\ "scheduled" \in life[p] /\ ~berth[p]
    /\ life'    = [life    EXCEPT ![p] = @ \ {"scheduled"}]
    /\ booking' = [booking EXCEPT ![p] = "none"]
    /\ UNCHANGED <<class, draft, release, berth, stgDeployed, stgHealthy, hold,
                   prodAct, prodDeployed, verdict, uat, healthy, closed, served,
                   merged, pir, cleaned, freeze, estateEmg, badClaim, badClass,
                   badPromote, badVerdict, emgWaited>>

(***************************************************************************)
(* change/reap.sh:74-78 -- the window lapsed. reap.sh:10-14 reads only the *)
(* window's end: it does not look at deploy:production (ReapSparesInFlight *)
(* = FALSE is the script) nor at MERGED (#90). Nothing is re-booked and    *)
(* nothing goes back to requested: asking is a person's act.               *)
(***************************************************************************)
Reap(p) ==
    /\ ~closed[p] /\ "scheduled" \in life[p]
    /\ (ReapSparesInFlight => ~prodAct[p])
    /\ life'    = [life    EXCEPT ![p] = @ \ {"scheduled"}]
    /\ booking' = [booking EXCEPT ![p] = "none"]
    /\ berth'   = [berth   EXCEPT ![p] = IF ReapFreesBerth THEN FALSE ELSE @]
    /\ stgDeployed' = [stgDeployed EXCEPT ![p] = IF ReapFreesBerth THEN FALSE ELSE @]
    /\ stgHealthy'  = [stgHealthy  EXCEPT ![p] = IF ReapFreesBerth THEN FALSE ELSE @]
    /\ UNCHANGED <<class, draft, release, hold, prodAct, prodDeployed, verdict, uat,
                   healthy, closed, served, merged, pir, cleaned, freeze, estateEmg,
                   badClaim, badClass, badPromote, badVerdict, emgWaited>>

(***************************************************************************)
(* gates/preflight.sh, then change/activate.sh:265-268 -- the window opens, *)
(* the guards are re-evaluated and the berth is claimed. Each rule here is *)
(* a preflight refusal; with its constant off the refusal is skipped and   *)
(* badClaim records that a claim was made which the rule would refuse.     *)
(* The class can change AFTER the claim (a person declares mid-flight), so *)
(* badClass is recorded at the claim too.                                  *)
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
    /\ UNCHANGED <<class, life, draft, release, booking, stgDeployed, stgHealthy, hold,
                   prodAct, prodDeployed, verdict, uat, healthy, closed, served,
                   merged, pir, cleaned, freeze, estateEmg, badPromote, badVerdict,
                   emgWaited>>

(***************************************************************************)
(* THE INSTALL AND ITS HEALTH. deploy:staging is the berth; staging:deployed *)
(* is the deployer saying the install finished; staging:healthy is guard 5's *)
(* instrument (gates/health.sh --pr --env staging) saying the environment    *)
(* serves THIS head. The next step keys on the OBSERVATION, not the action:  *)
(* "if <env>:healthy is present after <env>:deployed, trigger the next step".*)
(* HealthyBeforeVerdict: e2e and smoke measure staging only once             *)
(* staging:healthy is recorded -- a verdict on an environment not known to   *)
(* serve the head is a verdict about nothing.                                *)
(***************************************************************************)
DeployStaging(p) ==
    /\ Open(p) /\ berth[p] /\ ~stgDeployed[p]
    /\ stgDeployed' = [stgDeployed EXCEPT ![p] = TRUE]
    /\ UNCHANGED <<class, life, draft, release, booking, berth, stgHealthy, hold,
                   prodAct, prodDeployed, verdict, uat, healthy, closed, served,
                   merged, pir, cleaned, freeze, estateEmg, badClaim, badClass,
                   badPromote, badVerdict, emgWaited>>

StagingHealthy(p) ==
    /\ Open(p) /\ stgDeployed[p] /\ ~stgHealthy[p]
    /\ stgHealthy' = [stgHealthy EXCEPT ![p] = TRUE]
    /\ UNCHANGED <<class, life, draft, release, booking, berth, stgDeployed, hold,
                   prodAct, prodDeployed, verdict, uat, healthy, closed, served,
                   merged, pir, cleaned, freeze, estateEmg, badClaim, badClass,
                   badPromote, badVerdict, emgWaited>>

\* staging:hold -- a person says "not to production yet"; only a person lifts it.
Hold(p) ==
    /\ Open(p)
    /\ hold' = [hold EXCEPT ![p] = ~@]
    /\ UNCHANGED <<class, life, draft, release, booking, berth, stgDeployed,
                   stgHealthy, prodAct, prodDeployed, verdict, uat, healthy, closed,
                   served, merged, pir, cleaned, freeze, estateEmg, badClaim, badClass,
                   badPromote, badVerdict, emgWaited>>

\* gates/e2e.sh --pr and gates/smoke.sh --pr -- the instrument labels its own
\* result; a new verdict replaces the old (exclusion group staging-verdict).
Observe(p) ==
    /\ Open(p) /\ berth[p]
    /\ (HealthyBeforeVerdict => stgHealthy[p])
    /\ badVerdict' = (badVerdict \/ ~stgHealthy[p])
    /\ \E v \in {"pass", "fail"} : verdict' = [verdict EXCEPT ![p] = v]
    /\ UNCHANGED <<class, life, draft, release, booking, berth, stgDeployed,
                   stgHealthy, hold, prodAct, prodDeployed, uat, healthy, closed,
                   served, merged, pir, cleaned, freeze, estateEmg, badClaim, badClass,
                   badPromote, emgWaited>>

\* change/observe.sh:44 -- a person accepts staging; the person is the instrument.
Accept(p) ==
    /\ Open(p) /\ berth[p] /\ verdict[p] = "pass" /\ ~uat[p]
    /\ uat' = [uat EXCEPT ![p] = TRUE]
    /\ UNCHANGED <<class, life, draft, release, booking, berth, stgDeployed,
                   stgHealthy, hold, prodAct, prodDeployed, verdict, healthy, closed,
                   served, merged, pir, cleaned, freeze, estateEmg, badClaim, badClass,
                   badPromote, badVerdict, emgWaited>>

(***************************************************************************)
(* promote.yml -- staging:smoke (a passing verdict) lands deploy:production; *)
(* an approved emergency is the break-glass path. uat is recorded when a   *)
(* person accepts and is no longer in the path. A person's staging:hold    *)
(* stops this, at the moment of promoting (HoldGuard).                      *)
(***************************************************************************)
Promote(p) ==
    /\ Open(p) /\ berth[p] /\ ~prodAct[p]
    /\ \/ verdict[p] = "pass"
       \/ IsEmergency(p)
    /\ (HoldGuard => ~hold[p])
    /\ badPromote' = (badPromote \/ hold[p])
    /\ prodAct' = [prodAct EXCEPT ![p] = TRUE]
    /\ UNCHANGED <<class, life, draft, release, booking, berth, stgDeployed,
                   stgHealthy, hold, prodDeployed, verdict, uat, healthy, closed,
                   served, merged, pir, cleaned, freeze, estateEmg, badClaim, badClass,
                   badVerdict, emgWaited>>

DeployProduction(p) ==
    /\ Open(p) /\ prodAct[p] /\ ~prodDeployed[p]
    /\ prodDeployed' = [prodDeployed EXCEPT ![p] = TRUE]
    /\ UNCHANGED <<class, life, draft, release, booking, berth, stgDeployed,
                   stgHealthy, hold, prodAct, verdict, uat, healthy, closed, served,
                   merged, pir, cleaned, freeze, estateEmg, badClaim, badClass,
                   badPromote, badVerdict, emgWaited>>

\* gates/health.sh --pr --env production:99 -- guard 5 converged on this head.
Converge(p) ==
    /\ Open(p) /\ prodDeployed[p] /\ ~healthy[p]
    /\ healthy' = [healthy EXCEPT ![p] = TRUE]
    /\ served'  = [served  EXCEPT ![p] = TRUE]
    /\ UNCHANGED <<class, life, draft, release, booking, berth, stgDeployed,
                   stgHealthy, hold, prodAct, prodDeployed, verdict, uat, closed,
                   merged, pir, cleaned, freeze, estateEmg, badClaim, badClass,
                   badPromote, badVerdict, emgWaited>>

(***************************************************************************)
(* THE ESTATE CLOSES FOR AN EMERGENCY (README §5b). EstateGuard already     *)
(* blocks entry. Evict(e, h): a declared, booked, ready itil:emergency      *)
(* takes the berth from a non-emergency holder, who keeps nothing that was  *)
(* about the staging it is losing and is NOT closed. Without               *)
(* EmergencyPreempts the same situation is recorded by EmergencyWaits.      *)
(***************************************************************************)
EmergencyReady(e) ==
    /\ estateEmg /\ Open(e) /\ IsEmergency(e)
    /\ "scheduled" \in life[e] /\ ~draft[e] /\ ~berth[e]

Evict(e, h) ==
    /\ EmergencyPreempts
    /\ EmergencyReady(e) /\ e # h
    /\ berth[h] /\ ~IsEmergency(h) /\ ~prodAct[h]
    /\ berth'   = [berth   EXCEPT ![h] = FALSE]
    /\ stgDeployed' = [stgDeployed EXCEPT ![h] = FALSE]
    /\ stgHealthy'  = [stgHealthy  EXCEPT ![h] = FALSE]
    /\ life'    = [life    EXCEPT ![h] = @ \ {"scheduled"}]
    /\ booking' = [booking EXCEPT ![h] = "none"]
    /\ verdict' = [verdict EXCEPT ![h] = "none"]
    /\ uat'     = [uat     EXCEPT ![h] = FALSE]
    /\ UNCHANGED <<class, draft, release, hold, prodAct, prodDeployed, healthy, closed,
                   served, merged, pir, cleaned, freeze, estateEmg, badClaim, badClass,
                   badPromote, badVerdict, emgWaited>>

EmergencyWaits(e) ==
    /\ ~EmergencyPreempts
    /\ EmergencyReady(e)
    /\ \E h \in PRs : h # e /\ berth[h] /\ ~IsEmergency(h) /\ ~prodAct[h]
    /\ emgWaited' = TRUE
    /\ UNCHANGED <<class, life, draft, release, booking, berth, stgDeployed,
                   stgHealthy, hold, prodAct, prodDeployed, verdict, uat, healthy,
                   closed, served, merged, pir, cleaned, freeze, estateEmg, badClaim,
                   badClass, badPromote, badVerdict>>

(***************************************************************************)
(* SETTLEMENT is four writes in a stated order, and two paths reach the    *)
(* merge. merge-on-healthy.yml -> release.sh is the AUTOMATIC path: fires  *)
(* on production:healthy, merges, clears the action labels, records        *)
(* nothing (RecordOnMerge = FALSE is the tree). change/settle.sh is the    *)
(* RECORDING path: change:complete, merge if not merged, the PIR, cleanup. *)
(***************************************************************************)
MergeOnHealthy(p) ==
    /\ Open(p) /\ healthy[p] /\ ~merged[p]
    /\ merged'  = [merged  EXCEPT ![p] = TRUE]
    /\ berth'   = [berth   EXCEPT ![p] = FALSE]
    /\ prodAct' = [prodAct EXCEPT ![p] = FALSE]
    /\ healthy' = [healthy EXCEPT ![p] = FALSE]
    /\ stgDeployed'  = [stgDeployed  EXCEPT ![p] = FALSE]
    /\ stgHealthy'   = [stgHealthy   EXCEPT ![p] = FALSE]
    /\ prodDeployed' = [prodDeployed EXCEPT ![p] = FALSE]
    /\ IF RecordOnMerge
       THEN /\ life'    = [life    EXCEPT ![p] = {}]
            /\ pir'     = [pir     EXCEPT ![p] = TRUE]
            /\ cleaned' = [cleaned EXCEPT ![p] = TRUE]
            /\ release' = [release EXCEPT ![p] = FALSE]
            /\ verdict' = [verdict EXCEPT ![p] = "none"]
            /\ uat'     = [uat     EXCEPT ![p] = FALSE]
            /\ booking' = [booking EXCEPT ![p] = "none"]
            /\ hold'    = [hold    EXCEPT ![p] = FALSE]
       ELSE UNCHANGED <<life, pir, cleaned, release, verdict, uat, booking, hold>>
    /\ UNCHANGED <<class, draft, closed, served, freeze, estateEmg, badClaim, badClass,
                   badPromote, badVerdict, emgWaited>>

\* settle.sh:70 re-measures production against the head; :105 writes complete.
Complete(p) ==
    /\ ~closed[p] /\ served[p] /\ "complete" \notin life[p] /\ ~pir[p]
    /\ life' = [life EXCEPT ![p] = @ \cup {"complete"}]
    /\ UNCHANGED <<class, draft, release, booking, berth, stgDeployed, stgHealthy,
                   hold, prodAct, prodDeployed, verdict, uat, healthy, closed, served,
                   merged, pir, cleaned, freeze, estateEmg, badClaim, badClass,
                   badPromote, badVerdict, emgWaited>>

\* settle.sh:124-140 -- merge unless the forge already says MERGED.
SettleMerge(p) ==
    /\ "complete" \in life[p] /\ ~merged[p]
    /\ merged' = [merged EXCEPT ![p] = TRUE]
    /\ UNCHANGED <<class, life, draft, release, booking, berth, stgDeployed,
                   stgHealthy, hold, prodAct, prodDeployed, verdict, uat, healthy,
                   closed, served, pir, cleaned, freeze, estateEmg, badClaim, badClass,
                   badPromote, badVerdict, emgWaited>>

\* settle.sh:150-168 -- the PIR, posted while the labels are still there to read.
Pir(p) ==
    /\ "complete" \in life[p] /\ merged[p] /\ ~pir[p]
    /\ pir' = [pir EXCEPT ![p] = TRUE]
    /\ UNCHANGED <<class, life, draft, release, booking, berth, stgDeployed,
                   stgHealthy, hold, prodAct, prodDeployed, verdict, uat, healthy,
                   closed, served, merged, cleaned, freeze, estateEmg, badClaim,
                   badClass, badPromote, badVerdict, emgWaited>>

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
            /\ stgDeployed'  = [stgDeployed  EXCEPT ![p] = FALSE]
            /\ stgHealthy'   = [stgHealthy   EXCEPT ![p] = FALSE]
            /\ prodDeployed' = [prodDeployed EXCEPT ![p] = FALSE]
            /\ hold'    = [hold    EXCEPT ![p] = FALSE]
       ELSE UNCHANGED <<life, berth, prodAct, release, verdict, uat, healthy, booking,
                        stgDeployed, stgHealthy, prodDeployed, hold>>
    /\ UNCHANGED <<class, draft, closed, served, merged, pir, freeze, estateEmg,
                   badClaim, badClass, badPromote, badVerdict, emgWaited>>

\* change/abort.sh:95-114 -- the change did not make it. Not the eviction.
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
    /\ stgDeployed'  = [stgDeployed  EXCEPT ![p] = FALSE]
    /\ stgHealthy'   = [stgHealthy   EXCEPT ![p] = FALSE]
    /\ prodDeployed' = [prodDeployed EXCEPT ![p] = FALSE]
    /\ UNCHANGED <<class, draft, booking, hold, prodAct, merged, pir, cleaned, freeze,
                   estateEmg, badClaim, badClass, badPromote, badVerdict, emgWaited>>

\* labeller.yml:101 on synchronize -- a push withdraws every label about the
\* old head: observations, and the deployed/healthy facts too.
Push(p) ==
    /\ Open(p) /\ (verdict[p] # "none" \/ uat[p] \/ healthy[p]
                   \/ stgDeployed[p] \/ stgHealthy[p] \/ prodDeployed[p])
    /\ verdict' = [verdict EXCEPT ![p] = "none"]
    /\ uat'     = [uat     EXCEPT ![p] = FALSE]
    /\ healthy' = [healthy EXCEPT ![p] = FALSE]
    /\ served'  = [served  EXCEPT ![p] = FALSE]
    /\ stgDeployed'  = [stgDeployed  EXCEPT ![p] = FALSE]
    /\ stgHealthy'   = [stgHealthy   EXCEPT ![p] = FALSE]
    /\ prodDeployed' = [prodDeployed EXCEPT ![p] = FALSE]
    /\ UNCHANGED <<class, life, draft, release, booking, berth, hold, prodAct, closed,
                   merged, pir, cleaned, freeze, estateEmg, badClaim, badClass,
                   badPromote, badVerdict, emgWaited>>

\* The estate: a person toggles freeze and emergency on issue #1.
Freeze ==
    /\ freeze' = ~freeze
    /\ UNCHANGED <<class, life, draft, release, booking, berth, stgDeployed,
                   stgHealthy, hold, prodAct, prodDeployed, verdict, uat, healthy,
                   closed, served, merged, pir, cleaned, estateEmg, badClaim, badClass,
                   badPromote, badVerdict, emgWaited>>

Estate ==
    /\ estateEmg' = ~estateEmg
    /\ UNCHANGED <<class, life, draft, release, booking, berth, stgDeployed,
                   stgHealthy, hold, prodAct, prodDeployed, verdict, uat, healthy,
                   closed, served, merged, pir, cleaned, freeze, badClaim, badClass,
                   badPromote, badVerdict, emgWaited>>

Next ==
    \/ \E p \in PRs : Label(p) \/ DeclareEmergency(p) \/ ResolveClass(p) \/ MarkReady(p)
                   \/ AddRelease(p) \/ Watch(p) \/ Request(p) \/ Book(p)
                   \/ Cancel(p) \/ Reap(p) \/ Activate(p)
                   \/ DeployStaging(p) \/ StagingHealthy(p) \/ Hold(p) \/ Observe(p)
                   \/ Accept(p) \/ Promote(p) \/ DeployProduction(p) \/ Converge(p)
                   \/ MergeOnHealthy(p) \/ Complete(p) \/ SettleMerge(p)
                   \/ Pir(p) \/ Cleanup(p)
                   \/ Abort(p) \/ Push(p) \/ EmergencyWaits(p)
    \/ \E e, h \in PRs : Evict(e, h)
    \/ Freeze \/ Estate

Spec == Init /\ [][Next]_vars

(***************************************************************************)
(*                              INVARIANTS                                 *)
(* One per rule. tla/check.sh flips each constant and TLC must name the    *)
(* invariant below it; sim/cross_check.py requires label_sim.py to agree.  *)
(***************************************************************************)

\* preflight.sh:187: nothing claims the berth with an undefined class  [ClassGuard]
NoDeployWithTwoClasses == badClass = FALSE

\* exclusion group `lifecycle`: at most one ACTIVE change:*       [LifecycleExclusive]
OneLifecycle == \A p \in PRs : Cardinality(Active(p)) <= 1

\* a draft never holds the berth or reaches production            [DraftGuard]
NoDraftDeployed == \A p \in PRs : draft[p] => (~berth[p] /\ ~prodAct[p])

\* no reservation, no deployment          [WindowGuard, ReapFreesBerth, ReapSparesInFlight]
NoUnbookedDeploy == \A p \in PRs : (berth[p] \/ prodAct[p]) => booking[p] # "none"

\* a held berth has a live window behind it
BerthHasCause == \A p \in PRs : berth[p] => "scheduled" \in life[p]

\* a berth is held by at most one change                          [BerthGuard]
AtMostOneHolder == Cardinality(Holder) <= 1

\* no claim was made that a rule should have refused              [FreezeGuard, EstateGuard]
NoRefusedClaim == badClaim = FALSE

\* cleanup released everything transient, change:complete included [SettleClears]
CleanIsClean ==
    \A p \in PRs : cleaned[p] =>
        (life[p] = {} /\ ~berth[p] /\ ~prodAct[p] /\ ~release[p] /\ ~stgDeployed[p]
         /\ ~stgHealthy[p] /\ ~prodDeployed[p] /\ ~hold[p]
         /\ verdict[p] = "none" /\ ~uat[p] /\ ~healthy[p] /\ booking[p] = "none")

\* a merged change that has lost its last lifecycle label has its record [RecordOnMerge]
MergedHasRecord == \A p \in PRs : (merged[p] /\ life[p] = {}) => pir[p]

\* a declared, ready emergency is never kept out by a standard or normal holder [EmergencyPreempts]
EmergencyNeverWaits == emgWaited = FALSE

\* deploy:production never lands under a person's staging:hold   [HoldGuard]
NoPromoteUnderHold == badPromote = FALSE

\* no instrument records a staging verdict before staging:healthy [HealthyBeforeVerdict]
VerdictOnHealthy == badVerdict = FALSE

Safety ==
    /\ TypeOK /\ NoDeployWithTwoClasses /\ OneLifecycle /\ NoDraftDeployed
    /\ NoUnbookedDeploy /\ AtMostOneHolder /\ NoRefusedClaim /\ BerthHasCause
    /\ CleanIsClean /\ MergedHasRecord /\ EmergencyNeverWaits
    /\ NoPromoteUnderHold /\ VerdictOnHealthy
=============================================================================
