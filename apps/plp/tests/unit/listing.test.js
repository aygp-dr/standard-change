// THE PRODUCT LIST, and the fact that there is only one of it.
//
// The defect these tests pin down was live on production blue: /search?q=shoes
// matched the shoes category, rendered a single link to /c/shoes, and listed
// no products -- while /c/shoes, one click away, listed three. Two renderers
// for the same shelf, and the search one was never reached for the commonest
// kind of query there is: the name of a category.
//
// So the assertions come in two halves:
//
//   1. SEARCH REACHES PRODUCTS. /search?q=shoes lists the products a person
//      can actually buy, not just a link to somewhere that would.
//   2. ONE RENDERER. The markup /search emits for a product is the markup
//      /c/<category> emits for the same product, byte for byte. A test that
//      only checked "the SKU appears somewhere" would pass on two copies that
//      had drifted, which is how they drifted.
//
// And, throughout: q comes off the wire. Issue #13 was a live reflected XSS in
// this estate, and the search box is the first thing here that is user text
// rather than a route the router already constrained.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { fileURLToPath } from 'node:url';
import {
  render, renderHtml, status, panel, productList, itemsFor, searchResults,
  loadCatalogue, loadProducts, CATALOGUE_FILE, PRODUCTS_FILE,
} from '../../src/server.js';

const OK_CATS = loadCatalogue(CATALOGUE_FILE);
const OK_PRODS = loadProducts(PRODUCTS_FILE);
const MISSING = fileURLToPath(
  new URL('../fixtures/catalogue/no-such-file.json', import.meta.url));

// The shoes category, read from the shipped file rather than hardcoded: if the
// catalogue changes, these tests must follow it or fail honestly, not assert
// against three SKU strings that stopped being true.
const SHOES = OK_CATS.categories.find((c) => c.slug === 'shoes');

// ---- 1. a query that matches: the products are LISTED ------------------------

test('shoes is a category with products, or these tests prove nothing', () => {
  assert.ok(SHOES, 'the shipped catalogue has no shoes category');
  assert.ok(SHOES.skus.length > 0, 'the shoes category lists no SKUs');
  // The premise of the whole defect: no PRODUCT NAME contains "shoes", so a
  // search that only matched names would find zero products for it. If a
  // product is ever called "Shoes", this test must be the thing that says so.
  assert.equal(OK_PRODS.products.filter((p) => /shoes/i.test(p.name)).length, 0,
    'a product is now named "shoes"; the category-expansion path is no longer ' +
    'the only way this query reaches a product, and these tests are weaker');
});

test('/search?q=shoes lists the products in the shoes category', () => {
  const d = render('/search?q=shoes', OK_CATS, OK_PRODS);
  assert.equal(status(d), 200);
  assert.deepEqual(d.items.map((i) => i.sku), SHOES.skus,
    '/search?q=shoes did not list the products a person can buy');
  for (const i of d.items)
    assert.ok(i.name, `${i.sku} listed with no name; the product file has one`);
});

test('the matching products are on the PAGE, linked to the product app', () => {
  const html = renderHtml('/search?q=shoes', OK_CATS, 9090, OK_PRODS);
  for (const sku of SHOES.skus) {
    assert.ok(html.includes(`href="/p/${sku}"`), `no link to ${sku}`);
    assert.ok(html.includes(sku), `${sku} is not on the page`);
  }
  assert.ok(html.includes('Trail Runner'), 'the product name is not rendered');
  assert.doesNotMatch(html, /No results/,
    'a query with matching products rendered the no-results state');
});

test('the category link survives -- browsing the shelf is still an answer', () => {
  const html = renderHtml('/search?q=shoes', OK_CATS, 9090, OK_PRODS);
  assert.ok(html.includes('href="/c/shoes"'),
    'listing the products dropped the link to the category itself');
});

// A direct name hit and a hit through a category are the same product, once.
test('a product reached twice is listed once', () => {
  // "shirt" matches the shirts CATEGORY (by title) and both shirt PRODUCTS
  // (by name), so every shirt SKU has two routes to this page.
  const d = render('/search?q=shirt', OK_CATS, OK_PRODS);
  const skus = d.items.map((i) => i.sku);
  assert.deepEqual(skus, [...new Set(skus)], `a SKU is listed twice: ${skus}`);
  assert.ok(skus.includes('SKU201') && skus.includes('SKU202'));
});

// ---- 2. ONE renderer, not two ------------------------------------------------

test('search and the category page render the same product identically', () => {
  const search = panel(render('/search?q=shoes', OK_CATS, OK_PRODS));
  const cat    = panel(render('/c/shoes', OK_CATS, OK_PRODS));
  const list   = productList(itemsFor(SHOES.skus, OK_PRODS.products));

  assert.ok(list.length > 0, 'the shared renderer produced nothing');
  assert.ok(cat.includes(list),
    'the category page does not use the shared product renderer');
  assert.ok(search.includes(list),
    'the search page does not use the shared product renderer -- the two ' +
    'lists have diverged again, which is the bug this test exists for');
});

test('the two pages agree on every product link, not just on the SKU text', () => {
  const links = (h) => (h.match(/href="\/p\/[^"]*"/g) || []);
  assert.deepEqual(links(panel(render('/search?q=shoes', OK_CATS, OK_PRODS))),
                   links(panel(render('/c/shoes', OK_CATS, OK_PRODS))));
});

// The category page must not acquire a dependency on a sibling app's data
// file. Names are a nicety; the list is not.
test('an unreadable product file does not empty the category page', () => {
  const d = render('/c/shoes', OK_CATS, loadProducts(MISSING));
  assert.equal(status(d), 200, 'the category page went down with pdp data');
  assert.deepEqual(d.results, SHOES.skus);
  const html = renderHtml('/c/shoes', OK_CATS, 9090, loadProducts(MISSING));
  for (const sku of SHOES.skus)
    assert.ok(html.includes(`href="/p/${sku}"`), `${sku} vanished`);
});

// ---- 3. a query that matches nothing -----------------------------------------

test('a query that matches nothing renders a clear no-results state', () => {
  const d = render('/search?q=zzzznothing', OK_CATS, OK_PRODS);
  assert.equal(status(d), 200, 'no results is not a 404');
  assert.equal(d.count, 0);
  assert.deepEqual(d.items, []);
  assert.equal(d.reason, 'no-results');

  const html = renderHtml('/search?q=zzzznothing', OK_CATS, 9090, OK_PRODS);
  assert.match(html, /No results/, 'an empty page is not a no-results state');
  assert.doesNotMatch(html, /cannot search/,
    '"nothing matched" must not read as "we could not look"');
  // Scoped to the PANEL, not the page: OneUI's estate nav links /p/SKU1 on
  // every page in the estate, so asserting against the whole document would
  // assert something about the nav and nothing about the search result.
  assert.doesNotMatch(panel(d), /href="\/p\//, 'a no-match query listed a product');
  // smoke.sh rejects a 200 with under 200 bytes as "not a page".
  assert.ok(html.length > 200, 'the no-results page is too thin to be a page');
});

// ---- 4. an empty q, and no q at all ------------------------------------------
//
// Two different requests that must both be the bare search page, and neither
// of which may claim there is nothing: nothing was asked.

test('an empty q is the bare search page, not a no-results page', () => {
  const d = render('/search?q=', OK_CATS, OK_PRODS);
  assert.equal(status(d), 200);
  assert.equal(d.query, '');
  assert.deepEqual(d.items, []);
  assert.equal(d.reason, 'empty-query');
  const html = renderHtml('/search?q=', OK_CATS, 9090, OK_PRODS);
  assert.doesNotMatch(html, /No results/,
    'an empty query rendered "no results"; nothing was searched');
  assert.match(html, /<input[^>]*name=q/, 'no box to type in');
});

test('a missing q parameter is the same page, and does not crash', () => {
  for (const p of ['/search', '/search/', '/search?other=1']) {
    const d = render(p, OK_CATS, OK_PRODS);
    assert.equal(status(d), 200, `${p} answered ${status(d)}`);
    assert.equal(d.query, '', `${p} did not treat a missing q as ""`);
    assert.deepEqual(d.items, [], `${p} listed something`);
    assert.equal(d.reason, 'empty-query', p);
    assert.doesNotThrow(() => renderHtml(p, OK_CATS, 9090, OK_PRODS), p);
  }
});

// A search whose whitespace-only query is not the same as a real one.
test('a whitespace-only query claims nothing either', () => {
  const d = render('/search?q=%20%20', OK_CATS, OK_PRODS);
  assert.equal(d.reason, 'empty-query');
  assert.deepEqual(searchResults('   ', OK_CATS.categories, OK_PRODS.products), []);
});

// ---- 5. escaping, in the listing this change added ---------------------------
//
// The expected strings are written out literally rather than computed with
// esc(). Calling esc() to check esc()'s output asserts that a function agrees
// with itself, which a broken one also does.
//
// "onfocus" and "onerror" appear in the expected text on purpose: escaped,
// they are inert characters inside an attribute value, and banning the
// substring would ban the harmless case while proving nothing about the
// dangerous one. What must not appear is the RAW query.
const PAYLOADS = [
  ['"><script>alert(1)</script>',
   '&quot;&gt;&lt;script&gt;alert(1)&lt;/script&gt;'],
  ['" onfocus="alert(1)', '&quot; onfocus=&quot;alert(1)'],
  ["'><img src=x onerror=alert(1)>",
   '&#39;&gt;&lt;img src=x onerror=alert(1)&gt;'],
  ['</title><b>x', '&lt;/title&gt;&lt;b&gt;x'],
  ['&', '&amp;'],
];

test('no payload reaches the search page as markup', () => {
  for (const [q, escaped] of PAYLOADS) {
    const html = renderHtml(`/search?q=${encodeURIComponent(q)}`,
                            OK_CATS, 9090, OK_PRODS);
    assert.ok(html.includes(escaped), `not escaped as expected: ${q}`);
    // A bare "&" is a payload too -- it is the character every other escape is
    // built out of, and a renderer that forgot it turns "&lt;" typed by a user
    // into a real "<". But `!html.includes('&')` is vacuously false on a
    // correctly escaped document, so the rule is stated properly: no ampersand
    // anywhere that is not opening one of the five entities esc() emits. For
    // every other payload the raw string must simply not appear.
    if (q === '&') {
      assert.equal(html.match(/&(?!(amp|lt|gt|quot|#39);)/g), null,
        'an unescaped ampersand is in the document');
    } else {
      assert.ok(!html.includes(q), `the raw query is in the document: ${q}`);
    }
    // The document's own <script>/<img>/</title> would be a false negative:
    // page() ships neither, and the <title> it does ship is closed before the
    // panel. Assert on the counts the clean page has.
    assert.ok(!/<script/i.test(html), `a script tag reached the page via ${q}`);
    assert.ok(!/<img/i.test(html), `an img tag reached the page via ${q}`);
    assert.equal((html.match(/<\/title>/gi) || []).length, 1,
      `a second </title> reached the page via ${q}`);
    // The attribute context -- the part a renderer that escaped < and > only
    // would leave wide open. [^>]* stops early if the value ever DID break
    // out, so the regex is itself part of the check.
    const input = html.match(/<input[^>]*>/)[0];
    assert.ok(input.includes(`value="${escaped}"`), `broke out of value=: ${input}`);
    assert.equal((input.match(/value=/g) || []).length, 1,
      `a second value= attribute appeared: ${input}`);
  }
});

// The listing renders values from the product file, and "it comes from config"
// is exactly what was said about the values that turned out to be reachable in
// issue #13. Hand productList() the hostile input directly: this is the only
// place that proves the LIST escapes, rather than the box above it.
test('the shared product renderer escapes what it lists', () => {
  const html = productList([
    // A nameless entry: the SKU is the LINK TEXT.
    { sku: '"><script>alert(1)</script>', name: null },
    // A named entry: the name is the link text...
    { sku: 'SKU9', name: '<img src=x onerror=alert(1)>' },
    // ...and the SKU moves into the badge beside it. That badge is a THIRD
    // interpolation and it is only reached when a name is present, so an item
    // with a hostile SKU *and* a name is the only input that tests it. Without
    // this row, deleting esc() from the badge fails no test at all -- observed,
    // not assumed: mutation M3 passed 63/63 until it was added.
    { sku: '"><svg onload=alert(1)>', name: 'Perfectly Fine Name' },
  ]);
  assert.ok(!/<script/i.test(html), 'a script tag came out of the product list');
  assert.ok(!/<img/i.test(html), 'an img tag came out of the product list');
  assert.ok(!/<svg/i.test(html), 'an svg tag came out of the product list');
  assert.ok(html.includes('&lt;script&gt;'), 'the SKU was not escaped');
  assert.ok(html.includes('&lt;img src=x onerror=alert(1)&gt;'),
    'the product name was not escaped');
  assert.ok(html.includes('<span class=v>&quot;&gt;&lt;svg onload=alert(1)&gt;</span>'),
    'the SKU badge beside a name was not escaped');
  // The href must be a correct URL AND a safe attribute; neither encoding
  // does the other's job. Read the attribute value back and assert it carries
  // no quote and no angle bracket of its own.
  for (const href of html.match(/href="[^"]*"/g)) {
    assert.ok(!/[<>]/.test(href), `an href carries markup: ${href}`);
    assert.equal((href.match(/"/g) || []).length, 2,
      `an href escaped its attribute: ${href}`);
  }
  assert.ok(html.includes('href="/p/%22%3E%3Cscript%3E'),
    'the SKU was not percent-encoded into the path');
});

// A SKU a category lists that the product file does not carry. It must list
// under its SKU rather than vanish -- plp does not get to delist a category's
// item because it could not find a name for it.
test('a product with no name still lists, under its SKU', () => {
  // `now` pinned far past every date in the catalogue so this test keeps
  // asserting what it is named after. It is about NAMES; a real `now` would
  // make it a freshness test as well, and it would start failing on a day
  // nobody chose (issue #18). `badge` is in the shape either way.
  const items = itemsFor(['SKU123', 'SKU-GHOST'], OK_PRODS.products, Date.UTC(2099, 0, 1));
  assert.deepEqual(items, [{ sku: 'SKU123', name: 'Trail Runner', badge: null },
                           { sku: 'SKU-GHOST', name: null, badge: null }]);
  const html = productList(items);
  assert.ok(html.includes('>SKU-GHOST</a>'), 'the nameless SKU vanished');
  assert.ok(html.includes('href="/p/SKU-GHOST"'));
});

test('an empty list renders nothing rather than an empty shell', () => {
  assert.equal(productList([]), '');
});

// ---- the freshness badge (issue #18) ----------------------------------------
//
// plp's HALF. That plp and pdp agree about the same SKU on the same day is
// asserted in apps/pdp/tests/unit/estate.test.js, where it belongs: neither
// app can see that from inside itself. What is asserted here is that the badge
// reaches BOTH of plp's routes, through the one renderer they share -- the
// listing and the search results are the same shelf, and a product that is New
// on one of them and plain on the other is this file's original defect wearing
// a new hat.
//
// Every case injects `now`. The badge is derived from a date; an assertion
// that read the clock would change verdict on a day nobody chose.

const BADGE_DAY = Date.parse('2026-09-13T00:00:00Z');
const LONG_AFTER = BADGE_DAY + 400 * 86400000;

test('a category listing badges a recently added product', () => {
  const d = render('/c/shoes', OK_CATS, OK_PRODS, BADGE_DAY);
  const trail = d.items.find((i) => i.sku === 'SKU123');
  assert.equal(trail.badge, 'New');
  const html = renderHtml('/c/shoes', OK_CATS, 9020, OK_PRODS, BADGE_DAY);
  assert.ok(html.includes('<span class=b>New</span>'), 'no badge on the listing');
});

test('search badges the same product the same way -- one renderer, one rule', () => {
  // The property this file exists for, extended to the badge: whatever markup
  // /c/shoes emits for a product, /search emits for that product, byte for
  // byte. Two copies of the freshness rule would pass a test that only asked
  // "is there a badge somewhere".
  const cat = render('/c/shoes', OK_CATS, OK_PRODS, BADGE_DAY);
  const srch = render('/search?q=Trail', OK_CATS, OK_PRODS, BADGE_DAY);
  const one = (d) => d.items.filter((i) => i.sku === 'SKU123');
  assert.deepEqual(productList(one(cat)), productList(one(srch)));
  assert.equal(one(srch)[0].badge, 'New');
  // and in the kind-tagged results a client reasons about, not only in `items`
  const r = srch.results.find((x) => x.kind === 'product' && x.sku === 'SKU123');
  assert.equal(r.badge, 'New');
});

test('a badge expires on the listing with no cleanup step', () => {
  const d = render('/c/shoes', OK_CATS, OK_PRODS, LONG_AFTER);
  assert.deepEqual(d.items.filter((i) => i.badge !== null), [],
                   'a badge outlived its date on the listing');
  assert.ok(!renderHtml('/c/shoes', OK_CATS, 9020, OK_PRODS, LONG_AFTER).includes('class=b'));
});

test('a SKU the product file does not carry gets no badge, as it gets no name', () => {
  // plp will not invent a freshness verdict for a product it cannot see. Same
  // rule as the name: the category still lists it, under its SKU.
  const items = itemsFor(['SKU-GHOST'], OK_PRODS.products, BADGE_DAY);
  assert.deepEqual(items, [{ sku: 'SKU-GHOST', name: null, badge: null }]);
  assert.ok(!productList(items).includes('class=b'));
});
