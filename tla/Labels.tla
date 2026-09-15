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
(* Fifteen CONSTANTS, one per rule, so the model can FAIL fifteen ways.    *)
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
          \* --- the fifteen rules, each switchable so its invariant can fail ---
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
          HealthyBeforeVerdict,\* an instrument measures staging only once staging:healthy is recorded
          LockResets,        \* refused at the lock: every marker goes, human intent included; the person re-states it
          MergeIsTheTombstone\* a MERGED change does not keep change:end -- the forge's MERGED is the record (the owner, 2026-09-15)

Classes   == {"standard", "normal", "emergency"}
Lifecycle == {"requested", "scheduled", "complete", "abandoned", "superseded"}
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
    cleaned,      \* cleaned[p]: the change:end LABEL is present on the PR
    tidied,       \* tidied[p]: the cleanup RAN and cleared every other label (settle.sh:244-252)
                  \* Split from `cleaned` 2026-09-15. They were one variable, which made
                  \* "the tidying happened" and "the tombstone is showing" inseparable --
                  \* so removing the label from a merged change would have made
                  \* CleanIsClean vacuous rather than making it say less.
    freeze,       \* ESTATE: the freeze label on the estate issue
    estateEmg,    \* ESTATE: the emergency label on the estate issue
    badClaim,     \* history: a claim that a rule should have refused was made
    badClass,     \* history: a berth was claimed with an undefined class
    badPromote,   \* history: deploy:production landed under a staging:hold
    badVerdict,   \* history: an instrument recorded a staging verdict before staging:healthy
    emgWaited,    \* history: a declared, ready emergency was kept out of staging by a holder
    refusedDirty  \* history: a change refused at the lock kept a marker

vars == <<class, life, draft, release, booking, berth, stgDeployed, stgHealthy, hold,
          prodAct, prodDeployed, verdict, uat, healthy, closed, served, merged, pir,
          cleaned, tidied, freeze, estateEmg, badClaim, badClass, badPromote, badVerdict, emgWaited,
          refusedDirty>>

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
    /\ tidied    \in [PRs -> BOOLEAN]
    /\ freeze    \in BOOLEAN
    /\ estateEmg \in BOOLEAN
    /\ badClaim  \in BOOLEAN
    /\ badClass  \in BOOLEAN
    /\ badPromote \in BOOLEAN
    /\ badVerdict \in BOOLEAN
    /\ emgWaited \in BOOLEAN
    /\ refusedDirty \in BOOLEAN

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
    /\ tidied    = [p \in PRs |-> FALSE]
    /\ freeze    = FALSE
    /\ estateEmg = FALSE
    /\ badClaim  = FALSE
    /\ badClass  = FALSE
    /\ badPromote = FALSE
    /\ badVerdict = FALSE
    /\ emgWaited = FALSE
    /\ refusedDirty = FALSE

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
                   merged, pir, cleaned, tidied, freeze, estateEmg, badClaim, badClass,
                   badPromote, badVerdict, emgWaited, refusedDirty>>

\* A person declares an emergency (label-owners.tsv: itil:emergency, human).
DeclareEmergency(p) ==
    /\ Open(p) /\ ~IsEmergency(p)
    /\ class' = [class EXCEPT ![p] = @ \cup {"emergency"}]
    /\ UNCHANGED <<life, draft, release, booking, berth, stgDeployed, stgHealthy, hold,
                   prodAct, prodDeployed, verdict, uat, healthy, closed, served,
                   merged, pir, cleaned, tidied, freeze, estateEmg, badClaim, badClass,
                   badPromote, badVerdict, emgWaited, refusedDirty>>

\* A person removes the derived class that is wrong (preflight.sh:190).
ResolveClass(p) ==
    /\ Open(p) /\ IsEmergency(p) /\ Cardinality(class[p]) > 1
    /\ class' = [class EXCEPT ![p] = {"emergency"}]
    /\ UNCHANGED <<life, draft, release, booking, berth, stgDeployed, stgHealthy, hold,
                   prodAct, prodDeployed, verdict, uat, healthy, closed, served,
                   merged, pir, cleaned, tidied, freeze, estateEmg, badClaim, badClass,
                   badPromote, badVerdict, emgWaited, refusedDirty>>

\* gh pr ready -- the author's act, and the only thing that clears draft.
MarkReady(p) ==
    /\ Open(p) /\ draft[p]
    /\ draft' = [draft EXCEPT ![p] = FALSE]
    /\ UNCHANGED <<class, life, release, booking, berth, stgDeployed, stgHealthy, hold,
                   prodAct, prodDeployed, verdict, uat, healthy, closed, served,
                   merged, pir, cleaned, tidied, freeze, estateEmg, badClaim, badClass,
                   badPromote, badVerdict, emgWaited, refusedDirty>>

\* A person adds release -- intent (README.org, Adding a label and removing it).
AddRelease(p) ==
    /\ Open(p) /\ ~release[p]
    /\ release' = [release EXCEPT ![p] = TRUE]
    /\ UNCHANGED <<class, life, draft, booking, berth, stgDeployed, stgHealthy, hold,
                   prodAct, prodDeployed, verdict, uat, healthy, closed, served,
                   merged, pir, cleaned, tidied, freeze, estateEmg, badClaim, badClass,
                   badPromote, badVerdict, emgWaited, refusedDirty>>

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
                   merged, pir, cleaned, tidied, freeze, estateEmg, badClaim, badClass,
                   badPromote, badVerdict, emgWaited, refusedDirty>>

\* A person adds change:requested directly (label-owners.tsv: human).
Request(p) ==
    /\ Open(p) /\ "requested" \notin life[p] /\ "scheduled" \notin life[p]
    /\ life' = [life EXCEPT ![p] = @ \cup {"requested"}]
    /\ UNCHANGED <<class, draft, release, booking, berth, stgDeployed, stgHealthy,
                   hold, prodAct, prodDeployed, verdict, uat, healthy, closed, served,
                   merged, pir, cleaned, tidied, freeze, estateEmg, badClaim, badClass,
                   badPromote, badVerdict, emgWaited, refusedDirty>>

\* change/schedule.sh block:257 -- book a window, queued or --at.
Book(p) ==
    /\ Open(p) /\ "scheduled" \notin life[p]
    /\ \E b \in {"queued", "designated"} : booking' = [booking EXCEPT ![p] = b]
    /\ life' = [life EXCEPT ![p] =
                  IF LifecycleExclusive THEN (@ \ {"requested"}) \cup {"scheduled"}
                                        ELSE @ \cup {"scheduled"}]
    /\ UNCHANGED <<class, draft, release, berth, stgDeployed, stgHealthy, hold,
                   prodAct, prodDeployed, verdict, uat, healthy, closed, served,
                   merged, pir, cleaned, tidied, freeze, estateEmg, badClaim, badClass,
                   badPromote, badVerdict, emgWaited, refusedDirty>>

\* change/schedule.sh cancel:303 -- a person un-books; still approved, unbooked.
Cancel(p) ==
    /\ ~closed[p] /\ "scheduled" \in life[p] /\ ~berth[p]
    /\ life'    = [life    EXCEPT ![p] = @ \ {"scheduled"}]
    /\ booking' = [booking EXCEPT ![p] = "none"]
    /\ UNCHANGED <<class, draft, release, berth, stgDeployed, stgHealthy, hold,
                   prodAct, prodDeployed, verdict, uat, healthy, closed, served,
                   merged, pir, cleaned, tidied, freeze, estateEmg, badClaim, badClass,
                   badPromote, badVerdict, emgWaited, refusedDirty>>

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
                   healthy, closed, served, merged, pir, cleaned, tidied, freeze, estateEmg,
                   badClaim, badClass, badPromote, badVerdict, emgWaited, refusedDirty>>

(***************************************************************************)
(* gates/preflight.sh, then change/activate.sh:271-275 -- the window opens,*)
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
                   merged, pir, cleaned, tidied, freeze, estateEmg, badPromote, badVerdict,
                   emgWaited, refusedDirty>>

(***************************************************************************)
(* THE LOCK. deploy:staging IS the environment lock (the owner, 2026-09-14). *)
(* A change that asks for staging while another holds it is not queued and  *)
(* not annotated: change/queue.sh clears EVERY marker it carries -- the     *)
(* window, the lifecycle, the observations, and the human intent            *)
(* (change:start / change:requested / release / staging:hold) -- and says   *)
(* who holds the lock. The person re-states the intent when the lock is     *)
(* free. "Since I have to": a refusal that leaves a queue label behind is a  *)
(* print statement that later reads as a claim.                             *)
(***************************************************************************)
Markers(p) ==
    \/ life[p] # {} \/ booking[p] # "none" \/ release[p] \/ hold[p]
    \/ verdict[p] # "none" \/ uat[p] \/ stgDeployed[p] \/ stgHealthy[p]

LockRefusal(p) ==
    /\ Open(p) /\ ~berth[p] /\ "scheduled" \in life[p] /\ ~draft[p]
    /\ (Holder \ {p}) # {}
    /\ IF LockResets
       THEN /\ life'    = [life    EXCEPT ![p] = {}]
            /\ booking' = [booking EXCEPT ![p] = "none"]
            /\ release' = [release EXCEPT ![p] = FALSE]
            /\ hold'    = [hold    EXCEPT ![p] = FALSE]
            /\ verdict' = [verdict EXCEPT ![p] = "none"]
            /\ uat'     = [uat     EXCEPT ![p] = FALSE]
            /\ stgDeployed' = [stgDeployed EXCEPT ![p] = FALSE]
            /\ stgHealthy'  = [stgHealthy  EXCEPT ![p] = FALSE]
            /\ refusedDirty' = refusedDirty
       ELSE /\ UNCHANGED <<life, booking, release, hold, verdict, uat, stgDeployed, stgHealthy>>
            /\ refusedDirty' = (refusedDirty \/ Markers(p))
    /\ UNCHANGED <<class, draft, berth, prodAct, prodDeployed, healthy, closed, served,
                   merged, pir, cleaned, tidied, freeze, estateEmg, badClaim, badClass,
                   badPromote, badVerdict, emgWaited>>

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
                   merged, pir, cleaned, tidied, freeze, estateEmg, badClaim, badClass,
                   badPromote, badVerdict, emgWaited, refusedDirty>>

StagingHealthy(p) ==
    /\ Open(p) /\ stgDeployed[p] /\ ~stgHealthy[p]
    /\ stgHealthy' = [stgHealthy EXCEPT ![p] = TRUE]
    /\ UNCHANGED <<class, life, draft, release, booking, berth, stgDeployed, hold,
                   prodAct, prodDeployed, verdict, uat, healthy, closed, served,
                   merged, pir, cleaned, tidied, freeze, estateEmg, badClaim, badClass,
                   badPromote, badVerdict, emgWaited, refusedDirty>>

\* staging:hold -- a person says "not to production yet"; only a person lifts it.
Hold(p) ==
    /\ Open(p)
    /\ hold' = [hold EXCEPT ![p] = ~@]
    /\ UNCHANGED <<class, life, draft, release, booking, berth, stgDeployed,
                   stgHealthy, prodAct, prodDeployed, verdict, uat, healthy, closed,
                   served, merged, pir, cleaned, tidied, freeze, estateEmg, badClaim, badClass,
                   badPromote, badVerdict, emgWaited, refusedDirty>>

\* gates/e2e.sh --pr and gates/smoke.sh --pr -- the instrument labels its own
\* result; a new verdict replaces the old (exclusion group staging-verdict).
Observe(p) ==
    /\ Open(p) /\ berth[p]
    /\ (HealthyBeforeVerdict => stgHealthy[p])
    /\ badVerdict' = (badVerdict \/ ~stgHealthy[p])
    /\ \E v \in {"pass", "fail"} : verdict' = [verdict EXCEPT ![p] = v]
    /\ UNCHANGED <<class, life, draft, release, booking, berth, stgDeployed,
                   stgHealthy, hold, prodAct, prodDeployed, uat, healthy, closed,
                   served, merged, pir, cleaned, tidied, freeze, estateEmg, badClaim, badClass,
                   badPromote, emgWaited, refusedDirty>>

\* change/observe.sh:44 -- a person accepts staging; the person is the instrument.
Accept(p) ==
    /\ Open(p) /\ berth[p] /\ verdict[p] = "pass" /\ ~uat[p]
    /\ uat' = [uat EXCEPT ![p] = TRUE]
    /\ UNCHANGED <<class, life, draft, release, booking, berth, stgDeployed,
                   stgHealthy, hold, prodAct, prodDeployed, verdict, healthy, closed,
                   served, merged, pir, cleaned, tidied, freeze, estateEmg, badClaim, badClass,
                   badPromote, badVerdict, emgWaited, refusedDirty>>

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
                   served, merged, pir, cleaned, tidied, freeze, estateEmg, badClaim, badClass,
                   badVerdict, emgWaited, refusedDirty>>

DeployProduction(p) ==
    /\ Open(p) /\ prodAct[p] /\ ~prodDeployed[p]
    /\ prodDeployed' = [prodDeployed EXCEPT ![p] = TRUE]
    /\ UNCHANGED <<class, life, draft, release, booking, berth, stgDeployed,
                   stgHealthy, hold, prodAct, verdict, uat, healthy, closed, served,
                   merged, pir, cleaned, tidied, freeze, estateEmg, badClaim, badClass,
                   badPromote, badVerdict, emgWaited, refusedDirty>>

\* gates/health.sh --pr --env production:99 -- guard 5 converged on this head.
Converge(p) ==
    /\ Open(p) /\ prodDeployed[p] /\ ~healthy[p]
    /\ healthy' = [healthy EXCEPT ![p] = TRUE]
    /\ served'  = [served  EXCEPT ![p] = TRUE]
    /\ UNCHANGED <<class, life, draft, release, booking, berth, stgDeployed,
                   stgHealthy, hold, prodAct, prodDeployed, verdict, uat, closed,
                   merged, pir, cleaned, tidied, freeze, estateEmg, badClaim, badClass,
                   badPromote, badVerdict, emgWaited, refusedDirty>>

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
                   served, merged, pir, cleaned, tidied, freeze, estateEmg, badClaim, badClass,
                   badPromote, badVerdict, emgWaited, refusedDirty>>

EmergencyWaits(e) ==
    /\ ~EmergencyPreempts
    /\ EmergencyReady(e)
    /\ \E h \in PRs : h # e /\ berth[h] /\ ~IsEmergency(h) /\ ~prodAct[h]
    /\ emgWaited' = TRUE
    /\ UNCHANGED <<class, life, draft, release, booking, berth, stgDeployed,
                   stgHealthy, hold, prodAct, prodDeployed, verdict, uat, healthy,
                   closed, served, merged, pir, cleaned, tidied, freeze, estateEmg, badClaim,
                   badClass, badPromote, badVerdict, refusedDirty>>

(***************************************************************************)
(* SETTLEMENT is four writes in a stated order, and two paths reach the    *)
(* merge. merge-on-healthy.yml -> release.sh is the AUTOMATIC path: fires  *)
(* on production:healthy, merges, clears the action labels, records        *)
(* nothing (RecordOnMerge = FALSE is the tree). change/settle.sh is the    *)
(* RECORDING path: change:complete, merge if not merged, the PIR, cleanup. *)
(*                                                                         *)
(* THE TWO TERMINAL WORDS (the owner, 2026-09-14). change:complete is the  *)
(* pipeline's OUTCOME and it drives the side effects: the merge to main,   *)
(* the PIR, and whatever else must hear that the change shipped (a ticket, *)
(* a message). change:end is the tombstone the cleanup writes when it has  *)
(* cleared every other label: it drives nothing, it only says the clearing *)
(* was settlement and not a refusal or a reaper. `cleaned` below IS        *)
(* change:end, and CleanIsClean is its invariant. A person writes neither; *)
(* the person's words are change:start and staging:hold.                   *)
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
            \* THE TOMBSTONE IS NOT WRITTEN ON THE MERGE PATH [MergeIsTheTombstone].
            \* settle.sh clears change:complete with the argument that once the
            \* forge records MERGED the label "restates a fact the platform owns,
            \* and two records of one fact can disagree while the platform's
            \* cannot" -- and then wrote change:end, which is that same
            \* restatement. #52 proved the label can drift: it carried change:end
            \* through an entire successful deploy while still open. mergedAt
            \* cannot drift. (the owner, 2026-09-15)
            /\ tidied'  = [tidied  EXCEPT ![p] = TRUE]
            /\ cleaned' = [cleaned EXCEPT ![p] = ~MergeIsTheTombstone]
            /\ release' = [release EXCEPT ![p] = FALSE]
            /\ verdict' = [verdict EXCEPT ![p] = "none"]
            /\ uat'     = [uat     EXCEPT ![p] = FALSE]
            /\ booking' = [booking EXCEPT ![p] = "none"]
            /\ hold'    = [hold    EXCEPT ![p] = FALSE]
       ELSE UNCHANGED <<life, pir, cleaned, tidied, release, verdict, uat, booking, hold>>
    /\ UNCHANGED <<class, draft, closed, served, freeze, estateEmg, badClaim, badClass,
                   badPromote, badVerdict, emgWaited, refusedDirty>>

\* settle.sh:70 re-measures production against the head; :105 writes complete.
Complete(p) ==
    /\ ~closed[p] /\ served[p] /\ "complete" \notin life[p] /\ ~pir[p]
    /\ life' = [life EXCEPT ![p] = @ \cup {"complete"}]
    /\ UNCHANGED <<class, draft, release, booking, berth, stgDeployed, stgHealthy,
                   hold, prodAct, prodDeployed, verdict, uat, healthy, closed, served,
                   merged, pir, cleaned, tidied, freeze, estateEmg, badClaim, badClass,
                   badPromote, badVerdict, emgWaited, refusedDirty>>

\* settle.sh:124-140 -- merge unless the forge already says MERGED.
SettleMerge(p) ==
    /\ "complete" \in life[p] /\ ~merged[p]
    /\ merged' = [merged EXCEPT ![p] = TRUE]
    /\ UNCHANGED <<class, life, draft, release, booking, berth, stgDeployed,
                   stgHealthy, hold, prodAct, prodDeployed, verdict, uat, healthy,
                   closed, served, pir, cleaned, tidied, freeze, estateEmg, badClaim, badClass,
                   badPromote, badVerdict, emgWaited, refusedDirty>>

\* settle.sh:150-168 -- the PIR, posted while the labels are still there to read.
Pir(p) ==
    /\ "complete" \in life[p] /\ merged[p] /\ ~pir[p]
    /\ pir' = [pir EXCEPT ![p] = TRUE]
    /\ UNCHANGED <<class, life, draft, release, booking, berth, stgDeployed,
                   stgHealthy, hold, prodAct, prodDeployed, verdict, uat, healthy,
                   closed, served, merged, cleaned, tidied, freeze, estateEmg, badClaim,
                   badClass, badPromote, badVerdict, emgWaited, refusedDirty>>

\* settle.sh:244-252 -- cleanup. Every transient label, change:complete included.
Cleanup(p) ==
    \* Guarded on `tidied`, not on `cleaned`. They were one variable; once the
    \* merge path stops leaving change:end, "the tombstone is showing" can no
    \* longer stand in for "the cleanup has run" or this action re-fires forever.
    /\ pir[p] /\ ~tidied[p]
    /\ tidied'  = [tidied  EXCEPT ![p] = TRUE]
    /\ cleaned' = [cleaned EXCEPT ![p] = ~MergeIsTheTombstone]
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
                   badClaim, badClass, badPromote, badVerdict, emgWaited, refusedDirty>>

\* change/abort.sh:95-114 -- the change did not make it. Not the eviction.
Abort(p) ==
    \* "the release, even if it fails on staging, should end and clean up":
    \* the closure code, then every marker gone, then the tombstone (cleaned).
    /\ Open(p) /\ ("scheduled" \in life[p] \/ berth[p])
    \* The tombstone STAYS here. An aborted change has no mergedAt, so nothing
    \* else distinguishes settlement from a refusal at the lock, the reaper, or
    \* an eviction -- all of which also leave a change with no labels. This is
    \* the case change:end was invented for, and the only one it still serves.
    /\ closed'  = [closed  EXCEPT ![p] = TRUE]
    /\ tidied'  = [tidied  EXCEPT ![p] = TRUE]
    /\ cleaned' = [cleaned EXCEPT ![p] = TRUE]
    /\ life'    = [life    EXCEPT ![p] = {}]
    /\ booking' = [booking EXCEPT ![p] = "none"]
    /\ berth'   = [berth   EXCEPT ![p] = FALSE]
    /\ prodAct' = [prodAct EXCEPT ![p] = FALSE]
    /\ hold'    = [hold    EXCEPT ![p] = FALSE]
    /\ release' = [release EXCEPT ![p] = FALSE]
    /\ verdict' = [verdict EXCEPT ![p] = "none"]
    /\ uat'     = [uat     EXCEPT ![p] = FALSE]
    /\ healthy' = [healthy EXCEPT ![p] = FALSE]
    /\ served'  = [served  EXCEPT ![p] = FALSE]
    /\ stgDeployed'  = [stgDeployed  EXCEPT ![p] = FALSE]
    /\ stgHealthy'   = [stgHealthy   EXCEPT ![p] = FALSE]
    /\ prodDeployed' = [prodDeployed EXCEPT ![p] = FALSE]
    /\ UNCHANGED <<class, draft, merged, pir, freeze, estateEmg, badClaim, badClass,
                   badPromote, badVerdict, emgWaited, refusedDirty>>

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
                   merged, pir, cleaned, tidied, freeze, estateEmg, badClaim, badClass,
                   badPromote, badVerdict, emgWaited, refusedDirty>>

\* The estate: a person toggles freeze and emergency on issue #1.
Freeze ==
    /\ freeze' = ~freeze
    /\ UNCHANGED <<class, life, draft, release, booking, berth, stgDeployed,
                   stgHealthy, hold, prodAct, prodDeployed, verdict, uat, healthy,
                   closed, served, merged, pir, cleaned, tidied, estateEmg, badClaim, badClass,
                   badPromote, badVerdict, emgWaited, refusedDirty>>

Estate ==
    /\ estateEmg' = ~estateEmg
    /\ UNCHANGED <<class, life, draft, release, booking, berth, stgDeployed,
                   stgHealthy, hold, prodAct, prodDeployed, verdict, uat, healthy,
                   closed, served, merged, pir, cleaned, tidied, freeze, badClaim, badClass,
                   badPromote, badVerdict, emgWaited, refusedDirty>>

Next ==
    \/ \E p \in PRs : Label(p) \/ DeclareEmergency(p) \/ ResolveClass(p) \/ MarkReady(p)
                   \/ AddRelease(p) \/ Watch(p) \/ Request(p) \/ Book(p)
                   \/ Cancel(p) \/ Reap(p) \/ Activate(p) \/ LockRefusal(p)
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
\* CleanIsClean is stated over `tidied` (the cleanup RAN), not over `cleaned`
\* (the change:end label is showing). It used to be one variable, and if it had
\* stayed one, removing the label from the merge path would have emptied this
\* invariant instead of narrowing it -- a check that cannot fail, which is the
\* defect this file exists to avoid. Over `tidied` it still binds every path.
CleanIsClean ==
    \A p \in PRs : tidied[p] =>
        (life[p] = {} /\ ~berth[p] /\ ~prodAct[p] /\ ~release[p] /\ ~stgDeployed[p]
         /\ ~stgHealthy[p] /\ ~prodDeployed[p] /\ ~hold[p]
         /\ verdict[p] = "none" /\ ~uat[p] /\ ~healthy[p] /\ booking[p] = "none")

\* a merged change that has lost its last lifecycle label has its record [RecordOnMerge]
MergedHasRecord == \A p \in PRs : (merged[p] /\ life[p] = {}) => pir[p]

\* ONCE THE CLEANUP HAS RUN, A MERGED CHANGE DOES NOT STILL CARRY change:end.
\* [MergeIsTheTombstone]   (the owner, 2026-09-15: "it's merged, i know the
\* change, if needed, has ended")
\*
\* Stated after the cleanup rather than as "never both", because the merge and
\* the cleanup are two discrete actions and the window between them is real --
\* the change IS merged and not yet tidied. What must not survive is the
\* tombstone sitting on a change the forge already records as MERGED, where it
\* restates a fact the platform owns and can disagree with it (#52 did).
\*
\* The abort path is deliberately untouched: an aborted change has no mergedAt,
\* so change:end is the only thing separating settlement from a refusal at the
\* lock, the reaper, or an eviction. This invariant does not reach it.
NoTombstoneOnMerged ==
    \A p \in PRs : (merged[p] /\ tidied[p]) => ~cleaned[p]

\* a declared, ready emergency is never kept out by a standard or normal holder [EmergencyPreempts]
EmergencyNeverWaits == emgWaited = FALSE

\* deploy:production never lands under a person's staging:hold   [HoldGuard]
NoPromoteUnderHold == badPromote = FALSE

\* no instrument records a staging verdict before staging:healthy [HealthyBeforeVerdict]
VerdictOnHealthy == badVerdict = FALSE

\* a change refused at the lock carries no marker afterwards        [LockResets]
LockRefusalResets == refusedDirty = FALSE

Safety ==
    /\ TypeOK /\ NoDeployWithTwoClasses /\ OneLifecycle /\ NoDraftDeployed
    /\ NoUnbookedDeploy /\ AtMostOneHolder /\ NoRefusedClaim /\ BerthHasCause
    /\ CleanIsClean /\ MergedHasRecord /\ EmergencyNeverWaits
    /\ NoPromoteUnderHold /\ VerdictOnHealthy /\ LockRefusalResets
=============================================================================
