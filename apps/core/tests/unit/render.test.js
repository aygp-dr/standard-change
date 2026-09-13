import { test } from 'node:test';
import assert from 'node:assert/strict';
import { render } from '../../src/server.js';

test('core render carries app identity and path', () => {
  const r = render('/x');
  assert.equal(r.app, 'core');
  assert.equal(r.path, '/x');
});
