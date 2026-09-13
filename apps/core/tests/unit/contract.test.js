// The contract every app owes the router, the labeller and guard 5.
// A per-app test can assert these; gates/e2e.sh asserts the rest against a
// running estate.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { render, staticFile, assets } from '../../src/server.js';

const meta = JSON.parse(readFileSync(new URL('../../routes.json', import.meta.url)));

test('render identifies this app, not another', () => {
  assert.equal(render('/x').app, 'core');
  assert.equal(meta.app, 'core');
});

test('render echoes the path it was asked for', () => {
  for (const p of ['/', '/deep/path', '/q?a=1']) assert.equal(render(p).path, p);
});

// An INDEPENDENT oracle. The earlier version compared render().routes to
// routes.json -- but render reads that same file at import, so the assertion
// compared the file to itself and could never fail. The expected set is
// written out here on purpose: changing routes.json must now break a test and
// force a deliberate edit, which is what makes it a contract.
const EXPECTED_ROUTES = ["/", "/login", "/account", "/cart",
                         "/about", "/contact", "/jobs", "/statics/"].map(String);

test("routes.json matches the declared contract for this app", () => {
  assert.deepEqual(meta.routes, EXPECTED_ROUTES);
});

test("render advertises the contract routes", () => {
  assert.deepEqual(render("/").routes, EXPECTED_ROUTES);
});

// core is the estate's default location (routes.json: fallthrough), so it is
// the app that decides a path does not exist. These pin the two halves of that
// job -- it must answer for what it owns, and refuse what it does not. Without
// the second, 'default location' silently becomes 'core returns 200 for
// anything', and the router's ownership gate can never fail again.
test('core declares itself the fallthrough', () => {
  assert.equal(meta.fallthrough, true);
});

test('core refuses a path no app claims', () => {
  for (const p of ['/definitely-not-a-route', '/search', '/p/SKU1'])
    assert.equal(render(p).found, false, `core claimed ${p}`);
});

// The declared route /statics/ tells the router where to send these. It must
// not, by itself, make everything under it exist -- that is how a default
// location stops being able to say no.
test('under /statics/ the file decides, not the prefix', () => {
  assert.equal(render('/statics/oneui.css').found, true);
  assert.equal(render('/statics/not-a-file.css').found, false);
  assert.equal(render('/statics/../../../etc/passwd').found, false);
  assert.equal(render('/statics/').found, true, 'the index is still served');
  assert.ok(assets().includes('oneui.css'));
});

test('core answers for every route it declares', () => {
  for (const r of meta.routes) assert.equal(render(r).found, true, `core disowned ${r}`);
});

test('statics are served from the app, and only from inside it', () => {
  assert.ok(staticFile('/statics/oneui.css'), 'oneui.css not served');
  assert.equal(staticFile('/statics/oneui.css').type, 'text/css');
  assert.equal(staticFile('/statics/nope.css'), null);
  for (const p of ['/statics/../../../etc/passwd', '/statics/..%2f..%2fpackage.json'])
    assert.equal(staticFile(p), null, `traversal escaped: ${p}`);
});

test('every declared route is servable', () => {
  for (const r of meta.routes) {
    const probe = r.replace(/:[^/]+/g, 'PROBE');
    assert.equal(render(probe).app, 'core', `route ${r} not served`);
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
