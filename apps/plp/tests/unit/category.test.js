// What plp does when the URL asks for a category it cannot show.
//
// Two distinct failures live here and the whole point is that they stay
// distinct: a category that is not in the catalogue (the catalogue is fine,
// the answer is no) and a catalogue that could not be loaded at all (we cannot
// answer). Both render a no-results page; they must not look the same to an
// operator, or a deleted config file gets triaged as an empty catalogue.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { fileURLToPath } from 'node:url';
import {
  render, renderHtml, status, owns, categoryOf, loadCatalogue, CATALOGUE_FILE,
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
  assert.ok(c.categories.length > 0, 'the shipped catalogue is empty');
});

// shoes is not an arbitrary choice: shared/oneui.js renders /c/shoes as the
// nav link for /c/:category on EVERY app in the estate, and gates/smoke.sh
// walks /c/shoes as step 3 of the journey. If it stops being a real category,
// every page in the estate links to a no-results page and smoke goes red.
test('shoes is a real category, because the whole estate links to it', () => {
  const d = render('/c/shoes');
  assert.equal(d.found, true);
  assert.equal(d.catalogue, 'ok');
  assert.ok(d.results.length > 0, '/c/shoes has no results');
  assert.equal(status(d), 200);
});

// ---- unknown category -------------------------------------------------------

test('an unknown category is a no-results page, not a pretend category', () => {
  const d = render('/c/not-a-real-category');
  assert.equal(d.found, false);
  assert.equal(d.reason, 'unknown-category');
  assert.equal(d.catalogue, 'ok', 'the catalogue loaded; say so');
  assert.deepEqual(d.results, []);
  assert.equal(status(d), 404);
});

test('a category page with no category named is an unknown category', () => {
  for (const p of ['/c/', '/c']) {
    const d = render(p);
    assert.equal(d.found, false, `${p} claimed to exist`);
    assert.equal(d.reason, 'unknown-category');
    assert.equal(status(d), 404);
  }
});

// ---- catalogue unavailable --------------------------------------------------

test('a missing catalogue renders no-results and says it is missing', () => {
  const d = render('/c/shoes', loadCatalogue(MISSING));
  assert.equal(d.found, false);
  assert.equal(d.catalogue, 'unavailable');
  assert.equal(d.reason, 'catalogue-missing');
  assert.equal(status(d), 503, 'a config we cannot read is not a 404');
});

test('a malformed catalogue does not crash the app', () => {
  for (const f of ['malformed.json', 'wrong-shape.json', 'bad-entry.json']) {
    const d = render('/c/shoes', loadCatalogue(fixture(f)));
    assert.equal(d.catalogue, 'unavailable', `${f} was accepted`);
    assert.equal(d.reason, 'catalogue-malformed', f);
    assert.equal(status(d), 503, f);
    assert.doesNotThrow(() => renderHtml('/c/shoes', loadCatalogue(fixture(f))), f);
  }
});

// THE distinguishing test. Without it, an operator reading the response cannot
// tell "we lost the config" from "the catalogue has nothing here" -- the two
// have the same user-visible page and completely different owners.
test('an empty catalogue is not the same response as a missing one', () => {
  const empty   = render('/c/shoes', loadCatalogue(fixture('empty.json')));
  const missing = render('/c/shoes', loadCatalogue(MISSING));

  assert.equal(empty.catalogue, 'ok');
  assert.equal(empty.reason, 'unknown-category');
  assert.equal(status(empty), 404);

  assert.equal(missing.catalogue, 'unavailable');
  assert.equal(missing.reason, 'catalogue-missing');
  assert.equal(status(missing), 503);

  assert.notEqual(empty.catalogue, missing.catalogue);
  assert.notEqual(status(empty), status(missing));
});

// ---- the HTML half ----------------------------------------------------------
//
// The gate in gates/e2e.sh asserts text/html for a browser GET; these assert
// that what comes back is a page a person can read, and that the status code
// is the same one the JSON representation reports. An earlier draft let the
// HTML branch write its own 200, so the browser saw "no results" while every
// machine on the path recorded a success.

const isPage = (h) => h.startsWith('<!doctype html>') && h.length > 200;

test('every no-results case renders a real HTML page', () => {
  const cases = [
    ['/c/not-a-real-category', loadCatalogue(CATALOGUE_FILE)],
    ['/c/shoes',               loadCatalogue(MISSING)],
    ['/c/shoes',               loadCatalogue(fixture('malformed.json'))],
  ];
  for (const [p, c] of cases) {
    const h = renderHtml(p, c);
    assert.ok(isPage(h), `${p} did not render a page`);
    assert.match(h, /No results/, `${p} did not say there are no results`);
  }
});

test('a known category renders its results, with links to the product app', () => {
  const h = renderHtml('/c/shoes');
  assert.ok(isPage(h));
  assert.doesNotMatch(h, /No results/);
  for (const sku of render('/c/shoes').results)
    assert.ok(h.includes(`href="/p/${sku}"`), `no link to ${sku}`);
});

test('the unavailable page names the fault; the unknown page does not', () => {
  assert.match(renderHtml('/c/shoes', loadCatalogue(MISSING)), /catalogue-missing/);
  assert.doesNotMatch(renderHtml('/c/nope'), /catalogue-(missing|malformed)/);
});

// The slug comes straight off the wire and is interpolated into the document.
test('a category slug cannot inject markup', () => {
  const h = renderHtml('/c/<script>alert(1)</script>');
  assert.doesNotMatch(h, /<script>alert/);
  assert.match(h, /&lt;script&gt;/);
});

// ---- everything that is not a category page ---------------------------------

test('/search is untouched by the catalogue', () => {
  for (const c of [loadCatalogue(MISSING), loadCatalogue(fixture('malformed.json'))]) {
    const d = render('/search?q=ping', c);
    assert.equal(d.found, true, 'a bad catalogue took /search down with it');
    assert.equal(d.results, undefined, '/search is not a category page');
    assert.equal(d.catalogue, undefined);
    assert.equal(status(d), 200);
  }
});

test('categoryOf tells a category page from anything else', () => {
  assert.equal(categoryOf('/search?q=shoes'), null);
  assert.equal(categoryOf('/cart'), null);
  assert.equal(categoryOf('/c/shoes'), 'shoes');
  assert.equal(categoryOf('/c/shoes?page=2'), 'shoes');
  assert.equal(categoryOf('/c/shoes/'), 'shoes');
  assert.equal(categoryOf('/c/%73hoes'), 'shoes');
  // a malformed percent-escape must not throw on the request path
  assert.doesNotThrow(() => categoryOf('/c/%'));
});

test('plp owns its declared routes and nothing else', () => {
  assert.equal(owns('/search'), true);
  assert.equal(owns('/c/shoes'), true);
  assert.equal(owns('/c/anything-at-all'), true, 'the prefix is still ours');
  assert.equal(owns('/cart'), false);
  assert.equal(owns('/definitely-not-a-route'), false);
});
