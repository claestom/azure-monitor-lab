const { test, expect } = require('@playwright/test');

const availability = { available: true, model: 'test-model', message: 'MCP tools connected', tools: [{ name: 'sreagent_agents_list', description: 'List SRE resources', readOnly: true }, { name: 'sreagent_scheduledtasks_pause', description: 'Pause a task', readOnly: false }] };
const response = { sessionId: 'owned-chat', state: 'ready', messages: [{ role: 'assistant', text: 'There is one configured SRE agent.' }], operations: [{ tool: 'sreagent_agents_list', arguments: { subscription: 'test-sub', 'resource-group': 'test-rg' }, result: { name: 'test-agent' }, status: 'succeeded' }], proposal: null, model: 'test-model', inputTokens: 120, outputTokens: 30, error: null, traceId: 'test-trace' };
function pending() {
  return { ...response, state: 'approval_required', operations: [], proposal: { id: 'approval-once', tool: 'sreagent_scheduledtasks_pause', description: 'Pause the nightly task.', arguments: { subscription: 'test-sub', agent: 'test-agent', 'task-id': 'nightly' }, expiresAt: new Date(Date.now() + 300000).toISOString() } };
}
async function ready(page) {
  await page.route('**/api/sre/availability', route => route.fulfill({ json: availability }));
  await page.goto('/');
  await page.getByRole('tab', { name: 'SRE MCP Assistant', exact: true }).click();
  await expect(page.locator('#sre-availability')).toHaveText('MCP tools connected');
}
async function ask(page, prompt = 'List my SRE agents') {
  await page.getByLabel('MCP question', { exact: true }).fill(prompt);
  await page.getByLabel('I approve model usage and read-only MCP calls for this question.').check();
  await page.getByRole('button', { name: 'Send', exact: true }).click();
}

test('MCP connection allows slow startup while keeping tool actions disabled', async ({ page }) => {
  await page.clock.install();
  let release;
  const blocked = new Promise(resolve => { release = resolve; });
  const requests = [];
  page.on('request', request => { if (request.url().includes('/api/sre/')) requests.push(request.url()); });
  await page.route('**/api/sre/availability', async route => {
    expect(new URL(route.request().headers().referer).origin).toBe(new URL(route.request().url()).origin);
    await blocked;
    await route.fulfill({ json: availability });
  });
  await page.goto('/');
  const requested = page.waitForRequest('**/api/sre/availability');
  await page.getByRole('tab', { name: 'SRE MCP Assistant', exact: true }).click();
  await requested;
  await page.clock.fastForward(30000);
  await expect(page.locator('#sre-connection')).toHaveText('Checking...');
  await expect(page.locator('#sre-connect')).toBeDisabled();
  await expect(page.locator('#sre-send')).toBeDisabled();
  release();
  await expect(page.locator('#sre-connection')).toHaveText('Runtime connected');
  expect(requests).toHaveLength(1);
  expect(requests[0]).toContain('/api/sre/availability');
});

test('MCP connection timeout is bounded and retry only repeats discovery', async ({ page }) => {
  await page.clock.install();
  let release;
  const blocked = new Promise(resolve => { release = resolve; });
  let checks = 0;
  const writes = [];
  page.on('request', request => { if (request.method() === 'POST' && request.url().includes('/api/sre/')) writes.push(request.url()); });
  await page.route('**/api/sre/availability', async route => {
    checks++;
    if (checks === 1) {
      await blocked;
      await route.abort().catch(() => {});
    } else await route.fulfill({ json: availability });
  });
  await page.goto('/');
  const requested = page.waitForRequest('**/api/sre/availability');
  await page.getByRole('tab', { name: 'SRE MCP Assistant', exact: true }).click();
  await requested;
  await page.clock.fastForward(104000);
  await expect(page.locator('#sre-connection')).toHaveText('Checking...');
  await page.clock.fastForward(1000);
  await expect(page.locator('#sre-availability')).toContainText('MCP startup timed out');
  await expect(page.locator('#sre-connect')).toBeEnabled();
  await expect(page.locator('#sre-send')).toBeDisabled();
  await expect(page.locator('#sre-tool-count')).toHaveText('0 MCP tools');
  expect(checks).toBe(1);
  release();
  await page.locator('#sre-connect').click();
  await expect(page.locator('#sre-connection')).toHaveText('Runtime connected');
  expect(checks).toBe(2);
  expect(writes).toEqual([]);
});

test('MCP connection displays the backend startup timeout without exposing an internal error', async ({ page }) => {
  await page.route('**/api/sre/availability', route => route.fulfill({ status: 504, json: { available: false, state: 'startup_timeout', message: 'MCP startup timed out. Retry the connection; no Azure operation was executed.', tools: [] } }));
  await page.goto('/');
  await page.getByRole('tab', { name: 'SRE MCP Assistant', exact: true }).click();
  await expect(page.locator('#sre-availability')).toHaveText('MCP startup timed out. Retry the connection; no Azure operation was executed.');
  await expect(page.locator('#sre-connect')).toBeEnabled();
  await expect(page.locator('#sre-send')).toBeDisabled();
});

test('MCP connection handles an empty sign-in response', async ({ page }) => {
  await page.route('**/api/sre/availability', route => route.fulfill({ status: 401, body: '' }));
  await page.goto('/');
  await page.getByRole('tab', { name: 'SRE MCP Assistant', exact: true }).click();
  await expect(page.locator('#sre-connection')).toHaveText('Sign-in required');
  await expect(page.locator('#sre-sign-in')).toBeVisible();
  await expect(page.locator('#sre-availability')).toContainText('Sign in with an approved lab operator');
  await expect(page.locator('#sre-send')).toBeDisabled();
});

test('MCP connection handles a non-JSON gateway response without displaying its body', async ({ page }) => {
  await page.route('**/api/sre/availability', route => route.fulfill({ status: 502, contentType: 'text/html', body: '<h1>private-upstream-detail</h1>' }));
  await page.goto('/');
  await page.getByRole('tab', { name: 'SRE MCP Assistant', exact: true }).click();
  await expect(page.locator('#sre-availability')).toContainText('HTTP 502');
  await expect(page.locator('#sre-availability')).not.toContainText('private-upstream-detail');
  await expect(page.locator('#sre-connect')).toBeEnabled();
  await expect(page.locator('#sre-send')).toBeDisabled();
});

test('MCP chat sends natural language without evidence or SRE threads and preserves follow-ups', async ({ page }) => {
  const submitted = [];
  const requests = [];
  page.on('request', request => requests.push(request.url()));
  await page.route('**/api/sre/messages', route => {
    submitted.push(route.request().postDataJSON());
    expect(route.request().headers()['x-amlab-agent-request']).toBe('true');
    return route.fulfill({ json: { ...response, messages: [{ role: 'assistant', text: '<img src=x onerror="window.injected=true">' }] } });
  });
  await ready(page);
  await page.getByLabel('MCP request preset').selectOption({ label: 'List SRE agents' });
  await expect(page.locator('#sre-send')).toBeDisabled();
  await expect(page.locator('#sre-question')).toHaveValue('List the SRE agents in this resource group.');
  await ask(page);
  await expect(page.locator('#sre-status')).toContainText('Response received');
  expect(submitted[0]).toEqual({ sessionId: null, prompt: 'List my SRE agents', consent: true });
  await expect(page.locator('#sre-messages')).toContainText('<img');
  expect(await page.evaluate(() => window.injected)).toBeUndefined();
  await expect(page.locator('#sre-consent')).not.toBeChecked();
  await expect(page.locator('#sre-metadata')).toContainText('120 input / 30 output');
  await expect(page.locator('#sre-operations')).toContainText('sreagent_agents_list');
  await ask(page, 'Which connectors does it have?');
  await expect(page.locator('#sre-status')).toContainText('Response received');
  expect(submitted[1].sessionId).toBe('owned-chat');
  expect(requests.filter(url => /investigat|threads|conversations/.test(url))).toEqual([]);
  await page.locator('#sre-new').click();
  await expect(page.locator('#sre-messages')).toBeEmpty();
});

test('MCP writes show exact scope and arguments and execute only after explicit approval', async ({ page }) => {
  let approvalCalls = 0;
  await page.route('**/api/sre/messages', route => route.fulfill({ json: pending() }));
  await page.route('**/api/sre/approval', route => {
    approvalCalls++;
    expect(route.request().postDataJSON()).toEqual({ sessionId: 'owned-chat', proposalId: 'approval-once', approve: true });
    expect(route.request().headers()['x-amlab-agent-request']).toBe('true');
    return route.fulfill({ json: { ...response, messages: [{ role: 'assistant', text: 'Operation completed.' }] } });
  });
  await ready(page);
  await ask(page, 'Pause the nightly task');
  await expect(page.locator('#sre-review')).toBeVisible();
  await expect(page.locator('#sre-operation-preview')).toContainText('sreagent_scheduledtasks_pause');
  await expect(page.locator('#sre-operation-preview')).toContainText('test-agent');
  await expect(page.locator('#sre-operation-preview')).toContainText('nightly');
  await expect(page.locator('#sre-send')).toBeDisabled();
  expect(approvalCalls).toBe(0);
  await page.getByRole('button', { name: 'Approve Operation', exact: true }).click();
  await expect(page.locator('#sre-review')).toBeHidden();
  await expect(page.locator('#sre-messages')).toContainText('Operation completed.');
  expect(approvalCalls).toBe(1);
});

test('MCP proposals can be declined without an execution request', async ({ page }) => {
  await page.route('**/api/sre/messages', route => route.fulfill({ json: pending() }));
  await page.route('**/api/sre/approval', route => {
    expect(route.request().postDataJSON().approve).toBe(false);
    return route.fulfill({ json: { ...response, operations: [], messages: [{ role: 'assistant', text: 'Operation not executed.' }] } });
  });
  await ready(page);
  await ask(page, 'Pause the nightly task');
  await page.getByRole('button', { name: 'Decline', exact: true }).click();
  await expect(page.locator('#sre-messages')).toContainText('Operation not executed.');
  await expect(page.locator('#sre-operation-count')).toHaveText('0 operations');
});

test('MCP unknown write outcomes cannot be replayed and refresh only reads local chat state', async ({ page }) => {
  let approvals = 0;
  const uncertain = { ...response, state: 'unknown', proposal: null, error: 'Unknown operation outcome. Check Azure.' };
  await page.route('**/api/sre/messages', route => route.fulfill({ json: pending() }));
  await page.route('**/api/sre/approval', route => { approvals++; return route.fulfill({ status: 502, json: uncertain }); });
  await page.route('**/api/sre/chats/owned-chat', route => route.fulfill({ json: uncertain }));
  await ready(page);
  await ask(page, 'Pause the nightly task');
  await page.locator('#sre-approve').click();
  await expect(page.locator('#sre-status')).toContainText('Unknown operation outcome');
  await expect(page.locator('#sre-review')).toBeHidden();
  await expect(page.locator('#sre-send')).toBeDisabled();
  await page.locator('#sre-refresh').click();
  await expect(page.locator('#sre-status')).toContainText('Unknown operation outcome');
  expect(approvals).toBe(1);
});

test('MCP cancellation stops the wait without silently repeating a question', async ({ page }) => {
  let release;
  const blocked = new Promise(resolve => { release = resolve; });
  await page.route('**/api/sre/messages', async route => { await blocked; await route.abort().catch(() => {}); });
  await ready(page);
  const sent = page.waitForRequest('**/api/sre/messages');
  await ask(page);
  await sent;
  await page.locator('#sre-stop').click();
  await expect(page.locator('#sre-status')).toContainText('Stopped waiting');
  await expect(page.locator('#sre-send')).toBeDisabled();
  release();
});

test('MCP API is disabled by default and rejects unsafe origins and hosts for questions and approvals', async ({ request }) => {
  const data = { prompt: 'List SRE agents', consent: true };
  expect((await request.post('/api/sre/messages', { data })).status()).toBe(403);
  expect((await request.post('/api/sre/approval', { data: { approve: true } })).status()).toBe(403);
  expect((await request.post('/api/sre/approval', { data, headers: { 'X-Amlab-Agent-Request': 'true', Origin: 'https://attacker.example' } })).status()).toBe(403);
  expect((await request.get('/api/sre/availability', { headers: { Host: 'attacker.example' } })).status()).toBe(401);
  const availability = await request.get('/api/sre/availability');
  expect((await availability.json()).available).toBe(false);
  expect(availability.headers()['cache-control']).toBe('no-store');
  expect((await request.post('/api/sre/messages', { data, headers: { 'X-Amlab-Agent-Request': 'true' } })).status()).toBe(503);
  expect((await request.get('/api/sre/conversations/old-thread')).status()).toBe(404);
});

for (const width of [1440, 390, 320]) {
  test(`MCP operation review remains readable at ${width}px`, async ({ page }) => {
    await page.setViewportSize({ width, height: 1000 });
    await page.route('**/api/sre/messages', route => route.fulfill({ json: { ...pending(), messages: [{ role: 'assistant', text: 'The nightly task can be paused.' }], proposal: { ...pending().proposal, arguments: { agent: 'LongResourceIdentifier'.repeat(20), 'task-id': 'nightly' } } } }));
    await ready(page);
    await ask(page, 'Pause the nightly task');
    await expect(page.locator('#sre-review')).toBeVisible();
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
    const clipped = await page.locator('button, select, h1, h2').evaluateAll(items => items.filter(item => item.clientWidth > 0 && item.scrollWidth > item.clientWidth + 2).map(item => item.textContent));
    expect(clipped).toEqual([]);
    await page.screenshot({ path: `test-results/mcp-review-${width}.png`, fullPage: true });
  });
}