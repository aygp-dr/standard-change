// What pdp does when the URL asks for a product it cannot show.
//
// Two distinct failures live here and the whole point is that they stay
// distinct: a SKU that is not in the catalogue (the catalogue is fine, the
// answer is no) and a catalogue that could not be loaded at all (we cannot
// answer). Both render a page; they must not look the same to an operator, or
// a deleted config file gets triaged as a delisted product.
//
// Same shape as apps/plp/tests/unit/category.test.js, deliberately. plp and
// pdp face the same question about a parameter they do not control, and an
// estate where /c/nope is a 404 and /p/nope is a 200 has two stories about
// what "we do not carry that" means.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { fileURLToPath } from 'node:url';
import {
  render, renderHtml, status, owns, skuOf, money, loadCatalogue, CATALOGUE_FILE,
  badge,
} from '../../src/server.js';

const fixture = (n) =>
  fileURLToPath(new URL(`../fixtures/catalogue/${n}`, import.meta.url));
// A path that is guaranteed not to exist. "missing" has to be a real state,
// not a mock: the app reads the filesystem, so the test deletes the file from
// the app's point of view by pointing it somewhere there is nothing.
const MISSING = fixture('no-such-file.json');

// ---- the catalogue that actually ships --------------------------------------

test('the shipped catalogue loads and is well formed', () => {
  const c = loadCatalogue(CATALOGUE_FILE);
  assert.equal(c.ok, true, `shipped catalogue rejected: ${c.reason}`);
  assert.ok(c.products.length > 0, 'the shipped catalogue is empty');
});

// SKU123 is not an arbitrary choice and it is not only a test's convenience:
// it is pdp's `health` path (guard 5 requires 200 on it), the `probes` entry
// gates/e2e.sh uses to check route ownership, step 4 of the gates/smoke.sh
// journey, and the add-to-cart journey's first hop. If it stops being a real
// product, four different gates go red for four different-looking reasons.
test('SKU123 is a real product, because four gates depend on it', () => {
  const d = render('/p/SKU123');
  assert.equal(d.found, true);
  assert.equal(d.catalogue, 'ok');
  assert.equal(status(d), 200);
  assert.equal(typeof d.product.name, 'string');
  assert.ok(d.product.name.length > 0);
  assert.equal(typeof d.product.price, 'number');
  assert.equal(typeof d.product.availability, 'string');
});

// ---- a known SKU renders the product ----------------------------------------

test('a known SKU renders name, price and availability, not the path', () => {
  const h = renderHtml('/p/SKU123');
  const p = render('/p/SKU123').product;
  assert.ok(h.startsWith('<!doctype html>'));
  assert.ok(h.includes(p.name), 'the product name is not on the page');
  assert.ok(h.includes(money(p.price, p.currency)), 'the price is not on the page');
  assert.match(h, /In stock|Low stock|Out of stock/, 'availability is not on the page');
  assert.ok(h.includes('SKU123'), 'the page does not say which product it is about');
  // The defect this issue names: the page used to be about pdp, not about the
  // product. A page whose only nouns are the app and the path has not changed.
  assert.doesNotMatch(h, /Product not found|Product unavailable/);
});

// Availability is prose on the page, not the slug out of the file. A page that
// says `out-of-stock` is showing a person the database.
test('availability is rendered as prose, not as the stored slug', () => {
  const h = renderHtml('/p/SKU125');   // out-of-stock in the shipped catalogue
  assert.match(h, /Out of stock/);
  assert.doesNotMatch(h, /out-of-stock/);
});

// ---- price and availability are badges --------------------------------------

const OPEN = /<span style="display:inline-block[^"]*"[^>]*>/g;

test('price and availability render as badges, not as inline body text', () => {
  const h = renderHtml('/p/SKU125');            // out-of-stock in the catalogue
  assert.match(h, /<span style="[^"]*">\$139\.00<\/span>/,
    'the price is not in a badge');
  assert.match(h, /<span style="[^"]*">Out of stock<\/span>/,
    'availability is not in a badge');
  // Distinguishable, not merely wrapped. Two badges in the same colour would
  // satisfy the assertions above and show a person nothing.
  const styles = (h.match(OPEN) || []).map((t) => t.match(/style="([^"]*)"/)[1]);
  assert.equal(styles.length, 2, `expected two badges, got ${styles.length}`);
  assert.notEqual(styles[0], styles[1], 'the two badges are styled identically');
});

test('an availability the catalogue invents cannot reach the style attribute', () => {
  // page() interpolates the panel RAW (shared/oneui.js), and availability is a
  // free string that loadCatalogue's shape check accepts. So the swatch is
  // looked up in a table of literals and never built from the stored slug.
  const evil = '" onmouseover="alert(1)';
  const catalogue = { ok: true, reason: null, products: [
    { sku: 'SKUX', name: 'Probe', price: 1, currency: 'USD', availability: evil }] };
  const h = renderHtml('/p/SKUX', catalogue);
  for (const tag of h.match(/<span [^>]*>/g) || [])
    assert.doesNotMatch(tag, /onmouseover/,
      `a catalogue-derived value reached a raw attribute: ${tag}`);
  assert.ok(h.includes('#374151'),
    'an unrecognised availability should fall through to the neutral swatch');
  // Still shown, escaped -- an availability we do not recognise is information.
  assert.ok(h.includes('&quot; onmouseover=&quot;alert(1)'),
    'the unrecognised slug was dropped rather than escaped');
});

test('badge escapes the text it is handed', () => {
  const h = badge('<b>x</b>', 'red');
  assert.ok(h.includes('&lt;b&gt;x&lt;/b&gt;'), 'badge did not escape its text');
  assert.doesNotMatch(h, /<b>/, 'badge emitted live markup from its text');
});

test('money formats to two places and names the currency', () => {
  assert.equal(money(89, 'USD'), '$89.00');
  assert.equal(money(74.5, 'USD'), '$74.50');
  assert.equal(money(10, 'JPY'), '10.00 JPY', 'an unknown currency is named, not dropped');
});

// ---- unknown SKU ------------------------------------------------------------

test('an unknown SKU is a not-found page, not a pretend product', () => {
  const d = render('/p/NOT-A-REAL-SKU');
  assert.equal(d.found, false);
  assert.equal(d.reason, 'unknown-sku');
  assert.equal(d.catalogue, 'ok', 'the catalogue loaded; say so');
  assert.equal(d.product, null);
  assert.equal(status(d), 404);
});

test('a product page with no SKU named is an unknown product', () => {
  for (const p of ['/p/', '/p']) {
    const d = render(p);
    assert.equal(d.found, false, `${p} claimed to exist`);
    assert.equal(d.reason, 'unknown-sku');
    assert.equal(status(d), 404);
  }
});

// ---- catalogue unavailable --------------------------------------------------

test('a missing catalogue is a 503 and says it is missing', () => {
  const d = render('/p/SKU123', loadCatalogue(MISSING));
  assert.equal(d.found, false);
  assert.equal(d.catalogue, 'unavailable');
  assert.equal(d.reason, 'catalogue-missing');
  assert.equal(status(d), 503, 'a config we cannot read is not a 404');
});

test('a malformed catalogue does not crash the app', () => {
  for (const f of ['malformed.json', 'wrong-shape.json', 'bad-entry.json',
                   'price-not-a-number.json']) {
    const d = render('/p/SKU123', loadCatalogue(fixture(f)));
    assert.equal(d.catalogue, 'unavailable', `${f} was accepted`);
    assert.equal(d.reason, 'catalogue-malformed', f);
    assert.equal(status(d), 503, f);
    assert.doesNotThrow(() => renderHtml('/p/SKU123', loadCatalogue(fixture(f))), f);
  }
});

// THE distinguishing test. Without it, an operator reading the response cannot
// tell "we lost the config" from "that SKU is not ours" -- the two have a
// similar user-visible page and completely different owners.
test('an empty catalogue is not the same response as a missing one', () => {
  const empty   = render('/p/SKU123', loadCatalogue(fixture('empty.json')));
  const missing = render('/p/SKU123', loadCatalogue(MISSING));

  assert.equal(empty.catalogue, 'ok');
  assert.equal(empty.reason, 'unknown-sku');
  assert.equal(status(empty), 404);

  assert.equal(missing.catalogue, 'unavailable');
  assert.equal(missing.reason, 'catalogue-missing');
  assert.equal(status(missing), 503);

  assert.notEqual(empty.catalogue, missing.catalogue);
  assert.notEqual(empty.reason, missing.reason);
  assert.notEqual(status(empty), status(missing));
});

// ---- the HTML half ----------------------------------------------------------
//
// gates/e2e.sh asserts text/html for a browser GET and gates/smoke.sh requires
// a body of real size; these assert that what comes back is a page a person
// can read, and that the status code is the same one the JSON representation
// reports. In plp an earlier draft let the HTML branch write its own 200, so
// the browser saw "no results" while every machine on the path recorded a
// success. One status() function, both representations, is the fix.

const isPage = (h) => h.startsWith('<!doctype html>') && h.length > 200;

test('every sad path renders a real HTML page, not a JSON blob', () => {
  const cases = [
    ['/p/NOT-A-REAL-SKU', loadCatalogue(CATALOGUE_FILE), /Product not found/],
    ['/p/SKU123',         loadCatalogue(MISSING),        /Product unavailable/],
    ['/p/SKU123',         loadCatalogue(fixture('malformed.json')), /Product unavailable/],
  ];
  for (const [p, c, says] of cases) {
    const h = renderHtml(p, c);
    assert.ok(isPage(h), `${p} did not render a page`);
    assert.match(h, says, `${p} did not say what went wrong`);
  }
});

test('the unavailable page names the fault; the not-found page does not', () => {
  assert.match(renderHtml('/p/SKU123', loadCatalogue(MISSING)), /catalogue-missing/);
  assert.doesNotMatch(renderHtml('/p/NOPE'), /catalogue-(missing|malformed)/);
});

// The SKU comes straight off the wire and is interpolated into the document.
// This is issue #13's class of defect, one app over.
test('a SKU cannot inject markup', () => {
  const h = renderHtml('/p/<script>alert(1)</script>');
  assert.doesNotMatch(h, /<script>alert/);
  assert.match(h, /&lt;script&gt;/);
});

test('a product name out of the catalogue cannot inject markup either', () => {
  // The catalogue is config: in a deployed environment it is whatever someone
  // put there, which makes it just as much "off the wire" as the URL.
  const c = { ok: true, reason: null, products: [
    { sku: 'X', name: '<img src=x onerror=alert(1)>', price: 1, currency: 'USD',
      availability: '<b>in-stock</b>' },
  ] };
  const h = renderHtml('/p/X', c);
  assert.doesNotMatch(h, /<img src=x/);
  assert.doesNotMatch(h, /<b>in-stock<\/b>/);
  assert.match(h, /&lt;img src=x/);
});

// ---- routing ----------------------------------------------------------------

test('skuOf tells a product page from anything else', () => {
  assert.equal(skuOf('/cart'), null);
  assert.equal(skuOf('/search?q=SKU123'), null);
  assert.equal(skuOf('/p/SKU123'), 'SKU123');
  assert.equal(skuOf('/p/SKU123?ref=plp'), 'SKU123');
  assert.equal(skuOf('/p/SKU123/'), 'SKU123');
  assert.equal(skuOf('/p/%53KU123'), 'SKU123');
  // a malformed percent-escape must not throw on the request path
  assert.doesNotThrow(() => skuOf('/p/%'));
});

test('pdp owns its declared route and nothing else', () => {
  assert.equal(owns('/p/SKU123'), true);
  assert.equal(owns('/p/anything-at-all'), true, 'the prefix is still ours');
  assert.equal(owns('/cart'), false);
  assert.equal(owns('/c/shoes'), false);
  assert.equal(owns('/definitely-not-a-route'), false);
});

test('a path that is not a product page is untouched by the catalogue', () => {
  for (const c of [loadCatalogue(MISSING), loadCatalogue(fixture('malformed.json'))]) {
    const d = render('/definitely-not-a-route', c);
    assert.equal(d.sku, undefined, 'that is not a product page');
    assert.equal(d.catalogue, undefined);
    assert.equal(status(d), 404);
  }
});
