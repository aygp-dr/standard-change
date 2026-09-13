#!/usr/bin/env node
// lint-app.mjs <app-dir> -- the lint gate for one app.
//
// `node --check` only proves the file parses, and `jq -e .` only proves the
// JSON is well formed. Neither can fail on the things that actually break a
// deployment, so this validates the routes.json CONTRACT from spec.org and
// the invariants the router and the labeller depend on.
import { readFileSync, existsSync } from 'node:fs';
import { basename, join, resolve } from 'node:path';

const dir = process.argv[2];
if (!dir) { console.error('usage: lint-app.mjs <app-dir>'); process.exit(2); }
const app = basename(resolve(dir));  // '.' must resolve to the app name
const findings = [];
const fail = (m) => findings.push(m);

// -- routes.json is the source of truth for the router, the labeller and the
//    port block, so every consumer's assumption is checked here.
const rpath = join(dir, 'routes.json');
if (!existsSync(rpath)) fail('routes.json is missing');
else {
  let r;
  try { r = JSON.parse(readFileSync(rpath, 'utf8')); }
  catch (e) { fail(`routes.json does not parse: ${e.message}`); }
  if (r) {
    if (r.app !== app) fail(`routes.json app="${r.app}" but the directory is "${app}"`);
    if (!Number.isInteger(r.port_offset)) fail('port_offset must be an integer');
    else if (r.port_offset < 1 || r.port_offset > 9)
      fail(`port_offset ${r.port_offset} is outside a ten-port block`);
    if (!Array.isArray(r.routes) || r.routes.length === 0)
      fail('routes must be a non-empty array');
    else {
      for (const route of r.routes) {
        if (typeof route !== 'string' || !route.startsWith('/'))
          fail(`route ${JSON.stringify(route)} must be a string starting with /`);
      }
      // `probes` hands gates/e2e.sh a concrete, valid instance of a
      // parameterised route, because the gate can no longer synthesize one
      // (an app may check the parameter -- plp checks the category). It is a
      // claim the gate TRUSTS, so it must name a declared route and land
      // inside it: a probe of /login for /c/:category would satisfy the
      // ownership check by testing a different route entirely.
      if (r.probes !== undefined) {
        if (typeof r.probes !== 'object' || r.probes === null || Array.isArray(r.probes))
          fail('probes must be an object mapping route -> concrete path');
        else for (const [route, probe] of Object.entries(r.probes)) {
          if (!r.routes.includes(route))
            fail(`probes names "${route}", which is not a declared route`);
          else if (typeof probe !== 'string')
            fail(`probe for "${route}" must be a string`);
          else if (!probe.startsWith(route.replace(/:[^/]*$/, '')))
            fail(`probe "${probe}" does not lie inside route "${route}"`);
          else if (probe.includes(':'))
            fail(`probe "${probe}" still contains a parameter; it must be concrete`);
        }
      }
      // the health path must be reachable through a declared route, or guard 5
      // probes something the router will 404
      if (typeof r.health !== 'string') fail('health must be a string');
      else {
        const hp = r.health.split('?')[0];
        const covered = r.routes.some((x) => {
          const prefix = x.replace(/:[^/]*/g, '');
          return prefix === '/' ? hp === '/' : hp.startsWith(prefix);
        });
        if (!covered) fail(`health "${r.health}" is not covered by any declared route`);
      }
    }
    if (!Array.isArray(r.journeys)) fail('journeys must be an array');
  }
}

// -- the server contract the router and guard 5 depend on
const spath = join(dir, 'src', 'server.js');
if (!existsSync(spath)) fail('src/server.js is missing');
else {
  const raw = readFileSync(spath, 'utf8');
  // Strip comments FIRST. The earlier version matched /x-build-sha/ against the
  // whole file, and line 1 is a comment mentioning it -- so deleting the actual
  // header left the gate green. A rule that its own documentation satisfies is
  // not a rule.
  const src = raw.replace(/\/\*[\s\S]*?\*\//g, '').replace(/(^|[^:])\/\/.*$/gm, '$1');
  if (!/x-build-sha/.test(src))
    fail('server does not set x-build-sha; guard 5 cannot identify the served build');
  if (!/export function render|export {[^}]*render/.test(src))
    fail('server does not export render(); the unit tests cannot reach it');
  if (!/isMain|require\.main/.test(src))
    fail('server listens unconditionally; importing it in a test will bind a port');
  // NOT "no console.log": the startup line is legitimate and goes to the app's
  // log file. The first version of this rule flagged all five apps for it,
  // which is a lint rule failing rather than five apps being wrong. What
  // matters is per-REQUEST logging to stdout, which floods the log under load.
  const handler = src.slice(src.indexOf('createServer'), src.indexOf('.listen('));
  if (/console\.(log|error)\(/.test(handler))
    fail('console logging inside the request handler; it floods the log under load');
  if (!/process\.env\.BIND|const BIND/.test(src))
    fail('server hardcodes its bind address; BIND must be configurable');
  // NOT a HEAD rule. node's single createServer handler serves every method
  // and suppresses the body for HEAD by itself -- verified with curl -I against
  // a live block. Only Python's BaseHTTPRequestHandler needs an explicit
  // do_HEAD, and that bug lives in targets/bastille/app.py, not here. Two rules
  // in this file were written by generalising a defect from the wrong runtime;
  // check the runtime before adding a third.
}

if (!existsSync(join(dir, 'tests', 'unit'))) fail('tests/unit is missing');

for (const f of findings) console.log(`FAIL ${app}: ${f}`);
console.log(`  ${app} lint: ${findings.length} finding(s)`);
process.exit(findings.length ? 1 : 0);
