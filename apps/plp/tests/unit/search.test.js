// /search?q= -- the first user-supplied input in this estate that is not a
// route, and the three things that arrive with it (issue #35).
//
//   1. FOUR STATES THAT MUST STAY DISTINCT. results, no results, no query yet,
//      and cannot-search. The middle two are 200 and the last is 503, and the
//      difference between "nothing matched" and "we could not look" has to be
//      legible in the JSON without reading the HTML.
//   2. ESCAPING. q lands in text AND in the input's value= attribute. Issue
//      #13 was a live reflected XSS in this estate through one unescaped
//      interpolation; the attribute context makes the quote escapes matter in
//      a way they did not for d.path.
//   3. THE HEALTH PATH. routes.json declares health "/search?q=ping" and guard
//      5 expects 200. "ping" matches nothing, so no-results MUST be 200 -- the
//      #24 failure, one app over.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import {
  render, renderHtml, status, queryOf, searchResults,
  loadCatalogue, loadProducts, CATALOGUE_FILE, PRODUCTS_FILE,
} from '../../src/server.js';

const meta = JSON.parse(readFileSync(new URL('../../routes.json', import.meta.url)));
const fixture = (n) =>
  fileURLToPath(new URL(`../fixtures/catalogue/${n}`, import.meta.url));
// plp's own fixtures for a file it does NOT own. They are here rather than in
// apps/pdp/tests because they are inputs to plp's loader: pdp validates price,
// currency and availability and plp validates neither, so a fixture that is
// bad for pdp is not necessarily bad for plp, and sharing them would tie two
// apps' negative tests together through a directory.
const pfixture = (n) =>
  fileURLToPath(new URL(`../fixtures/products/${n}`, import.meta.url));
// "missing" is a real state, not a mock: the app reads the filesystem, so the
// file is deleted from the app's point of view by pointing it at nothing.
const MISSING = fixture('no-such-file.json');
const OK_CATS = loadCatalogue(CATALOGUE_FILE);
const OK_PRODS = loadProducts(PRODUCTS_FILE);

// ---- the query, off the wire ------------------------------------------------

test('queryOf tells "not a search" apart from "a search with no query"', () => {
  assert.equal(queryOf('/c/shoes'), null);
  assert.equal(queryOf('/'), null);
  assert.equal(queryOf('/searching-for-trouble'), null);
  assert.equal(queryOf('/search'), '');
  assert.equal(queryOf('/search/'), '');
  assert.equal(queryOf('/search?q='), '');
  assert.equal(queryOf('/search?other=1'), '');
});

test('queryOf decodes what a GET form actually puts on the wire', () => {
  assert.equal(queryOf('/search?q=trail+runner'), 'trail runner');
  assert.equal(queryOf('/search?q=trail%20runner'), 'trail runner');
  assert.equal(queryOf('/search?q=caf%C3%A9'), 'café');
});

// categoryOf has to guard decodeURIComponent against this; the URL parser does
// not throw, but the test is here so a future hand-rolled decoder cannot
// quietly reintroduce a 500 on a one-character request.
test('a malformed escape is answered, not thrown', () => {
  assert.equal(queryOf('/search?q=%'), '%');
  const d = render('/search?q=%', OK_CATS, OK_PRODS);
  assert.equal(status(d), 200);
});

// ---- what matches -----------------------------------------------------------

test('a category is found by slug and by title, case-insensitively', () => {
  for (const q of ['shoes', 'SHOES', 'Shoe']) {
    const hits = searchResults(q, OK_CATS.categories, OK_PRODS.products);
    assert.ok(hits.some((r) => r.kind === 'category' && r.slug === 'shoes'),
      `${q} did not find the shoes category`);
  }
});

test('a product is found by name -- the reason plp reads pdp data at all', () => {
  const hits = searchResults('trail', OK_CATS.categories, OK_PRODS.products);
  const p = hits.find((r) => r.kind === 'product');
  assert.ok(p, '"trail" found no product; categories.json has no product names');
  assert.equal(p.sku, 'SKU123');
  assert.equal(p.href, '/p/SKU123');
});

test('a product is found by SKU', () => {
  const hits = searchResults('sku301', OK_CATS.categories, OK_PRODS.products);
  assert.deepEqual(hits.filter((r) => r.kind === 'product').map((r) => r.sku),
    ['SKU301']);
});

test('categories and products stay distinguishable in the payload', () => {
  const hits = searchResults('shirt', OK_CATS.categories, OK_PRODS.products);
  assert.ok(hits.some((r) => r.kind === 'category'));
  assert.ok(hits.some((r) => r.kind === 'product'));
  for (const r of hits) assert.ok(r.kind === 'category' || r.kind === 'product');
});

test('an empty or whitespace query matches nothing rather than everything', () => {
  for (const q of ['', '   ']) {
    assert.deepEqual(searchResults(q, OK_CATS.categories, OK_PRODS.products), []);
  }
});

// ---- the four states --------------------------------------------------------

test('a query that matches is 200 with results', () => {
  const d = render('/search?q=shoes', OK_CATS, OK_PRODS);
  assert.equal(status(d), 200);
  assert.equal(d.found, true);
  assert.equal(d.query, 'shoes');
  assert.ok(d.count > 0);
  assert.equal(d.reason, null);
  assert.equal(d.catalogue, 'ok');
  assert.equal(d.products, 'ok');
});

// The decision, stated as a test so it cannot be undone by accident: a search
// that matched nothing is a successful answer to a reasonable question. The
// address exists -- unlike /p/NOSUCH, where the RESOURCE does not.
test('a query that matches nothing is 200, and says so', () => {
  const d = render('/search?q=zzzznothing', OK_CATS, OK_PRODS);
  assert.equal(status(d), 200, 'no results must not be a 404');
  assert.equal(d.found, true);
  assert.equal(d.count, 0);
  assert.deepEqual(d.results, []);
  assert.equal(d.reason, 'no-results');
  assert.equal(d.catalogue, 'ok', 'the catalogue loaded; say so');
  assert.equal(d.products, 'ok');
});

test('no query at all is the bare search page and claims nothing', () => {
  for (const p of ['/search', '/search?q=']) {
    const d = render(p, OK_CATS, OK_PRODS);
    assert.equal(status(d), 200);
    assert.equal(d.query, '');
    assert.equal(d.count, 0);
    assert.equal(d.reason, 'empty-query',
      'an empty query must not report "no results" -- nothing was searched');
  }
});

test('unreadable product data is 503, not "no results"', () => {
  for (const [file, reason] of [[MISSING, 'products-missing'],
                                [pfixture('malformed.json'), 'products-malformed'],
                                [pfixture('wrong-shape.json'), 'products-malformed'],
                                [pfixture('bad-entry.json'), 'products-malformed']]) {
    const d = render('/search?q=trail', OK_CATS, loadProducts(file));
    assert.equal(status(d), 503, `${reason} answered ${status(d)}`);
    assert.equal(d.found, false);
    assert.equal(d.products, 'unavailable');
    assert.equal(d.catalogue, 'ok', 'plp could read its own file; do not blame it');
    assert.equal(d.reason, reason, 'the reason must name the file an operator has to fix');
    assert.deepEqual(d.results, []);
  }
});

test('unreadable categories is also 503, and names the other file', () => {
  const d = render('/search?q=trail', loadCatalogue(MISSING), OK_PRODS);
  assert.equal(status(d), 503);
  assert.equal(d.catalogue, 'unavailable');
  assert.equal(d.reason, 'catalogue-missing');
});

// The whole point of the 503: half an answer, presented as the answer, is a
// lie. "trail" matches a product and nothing else, so a categories-only
// fallback would report "no results for trail" while the product sits there.
test('search does not fall back to half the data and call it no results', () => {
  const d = render('/search?q=trail', OK_CATS, loadProducts(MISSING));
  assert.notEqual(d.reason, 'no-results');
  assert.equal(status(d), 503);
});

// ---- the health path --------------------------------------------------------
//
// AMENDED IN THE DIRECTION OF THE OBSERVATION. These two tests were written
// when routes.json declared health "/search?q=ping", and they asserted that
// the declared health path was a search returning 200. #37 moved health to the
// dedicated /__health/<app> route precisely so that a product change could not
// take guard 5 down with it -- which is this change. Rebasing onto that main
// left both tests red against a path render() correctly reports it does not
// own, and a red test whose subject has moved is not evidence of a defect.
//
// What survives is the rule they existed to protect, restated against what is
// now true: health must NOT be a search, and a no-results search must still be
// 200 for its own reasons rather than because guard 5 needs it to be.
test('the declared health path is not a search at all', () => {
  assert.equal(queryOf(meta.health), null,
    `health is "${meta.health}"; a health path that is a search fails the day ` +
    'search gains an opinion -- #24 (pdp /p/PING) and the reason #37 moved it');
  assert.equal(meta.health, '/__health/plp',
    'guard 5 and gates/lint-app.mjs both expect the reserved route');
});

// The no-results 200 is now load-bearing on its own merits, not as a prop
// under the health check. gates/smoke.sh walks /search?q=shoes as step 2 of
// the journey and requires 200 text/html, so a search that answered 404 for a
// miss would still break a gate -- one gate over from where it used to.
test('a miss on the shipped data is still 200, with the real files', () => {
  const d = render('/search?q=ping',
                   loadCatalogue(CATALOGUE_FILE), loadProducts(PRODUCTS_FILE));
  assert.equal(d.count, 0, '"ping" is supposed to match nothing');
  assert.equal(status(d), 200, `a no-results search answered ${status(d)}`);
});

// ---- escaping, in both contexts ---------------------------------------------

// The expected escaping is written out literally rather than computed with
// esc(). Calling esc() to check esc()'s output asserts that a function agrees
// with itself, which is true of a broken one too.
//
// "onfocus" and "onerror" appear in the expected strings on purpose: escaped,
// they are TEXT inside an attribute value, and a test that banned the
// substring would be banning the harmless case while proving nothing about the
// dangerous one. What must not appear is the raw query, because the raw query
// is the only way the quote or the angle bracket gets out.
const PROBES = [
  ['<script>alert(1)</script>', '&lt;script&gt;alert(1)&lt;/script&gt;'],
  ['" onfocus="alert(1)', '&quot; onfocus=&quot;alert(1)'],
  ["' onfocus='alert(1)", '&#39; onfocus=&#39;alert(1)'],
  ['"><img src=x onerror=alert(1)>', '&quot;&gt;&lt;img src=x onerror=alert(1)&gt;'],
  ['</textarea><script>alert(1)</script>',
   '&lt;/textarea&gt;&lt;script&gt;alert(1)&lt;/script&gt;'],
];

test('no probe reaches the page as markup', () => {
  for (const [q, escaped] of PROBES) {
    const html = renderHtml(`/search?q=${encodeURIComponent(q)}`, OK_CATS, 9090, OK_PRODS);
    assert.ok(!html.includes(q), `the raw query is in the document: ${q}`);
    assert.ok(html.includes(escaped), `the query is not escaped as expected: ${q}`);
    assert.ok(!/<script/i.test(html), `a script tag reached the page via ${q}`);
    assert.ok(!/<img/i.test(html), `an img tag reached the page via ${q}`);
    assert.ok(!/<\/textarea/i.test(html), `a closing textarea reached the page via ${q}`);
  }
});

// The attribute context specifically. The value= attribute is the part d.path
// never exercised, and a renderer that escaped < and > only would pass most of
// the assertions above while leaving the input wide open.
//
// The tag is matched with [^>]* on purpose: if a query ever DID break out, the
// match would stop early and the value= assertion would fail -- so the regex
// is itself part of the check.
test('the input value attribute survives every quote-breaking query', () => {
  for (const [q, escaped] of PROBES) {
    const html = renderHtml(`/search?q=${encodeURIComponent(q)}`, OK_CATS, 9090, OK_PRODS);
    const input = html.match(/<input[^>]*>/)[0];
    assert.ok(input.includes(`value="${escaped}"`),
      `the query escaped its attribute: ${input}`);
    assert.equal((input.match(/value=/g) || []).length, 1,
      `a second value= attribute appeared: ${input}`);
  }
});

test('the query is echoed back, escaped, so a person sees what they typed', () => {
  const html = renderHtml('/search?q=%3Cb%3Eshoes%3C%2Fb%3E', OK_CATS, 9090, OK_PRODS);
  assert.ok(html.includes('&lt;b&gt;shoes&lt;/b&gt;'), 'the query is not shown back');
});

// ---- the page a person gets -------------------------------------------------

test('every search state renders a form, including the one that cannot search', () => {
  const states = [
    ['/search', OK_PRODS],
    ['/search?q=shoes', OK_PRODS],
    ['/search?q=zzzznothing', OK_PRODS],
    ['/search?q=shoes', loadProducts(MISSING)],
  ];
  for (const [path, prods] of states) {
    const html = renderHtml(path, OK_CATS, 9090, prods);
    assert.ok(/<form[^>]*action="\/search"/.test(html), `${path}: no form`);
    assert.ok(/method="get"/.test(html),
      `${path}: the form must be GET -- a POST result is unlinkable and unprobeable`);
    assert.ok(/<input[^>]*name=q/.test(html), `${path}: no input named q`);
  }
});

test('the page distinguishes "nothing matched" from "we could not look"', () => {
  const none = renderHtml('/search?q=zzzznothing', OK_CATS, 9090, OK_PRODS);
  const down = renderHtml('/search?q=zzzznothing', OK_CATS, 9090, loadProducts(MISSING));
  assert.ok(none.includes('No results'));
  assert.ok(!none.includes('cannot search'));
  assert.ok(down.includes('cannot search'));
  assert.ok(down.includes('products-missing'), 'the operator cannot grep the page');
});

test('a result page links every hit at an address that app serves', () => {
  const html = renderHtml('/search?q=shirt', OK_CATS, 9090, OK_PRODS);
  const d = render('/search?q=shirt', OK_CATS, OK_PRODS);
  for (const r of d.results) {
    assert.ok(html.includes(`href="${r.href}"`), `${r.href} is not on the page`);
    assert.ok(r.href.startsWith('/c/') || r.href.startsWith('/p/'),
      `${r.href} is not a route this estate serves`);
  }
});
