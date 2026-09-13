import { test } from 'node:test';
import assert from 'node:assert/strict';
import { render, shippingForm, DUE } from '../../src/server.js';

test('checkout render carries app identity and path', () => {
  const r = render('/x');
  assert.equal(r.app, 'checkout');
  assert.equal(r.path, '/x');
});

// Step 1 of the copy stack: the shopper is told the figure before being asked
// to fill anything in, not after. DUE is asserted through the panel rather than
// only as a constant -- a constant nothing renders is not copy.
test('the checkout panel states what the order comes to', () => {
  assert.match(shippingForm(new URLSearchParams()), /Your order comes to/);
  assert.ok(shippingForm(new URLSearchParams()).includes(DUE), 'the amount is rendered');
});
