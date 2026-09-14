const { test, expect } = require('@playwright/test');

const catalog = { available: true, state: 'ready', message: 'Connected to existing lab agents', agents: [
  { key: 'triage', name: 'Support Triage', model: 'test-model' },
  { key: 'finops', name: 'FinOps Q&A', model: 'test-model' }
] };
const answer = { agent: 'Support Triage', model: 'test-model', text: 'Technical: inspect the application trace.', status: 'completed', inputTokens: 120, outputTokens: 32, estimatedCostUsd: null, durationMs: 1400, traceId: '0123456789abcdef0123456789abcdef', runId: 'run_test' };
async function ready(page) {
  await page.route('**/api/agents/catalog', route => route.fulfill({ json: catalog }));
  await page.goto('/');
  await page.getByRole('tab', { name: 'Foundry Playground' }).click();
  await expect(page.getByLabel('Agent', { exact: true })).toBeEnabled();
}
async function approve(page) {
  await page.getByLabel('Task', { exact: true }).fill('The app returns an error.');
  await page.getByLabel('I approve billable model usage for this task.').check();
}

test('agent API rejects unsafe requests, enforces consent and size, defaults off, and limits requests', async ({ request }) => {
  const data = { agent: 'triage', prompt: 'Test task', consent: true };
  const headers = { 'X-Amlab-Agent-Request': 'true' };
  expect((await request.post('/api/agents/run', { data })).status()).toBe(403);
  expect((await request.post('/api/agents/run', { data, headers: { ...headers, Host: 'attacker.example' } })).status()).toBe(401);
  expect((await request.post('/api/agents/run', { data, headers: { ...headers, Origin: 'https://attacker.example' } })).status()).toBe(403);
  for (const invalid of [{ ...data, agent: 'arbitrary-agent' }, { ...data, prompt: '' }, { ...data, prompt: 'a'.repeat(4001) }, { ...data, consent: false }]) {
    expect((await request.post('/api/agents/run', { data: invalid, headers })).status()).toBe(400);
  }
  const disabled = await request.post('/api/agents/run', { data, headers });
  expect(disabled.status()).toBe(503);
  expect((await disabled.json()).state).toBe('not_configured');
  expect((await request.post('/api/agents/run', { data, headers })).status()).toBe(503);
  const limited = await request.post('/api/agents/run', { data, headers });
  expect(limited.status()).toBe(429);
  expect(Number(limited.headers()['retry-after'])).toBeGreaterThan(0);
  const available = await request.get('/api/agents/catalog');
  expect((await available.json()).available).toBe(false);
  expect(available.headers()['cache-control']).toBe('no-store');
  const context = await request.get('/api/agents/context');
  expect(Object.keys(await context.json()).sort()).toEqual(['appService', 'foundryUrl', 'resourceGroup', 'sreUrl']);
  expect(await context.text()).not.toMatch(/InstrumentationKey|ConnectionString|password/i);
});

test('tabs preserve console state, support keyboard navigation, and validate agent destinations', async ({ page }) => {
  await page.route('**/api/agents/context', route => route.fulfill({ json: { resourceGroup: 'test-rg', appService: 'test-app', sreUrl: 'https://sre.azure.com/#/agent/test', foundryUrl: 'javascript:alert(1)' } }));
  await page.goto('/');
  await page.getByRole('tab', { name: 'Traffic & Faults', exact: true }).click();
  await page.getByRole('button', { name: /Check Health/ }).click();
  await expect(page.locator('#total')).toHaveText('1');
  await page.getByRole('button', { name: /Trigger Error/ }).click();
  await expect(page.locator('#total')).toHaveText('2');
  await page.getByRole('tab', { name: 'Traffic & Faults', exact: true }).focus();
  await page.keyboard.press('ArrowRight');
  await expect(page.getByRole('tab', { name: 'Lab Operations', exact: true })).toBeFocused();
  await page.keyboard.press('ArrowRight');
  await expect(page.getByRole('tab', { name: 'SRE MCP Assistant', exact: true })).toBeFocused();
  await expect(page.locator('#panel-console')).toBeHidden();
  await expect(page.getByLabel('Investigation brief')).toHaveCount(0);
  await expect(page.locator('#sre-open')).toHaveAttribute('href', 'https://sre.azure.com/#/agent/test');
  await expect(page.locator('#foundry-open')).not.toHaveAttribute('href');
  await page.getByRole('tab', { name: 'SRE MCP Assistant', exact: true }).focus();
  await page.keyboard.press('End');
  await expect(page.locator('#tab-foundry')).toBeFocused();
  await page.keyboard.press('Home');
  await expect(page.locator('#tab-health')).toBeFocused();
  await expect(page.locator('#panel-health')).toBeVisible();
  await page.keyboard.press('ArrowRight');
  await expect(page.locator('#panel-console')).toBeVisible();
  await expect(page.locator('#total')).toHaveText('2');
  await page.getByRole('button', { name: 'Clear session results' }).click();
  await expect(page.locator('#total')).toHaveText('0');
});

test('playground shows actual returned metadata, requires per-task consent, and keeps AI text inert', async ({ page }) => {
  let submitted;
  await page.route('**/api/agents/run', async route => {
    submitted = route.request().postDataJSON();
    expect(route.request().headers()['x-amlab-agent-request']).toBe('true');
    await route.fulfill({ json: { ...answer, text: '<img src=x onerror="window.injected=true">' } });
  });
  await ready(page);
  await page.getByLabel('Task', { exact: true }).fill('Test');
  await expect(page.getByRole('button', { name: 'Run Agent', exact: true })).toBeDisabled();
  await approve(page);
  await page.getByRole('button', { name: 'Run Agent', exact: true }).click();
  await expect(page.locator('#agent-status')).toContainText('Completed');
  expect(submitted).toEqual({ agent: 'triage', prompt: 'The app returns an error.', consent: true });
  await expect(page.locator('#agent-results')).toContainText('120');
  await expect(page.locator('#agent-results')).toContainText('32');
  await expect(page.locator('#agent-results')).toContainText('Rates not configured');
  await expect(page.locator('#agent-results')).toContainText(answer.traceId);
  await expect(page.locator('#agent-results')).toContainText('<img');
  expect(await page.evaluate(() => window.injected)).toBeUndefined();
  await expect(page.getByLabel('I approve billable model usage for this task.')).not.toBeChecked();
  await page.getByRole('button', { name: 'Clear task results' }).click();
  await expect(page.locator('#agent-results')).toBeEmpty();
});

test('playground reports unavailable services and recovers after cancellation and upstream failure', async ({ page }) => {
  await page.goto('/');
  await page.getByRole('tab', { name: 'Foundry Playground' }).click();
  await expect(page.locator('#agent-availability')).toContainText('not enabled');
  await expect(page.getByRole('button', { name: 'Run Agent', exact: true })).toBeDisabled();
  await page.route('**/api/agents/catalog', route => route.fulfill({ json: catalog }));
  await page.getByRole('button', { name: 'Refresh agent availability' }).click();
  await expect(page.getByLabel('Agent', { exact: true })).toBeEnabled();
  let release;
  const blocked = new Promise(resolve => { release = resolve; });
  await page.route('**/api/agents/run', async route => { await blocked; await route.abort().catch(() => {}); });
  await approve(page);
  const sent = page.waitForRequest('**/api/agents/run');
  await page.getByRole('button', { name: 'Run Agent', exact: true }).click();
  await sent;
  await expect(page.getByLabel('Agent', { exact: true })).toBeDisabled();
  await page.getByRole('button', { name: 'Cancel', exact: true }).click();
  await expect(page.locator('#agent-status')).toContainText('Stopped waiting');
  release();
  await page.unroute('**/api/agents/run');
  await page.route('**/api/agents/run', route => route.fulfill({ status: 429, headers: { 'Retry-After': '15', 'X-Amlab-Trace-Id': 'failure-trace' }, json: { error: 'Foundry capacity exceeded.' } }));
  await approve(page);
  await page.getByRole('button', { name: 'Run Agent', exact: true }).click();
  await expect(page.locator('#agent-status')).toContainText('Retry after 15 seconds');
  await expect(page.locator('#agent-status')).toContainText('failure-trace');
});

for (const width of [1440, 390, 320]) {
  test(`agent tabs render without overflow at ${width}px`, async ({ page }, testInfo) => {
    const errors = [];
    page.on('pageerror', error => errors.push(error.message));
    await page.setViewportSize({ width, height: width > 760 ? 1000 : 844 });
    await page.route('**/api/agents/run', route => route.fulfill({ json: answer }));
    await ready(page);
    await approve(page);
    await page.getByRole('button', { name: 'Run Agent', exact: true }).click();
    await expect(page.locator('#agent-status')).toContainText('Completed');
    for (const name of ['Foundry Playground', 'SRE MCP Assistant']) {
      await page.getByRole('tab', { name, exact: true }).click();
      await expect(page.locator('.mobile-feedback')).toBeHidden();
      expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
      const clipped = await page.locator('button, select, h1, h2').evaluateAll(items => items.filter(item => item.clientWidth > 0 && item.scrollWidth > item.clientWidth + 2).map(item => item.textContent));
      expect(clipped).toEqual([]);
      await page.screenshot({ path: testInfo.outputPath(`${name.split(' ')[0].toLowerCase()}-${width}.png`), fullPage: true });
    }
    expect(errors).toEqual([]);
  });
}