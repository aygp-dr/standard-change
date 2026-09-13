// The contract every app owes the router, the labeller and guard 5.
// A per-app test can assert these; gates/e2e.sh asserts the rest against a
// running estate.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { render } from '../../src/server.js';

const meta = JSON.parse(readFileSync(new URL('../../routes.json', import.meta.url)));

test('render identifies this app, not another', () => {
  assert.equal(render('/x').app, 'pdp');
  assert.equal(meta.app, 'pdp');
});

test('render echoes the path it was asked for', () => {
  for (const p of ['/', '/deep/path', '/q?a=1']) assert.equal(render(p).path, p);
});

// An INDEPENDENT oracle. The earlier version compared render().routes to
// routes.json -- but render reads that same file at import, so the assertion
// compared the file to itself and could never fail. The expected set is
// written out here on purpose: changing routes.json must now break a test and
// force a deliberate edit, which is what makes it a contract.
const EXPECTED_ROUTES = ["/p/:sku"].map(String);

test("routes.json matches the declared contract for this app", () => {
  assert.deepEqual(meta.routes, EXPECTED_ROUTES);
});

test("render advertises the contract routes", () => {
  assert.deepEqual(render("/").routes, EXPECTED_ROUTES);
});

test('every declared route is servable', () => {
  for (const r of meta.routes) {
    const probe = r.replace(/:[^/]+/g, 'PROBE');
    assert.equal(render(probe).app, 'pdp', `route ${r} not served`);
  }
});

// gates/e2e.sh asserts route ownership by fetching a concrete path per route.
// It builds one by substitution (/p/:sku -> /p/PROBE) unless the app declares
// a real instance, and substitution assumed every parameter value exists --
// which stopped being true the moment pdp started checking the SKU against its
// catalogue, at which point /p/PROBE is correctly a 404 and the ownership
// check fails on a working estate. So pdp declares a real instance, and that
// instance is part of the contract: the gate will fetch it and expect 200.
const EXPECTED_PROBES = { '/p/:sku': '/p/SKU123' };

test('routes.json declares the probe the e2e gate will use', () => {
  assert.deepEqual(meta.probes, EXPECTED_PROBES);
});

test('every declared probe names a declared route and really exists', () => {
  for (const [route, probe] of Object.entries(meta.probes)) {
    assert.ok(meta.routes.includes(route), `probe for undeclared route ${route}`);
    assert.ok(probe.startsWith(route.replace(/:[^/]*$/, '')),
      `probe ${probe} is outside route ${route}`);
    assert.equal(render(probe).found, true,
      `the e2e gate will fetch ${probe} and expect 200, but pdp does not have it`);
  }
});

// Guard 5 requires 200 on the health path, and pdp has no route that is not a
// product page -- so its health path is necessarily a SKU, and a health path
// naming a product the catalogue does not carry reads as "pdp is down".
// `health` was /p/PING while every SKU was a 200; it is a real product now
// because pdp answers 404 for one it does not have.
test('the health path is a product pdp actually serves', () => {
  assert.equal(render(meta.health.split('?')[0]).found, true,
    `guard 5 fetches ${meta.health} and expects 200`);
});

test('the health path is one of the declared routes', () => {
  const hp = meta.health.split('?')[0];
  const covered = meta.routes.some((x) => {
    const prefix = x.replace(/:[^/]*/g, '');
    return prefix === '/' ? hp === '/' : hp.startsWith(prefix);
  });
  assert.ok(covered, `health ${meta.health} is not covered by ${meta.routes}`);
});

test('port_offset fits inside a ten-port block', () => {
  assert.ok(Number.isInteger(meta.port_offset));
  assert.ok(meta.port_offset >= 1 && meta.port_offset <= 9);
});
