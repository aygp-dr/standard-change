# STACK.md — checkout copy, three steps

Three changes to `apps/checkout/` that together tell a shopper what they are
about to pay, what happens next, and how to go back. Each lands on its own and
is reviewable on its own. The order is not a preference — steps 2 and 3 do not
apply to the tree that precedes them.

## The steps

1. **State the amount.** Introduce `DUE`, the single constant holding what the
   basket comes to, and print it above the shipping-address form on `/checkout`.
   *Cannot be reordered later:* it is the only step that introduces new data.
   Steps 2 and 3 both quote `DUE`; neither diff applies to a tree where the
   constant does not exist.

2. **Say what happens next, on the step where it happens.** `/checkout/payment`
   currently renders no panel at all — `renderHtml` returns `extra` only for
   `/checkout`. Give it one, naming the amount and promising that nothing is
   charged until the shopper confirms.
   *Cannot be reordered earlier:* the sentence names `DUE`, which step 1 defines.
   Moved ahead of step 1 this step would have to introduce the constant itself,
   which is to say it would have absorbed step 1.

3. **Offer the way back, without losing what was typed.** Add a "back to
   shipping address" link to the payment panel, carrying the shopper's query
   string so the address they already entered survives the round trip.
   *Cannot be reordered earlier:* before step 2 the payment page renders nothing.
   There is no panel to put the link in, and no call site that passes the query
   to one. This is structural, not stylistic.

## Is the stack real?

Mostly, and the two joints are not equally strong. Saying so is the point.

- **2 → 3 is a hard dependency.** Step 3 adds a link to a panel that step 2
  creates, reached through a dispatch that step 2 introduces. On the tree before
  step 2 there is no `/checkout/payment` panel, so step 3 has nothing to edit.
  Reversing these two is not a matter of taste; the third diff does not apply.

- **1 → 2 is a data dependency, and it is softer.** Step 2's copy interpolates
  `DUE`, so its diff genuinely does not apply before step 1 — but the *idea* of
  step 2 does not require step 1. A "nothing is charged until you confirm"
  sentence with no figure in it would be a smaller, still-shippable change. The
  dependency is real as written and would evaporate if step 2 were written
  without the amount. It is honest to call this joint a choice that was made
  rather than a constraint that was found.

So: one genuine structural dependency, one deliberate data dependency, zero
free reorderings as the steps are written.

## Constraints held

- Each step changes fewer than five lines of `apps/checkout/src/server.js`.
- Nothing outside `apps/checkout/` is touched. No new dependencies.
- The JSON contract (`render()`) is untouched; all three steps are HTML-only, so
  `routes.json`, the router, the labeller and guard 5 see no change.
- `page()`'s fourth argument is interpolated raw. Every panel these steps put
  there is static copy except the back link's `href`, which is request-derived
  and goes through `esc()`.
