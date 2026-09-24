const { test, expect } = require('@playwright/test');

test('protected agent tabs offer platform sign-in without affecting anonymous lab actions', async ({ page }) => {
  const unauthorized = { available: false, message: 'Sign in with an approved lab operator account.', agents: [] };
  await page.route('**/api/sre/availability', route => route.fulfill({ status: 401, json: unauthorized }));
  await page.route('**/api/agents/catalog', route => route.fulfill({ status: 401, json: unauthorized }));
  await page.goto('/');
  await page.getByRole('tab', { name: 'Traffic & Faults', exact: true }).click();
  await page.getByRole('button', { name: /Check Health/ }).click();
  await expect(page.locator('#total')).toHaveText('1');
  await page.getByRole('tab', { name: 'SRE MCP Assistant', exact: true }).click();
  await expect(page.locator('#sre-sign-in')).toBeVisible();
  await expect(page.locator('#sre-sign-in')).toHaveAttribute('href', '/.auth/login/aad?post_login_redirect_uri=/');
  await expect(page.locator('#sre-send')).toBeDisabled();
  await page.getByRole('tab', { name: 'Foundry Playground', exact: true }).click();
  await expect(page.locator('#agent-sign-in')).toBeVisible();
  await expect(page.locator('#agent-send')).toBeDisabled();
  await page.unroute('**/api/agents/catalog');
  await page.route('**/api/agents/catalog', route => route.fulfill({ json: { available: true, message: 'Connected', agents: [] } }));
  await page.locator('#agent-refresh').click();
  await expect(page.locator('#agent-sign-in')).toBeHidden();
});