export function initializeInfrastructureHealth({ refreshIcons, checkWebAppHealth }) {
  const byId = id => document.getElementById(id);
  const states = { healthy: 'Healthy', warning: 'Warning', critical: 'Critical', unknown: 'Unknown' };
  const types = {
    'microsoft.compute/virtualmachines': 'Virtual machine', 'microsoft.compute/virtualmachinescalesets': 'VM scale set',
    'microsoft.containerservice/managedclusters': 'AKS cluster', 'microsoft.web/sites': 'App Service',
    'microsoft.web/serverfarms': 'App Service plan', 'microsoft.insights/components': 'Application Insights',
    'microsoft.operationalinsights/workspaces': 'Log Analytics', 'microsoft.dashboard/grafana': 'Managed Grafana',
    'microsoft.keyvault/vaults': 'Key Vault', 'microsoft.storage/storageaccounts': 'Storage account'
  };
  let snapshot = null;
  let attempted = false;
  let pending = false;
  let failedRefresh = false;
  let nextCheck = 0;

  function element(tag, text, className) {
    const node = document.createElement(tag);
    if (text !== undefined) node.textContent = text;
    if (className) node.className = className;
    return node;
  }
  function state(value) { return Object.hasOwn(states, value) ? value : 'unknown'; }
  function badge(value) {
    const status = state(value);
    const node = element('span', undefined, `infra-badge infra-${status}`);
    const icon = element('i');
    icon.dataset.lucide = { healthy: 'check', warning: 'triangle-alert', critical: 'x', unknown: 'circle-help' }[status];
    node.append(icon, element('span', states[status]));
    return node;
  }
  function time(value) {
    const date = new Date(value);
    return value && Number.isFinite(date.getTime()) ? date.toLocaleString([], { dateStyle: 'short', timeStyle: 'medium' }) : 'Not reported';
  }
  function signalCell(signal, label) {
    const cell = element('td');
    cell.dataset.label = label;
    if (!signal) cell.append(element('span', 'No workbook rule for this resource type', 'muted'));
    else {
      cell.append(badge(signal.state), element('p', signal.detail || 'No assessment returned.'));
      if (signal.observedAt) cell.append(element('small', `Observed ${time(signal.observedAt)}`));
    }
    return cell;
  }
  function updateFreshness() {
    byId('infra-refresh').disabled = pending || Date.now() < nextCheck;
    byId('infra-refresh').title = pending ? 'Health check in progress' : Date.now() < nextCheck ? `Next check available ${time(nextCheck)}` : 'Refresh infrastructure health';
    const stale = Boolean(snapshot && (failedRefresh || !snapshot.expiresAt || Date.now() >= Date.parse(snapshot.expiresAt)));
    byId('infra-stale').hidden = !stale;
    byId('infra-stale').textContent = failedRefresh ? 'Showing the previous snapshot. The latest check was unsuccessful.' : 'Stale snapshot. A new check is available.';
    byId('infra-checked').textContent = snapshot ? `Checked ${time(snapshot.checkedAt)}${snapshot.cached ? ' / cached' : ''}` : 'Not checked';
  }
  function render() {
    const resources = snapshot?.resources || [];
    for (const status of Object.keys(states)) byId(`infra-count-${status}`).textContent = snapshot ? resources.filter(resource => state(resource.state) === status).length : '-';
    byId('infra-count-total').textContent = snapshot ? resources.length : '-';
    const search = byId('infra-search').value.trim().toLowerCase();
    const filter = byId('infra-filter').value;
    const visible = resources.filter(resource => (!filter || state(resource.state) === filter)
      && `${resource.name} ${resource.type} ${resource.location}`.toLowerCase().includes(search));
    const rows = visible.map(resource => {
      const row = element('tr');
      const name = element('td');
      name.dataset.label = 'Resource';
      const link = element('a', resource.name || 'Unnamed resource');
      try {
        const url = new URL(resource.portalUrl);
        if (url.protocol === 'https:' && url.hostname === 'portal.azure.com'
          && !url.port && !url.username && !url.password && !url.search && url.pathname === '/' && url.hash.startsWith('#resource/subscriptions/')) {
          link.href = url.href;
          link.target = '_blank';
          link.rel = 'noopener noreferrer';
          link.title = 'Open resource in Azure';
        }
      } catch {}
      name.append(link, element('small', types[resource.type?.toLowerCase()] || resource.type || 'Resource'), element('small', resource.location || 'Location not reported'));
      if (resource.provisioningState) name.append(element('small', `Provisioning: ${resource.provisioningState}`));
      const status = element('td');
      status.dataset.label = 'Status';
      status.append(badge(resource.state));
      row.append(name, status, signalCell(resource.platform, 'Platform availability'), signalCell(resource.telemetry, 'Workbook telemetry'));
      return row;
    });
    byId('infra-rows').replaceChildren(...rows);
    byId('infra-table').hidden = !visible.length;
    byId('infra-empty').hidden = visible.length > 0;
    byId('infra-empty-text').textContent = snapshot ? resources.length ? 'No resources match these filters.' : 'No resources were returned for this resource group.' : 'No infrastructure snapshot available.';
    byId('infra-visible').textContent = snapshot ? `${visible.length} of ${resources.length} resources` : '';
    byId('infra-sources').replaceChildren(...(snapshot?.sources || []).map(source => {
      const item = element('li');
      item.append(element('strong', source.name), element('span', source.available ? 'Checked' : 'Unavailable', source.available ? 'infra-healthy' : 'infra-warning'), element('p', source.detail));
      return item;
    }));
    byId('infra-source-details').hidden = !snapshot;
    updateFreshness();
    refreshIcons();
  }
  async function load(force = false) {
    updateFreshness();
    if (pending || (!force && attempted) || Date.now() < nextCheck) return;
    attempted = true;
    pending = true;
    void checkWebAppHealth();
    byId('infra-status').textContent = 'Checking lab infrastructure...';
    byId('panel-health').setAttribute('aria-busy', 'true');
    updateFreshness();
    try {
      const response = await fetch('/api/infra/health', { cache: 'no-store', signal: AbortSignal.timeout(50000) });
      const data = await response.json();
      byId('infra-sign-in').hidden = response.status !== 401;
      if (response.status === 401) {
        snapshot = null;
        failedRefresh = false;
        byId('infra-status').textContent = 'Sign in with an approved lab operator account to check infrastructure health.';
      } else if (response.ok && data.available && Array.isArray(data.resources)) {
        snapshot = data;
        failedRefresh = false;
        nextCheck = Math.max(Date.now(), Math.min(Date.now() + 60000, Date.parse(data.expiresAt) || Date.now()));
        byId('infra-status').textContent = data.message || 'Health snapshot received.';
      } else {
        failedRefresh = Boolean(snapshot);
        const retry = Number(response.headers.get('Retry-After'));
        nextCheck = Date.now() + (response.status === 429 && retry > 0 ? Math.min(retry, 120) : 15) * 1000;
        byId('infra-status').textContent = data.message || data.error || 'Infrastructure health could not be checked.';
      }
    } catch {
      failedRefresh = Boolean(snapshot);
      nextCheck = Date.now() + 15000;
      byId('infra-status').textContent = 'Infrastructure health could not be reached. Check connectivity and retry.';
    } finally {
      pending = false;
      byId('panel-health').setAttribute('aria-busy', 'false');
      render();
    }
  }
  byId('infra-refresh').addEventListener('click', () => load(true));
  byId('infra-search').addEventListener('input', render);
  byId('infra-filter').addEventListener('change', render);
  setInterval(updateFreshness, 1000);
  return { load };
}