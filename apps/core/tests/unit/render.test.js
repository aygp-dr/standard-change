import { test } from 'node:test';
import assert from 'node:assert/strict';
import { render, panel, PANELS } from '../../src/server.js';

test('core render carries app identity and path', () => {
  const r = render('/x');
  assert.equal(r.app, 'core');
  assert.equal(r.path, '/x');
});

// The panel table is the seam every per-route change lands in. These tests are
// about the SEAM, not about any row -- a row's own test ships with the row.
test('panel returns nothing for a route with no entry', () => {
  assert.equal(panel('/'), '');
  assert.equal(panel('/nothing-here'), '');
});

test('panel strips the query string before looking the route up', () => {
  // Without this a bookmarked /cart?from=pdp silently renders no panel.
  PANELS['/__probe'] = '<p>probe</p>';
  try {
    assert.equal(panel('/__probe?a=1&b=2'), '<p>probe</p>');
    assert.equal(panel('/__probe'), '<p>probe</p>');
  } finally {
    delete PANELS['/__probe'];
  }
});

test('every panel entry is a static string, not a function of the request', () => {
  // page() interpolates `extra` raw. A row that is not a literal is a row that
  // can carry a request into the document unescaped.
  for (const [route, html] of Object.entries(PANELS)) {
    assert.equal(typeof html, 'string', `${route} is not a string`);
  }
});
