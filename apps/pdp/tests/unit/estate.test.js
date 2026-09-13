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
