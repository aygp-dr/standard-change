# STACK.md — four steps to the search results copy

Four changes to `apps/plp/`, each independently shippable, each depending on
the one before it. Production code only; each step is under five lines of
`src/server.js`. Tests are counted separately — the five-line budget is a
budget on the change, not on the evidence for it.

Starting point: `/search` is a declared route that plp answers with the
generic app document. It does not read `q`, does not search anything, and its
page says nothing about what was searched for.

## 1. `render()` reads `q` off the search URL

- **Changes:** `/search?q=boots` puts `query: "boots"` in the JSON body
  (`""` when the term is absent or empty). Nothing renders differently.
- **Cannot be earlier:** it is first. Every later step reads `d.query`; the
  field does not exist until this lands.

## 2. `panel()` names the term back to the shopper, escaped

- **Changes:** the HTML search page gains a panel — `Results for <q>` — with
  `q` passed through `esc()` from `shared/oneui.js`.
- **Cannot be earlier than 1:** the branch is guarded on `d.query !== undefined`
  and interpolates `d.query`. Before step 1 that field is always `undefined`,
  so the branch is unreachable and the step is a no-op with no test to write.

## 3. `render()` matches the term against the catalogue

- **Changes:** `results` for a search becomes the SKUs of every category whose
  slug or title contains the term. JSON only; the panel from step 2 still
  returns before it reads them.
- **Cannot be earlier than 2:** this is a shippability dependency, not a
  compile one. `panel()` opens with `if (d.results === undefined) return ''`
  and then falls into the *category* branches. Giving a search a `results`
  array while step 2's early return is absent sends `/search` into the
  category-page copy, which renders an empty `<h2>` and the category name
  `(none)`. Landing 3 before 2 therefore ships a visibly broken page; landing
  it after 2 cannot, because the search branch returns first.

## 4. The search panel reports the count and the two no-result cases

- **Changes:** rewrites step 2's copy — a result count in the heading, a
  distinct sentence for "nothing matched", and a distinct one for "you have
  not typed anything yet".
- **Cannot be earlier than 3:** the heading reads `d.results.length`. Before
  step 3, `d.results` is `undefined` on a search and the expression throws a
  `TypeError` inside the request handler — a 500, not a copy change. It also
  edits the exact template literal step 2 introduces, so there is nothing to
  rewrite before 2.

## Honest notes on the ordering

- 1 → 2 and 3 → 4 are hard dependencies: the later step reads a field or a
  string the earlier step creates, and fails loudly without it.
- 2 → 3 is the soft link. Step 3 compiles and its own tests pass on top of
  step 1 alone. What it cannot do without step 2 is *ship*: the tree between
  the two commits serves a broken search page. That is still an ordering
  constraint — "every commit is deployable" is the property the stack exists
  to preserve — but it is weaker than the other two, and calling it the same
  kind of dependency would be overselling it.
- The split between 1 and 2 is also forced by the five-line budget. A single
  "search page names the term" commit would be the natural unit of review;
  two commits is what the budget allows.
