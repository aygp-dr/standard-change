import { test } from 'node:test';
import assert from 'node:assert/strict';
import { render } from '../../src/server.js';

test('plp render carries app identity and path', () => {
  const r = render('/x');
  assert.equal(r.app, 'plp');
  assert.equal(r.path, '/x');
});
