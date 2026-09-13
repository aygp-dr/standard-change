import { test } from 'node:test';
import assert from 'node:assert/strict';
import { render } from '../../src/server.js';

test('pdp render carries app identity and path', () => {
  const r = render('/x');
  assert.equal(r.app, 'pdp');
  assert.equal(r.path, '/x');
});
