// OneUI is imported by every app, so a defect here is a defect in all of them.
// Until this file there were no tests on it at all -- the shared surface with
// the largest blast radius in the repo was the only module nothing asserted.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { esc, page, VERSION } from '../oneui.js';

const ESTATE = [{ app: 'core', port_offset: 1, routes: ['/'] }];
const d = (over = {}) => ({ app: 'core', path: '/', sha: 'abc1234', block: '0', ...over });

test('esc neutralises every character that can leave a text context', () => {
  assert.equal(esc('<script>'), '&lt;script&gt;');
  assert.equal(esc('a"b'), 'a&quot;b');
  assert.equal(esc("a'b"), 'a&#39;b');
  // & must be escaped FIRST or the replacements are themselves re-escaped into
  // nonsense (&lt; -> &amp;lt;). The single-pass character class makes that
  // impossible to get wrong by reordering.
  assert.equal(esc('&lt;'), '&amp;lt;');
  assert.equal(esc(null), '');
  assert.equal(esc(undefined), '');
});

// The regression. Each of these reached the document verbatim before this fix,
// on every app, in every environment, including the rollback target.
test('a request path cannot inject markup', () => {
  const html = page(d({ path: '/<script>alert(1)</script>' }), ESTATE, '#fff');
  assert.ok(!html.includes('<script>alert(1)'), 'script tag survived escaping');
  assert.ok(html.includes('&lt;script&gt;alert(1)&lt;/script&gt;'), 'path not rendered at all');
});

test('a path cannot break out of an attribute or close the style block', () => {
  for (const p of ['/"onmouseover="alert(1)', '/</style><script>alert(1)</script>']) {
    const html = page(d({ path: p }), ESTATE, '#fff');
    assert.ok(!html.includes('onmouseover="alert'), `attribute break: ${p}`);
    assert.ok(!html.includes('<script>alert(1)'), `style break: ${p}`);
  }
});

// The other three interpolated values. app and block come from config and sha
// from the deployer, so they are less exposed than path -- but "less exposed"
// is how path got here. The renderer escapes what it interpolates, full stop.
test('every interpolated value is escaped, not just the obvious one', () => {
  const html = page(d({ app: '<b>x</b>', sha: '<i>y</i>', block: '<u>z</u>' }), ESTATE, '#fff');
  for (const t of ['<b>x</b>', '<i>y</i>', '<u>z</u>']) {
    assert.ok(!html.includes(t), `unescaped: ${t}`);
  }
});

test('a valid document is still produced', () => {
  const html = page(d(), ESTATE, '#e8f0ff');
  assert.ok(html.startsWith('<!doctype html>'));
  assert.ok(html.includes('OneUI ' + VERSION));
  assert.ok(html.includes('#e8f0ff'), 'background not applied');
});

// The version must describe the SURFACE, not the intent of whoever bumped it.
// The first version of this test hardcoded "1.0.x and arity 3" and failed the
// moment a legitimate minor arrived -- it was pinning a fact, not a rule. The
// rule is semver: growing the surface is a minor, and shipping that as a patch
// is what makes a pinned dependency lie about what it needs.
test('the version matches the surface it exposes', () => {
  const [maj, min, patch] = VERSION.split('.').map(Number);
  assert.ok([maj, min, patch].every(Number.isInteger), `not semver: ${VERSION}`);

  // page(d, estate, background) is the 1.0 surface. Optional parameters do not
  // count toward Function.length, so arity 3 means nothing was ADDED.
  const REQUIRED = 3;
  assert.equal(page.length, REQUIRED, 'page() required arity changed');

  // Optional params are additive, so they are a minor, not a patch.
  const optional = page.toString().includes('extra =');
  if (optional) {
    assert.ok(min >= 1, `page() takes an optional slot, so this is at least a minor, not ${VERSION}`);
  } else {
    assert.equal(min, 0, `nothing was added to the surface, so ${VERSION} overstates the change`);
  }
});
