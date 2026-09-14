export function initializeSreAssistant() {
  const byId = id => document.getElementById(id);
  let checked = false;
  let available = false;
  let checking = false;
  let active = null;
  let sessionId = null;
  let proposal = null;
  let state = 'ready';

  function element(tag, text, className) {
    const item = document.createElement(tag);
    item.textContent = text;
    if (className) item.className = className;
    return item;
  }
  function controls() {
    const busy = Boolean(active) || checking;
    byId('sre-send').disabled = busy || !available || state !== 'ready' || !byId('sre-question').value.trim() || !byId('sre-consent').checked;
    byId('sre-stop').disabled = !active;
    byId('sre-refresh').disabled = busy || !sessionId;
    byId('sre-new').disabled = busy || Boolean(proposal);
    byId('sre-connect').disabled = busy;
    byId('sre-approve').disabled = busy || !proposal || Date.now() >= Date.parse(proposal.expiresAt);
    byId('sre-decline').disabled = busy || !proposal;
    for (const id of ['sre-question', 'sre-consent', 'sre-example']) byId(id).disabled = busy;
  }
  async function load(force = false) {
    if ((checked && !force) || checking || active) return;
    checked = true;
    checking = true;
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 105000);
    const timeoutMessage = 'MCP startup timed out. Retry the connection; no Azure operation was executed.';
    let failureMessage = 'MCP connection check failed. Check your connection and retry.';
    controls();
    byId('sre-availability').textContent = 'Connecting to SRE MCP...';
    byId('sre-connection').textContent = 'Checking...';
    try {
      const response = await fetch('/api/sre/availability', { cache: 'no-store', referrerPolicy: 'same-origin', signal: controller.signal });
      byId('sre-sign-in').hidden = response.status !== 401;
      failureMessage = response.status === 504 ? timeoutMessage : `MCP connection check failed (HTTP ${response.status}). Retry the connection.`;
      const body = await response.json().catch(() => null);
      const data = body && typeof body === 'object' && !Array.isArray(body) ? body : null;
      if (controller.signal.aborted || (!data && response.status !== 401)) throw new Error('MCP availability response was not readable.');
      available = response.ok && data?.available === true;
      byId('sre-connection').textContent = response.status === 401 ? 'Sign-in required' : available ? 'Runtime connected' : 'Unavailable';
      byId('sre-availability').textContent = typeof data?.message === 'string' ? data.message
        : response.status === 401 ? 'Sign in with an approved lab operator account to connect to MCP.'
        : available ? 'MCP tools connected.' : failureMessage;
      const tools = available && Array.isArray(data?.tools) ? data.tools : [];
      byId('sre-tool-count').textContent = `${tools.length} MCP tools${typeof data?.model === 'string' ? ` / ${data.model}` : ''}`;
      byId('sre-tools').replaceChildren(...tools.map(tool => {
        const item = element('li', `${tool.name} (${tool.readOnly ? 'Read' : 'Approval required'})`);
        item.title = tool.description;
        return item;
      }));
    } catch {
      available = false;
      byId('sre-connection').textContent = 'Unavailable';
      byId('sre-availability').textContent = controller.signal.aborted ? timeoutMessage : failureMessage;
      byId('sre-tool-count').textContent = '0 MCP tools';
      byId('sre-tools').replaceChildren();
    } finally { clearTimeout(timeout); checking = false; controls(); }
  }
  function render(data) {
    sessionId = data.sessionId;
    state = data.state;
    proposal = data.proposal;
    const labels = { ready: 'Response received', approval_required: 'Review required. No proposed change has been executed.', unknown: 'Operation outcome unknown. Check Azure before attempting it again.' };
    byId('sre-status').textContent = data.error || labels[state] || 'Chat updated';
    const tokens = data.inputTokens == null || data.outputTokens == null ? 'Token usage not reported' : `${data.inputTokens.toLocaleString()} input / ${data.outputTokens.toLocaleString()} output tokens`;
    byId('sre-metadata').textContent = `${data.model} | ${tokens}${data.traceId ? ` | App trace: ${data.traceId}` : ''}`;
    byId('sre-messages').replaceChildren(...data.messages.map(message => {
      const item = element('article', '', `agent-result sre-message ${message.role === 'user' ? 'sre-user-message' : ''}`);
      item.append(element('h3', message.role === 'user' ? 'You' : 'MCP Assistant'), element('div', message.text, 'agent-answer'));
      return item;
    }));
    byId('sre-review').hidden = !proposal;
    if (proposal) {
      byId('sre-operation-description').textContent = proposal.description;
      byId('sre-operation-preview').textContent = JSON.stringify({ tool: proposal.tool, arguments: proposal.arguments }, null, 2);
      byId('sre-operation-expiry').textContent = `Approval expires: ${new Date(proposal.expiresAt).toLocaleTimeString()}`;
    }
    byId('sre-operation-count').textContent = `${data.operations.length} operations`;
    byId('sre-operations').replaceChildren(...data.operations.map(operation => {
      const item = element('details', '', 'sre-operation');
      item.append(element('summary', `${operation.tool} / ${operation.status}`), element('pre', JSON.stringify({ arguments: operation.arguments, result: operation.result }, null, 2)));
      return item;
    }));
  }
  async function request(mode) {
    if (active || checking) return;
    const refresh = mode === 'refresh';
    const resolving = mode === 'approve' || mode === 'decline';
    const payload = resolving ? { sessionId, proposalId: proposal.id, approve: mode === 'approve' }
      : { sessionId, prompt: byId('sre-question').value.trim(), consent: byId('sre-consent').checked };
    const controller = new AbortController();
    active = controller;
    const previousState = state;
    if (!refresh) state = 'unknown';
    if (resolving) { proposal = null; byId('sre-review').hidden = true; }
    const started = performance.now();
    const progress = () => { byId('sre-status').textContent = `${refresh ? 'Reading chat' : resolving ? 'Resolving operation' : 'Working with MCP tools'}... ${Math.floor((performance.now() - started) / 1000)}s`; };
    progress();
    const ticker = setInterval(progress, 1000);
    const timeout = setTimeout(() => controller.abort(), refresh ? 25000 : resolving ? 75000 : 165000);
    controls();
    try {
      const response = await fetch(refresh ? `/api/sre/chats/${encodeURIComponent(sessionId)}` : resolving ? '/api/sre/approval' : '/api/sre/messages', {
        method: refresh ? 'GET' : 'POST', cache: 'no-store', referrerPolicy: 'same-origin', signal: controller.signal,
        headers: refresh ? {} : { 'Content-Type': 'application/json', 'X-Amlab-Agent-Request': 'true' },
        body: refresh ? undefined : JSON.stringify(payload)
      });
      const data = await response.json();
      if (data.sessionId && Array.isArray(data.messages)) render(data);
      if (!response.ok) {
        if (!data.state && !resolving) state = [400, 401, 403, 404, 429, 503].includes(response.status) ? previousState : 'unknown';
        const retry = response.headers.get('Retry-After');
        throw new Error(`${data.error || 'MCP request failed.'}${retry ? ` Retry after ${retry}s.` : ''}`);
      }
      if (mode === 'ask') byId('sre-question').value = '';
    } catch (error) {
      byId('sre-status').textContent = controller.signal.aborted
        ? 'Stopped waiting. Model usage or approved Azure operations may continue. Refresh this chat before attempting the operation again.'
        : error.message;
    } finally {
      clearInterval(ticker);
      clearTimeout(timeout);
      active = null;
      if (mode === 'ask') byId('sre-consent').checked = false;
      controls();
    }
  }
  byId('sre-form').addEventListener('submit', event => { event.preventDefault(); if (!byId('sre-send').disabled) request('ask'); });
  byId('sre-refresh').addEventListener('click', () => request('refresh'));
  byId('sre-stop').addEventListener('click', () => active?.abort());
  byId('sre-connect').addEventListener('click', () => load(true));
  byId('sre-approve').addEventListener('click', () => { if (proposal) request('approve'); });
  byId('sre-decline').addEventListener('click', () => { if (proposal) request('decline'); });
  byId('sre-example').addEventListener('change', () => { byId('sre-question').value = byId('sre-example').value; controls(); });
  byId('sre-new').addEventListener('click', () => {
    if (state === 'unknown' && !window.confirm('An approved operation may have run. Check Azure before repeating it. Start a new chat?')) return;
    sessionId = null;
    proposal = null;
    state = 'ready';
    for (const id of ['sre-messages', 'sre-operations']) byId(id).replaceChildren();
    byId('sre-review').hidden = true;
    byId('sre-metadata').textContent = '';
    byId('sre-operation-count').textContent = '0 operations';
    byId('sre-status').textContent = 'New MCP chat';
    byId('sre-question').value = '';
    byId('sre-example').value = '';
    byId('sre-consent').checked = false;
    controls();
    byId('sre-question').focus();
  });
  for (const id of ['sre-question', 'sre-consent']) byId(id).addEventListener('input', controls);
  controls();
  return { load };
}