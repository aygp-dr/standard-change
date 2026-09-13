import { test } from 'node:test';
import assert from 'node:assert/strict';
import { render, renderHtml, shippingForm, DUE } from '../../src/server.js';

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

// Step 2: the payment step used to render no panel at all -- renderHtml only
// built `extra` for /checkout. Assert both halves: the panel exists, and the
// shipping form has NOT leaked onto it.
test('the payment step says what is about to happen, and for how much', () => {
  const html = renderHtml('/checkout/payment', 9000);
  assert.match(html, /Nothing is charged until you confirm/);
  assert.ok(html.includes(DUE), 'the payment step names the same amount');
  assert.ok(!html.includes('Shipping address'), 'the shipping form stays on /checkout');
});
