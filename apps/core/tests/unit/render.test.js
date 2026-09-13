import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
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

test('every panel entry is a literal in the SOURCE, not merely a string at runtime', () => {
  // This test used to assert `typeof html === 'string'` and was void for the
  // claim it made: TYPE IS NOT PROVENANCE. A row built from
  // `new URL(...).searchParams.get('q')` is a string at runtime and passed,
  // while carrying a request straight into a raw interpolation point. The
  // reviewer demonstrated it by adding such a row; the whole suite stayed
  // green. By this repo's own gate-selftest rule, a check that cannot fail for
  // the thing it names produces no verdict.
  //
  // So assert on the SOURCE TEXT. Every row must be a plain quoted literal --
  // no template substitution, no concatenation, no call expression. That is
  // the rule the comment above PANELS already states; this makes it enforced
  // rather than stated, and leaves intended markup alone.
  const src = readFileSync(new URL('../../src/server.js', import.meta.url), 'utf8');
  const body = src.match(/export const PANELS = \{([\s\S]*?)\n\};/);
  assert.ok(body, 'could not find the PANELS literal in the source');

  const rows = body[1].split('\n')
    .map((l) => l.replace(/\/\/.*$/, '').trim())
    .filter((l) => l.length > 0);

  for (const row of rows) {
    const value = row.slice(row.indexOf(':') + 1).trim().replace(/,$/, '');
    assert.ok(/^'[^']*'$|^"[^"]*"$/.test(value),
      `PANELS row is not a plain quoted literal, so it can carry a request ` +
      `into page()'s raw interpolation: ${row}`);
  }
});

test('the literal check rejects a request-derived row', () => {
  // The negative direction, because a checker that has never rejected anything
  // is one nobody has tested. This is the exact row the reviewer used.
  const evil = "'/evil': `<p>` + new URL(u).searchParams.get('q') + `</p>`,";
  const value = evil.slice(evil.indexOf(':') + 1).trim().replace(/,$/, '');
  assert.ok(!/^'[^']*'$|^"[^"]*"$/.test(value),
    'the literal check accepted a row built from a request');
});
