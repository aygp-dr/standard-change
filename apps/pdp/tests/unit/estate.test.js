// plp and pdp must agree about which SKUs exist.
//
// This is the one assertion in issue #17 that no single app's tests can make,
// and the reason the "just copy plp's pattern" answer is not free: the moment
// pdp has its own product list, apps/plp/categories.json and
// apps/pdp/products.json are two files that can disagree, and the disagreement
// is invisible from inside either app. plp links /p/SKU124 from /c/shoes, its
// own tests pass, pdp's own tests pass, and a person clicking the second shoe
// on the category page gets a 404. Every gate is green.
//
// So it is asserted HERE, statically, in `gmake test` -- before anything is
// deployed. (Had pdp fetched its catalogue from external/mock instead, this
// check could only have run against a live estate, i.e. after the deploy it
// exists to prevent. That is a large part of why it does not.)
//
// It reaches across the app boundary on purpose. The invariant belongs to
// neither app -- it belongs to the estate -- and the honest long-term home is
// gates/, once a third app carries catalogue data and the check owes itself a
// negative test. Until then it lives in the suite of the app that 404s.
//
// DIRECTION MATTERS. Every SKU plp LINKS must render on pdp. The converse is
// not required: a product that is in no category is a merchandising decision,
// not a broken link.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { render, status, loadCatalogue, CATALOGUE_FILE } from '../../src/server.js';
// plp's server, imported for the SECOND estate invariant below (#35): plp's
// search now reads pdp's product file, so there is a new way for these two to
// disagree and it is asserted here for the same reason the first one is --
// neither app can see it from inside itself. Importing it binds no port
// (server.js only listens when it is argv[1]).
import {
  render as plpRender, loadProducts as plpLoadProducts,
  PRODUCTS_FILE as PLP_READS,
} from '../../../plp/src/server.js';

const PLP_CATEGORIES = fileURLToPath(
  new URL('../../../plp/categories.json', import.meta.url));

const plp = JSON.parse(readFileSync(PLP_CATEGORIES, 'utf8'));

// A guard on the guard. If plp's file moves or changes shape, this test must
// fail loudly rather than quietly iterate over nothing and report agreement.
test("plp's catalogue is readable and non-empty from here", () => {
  assert.ok(Array.isArray(plp.categories), 'plp/categories.json changed shape');
  assert.ok(plp.categories.length > 0, 'plp lists no categories');
  const linked = plp.categories.flatMap((c) => c.skus || []);
  assert.ok(linked.length > 0, 'plp links no SKUs -- this test would assert nothing');
});

// The assertion, stated against what pdp actually SERVES rather than against
// what its file contains. The file agreeing is not the property anyone cares
// about; the property is that the link works.
test('every SKU plp links from a category page is a 200 on pdp', () => {
  const catalogue = loadCatalogue(CATALOGUE_FILE);
  assert.equal(catalogue.ok, true, `pdp cannot read its own catalogue: ${catalogue.reason}`);

  const broken = [];
  for (const c of plp.categories) {
    for (const sku of c.skus || []) {
      const d = render(`/p/${sku}`, catalogue);
      if (status(d) !== 200) broken.push(`/c/${c.slug} -> /p/${sku} (${status(d)} ${d.reason})`);
    }
  }
  assert.deepEqual(broken, [],
    'plp links products pdp has never heard of; the estate is broken and ' +
    'neither app can see it:\n  ' + broken.join('\n  '));
});

// Named separately because this is the specific example issue #17 gives, and
// because /c/shoes is the category the whole estate links to from OneUI's nav
// and gates/smoke.sh walks as step 3.
test('every shoe on /c/shoes has a product page', () => {
  const shoes = plp.categories.find((c) => c.slug === 'shoes');
  assert.ok(shoes, '/c/shoes is gone; the estate nav links to it from every app');
  for (const sku of shoes.skus) {
    const d = render(`/p/${sku}`);
    assert.equal(status(d), 200, `/c/shoes links /p/${sku}, which pdp does not serve`);
    assert.equal(d.product.sku, sku);
  }
});

// ---- the second estate invariant: plp searches pdp's product data (#35) -----
//
// plp answers /search?q= by reading apps/pdp/products.json directly -- one
// product list in the estate rather than a copy that drifts or an HTTP call
// that makes plp's health depend on pdp being up (the reasoning is in
// apps/plp/src/server.js above PRODUCTS_FILE).
//
// That choice creates exactly one new way for the two apps to disagree, and it
// is a quiet one: pdp moves or renames its file, pdp's own tests stay green
// because pdp knows where its file went, and plp starts answering 503 to every
// search -- including /search?q=ping, which is plp's declared health path, so
// guard 5 reports plp UNHEALTHY for a change made in pdp. Asserted here,
// statically, in `gmake test`, before anything is deployed.
test('plp reads the very file pdp serves from, not a copy of it', () => {
  assert.equal(PLP_READS, CATALOGUE_FILE,
    'plp and pdp are looking at different product files; they will disagree ' +
    'and only a person clicking a search result will find out');
});

test("pdp's product file satisfies plp's reader too", () => {
  const seen = plpLoadProducts(PLP_READS);
  assert.equal(seen.ok, true,
    `plp cannot read pdp's products (${seen.reason}); every search is a 503, ` +
    "and plp's health path is a search");
  assert.equal(seen.products.length,
    loadCatalogue(CATALOGUE_FILE).products.length,
    'plp and pdp see a different number of products in the same file');
});

// Same DIRECTION as the category assertion above: everything plp LINKS must
// render on pdp. A search result is a link like any other, and it is the only
// link in the estate built from pdp's own data by another app.
test('every product plp returns from a search is a 200 on pdp', () => {
  const catalogue = loadCatalogue(CATALOGUE_FILE);
  const broken = [];
  // Search for each product by name, which is the thing #35 added and the only
  // query that can surface a product plp has no other route to.
  for (const p of catalogue.products) {
    const d = plpRender(`/search?q=${encodeURIComponent(p.name)}`);
    for (const r of d.results.filter((x) => x.kind === 'product')) {
      const seen = render(r.href, catalogue);
      if (status(seen) !== 200) broken.push(`search "${p.name}" -> ${r.href} (${status(seen)})`);
    }
  }
  assert.deepEqual(broken, [],
    'plp search links products pdp does not serve:\n  ' + broken.join('\n  '));
});

// The estate's own demo query. gates/smoke.sh walks /search?q=shoes as step 2
// of the journey and OneUI links /search from every app, so a search that
// returns nothing for the one category the whole estate advertises is a broken
// front page even though every status code is 200.
test('the query gates/smoke.sh walks still finds something', () => {
  const d = plpRender('/search?q=shoes');
  assert.equal(d.reason, null, `/search?q=shoes reports ${d.reason}`);
  assert.ok(d.count > 0, 'the estate advertises /c/shoes and search cannot find it');
});
