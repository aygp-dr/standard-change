// The "Add to cart" control on a product page.
//
// pdp's part in the add-to-cart journey is exactly one link, so this suite is
// about three things and nothing else: that the link is THERE on a page that
// found a product, that it is NOT there on either page that did not, and that
// a SKU cannot break out of the href or the document.
//
// It deliberately asserts nothing about what /cart does with `add`. That route
// belongs to core (apps/core/routes.json declares it) and a test here that
// expected a behaviour from it would be pdp failing when core changed.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { fileURLToPath } from 'node:url';
import {
  render, renderHtml, panel, addToCart, loadCatalogue, CATALOGUE_FILE,
} from '../../src/server.js';

const fixture = (n) =>
  fileURLToPath(new URL(`../fixtures/catalogue/${n}`, import.meta.url));
const MISSING = fixture('no-such-file.json');

// ---- the link is on a page that found a product -----------------------------

// SKU123 again, for the reason product.test.js gives: it is the probe, the
// health path and this journey's first hop. If the link is anywhere, it is here.
test('a known product page offers a GET link to /cart?add=<sku>', () => {
  const h = renderHtml('/p/SKU123');
  assert.match(h, /href="\/cart\?add=SKU123"/, 'no add-to-cart link on the product page');
  assert.match(h, /Add to cart/, 'the link has no label a person can read');
});

// A GET, and the whole point of choosing one. A form or a fetch() would make
// the journey unprobeable by curl and unusable without JavaScript.
test('add to cart is a plain link, not a form and not script', () => {
  const h = renderHtml('/p/SKU123');
  const markup = panel(render('/p/SKU123'));
  assert.match(markup, /^<h2>/, 'the panel is still the product panel');
  assert.match(markup, /<a class=cart href="\/cart\?add=SKU123">Add to cart<\/a>/);
  assert.doesNotMatch(markup, /<form|method=|onclick|<script/i,
    'the control was implemented as something other than a link');
  // Nothing in the page turned into a POST target either.
  assert.doesNotMatch(h, /<form/i);
});

test('every product in the shipped catalogue gets a link naming itself', () => {
  for (const p of loadCatalogue(CATALOGUE_FILE).products) {
    const h = renderHtml(`/p/${encodeURIComponent(p.sku)}`);
    assert.match(h, new RegExp(`href="/cart\\?add=${p.sku}"`), `${p.sku} has no link`);
  }
});

// /p/%53KU123 is the same product as /p/SKU123, so it must add the same thing.
// This pins the URL SPELLING, not the choice of `p.sku` over `d.sku` in panel():
// those two are equal by construction (render() matches on exact equality) and
// no test here can separate them.
test('an escaped spelling of the path links to the same cart entry', () => {
  assert.match(renderHtml('/p/%53KU123'), /href="\/cart\?add=SKU123"/);
});

// ---- and NOT on a page that did not ------------------------------------------
//
// The sad paths are the reason this is a test and not a glance at the page. A
// 404 that offers to add the product it has just said it does not have is worse
// than no control at all: it tells a person the product exists.

test('the 404 page does not offer to add a product it has not got', () => {
  const h = renderHtml('/p/NOT-A-REAL-SKU');
  assert.match(h, /Product not found/, 'this was supposed to be the not-found page');
  assert.doesNotMatch(h, /Add to cart/);
  assert.doesNotMatch(h, /\/cart\?add=/);
});

test('the 503 page does not offer to add a product it cannot show', () => {
  for (const c of [loadCatalogue(MISSING), loadCatalogue(fixture('malformed.json'))]) {
    const h = renderHtml('/p/SKU123', c);
    assert.match(h, /Product unavailable/, 'this was supposed to be the unavailable page');
    assert.doesNotMatch(h, /Add to cart/);
    assert.doesNotMatch(h, /\/cart\?add=/);
  }
});

// /p and /p/ name no SKU at all. Same rule, stated separately because it
// reaches the not-found branch by a different route.
test('a product page naming no SKU offers nothing to add', () => {
  for (const p of ['/p', '/p/']) {
    assert.doesNotMatch(renderHtml(p), /Add to cart/, `${p} offered a cart link`);
  }
});

// A page that is not a product page has no panel and therefore no link.
test('a path that is not a product page has no cart link', () => {
  assert.equal(panel(render('/definitely-not-a-route')), '');
});

// ---- escaping: issue #13's class of defect, in an attribute -------------------
//
// The SKU reaches the document twice -- as text and inside an href -- and the
// catalogue is config, which in a deployed environment is whatever someone put
// there. Both interpolations are hostile input until proven otherwise.

const hostile = (sku) => ({
  ok: true, reason: null,
  products: [{ sku, name: 'Hostile', price: 1, currency: 'USD',
               availability: 'in-stock' }],
});

test('a SKU containing markup is escaped in the text and in the href', () => {
  const sku = '<script>alert(1)</script>';
  const h = renderHtml(`/p/${encodeURIComponent(sku)}`, hostile(sku));

  // The document: no live markup anywhere, and the SKU is still visible, escaped.
  assert.doesNotMatch(h, /<script>alert/, 'the SKU executed as markup');
  assert.match(h, /&lt;script&gt;/, 'the SKU is not on the page at all');

  // The href: percent-encoded, so the SKU is one parameter value and not a
  // second attribute, a second tag, or a truncated URL.
  assert.match(h, /href="\/cart\?add=%3Cscript%3Ealert\(1\)%3C%2Fscript%3E"/);
  assert.ok(h.includes('Add to cart'), 'the link vanished instead of being escaped');
});

// The quote-breakout, stated on its own because it escapes the ATTRIBUTE rather
// than the element.
//
// Asserted STRUCTURALLY -- the anchor must equal one exact string -- and not by
// grepping the page for `onmouseover`. Percent-encoding leaves the letters of a
// payload intact (`" onmouseover="` becomes `%22%20onmouseover%3D%22`), so a
// substring search finds the word in a href that is completely inert and would
// have to be written to pass either way. What makes it inert is that the value
// carries no quote to close the attribute with, which is what this checks.
test('a SKU cannot break out of the href attribute', () => {
  const sku = '" onmouseover="alert(1)';
  const link = addToCart(sku);

  assert.equal(link,
    '<a class=cart href="/cart?add=%22%20onmouseover%3D%22alert(1)">Add to cart</a>',
    'the anchor is not one tag with exactly a class and a href');

  const href = link.match(/href="([^"]*)"/)[1];
  assert.doesNotMatch(href, /["'<>\s]/, 'the href value carries raw attribute punctuation');
  assert.equal(decodeURIComponent(href), `/cart?add=${sku}`, 'the SKU did not survive');

  // Same anchor, unchanged, once the page is built around it.
  const h = renderHtml(`/p/${encodeURIComponent(sku)}`, hostile(sku));
  assert.ok(h.includes(link), 'the page rendered a different anchor than addToCart did');
  assert.doesNotMatch(h, /add="/, 'the href attribute was closed early');
});

// & and # are the encoding bugs that are NOT security bugs and would ship
// silently: the link still looks fine and core receives the wrong SKU.
test('a SKU with URL punctuation stays one parameter value', () => {
  for (const sku of ['A&B=1', 'A#B', 'A B', 'A/B', 'A?B']) {
    const link = addToCart(sku);
    const got = link.match(/href="\/cart\?add=([^"]*)"/);
    assert.ok(got, `${sku} produced no href`);
    assert.equal(decodeURIComponent(got[1]), sku,
      `${sku} does not survive the round trip through the URL`);
    assert.doesNotMatch(got[1], /[&#?/ ]/, `${sku} left punctuation raw in the query`);
  }
});

// The unit under the page, so a failure points at the encoder rather than at
// whichever of the assertions above happened to run first.
test('addToCart emits one anchor with a percent-encoded SKU', () => {
  assert.equal(addToCart('SKU123'),
    '<a class=cart href="/cart?add=SKU123">Add to cart</a>');
  assert.equal(addToCart('<>&"\''),
    '<a class=cart href="/cart?add=%3C%3E%26%22&#39;">Add to cart</a>');
});

// BOTH encodings are load-bearing, and the apostrophe is what proves it.
//
// encodeURIComponent does not escape ' (nor ! ~ * ( ) ) -- they are legal in a
// URI component -- so ' arrives at the attribute raw and esc() is the only
// thing that turns it into &#39;. Delete esc() from addToCart and this test
// fails. Without this case it would not: every other payload in this file is
// made inert by percent-encoding alone, so the suite would have passed with the
// second layer removed, which is a suite that cannot see half of what it claims.
test("esc() handles the characters encodeURIComponent is entitled to leave alone", () => {
  assert.equal(addToCart("a'b"),
    '<a class=cart href="/cart?add=a&#39;b">Add to cart</a>',
    "an apostrophe reached the href unescaped: esc() is missing or bypassed");

  // ...and encodeURIComponent handles what esc() is entitled to leave alone: &
  // is not special in HTML attribute VALUES the way it is in a query string.
  assert.equal(addToCart('a&b'),
    '<a class=cart href="/cart?add=a%26b">Add to cart</a>');
});
