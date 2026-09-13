// The contract every app owes the router, the labeller and guard 5.
// A per-app test can assert these; gates/e2e.sh asserts the rest against a
// running estate.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { render } from '../../src/server.js';

const meta = JSON.parse(readFileSync(new URL('../../routes.json', import.meta.url)));

test('render identifies this app, not another', () => {
  assert.equal(render('/x').app, 'mock');
  assert.equal(meta.app, 'mock');
});

test('render echoes the path it was asked for', () => {
  for (const p of ['/', '/deep/path', '/q?a=1']) assert.equal(render(p).path, p);
});

// An INDEPENDENT oracle. The earlier version compared render().routes to
// routes.json -- but render reads that same file at import, so the assertion
// compared the file to itself and could never fail. The expected set is
// written out here on purpose: changing routes.json must now break a test and
// force a deliberate edit, which is what makes it a contract.
const EXPECTED_ROUTES = ["/api/catalog", "/api/cart"].map(String);

test("routes.json matches the declared contract for this app", () => {
  assert.deepEqual(meta.routes, EXPECTED_ROUTES);
});

test("render advertises the contract routes", () => {
  assert.deepEqual(render("/").routes, EXPECTED_ROUTES);
});

test('every declared route is servable', () => {
  for (const r of meta.routes) {
    const probe = r.replace(/:[^/]+/g, 'PROBE');
    assert.equal(render(probe).app, 'mock', `route ${r} not served`);
  }
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
