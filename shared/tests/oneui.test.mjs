// OneUI is imported by every app, so a defect here is a defect in all of them.
// Until this file there were no tests on it at all -- the shared surface with
// the largest blast radius in the repo was the only module nothing asserted.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { esc, page, environment, HOST, VERSION } from '../oneui.js';

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

// ---- the estate nav ---------------------------------------------------------
//
// The nav is rendered on every page of every app, so a link it invents is a
// broken link in four apps at once -- and gates/smoke.sh is the only gate that
// follows links, so it is the only thing that can see it. It did: /p/SKU1,
// substituted for /p/:sku, 404ed as soon as pdp started checking the SKU
// against a catalogue (#17).

test('the nav links the instance the app declares, not one it invented', () => {
  const estate = [{ app: 'pdp', port_offset: 3, routes: ['/p/:sku'],
                    probes: { '/p/:sku': '/p/SKU123' } }];
  const html = page(d({ app: 'pdp' }), estate, '#fff');
  assert.ok(html.includes('href="/p/SKU123"'), 'the declared probe is not linked');
  assert.ok(!html.includes('/p/SKU1"'), 'the invented instance is still linked');
});

test('a route with no declared probe still gets a link', () => {
  // Substitution stays the fallback -- gates/e2e.sh does the same -- so an app
  // that declares nothing is no worse off than before.
  const estate = [{ app: 'plp', port_offset: 2, routes: ['/c/:category'] }];
  const html = page(d({ app: 'plp' }), estate, '#fff');
  assert.ok(html.includes('href="/c/shoes"'));
});

test('a probe out of routes.json cannot inject markup', () => {
  // routes.json is config: in a deployed environment it is whatever is on
  // disk, which makes it exactly as trusted as the request line was in 1.0.1.
  const estate = [{ app: '<b>x</b>', port_offset: 1, routes: ['/p/:sku'],
                    probes: { '/p/:sku': '/p/"><script>alert(1)</script>' } }];
  const html = page(d(), estate, '#fff');
  assert.ok(!html.includes('<script>alert(1)'), 'probe escaped the attribute');
  assert.ok(!html.includes('<b>x</b>'), 'app name was interpolated raw');
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

// ---- where am I (issue #15) -------------------------------------------------
//
// The footer used to end in `block <BLOCK>`, a string the deployer exported,
// and the page never said what KIND of environment it was. These pin the
// derivation: the port map is the oracle, and the port is a fact about the
// running process.

test('the port map decides the tier, across every boundary', () => {
  const tier = (p) => environment(p).tier;
  // the dev tier and both ends of it
  assert.equal(tier(9000), 'dev');
  assert.equal(tier(9021), 'dev');
  assert.equal(tier(9099), 'dev');
  // the team tier -- real environments that cannot promote
  assert.equal(tier(9100), 'team');
  assert.equal(tier(9199), 'team');
  // the protected tier -- the path to production
  assert.equal(tier(9200), 'protected');
  assert.equal(tier(9299), 'protected');
  // off the map at both ends. 8999 and 9300 are one port outside, and the
  // boundaries are where an off-by-one would put production in the dev tier.
  for (const p of [80, 8080, 8999, 9300, 10000]) assert.equal(tier(p), 'unknown', `port ${p}`);
});

test('each tier carries the sentence that makes it mean something', () => {
  assert.match(environment(9021).note, /disposable/);
  assert.match(environment(9123).note, /cannot promote/);
  assert.match(environment(9201).note, /path to production/);
  assert.match(environment(8080).note, /outside the project port map/);
});

test('the ten-port block names the environment inside the protected tier', () => {
  // The mapping targets/node/deploy.sh deploys by. An app in the staging block
  // listens on 9201-9204, not on 9200: every port in the block is staging.
  for (const p of [9200, 9201, 9202, 9203, 9204, 9205]) {
    assert.equal(environment(p).env, 'staging', `port ${p}`);
    assert.equal(environment(p).colour, null, `port ${p} invented a colour`);
  }
  for (const p of [9210, 9211, 9214]) {
    assert.equal(environment(p).env, 'production');
    assert.equal(environment(p).colour, 'blue', `port ${p}`);
  }
  for (const p of [9220, 9221, 9224]) {
    assert.equal(environment(p).env, 'production');
    assert.equal(environment(p).colour, 'green', `port ${p}`);
  }
  // the front. switch.sh asks it which colour is live; it is production too.
  assert.equal(environment(9230).env, 'production');
});

test('a dev or team block is named by its number, not invented', () => {
  assert.deepEqual(
    [environment(9000), environment(9021), environment(9095), environment(9123)].map((w) => w.env),
    ['block 0', 'block 2', 'block 9', 'block 12']);
  // A reserved protected block has no name either, and must not borrow one.
  assert.equal(environment(9250).env, 'block 25');
  assert.equal(environment(9250).colour, null);
});

test('a port that is not a port produces "unknown", not a guess', () => {
  for (const p of [undefined, null, '', 'staging', NaN, -1, 0, 9200.5, {}]) {
    const w = environment(p);
    assert.equal(w.tier, 'unknown', `${String(p)} was placed in a tier`);
    assert.equal(w.env, null);
    assert.equal(w.colour, null);
  }
});

test('the page states host, tier and environment', () => {
  const html = page(d({ host: 'hydra', port: 9021 }), ESTATE, '#fff');
  assert.match(html, /hydra:9021 · <span class=t>dev<\/span> · block 2/);
});

// The unit-tested claim that stands in for deploying to the protected tier:
// the SAME renderer, handed the staging port, says protected and staging.
test('the same renderer says protected · staging for the staging block', () => {
  const html = page(d({ host: 'hydra', port: 9200 }), ESTATE, '#fff');
  assert.match(html, /hydra:9200 · <span class=t>protected<\/span> · staging/);
  assert.ok(html.includes('class="e protected"'), 'the tier is not marked on the element');
});

test('production says its colour, so the page agrees with switch.sh status', () => {
  assert.match(page(d({ host: 'h', port: 9210 }), ESTATE, '#fff'),
               /<span class=t>protected<\/span> · production · <b>blue<\/b>/);
  assert.match(page(d({ host: 'h', port: 9220 }), ESTATE, '#fff'),
               /<span class=t>protected<\/span> · production · <b>green<\/b>/);
});

// Guard 5's defect, in miniature. BLOCK is whatever the deployer exported; if
// it could move the tier line, a dev block could call itself production.
test('the declared block cannot change what the page says the tier is', () => {
  const html = page(d({ host: 'hydra', port: 9021, block: 'production-blue' }), ESTATE, '#fff');
  assert.match(html, /hydra:9021 · <span class=t>dev<\/span> · block 2/);
  assert.ok(!/production/.test(html.split('<p class=v>')[0]),
            'a deployer-supplied string reached the environment line');
  // It is not hidden either -- it is demoted to the version line, as a claim.
  assert.match(html, /declared block <code>production-blue<\/code>/);
});

test('a caller that says nothing about where it is gets "unknown", not a tier', () => {
  const html = page(d(), ESTATE, '#fff');
  assert.match(html, /\?:\? · <span class=t>unknown<\/span>/);
});

// The whole point of #13: everything interpolated goes through esc(). host and
// port are new interpolations, and "it comes from config" is what was said
// about block before a request path proved the rule has no exceptions.
test('host and port are escaped like everything else', () => {
  const html = page(d({ host: '<img src=x onerror=alert(1)>', port: 9021 }), ESTATE, '#fff');
  assert.ok(!html.includes('<img src=x'), 'host reached the document as markup');
  assert.ok(html.includes('&lt;img src=x onerror=alert(1)&gt;'), 'host not rendered at all');

  // The environment line puts the tier note in an ATTRIBUTE, so a value that
  // closes the quote is the interesting case even though the tier text itself
  // is ours: the port is rendered inside that element.
  const q = page(d({ host: 'h" onmouseover="alert(1)', port: 9200 }), ESTATE, '#fff');
  assert.ok(!q.includes('onmouseover="alert'), 'host broke out of an attribute');
  // The port is coerced to a number before it is rendered, so a string that is
  // not a port never reaches the document at all -- it renders as ?, which is
  // also the honest answer. Belt and braces: esc() still runs on it.
  const p = page(d({ host: 'h', port: '9200"><script>alert(1)</script>' }), ESTATE, '#fff');
  assert.ok(!p.includes('<script>alert(1)'), 'port broke out and injected a script');
  assert.match(p, /h:\? · <span class=t>unknown<\/span>/);
});

test('the host is read from the machine, not from the environment', () => {
  // process.env.HOSTNAME is a string anyone can export; os.hostname() is not.
  assert.equal(typeof HOST, 'string');
  assert.ok(HOST.length > 0);
});

// The shared stylesheet is part of the surface. An app may rely on `.b`
// existing, so removing it is a breaking change to every app at once -- which
// is the whole point of this change being here rather than in one app.
test('the shared stylesheet carries the badge class', () => {
  const html = page({ app: 'x', path: '/', sha: 'abc1234', block: '0' },
                    [{ app: 'x', port_offset: 1, routes: ['/'] }], '#fff');
  assert.match(html, /\.b\{background:/, '.b missing from the shared stylesheet');
});
