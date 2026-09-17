import { initializeSreAssistant } from './sre-assistant.js';
import { initializeInfrastructureHealth } from './infrastructure-health.js';
import { initializeLabOperations } from './lab-operations.js';

export function initializeAgentViews({ resizeChart, toast, refreshIcons, checkWebAppHealth }) {
  const byId = id => document.getElementById(id);
  const sre = initializeSreAssistant();
  const infrastructure = initializeInfrastructureHealth({ refreshIcons, checkWebAppHealth });
  const operations = initializeLabOperations({ refreshIcons });
  let context = {};
  let availableAgents = [];
  let activeRequest = null;
  let catalogLoaded = false;
  let refreshing = false;
  const tabs = [...document.querySelectorAll('[role="tab"]')];

  function activate(tab) {
    for (const item of tabs) {
      const selected = item === tab;
      item.setAttribute('aria-selected', String(selected));
      item.tabIndex = selected ? 0 : -1;
      byId(item.getAttribute('aria-controls')).hidden = !selected;
    }
    const consoleActive = tab.id === 'tab-console';
    document.querySelector('.mobile-feedback').hidden = !consoleActive;
    document.querySelector('.skip-link').href = consoleActive ? '#controls' : `#${tab.getAttribute('aria-controls')}`;
    document.querySelector('.skip-link').textContent = consoleActive ? 'Skip to lab controls' : 'Skip to active view';
    if (consoleActive) requestAnimationFrame(resizeChart);
    operations.activate(tab.id === 'tab-operations');
    if (tab.id === 'tab-health') infrastructure.load();
    if (tab.id === 'tab-sre') sre.load();
    if (tab.id === 'tab-foundry' && !catalogLoaded) loadCatalog();
  }
  tabs.forEach((tab, index) => {
    tab.addEventListener('click', () => activate(tab));
    tab.addEventListener('keydown', event => {
      const next = { ArrowRight: (index + 1) % tabs.length, ArrowLeft: (index + tabs.length - 1) % tabs.length, Home: 0, End: tabs.length - 1 }[event.key];
      if (next === undefined) return;
      event.preventDefault();
      tabs[next].focus();
      activate(tabs[next]);
    });
  });

  function setDestination(id, value) {
    const link = byId(id);
    link.removeAttribute('href');
    link.setAttribute('aria-disabled', 'true');
    link.title = 'Destination not configured';
    try {
      const url = new URL(value);
      if (url.protocol !== 'https:' || url.username || url.password) return false;
      link.href = url.href;
      link.target = '_blank';
      link.rel = 'noopener noreferrer';
      link.removeAttribute('aria-disabled');
      link.title = 'Open in Azure; your account permissions apply';
      return true;
    } catch { return false; }
  }
  async function loadContext() {
    try {
      const response = await fetch('/api/agents/context', { cache: 'no-store', signal: AbortSignal.timeout(10000) });
      if (!response.ok) throw new Error('Context unavailable');
      context = await response.json();
      byId('lab-resource').textContent = context.resourceGroup || 'Not configured';
      byId('lab-app').textContent = context.appService || 'Not configured';
      byId('sre-resource').textContent = context.resourceGroup || 'Not configured';
      byId('sre-app').textContent = context.appService || 'Not configured';
      byId('sre-destination-status').textContent = setDestination('sre-open', context.sreUrl) ? 'SRE Agent destination configured' : 'SRE Agent destination not configured';
      setDestination('foundry-open', context.foundryUrl);
    } catch {
      byId('lab-resource').textContent = 'Unavailable';
      byId('lab-app').textContent = 'Unavailable';
      byId('sre-destination-status').textContent = 'Agent destinations unavailable';
    }
  }

  function updateAgentControls() {
    const running = Boolean(activeRequest);
    byId('agent-send').disabled = running || refreshing || !availableAgents.length || !byId('agent-prompt').value.trim() || !byId('agent-consent').checked;
    byId('agent-cancel').disabled = !running;
    byId('agent-choice').disabled = running || refreshing || !availableAgents.length;
    byId('agent-refresh').disabled = running || refreshing;
    byId('agent-prompt').disabled = running;
    byId('agent-consent').disabled = running;
    byId('agent-clear').disabled = running;
    byId('agent-model').textContent = availableAgents.find(item => item.key === byId('agent-choice').value)?.model || 'Model unavailable';
    byId('prompt-length').textContent = `${byId('agent-prompt').value.length.toLocaleString()} / 4,000`;
  }
  async function loadCatalog() {
    if (refreshing || activeRequest) return;
    refreshing = true;
    catalogLoaded = true;
    updateAgentControls();
    byId('agent-availability').textContent = 'Checking agent availability...';
    byId('foundry-connection').textContent = 'Checking...';
    const previous = byId('agent-choice').value;
    try {
      const response = await fetch('/api/agents/catalog', { cache: 'no-store', signal: AbortSignal.timeout(20000) });
      byId('agent-sign-in').hidden = response.status !== 401;
      const data = await response.json();
      availableAgents = response.ok && data.available && Array.isArray(data.agents) ? data.agents : [];
      byId('foundry-connection').textContent = response.status === 401 ? 'Sign-in required' : availableAgents.length
        ? `${availableAgents.length} agent${availableAgents.length === 1 ? '' : 's'} available` : 'Unavailable';
      byId('agent-availability').textContent = data.message || 'Agent discovery failed';
      byId('agent-choice').replaceChildren(...availableAgents.map(item => new Option(item.name, item.key)));
      if (!availableAgents.length) byId('agent-choice').append(new Option('No agents available', ''));
      if (availableAgents.some(item => item.key === previous)) byId('agent-choice').value = previous;
    } catch {
      availableAgents = [];
      byId('foundry-connection').textContent = 'Unavailable';
      byId('agent-choice').replaceChildren(new Option('No agents available', ''));
      byId('agent-availability').textContent = 'Agent discovery unavailable. Retry shortly.';
    } finally { refreshing = false; updateAgentControls(); }
  }
  byId('agent-refresh').addEventListener('click', loadCatalog);
  for (const id of ['agent-choice', 'agent-prompt', 'agent-consent']) byId(id).addEventListener('input', updateAgentControls);

  function element(tag, text, className) {
    const item = document.createElement(tag);
    item.textContent = text;
    if (className) item.className = className;
    return item;
  }
  function showAnswer(data, prompt, traceId) {
    const result = element('article', '', 'agent-result');
    result.append(element('h3', data.agent), element('p', prompt, 'submitted-task'), element('div', data.text || 'No text response was returned.', 'agent-answer'));
    const metadata = element('dl', '', 'agent-metadata');
    for (const [label, value] of [
      ['Model', data.model || 'Unavailable'], ['Latency', `${Math.round(data.durationMs).toLocaleString()} ms`],
      ['Input tokens', data.inputTokens?.toLocaleString() ?? 'Not reported'],
      ['Output tokens', data.outputTokens?.toLocaleString() ?? 'Not reported'],
      ['Estimated USD', data.estimatedCostUsd == null ? 'Rates not configured' : `$${Number(data.estimatedCostUsd).toFixed(6)}`],
      ['Run ID', data.runId || 'Unavailable'], ['Trace ID', traceId || 'Unavailable']
    ]) metadata.append(element('dt', label), element('dd', value));
    result.append(metadata);
    if (traceId) {
      const copy = element('button', '', 'icon-button');
      copy.title = 'Copy agent trace ID';
      copy.setAttribute('aria-label', copy.title);
      const icon = document.createElement('i');
      icon.dataset.lucide = 'copy';
      copy.append(icon);
      copy.addEventListener('click', async () => {
        try { await navigator.clipboard.writeText(traceId); toast('Agent trace ID copied'); }
        catch { toast('Clipboard unavailable. Select the trace ID to copy it.'); }
      });
      result.append(copy);
    }
    byId('agent-results').prepend(result);
    while (byId('agent-results').children.length > 10) byId('agent-results').lastElementChild.remove();
    refreshIcons();
  }
  byId('agent-form').addEventListener('submit', async event => {
    event.preventDefault();
    if (byId('agent-send').disabled) return;
    const prompt = byId('agent-prompt').value.trim();
    activeRequest = new AbortController();
    updateAgentControls();
    const started = performance.now();
    const ticker = setInterval(() => { byId('agent-status').textContent = `Agent task running / ${Math.floor((performance.now() - started) / 1000)} s`; }, 500);
    byId('agent-status').textContent = 'Submitting agent task...';
    try {
      const response = await fetch('/api/agents/run', {
        method: 'POST', cache: 'no-store', referrerPolicy: 'same-origin',
        headers: { 'Content-Type': 'application/json', 'X-Amlab-Agent-Request': 'true' },
        body: JSON.stringify({ agent: byId('agent-choice').value, prompt, consent: true }),
        signal: AbortSignal.any([activeRequest.signal, AbortSignal.timeout(115000)])
      });
      const traceId = response.headers.get('X-Amlab-Trace-Id') || '';
      const data = await response.json().catch(error => {
        if (error instanceof SyntaxError) return null;
        throw error;
      });
      byId('agent-sign-in').hidden = response.status !== 401 && response.status !== 403;
      if (!response.ok) {
        const retry = response.headers.get('Retry-After');
        const message = typeof data?.error === 'string' ? data.error : response.status === 401
          ? 'Sign in with an approved lab operator account before submitting again.' : response.status === 403
          ? 'App Service or the application rejected the request. Check sign-in and same-origin access.'
          : 'The app returned an unexpected response. Check the server trace before retrying.';
        byId('agent-status').textContent = `HTTP ${response.status}: ${message}${retry ? ` Retry after ${retry} seconds.` : ''}${traceId ? ` Trace: ${traceId}` : ''}`;
        return;
      }
      if (typeof data?.agent !== 'string' || typeof data?.text !== 'string') {
        byId('agent-status').textContent = `The app returned an invalid agent response (HTTP ${response.status}). Check sign-in and the server trace before retrying.${traceId ? ` Trace: ${traceId}` : ''}`;
        return;
      }
      showAnswer(data, prompt, data.traceId || traceId);
      byId('agent-status').textContent = `Completed / ${new Date().toISOString()}`;
    } catch (error) {
      byId('agent-status').textContent = error.name === 'AbortError' || error.name === 'TimeoutError'
        ? 'Stopped waiting. Server cancellation and cleanup are best-effort; incurred usage may still be billed.'
        : 'The app could not return a result. Check connectivity and the server trace before retrying.';
    } finally {
      clearInterval(ticker);
      activeRequest = null;
      byId('agent-consent').checked = false;
      updateAgentControls();
    }
  });
  byId('agent-cancel').addEventListener('click', () => activeRequest?.abort());
  byId('agent-clear').addEventListener('click', () => {
    byId('agent-results').replaceChildren();
    byId('agent-status').textContent = 'No tasks submitted';
    byId('agent-prompt').value = '';
    byId('agent-consent').checked = false;
    updateAgentControls();
  });
  activate(tabs[0]);
  loadContext();
}