// journey.spec.mjs -- the storefront AS IT IS, pinned.
//
// This is not a wish list. Every assertion below is what the estate served on
// 2026-09-14 at dff0887, including the parts a person would call unfinished:
// the cart page that says nothing about the cart, the $42.00 total, the
// "Ready to continue to payment." that is text and not a link. They are pinned
// ON PURPOSE. A change that alters the flow or the navigation (#40, #52, #71
// are open and will) lands approved with the unit tests green, and is then
// refused on entry to staging by THIS suite, because acceptance was never
// updated to say what the new behaviour is. That refusal is correct: the
// tests are the record of what was accepted, and a change to the flow is a
// change to what must be accepted. The PR updates this file, and the reviewer
// reads the diff of the acceptance alongside the diff of the code.
//
// One test, serial steps, one browser context: ~2 s. The steps exist so the
// refusal names the page.
import { test, expect } from "@playwright/test";

const shas = new Map();
const note = (res, page) => shas.set(page, res.headers()["x-build-sha"]);

test("home → plp → pdp → add to cart → checkout, as-is", async ({ page }) => {
  await test.step("home is core", async () => {
    const res = await page.goto("/");
    expect(res.headers()["x-routed-to"]).toBe("core"); note(res, "home");
    await expect(page.locator("h1")).toHaveText("core");
    await expect(page.locator("a[href='/c/shoes']").first()).toBeVisible();
  });

  await test.step("category is plp, three results", async () => {
    const res = await page.goto("/c/shoes");
    expect(res.headers()["x-routed-to"]).toBe("plp"); note(res, "plp");
    await expect(page.locator("h1")).toHaveText("plp");
    await expect(page.locator("h2")).toHaveText("Shoes");
    await expect(page.getByText("3 result(s) in")).toBeVisible();
    for (const name of ["Trail Runner", "Court Sneaker", "Chelsea Boot"]) {
      await expect(page.getByRole("link", { name })).toBeVisible();
    }
  });

  await test.step("product is pdp: Trail Runner, $89.00, in stock", async () => {
    await page.locator("a[href='/p/SKU123']").first().click();
    await expect(page).toHaveURL(/\/p\/SKU123$/);
    await expect(page.locator("h1")).toHaveText("pdp");
    await expect(page.locator("h2")).toHaveText("Trail Runner");
    await expect(page.getByText("$89.00")).toBeVisible();
    await expect(page.getByText("In stock")).toBeVisible();
  });

  await test.step("add to cart crosses to core (as-is: the cart page shows no cart)", async () => {
    const [res] = await Promise.all([
      page.waitForResponse(r => r.url().includes("/cart")),
      page.locator("a.cart", { hasText: "Add to cart" }).click(),
    ]);
    expect(res.headers()["x-routed-to"]).toBe("core"); note(res, "cart");
    await expect(page).toHaveURL(/\/cart\?add=SKU123$/);
    await expect(page.locator("h1")).toHaveText("core");
    // pinned as-is; #40 / #52 change this and must change this line
    await expect(page.getByText("Trail Runner")).toHaveCount(0);
  });

  await test.step("checkout: $42.00 total, four-field shipping form (as-is)", async () => {
    const res = await page.goto("/checkout");
    expect(res.headers()["x-routed-to"]).toBe("checkout"); note(res, "checkout");
    await expect(page.locator("h1")).toHaveText("checkout");
    await expect(page.getByText("Your order comes to")).toContainText("$42.00");
    await expect(page.locator("h2")).toHaveText("Shipping address");
    for (const n of ["name", "line1", "city", "postcode"]) {
      await expect(page.locator(`input[name='${n}']`)).toBeVisible();
    }
  });

  await test.step("the form round-trips; 'Ready to continue' is text, not a link (as-is)", async () => {
    await page.fill("input[name='name']", "Test User");
    await page.fill("input[name='line1']", "1 Test Street");
    await page.fill("input[name='city']", "Testville");
    await page.fill("input[name='postcode']", "00000");
    await page.locator("form[action='/checkout'] button, form[action='/checkout'] input[type=submit]").first().click();
    await expect(page).toHaveURL(/\/checkout\?name=Test\+User/);
    await expect(page.locator("input[name='city']")).toHaveValue("Testville");
    await expect(page.getByText("Ready to continue to payment.")).toBeVisible();
    // pinned as-is; #71 makes this a link and must change this line
    await expect(page.getByRole("link", { name: /continue to payment/i })).toHaveCount(0);
  });

  await test.step("payment: $42.00, a back link, no confirm control (as-is)", async () => {
    const res = await page.goto("/checkout/payment");
    expect(res.headers()["x-routed-to"]).toBe("checkout"); note(res, "payment");
    await expect(page.locator("h2")).toHaveText("Payment");
    await expect(page.getByText("You are about to pay")).toContainText("$42.00");
    await expect(page.getByRole("link", { name: /back to shipping address/i })).toBeVisible();
    await expect(page.getByRole("button", { name: /confirm|pay/i })).toHaveCount(0);
  });

  await test.step("one estate: every page reported the same build", async () => {
    const seen = new Set(shas.values());
    expect([...seen]).toHaveLength(1);
    expect([...seen][0]).toMatch(/^[0-9a-f]{7,40}$/);
  });
});
