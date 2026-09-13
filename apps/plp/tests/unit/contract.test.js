// The contract every app owes the router, the labeller and guard 5.
// A per-app test can assert these; gates/e2e.sh asserts the rest against a
// running estate.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { render } from '../../src/server.js';

const meta = JSON.parse(readFileSync(new URL('../../routes.json', import.meta.url)));

test('render identifies this app, not another', () => {
  assert.equal(render('/x').app, 'plp');
  assert.equal(meta.app, 'plp');
});

test('render echoes the path it was asked for', () => {
  for (const p of ['/', '/deep/path', '/q?a=1']) assert.equal(render(p).path, p);
});

// An INDEPENDENT oracle. The earlier version compared render().routes to
// routes.json -- but render reads that same file at import, so the assertion
// compared the file to itself and could never fail. The expected set is
// written out here on purpose: changing routes.json must now break a test and
// force a deliberate edit, which is what makes it a contract.
const EXPECTED_ROUTES = ["/search", "/c/:category"].map(String);

test("routes.json matches the declared contract for this app", () => {
  assert.deepEqual(meta.routes, EXPECTED_ROUTES);
});

test("render advertises the contract routes", () => {
  assert.deepEqual(render("/").routes, EXPECTED_ROUTES);
});

test('every declared route is servable', () => {
  for (const r of meta.routes) {
    const probe = r.replace(/:[^/]+/g, 'PROBE');
    assert.equal(render(probe).app, 'plp', `route ${r} not served`);
  }
});

// gates/e2e.sh asserts route ownership by fetching a concrete path per route.
// It used to build one by substitution, which assumed every parameter value
// exists -- false since plp started checking the category against its
// catalogue. So plp declares a real instance, and that instance is part of the
// contract: the gate will fetch it and expect 200, so it must actually resolve
// to a category we have. An unknown category here turns the ownership check
// into a check of the 404 path, silently.
const EXPECTED_PROBES = { '/c/:category': '/c/shoes' };

test('routes.json declares the probe the e2e gate will use', () => {
  assert.deepEqual(meta.probes, EXPECTED_PROBES);
});

test('every declared probe names a declared route and really exists', () => {
  for (const [route, probe] of Object.entries(meta.probes)) {
    assert.ok(meta.routes.includes(route), `probe for undeclared route ${route}`);
    assert.ok(probe.startsWith(route.replace(/:[^/]*$/, '')),
      `probe ${probe} is outside route ${route}`);
    assert.equal(render(probe).found, true,
      `the e2e gate will fetch ${probe} and expect 200, but plp does not have it`);
  }
});

test('the health path is the reserved health route, not a business route', () => {
  // Was: "the health path is one of the declared routes". That assertion was
  // right about ROUTABILITY and wrong about how to get it -- it forced every
  // app's health onto a business route, which broke pdp when it started
  // validating SKUs (#24) and would break plp the moment search searches (#35).
  //
  // /__health/<app> is routed by the router directly and is deliberately not
  // declared: it is not part of the contract the estate offers, so no product
  // change can take guard 5 down with it.
  assert.equal(meta.health, `/__health/${meta.app}`);
  assert.ok(!meta.routes.includes(meta.health),
    'the health route must NOT be a declared route -- it is not part of the contract');
});

test('port_offset fits inside a ten-port block', () => {
  assert.ok(Number.isInteger(meta.port_offset));
  assert.ok(meta.port_offset >= 1 && meta.port_offset <= 9);
});
