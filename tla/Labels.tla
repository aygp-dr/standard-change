-------------------------------- MODULE Labels --------------------------------
(***************************************************************************)
(* THE LABEL NAMESPACE, as change/label-owners.tsv declares it.             *)
(*                                                                         *)
(* StandardChange.tla and Concurrent.tla model the EVIDENCE side of this    *)
(* pipeline -- staging passes, divergence classes, berths, the merge -- and *)
(* they model it well. What neither can express is the thing the namespace  *)
(* split of 2026-09-13 was about:                                           *)
(*                                                                          *)
(*   1. Three INDEPENDENT axes. Both existing specs carry one boolean named  *)
(*      `emergency`, used as a break-glass bypass. There is no class axis,   *)
(*      no lifecycle, no scope, and so no way to state "a PR carries two     *)
(*      classes" -- which is what #2 actually did.                           *)
(*   2. The ESTATE. `freeze`, and "an emergency is in flight", are not       *)
(*      properties of a change at all. Neither spec has a variable that is   *)
(*      not indexed by PR, so neither can say the estate is closed.          *)
(*   3. control-plane, and the soak. A change that alters how every future   *)
(*      change is verified is not proven by its own merge                    *)
(*      (docs/changing-the-pipeline.org), and `merged` in both specs is      *)
(*      terminal.                                                            *)
(*                                                                          *)
(* That gap is why the emergency question could not be settled from the      *)
(* model. This module closes it, and the constants below are switchable so   *)
(* that it can FAIL -- tla/check.sh runs every one of them in both           *)
(* directions. A model that can only pass proves nothing.                    *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS
    PRs,
    MaxMerges,
    \* Is "an emergency is in flight" a label of its own, or is it read off
    \* the itil:* CLASSIFICATION? FALSE is the repository as it stands.
    \* sim/label_sim.py --question emergency finds the deciding state.
    SeparateEmergency,
    \* Does preflight refuse a change carrying NO class? Today the exclusion
    \* group's cardinality is `<=1`, which permits zero, and every rule in
    \* preflight branches on the class.
    ClassRequired,
    \* Does a lifecycle transition REPLACE the previous state? Today
    \* change:requested is never cleared until settle.sh's final cleanup, so
    \* the states accumulate and the group says "<=1 active".
    LifecycleReplaces,
    \* Is a control-plane change counted proven by its own merge?
    Soak,
    \* Guard 1. Present at two sites -- preflight and change/queue.sh.
    BerthMutex,
    \* ADR 0001 S8: a freeze or an emergency in flight stops ordinary change.
    EstateBlocks,
    \* Is the `class` exclusion group ENFORCED, or merely declared? Today
    \* nothing reconciles the labeller's derived itil:standard with a person's
    \* itil:emergency, so a PR carries both -- #2 did. preflight REFUSES such a
    \* PR, which is a mitigation and not enforcement: the declared cardinality
    \* is still violated, and the TSV's own "who resolves" column says a person.
    ClassExclusive,
    \* Does preflight refuse a two-class change? That refusal is what keeps the
    \* unenforced cardinality from changing any verdict.
    ClassConflictRefused,
    \* Is an emergency exempt from the BERTH check too, or only from the checks
    \* that run after it? preflight checks the berth first and exempts nobody
    \* there, which is what produces the mutual block below.
    EmergencyPreempts

Classes   == {"S", "N", "E"}        \* itil:standard | :normal | :emergency
Lifecycle == {"R", "C", "X"}        \* change:requested | :scheduled | :complete
Scopes    == {"app", "cp", "inert"} \* app:* | control-plane | neither

VARIABLES
    cls,       \* cls[p]   : the CLASS axis. A SET, because nothing enforces
               \*            the cardinality: the labeller derives S or N from
               \*            the diff and a person declares E, and the two
               \*            writers never meet. #2 carried two at once.
    life,      \* life[p]  : the LIFECYCLE axis. Also a set, same reason.
    scope,     \* scope[p] : the SCOPE axis. Derived from the diff, fixed.
    verified,  \* verified[p] : the authorization stack is green on this head.
               \*            Collapsed on purpose -- StandardChange.tla and
               \*            Concurrent.tla model the stack properly and this
               \*            module is about the namespace, not the evidence.
    berth,     \* berth[p] : deploy:staging, the berth claim guard 1 reads
    inprod,    \* inprod[p]: production has CONVERGED on this build
    emgest,    \* emgest[p]: a bare `emergency` label -- the ESTATE fact.
               \*            With SeparateEmergency = FALSE it has no existence
               \*            of its own: the act that writes it is the act that
               \*            writes "E" into cls.
    merged,
    frozen,    \* THE ESTATE. Not indexed by PR, which is the whole point: a
               \* freeze is a fact about the world a change would deploy into.
    mainV,
    \* History variables. Several of these properties are about the ORDER
    \* things happened in and a state alone cannot say that -- the same device
    \* as `regressed` in StandardChange.tla.
    bypassed,      \* an ordinary change moved while the estate was closed
    selfGranted,   \* one write closed the estate AND exempted its own carrier
    unclassified,  \* something reached production carrying no class at all
    twoClassMoved  \* a PR with an UNDEFINED class moved anyway

vars == <<cls, life, scope, verified, berth, inprod, emgest, merged,
          frozen, mainV, bypassed, selfGranted, unclassified,
          twoClassMoved>>

TypeOK ==
    /\ cls          \in [PRs -> SUBSET Classes]
    /\ life         \in [PRs -> SUBSET Lifecycle]
    /\ scope        \in [PRs -> Scopes]
    /\ verified     \in [PRs -> BOOLEAN]
    /\ berth        \in [PRs -> BOOLEAN]
    /\ inprod       \in [PRs -> BOOLEAN]
    /\ emgest       \in [PRs -> BOOLEAN]
    /\ merged       \in [PRs -> BOOLEAN]
    /\ frozen       \in BOOLEAN
    /\ mainV        \in 0..MaxMerges
    /\ bypassed     \in BOOLEAN
    /\ selfGranted  \in BOOLEAN
    /\ unclassified \in BOOLEAN
    /\ twoClassMoved \in BOOLEAN

Init ==
    /\ cls          = [p \in PRs |-> {}]
    /\ life         = [p \in PRs |-> {}]
    \* nondeterministic, so every mix of what-the-diff-touched is covered
    /\ scope        \in [PRs -> Scopes]
    /\ verified     = [p \in PRs |-> FALSE]
    /\ berth        = [p \in PRs |-> FALSE]
    /\ inprod       = [p \in PRs |-> FALSE]
    /\ emgest       = [p \in PRs |-> FALSE]
    /\ merged       = [p \in PRs |-> FALSE]
    /\ frozen       = FALSE
    /\ mainV        = 0
    /\ bypassed     = FALSE
    /\ selfGranted  = FALSE
    /\ unclassified = FALSE
    /\ twoClassMoved = FALSE

Live(p) == ~merged[p]

(***************************************************************************)
(* THE ESTATE. Two causes, and preflight's comment says they are ONE RULE.  *)
(*                                                                          *)
(* EstateEmergency is the whole question in one operator. With               *)
(* SeparateEmergency it is read off a label that says only "the estate is    *)
(* moving"; without it, off a CLASSIFICATION of some change.                 *)
(***************************************************************************)
DeclaresEmergency(q) ==
    IF SeparateEmergency THEN emgest[q] ELSE "E" \in cls[q]

EstateEmergencyFor(p) ==
    \E q \in PRs : q # p /\ Live(q) /\ DeclaresEmergency(q)

\* THE TRUTH ABOUT THE ESTATE, and note what is NOT in it: the EstateBlocks
\* constant. The first version guarded this operator with it, so switching the
\* rule off also switched off the ability to notice it had been switched off --
\* the mutant graded itself and the negative run passed. EstateBlocks belongs in
\* Preflight, which is the RULE; this is the WORLD. It is guard 5's defect in a
\* model: if the thing being checked supplies the evidence, there is no check.
\* sim/label_sim.py had the identical bug, found the same way.
EstateClosedFor(p) == frozen \/ EstateEmergencyFor(p)

\* preflight: `this is itil:emergency -- the freeze and queue rules do not
\* apply to it`. Read off the CLASS, always, and correctly so: the exemption
\* is about what kind of change this is.
Exempt(p) == "E" \in cls[p]

BerthHeldAgainst(p) == \E q \in PRs : q # p /\ Live(q) /\ berth[q]

(***************************************************************************)
(* gates/preflight.sh, in preflight's own order. The ORDER is load-bearing: *)
(* the berth check comes BEFORE the estate check and carries no emergency   *)
(* exemption, so an emergency waits on an ordinary change's berth while that *)
(* ordinary change waits on the emergency.                                   *)
(***************************************************************************)
\* Split so that "refused FOR THE BERTH" is expressible. It has to be: an
\* emergency refused for carrying two classes is a different defect from one
\* refused for a berth, and Stuck below must name only the second. The
\* simulator distinguishes them by preflight's exit code (5); this is the same
\* distinction without the exit codes, and the cross-check is what required it.
PreflightSansBerth(p) ==
    /\ Live(p)
    /\ "C" \in life[p]                                 \* on the calendar
    /\ verified[p]                                     \* gates green, this head
    /\ ClassRequired => cls[p] # {}                    \* classified at all
    /\ ClassConflictRefused =>
          ~("E" \in cls[p] /\ cls[p] \cap {"S","N"} # {})   \* ONE class, not two
    /\ EstateBlocks => (EstateClosedFor(p) => Exempt(p))  \* S8, with its exemption

BerthOK(p) ==
    (BerthMutex /\ ~(EmergencyPreempts /\ Exempt(p))) => ~BerthHeldAgainst(p)

Preflight(p) == PreflightSansBerth(p) /\ BerthOK(p)

(***************************************************************************)
(*                            THE LABELLER                                  *)
(* is_normal wins over has_app, and NEITHER matches an inert diff -- the     *)
(* classify step then leaves the class alone, so an inert change carries no  *)
(* class at all. .github/workflows/labeller.yml.                            *)
(***************************************************************************)
Derived(p) ==
    IF ClassExclusive /\ "E" \in cls[p] THEN {}
    ELSE CASE scope[p] = "app" -> {"S"}
           [] scope[p] = "cp"  -> {"N"}
           [] OTHER            -> {}

DeriveClass(p) ==
    /\ Live(p)
    /\ cls' = [cls EXCEPT ![p] = Derived(p) \cup (cls[p] \cap {"E"})]
    /\ cls' # cls
    /\ UNCHANGED <<life, scope, verified, berth, inprod, emgest, merged,
                   frozen, mainV, bypassed, selfGranted, unclassified,
          twoClassMoved>>

(***************************************************************************)
(*                           THE LIFECYCLE                                  *)
(* Note what is NOT here: nothing removes change:requested. The declaration  *)
(* says "the pipeline clears it" and the only thing that does is             *)
(* change/settle.sh's cleanup, at the very end -- so without                 *)
(* LifecycleReplaces the states ACCUMULATE, while the exclusion group says   *)
(* at most one may be active.                                                *)
(***************************************************************************)
Request(p) ==
    /\ Live(p) /\ life[p] = {}
    /\ life' = [life EXCEPT ![p] = {"R"}]
    /\ UNCHANGED <<cls, scope, verified, berth, inprod, emgest, merged,
                   frozen, mainV, bypassed, selfGranted, unclassified,
          twoClassMoved>>

Book(p) ==
    /\ Live(p) /\ "R" \in life[p] /\ "C" \notin life[p]
    /\ life' = [life EXCEPT ![p] = IF LifecycleReplaces THEN {"C"}
                                                        ELSE life[p] \cup {"C"}]
    /\ UNCHANGED <<cls, scope, verified, berth, inprod, emgest, merged,
                   frozen, mainV, bypassed, selfGranted, unclassified,
          twoClassMoved>>

Gate(p) ==
    /\ Live(p) /\ ~verified[p]
    /\ verified' = [verified EXCEPT ![p] = TRUE]
    /\ UNCHANGED <<cls, life, scope, berth, inprod, emgest, merged,
                   frozen, mainV, bypassed, selfGranted, unclassified,
          twoClassMoved>>

(***************************************************************************)
(* A person declares an emergency.                                          *)
(*                                                                          *)
(* THIS IS THE DECISIVE ACTION. Without SeparateEmergency there is ONE       *)
(* label, so the single write does two things to two different subjects: it  *)
(* closes the estate to every other change AND it exempts its own carrier    *)
(* from the closure. selfGranted records exactly that conjunction.           *)
(***************************************************************************)
SelfGrant(p, newCls, newEst) ==
    LET declaresAfter == IF SeparateEmergency THEN newEst ELSE "E" \in newCls
        \* BOTH quantified over the same set -- the OTHER live changes, the
        \* ones a closure would actually block. The first version had Live(q)
        \* on `before` and a bare `frozen` on `after`, so a freeze declared
        \* while every other PR was merged read as newly-closing. Symmetry is
        \* the whole content of "did THIS write close it".
        closedBefore == \E q \in PRs : q # p /\ Live(q) /\ EstateClosedFor(q)
        closedAfter  == \E q \in PRs : q # p /\ Live(q)
                          /\ (frozen \/ declaresAfter \/ EstateEmergencyFor(q))
    IN /\ ~closedBefore /\ closedAfter
       /\ ~Exempt(p) /\ "E" \in newCls

DeclareEmergency(p) ==
    /\ Live(p) /\ "E" \notin cls[p]
    /\ LET new == IF ClassExclusive THEN {"E"} ELSE cls[p] \cup {"E"} IN
       IF SeparateEmergency
       THEN \* TWO ACTS, because they are two facts about two subjects.
            /\ cls'    = [cls    EXCEPT ![p] = new]
            /\ emgest' = emgest
            /\ selfGranted' = (selfGranted \/ SelfGrant(p, new, FALSE))
       ELSE \* ONE LABEL. They cannot be performed apart.
            /\ cls'    = [cls    EXCEPT ![p] = new]
            /\ emgest' = [emgest EXCEPT ![p] = TRUE]
            /\ selfGranted' = (selfGranted \/ SelfGrant(p, new, TRUE))
    /\ UNCHANGED <<life, scope, verified, berth, inprod, merged, frozen,
                   mainV, bypassed, unclassified, twoClassMoved>>

\* Only reachable when the estate fact has a label of its own. Declaring the
\* estate closed classifies nobody, which is the whole content of the repair.
DeclareEstateEmergency(p) ==
    /\ SeparateEmergency
    /\ Live(p) /\ ~emgest[p]
    /\ emgest' = [emgest EXCEPT ![p] = TRUE]
    /\ UNCHANGED <<cls, life, scope, verified, berth, inprod, merged, frozen,
                   mainV, bypassed, selfGranted, unclassified, twoClassMoved>>

WithdrawEmergency(p) ==
    /\ Live(p) /\ ("E" \in cls[p] \/ emgest[p])
    /\ cls'    = [cls    EXCEPT ![p] = cls[p] \ {"E"}]
    /\ emgest' = [emgest EXCEPT ![p] = FALSE]
    /\ UNCHANGED <<life, scope, verified, berth, inprod, merged, frozen,
                   mainV, bypassed, selfGranted, unclassified, twoClassMoved>>

\* `freeze` on any open PR. Modelled as an estate fact, because that is what it
\* is -- and note that it is the ONLY label in this repository shaped that way,
\* while having no row in change/label-owners.tsv at all.
Freeze ==
    /\ ~frozen /\ frozen' = TRUE
    /\ UNCHANGED <<cls, life, scope, verified, berth, inprod, emgest, merged,
                   mainV, bypassed, selfGranted, unclassified, twoClassMoved>>

Thaw ==
    /\ frozen /\ frozen' = FALSE
    /\ UNCHANGED <<cls, life, scope, verified, berth, inprod, emgest, merged,
                   mainV, bypassed, selfGranted, unclassified, twoClassMoved>>

(***************************************************************************)
(* Movement. Both steps record what was wrong about taking them, because the *)
(* declaration may be withdrawn before anyone looks at the result.           *)
(***************************************************************************)
Moving(p) == EstateClosedFor(p) /\ ~Exempt(p)

\* A change whose class is UNDEFINED -- two of them at once -- moving anyway.
\* Every rule in preflight branches on the class, so this is not a nuance.
TwoClass(p) == Cardinality(cls[p]) > 1

ClaimBerth(p) ==
    /\ Preflight(p) /\ ~berth[p]
    \* PREEMPTION IS EVICTION, not sharing -- the first version let the
    \* emergency claim a berth somebody else held and BerthSingleton went red
    \* on the positive run. An emergency that has to wait for the berth is the
    \* defect; an emergency that silently doubles up in it is a worse one.
    \* The evicted change must be told, which is what blocked:queue is for.
    /\ berth' = [q \in PRs |-> IF q = p THEN TRUE
                              ELSE IF EmergencyPreempts /\ Exempt(p) THEN FALSE
                              ELSE berth[q]]
    /\ bypassed' = (bypassed \/ Moving(p))
    /\ twoClassMoved' = (twoClassMoved \/ TwoClass(p))
    /\ UNCHANGED <<cls, life, scope, verified, inprod, emgest, merged, frozen,
                   mainV, selfGranted, unclassified>>

DeployProduction(p) ==
    /\ Preflight(p) /\ berth[p] /\ ~inprod[p]
    /\ inprod'        = [inprod EXCEPT ![p] = TRUE]
    /\ bypassed'      = (bypassed \/ Moving(p))
    /\ unclassified'  = (unclassified \/ (cls[p] = {}))
    /\ twoClassMoved' = (twoClassMoved \/ TwoClass(p))
    /\ UNCHANGED <<cls, life, scope, verified, berth, emgest, merged, frozen,
                   mainV, selfGranted>>

\* change/settle.sh sets change:complete BEFORE the merge, and does NOT remove
\* change:scheduled -- the second place the lifecycle accumulates.
Complete(p) ==
    /\ Live(p) /\ inprod[p] /\ "X" \notin life[p]
    /\ life' = [life EXCEPT ![p] = IF LifecycleReplaces THEN {"X"}
                                                        ELSE life[p] \cup {"X"}]
    /\ UNCHANGED <<cls, scope, verified, berth, inprod, emgest, merged, frozen,
                   mainV, bypassed, selfGranted, unclassified, twoClassMoved>>

(***************************************************************************)
(* THE SOAK. docs/changing-the-pipeline.org: a control-plane change alters   *)
(* how every FUTURE change is verified, so the evidence that it works is     *)
(* future changes being verified by it. With Soak, such a change cannot be   *)
(* counted proven by its own merge. Nothing in the repository implements     *)
(* this, which is why it is a constant and not a fact.                       *)
(***************************************************************************)
Merge(p) ==
    /\ Live(p) /\ "X" \in life[p] /\ mainV < MaxMerges
    /\ Soak => scope[p] # "cp"
    /\ merged' = [merged EXCEPT ![p] = TRUE]
    /\ berth'  = [berth  EXCEPT ![p] = FALSE]
    /\ mainV'  = mainV + 1
    /\ UNCHANGED <<cls, life, scope, verified, inprod, emgest, frozen,
                   bypassed, selfGranted, unclassified, twoClassMoved>>

\* settle.sh's cleanup clears change:complete once the forge records MERGED.
\* change/label-owners.tsv marks that label persistent and says "Never
\* cleared"; the exclusion-group note in the same file says it is cleared at
\* cleanup. The file contradicts itself and this is the behaviour that decides
\* which half is right -- it is the code's.
Cleanup(p) ==
    /\ merged[p] /\ life[p] # {}
    /\ life' = [life EXCEPT ![p] = {}]
    /\ UNCHANGED <<cls, scope, verified, berth, inprod, emgest, merged, frozen,
                   mainV, bypassed, selfGranted, unclassified, twoClassMoved>>

Next ==
    \/ \E p \in PRs :
          \/ DeriveClass(p) \/ Request(p) \/ Book(p) \/ Gate(p)
          \/ DeclareEmergency(p) \/ DeclareEstateEmergency(p)
          \/ WithdrawEmergency(p)
          \/ ClaimBerth(p) \/ DeployProduction(p) \/ Complete(p)
          \/ Merge(p) \/ Cleanup(p)
    \/ Freeze \/ Thaw

Spec == Init /\ [][Next]_vars

(***************************************************************************)
(*                              INVARIANTS                                  *)
(***************************************************************************)

\* change/label-owners.tsv, exclusion group `class`, cardinality <=1. Stated
\* over the LABEL SET, because that is what the declaration is about -- which
\* is where this module and sim/label_sim.py first disagreed: the simulator
\* stated it over preflight's verdict and found it holding, because preflight
\* refuses such a PR. Both are true and they are DIFFERENT PROPERTIES, so both
\* are stated, here and there. The declared cardinality is violated; the
\* refusal below is what stops that from changing any verdict.
ClassAtMostOne == \A p \in PRs : Live(p) => Cardinality(cls[p]) <= 1

\* And the mitigation: a change whose class is undefined never moves.
NoUndefinedClassMoves == ~twoClassMoved

\* exclusion group `lifecycle`, cardinality "<=1 active".
LifecycleAtMostOneActive == \A p \in PRs : Live(p) => Cardinality(life[p]) <= 1

\* The group's cardinality is <=1, which permits ZERO -- and every rule in
\* preflight branches on the class, so an unclassified change satisfies all of
\* them by falling through.
ClassifiedBeforeDeploy == ~unclassified

\* Guard 1.
BerthSingleton == Cardinality({p \in PRs : Live(p) /\ berth[p]}) <= 1

\* ADR 0001 S8. One rule, two causes, one exemption.
OrdinaryChangeWaits == ~bypassed

\* THE ONE THE QUESTION TURNS ON. No single human write may both close the
\* estate to every other change and exempt its own carrier from the closure.
\* With SeparateEmergency = FALSE this is VIOLATED IN ONE STEP, and that is the
\* whole argument for a bare `emergency` label.
DeclaringABlockDoesNotExempt == ~selfGranted

\* ADR 0001 S8: "an emergency is what a freeze is FOR; blocking it would mean
\* the freeze prevents its own remedy." preflight checks the BERTH before it
\* checks the estate, and the berth check carries no exemption -- so an
\* emergency waits on an ordinary change's berth while that ordinary change is
\* refused with exit 2 for the emergency being in flight. Nothing releases the
\* berth: deploy:staging is owned by the workflow and cleared by settle.sh,
\* which the held change can never reach.
\* Note this one DOES read the rules, unlike EstateClosedFor above, and that is
\* not the self-grading defect: "is the estate closed" is a fact about the
\* world, while "is this change refused" is a fact about the rules, and being
\* stuck is by definition the second kind.
Stuck(p) ==
    /\ Live(p) /\ "E" \in cls[p]
    /\ PreflightSansBerth(p)                  \* nothing else refuses it
    /\ ~BerthOK(p)                            \* the BERTH, and only the berth
    /\ \E q \in PRs : /\ q # p /\ Live(q) /\ berth[q] /\ "E" \notin cls[q]
                     /\ EstateClosedFor(q) /\ ~Exempt(q)
                     \* and the holder is refused for the emergency being in
                     \* flight, so it can never reach settle.sh to release it

EmergencyNeverWaits == \A p \in PRs : ~Stuck(p)

\* docs/changing-the-pipeline.org: a control-plane change is proven by USE.
ControlPlaneSoaks == \A p \in PRs : merged[p] => scope[p] # "cp"

Safety ==
    /\ TypeOK
    /\ ClassAtMostOne
    /\ NoUndefinedClassMoves
    /\ LifecycleAtMostOneActive
    /\ ClassifiedBeforeDeploy
    /\ BerthSingleton
    /\ OrdinaryChangeWaits
    /\ DeclaringABlockDoesNotExempt
    /\ EmergencyNeverWaits
    /\ ControlPlaneSoaks
=============================================================================
