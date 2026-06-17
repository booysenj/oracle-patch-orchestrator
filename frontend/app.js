const API = window.location.origin + '/api';
const WS_URL = (window.location.protocol === 'https:' ? 'wss://' : 'ws://') + window.location.host + '/ws/logs';
let TOKEN = localStorage.getItem('token') || '';
let currentUser = localStorage.getItem('currentUser') || '';
let vms = [];
let selectedVm = null;
let ws = null;
let activeLogJobId = null;
let autoRefreshTimer = null;
let autoRefreshMs = parseInt(localStorage.getItem('autoRefreshMs') || '30000');
let orchSettings = {};

// -- Theme Manager --
const THEMES = {
  dark: {
    '--bg':'#0c0e14','--surface':'#151821','--surface2':'#1e2230','--surface3':'#262a3a',
    '--border':'#2a2e3f','--border-hover':'#3d4260','--text':'#e4e7f0','--text-dim':'#7c8198',
    '--text-muted':'#555a70','--accent':'#5b9aff','--accent-hover':'#4888f0',
    '--accent-glow':'rgba(91,154,255,0.15)','--log-bg':'#080a10'
  },
  midnight: {
    '--bg':'#0a0f1e','--surface':'#111833','--surface2':'#182040','--surface3':'#1f2a50',
    '--border':'#253060','--border-hover':'#354580','--text':'#d8dff5','--text-dim':'#8090c0',
    '--text-muted':'#506090','--accent':'#7c6aff','--accent-hover':'#6b58e8',
    '--accent-glow':'rgba(124,106,255,0.15)','--log-bg':'#060a18'
  },
  nord: {
    '--bg':'#2e3440','--surface':'#3b4252','--surface2':'#434c5e','--surface3':'#4c566a',
    '--border':'#4c566a','--border-hover':'#5e6a82','--text':'#eceff4','--text-dim':'#d8dee9',
    '--text-muted':'#7b88a1','--accent':'#88c0d0','--accent-hover':'#81a1c1',
    '--accent-glow':'rgba(136,192,208,0.15)','--log-bg':'#242933'
  },
  light: {
    '--bg':'#f5f6fa','--surface':'#ffffff','--surface2':'#f0f1f5','--surface3':'#e8e9ef',
    '--border':'#d8dae0','--border-hover':'#c0c3cc','--text':'#1a1d2e','--text-dim':'#4a4e68',
    '--text-muted':'#8a8ea5','--accent':'#3b7dff','--accent-hover':'#2a6ae8',
    '--accent-glow':'rgba(59,125,255,0.1)','--log-bg':'#f8f9fc'
  },
  solarized: {
    '--bg':'#002b36','--surface':'#073642','--surface2':'#0a4050','--surface3':'#0d4d5e',
    '--border':'#1a5c6c','--border-hover':'#2a7a8c','--text':'#fdf6e3','--text-dim':'#93a1a1',
    '--text-muted':'#657b83','--accent':'#b58900','--accent-hover':'#cb9a00',
    '--accent-glow':'rgba(181,137,0,0.15)','--log-bg':'#001e28'
  },
  dracula: {
    '--bg':'#1e1f29','--surface':'#282a36','--surface2':'#2e303e','--surface3':'#363848',
    '--border':'#44475a','--border-hover':'#5a5e78','--text':'#f8f8f2','--text-dim':'#bfc0cc',
    '--text-muted':'#6272a4','--accent':'#bd93f9','--accent-hover':'#a87de8',
    '--accent-glow':'rgba(189,147,249,0.15)','--log-bg':'#15161e'
  }
};

function setTheme(name) {
  var vars = THEMES[name];
  if (!vars) return;
  var root = document.documentElement;
  Object.entries(vars).forEach(function(kv) { root.style.setProperty(kv[0], kv[1]); });
  localStorage.setItem('theme', name);
  document.querySelectorAll('.theme-btn').forEach(function(b) {
    b.classList.toggle('active', b.dataset.theme === name);
  });
}

function initTheme() { setTheme(localStorage.getItem('theme') || 'dark'); }

// -- Toast Notifications --
function showToast(message, type) {
  type = type || 'info';
  var container = document.getElementById('toastContainer');
  if (!container) {
    container = document.createElement('div');
    container.id = 'toastContainer';
    container.className = 'toast-container';
    document.body.appendChild(container);
  }
  var toast = document.createElement('div');
  toast.className = 'toast toast-' + type;
  var icons = { success:'\u2714', error:'\u2718', info:'\u2139', warning:'\u26A0' };
  toast.innerHTML = '<span class="toast-icon">' + (icons[type]||icons.info) + '</span>' +
    '<span class="toast-msg">' + message + '</span>' +
    '<button class="toast-close" onclick="this.parentElement.remove()">\u00D7</button>';
  container.appendChild(toast);
  requestAnimationFrame(function() { toast.classList.add('toast-show'); });
  setTimeout(function() {
    toast.classList.remove('toast-show');
    toast.classList.add('toast-hide');
    setTimeout(function() { toast.remove(); }, 300);
  }, 5000);
}

// -- API Helper --
async function api(path, opts) {
  opts = opts || {};
  var res = await fetch(API + path, Object.assign({}, opts, {
    headers: Object.assign({
      'Content-Type': 'application/json',
      'Authorization': 'Bearer ' + TOKEN
    }, opts.headers || {})
  }));
  if (res.status === 401 || res.status === 403) {
    logout();
    throw new Error('Session expired');
  }
  if (!res.ok) { var errData = await res.json().catch(function() { return {}; }); throw new Error(errData.error || 'HTTP ' + res.status); }
  return res.json();
}

// -- Auth / Login --
async function doLogin() {
  var user = document.getElementById('loginUser').value.trim();
  var pass = document.getElementById('loginPass').value;
  var errEl = document.getElementById('loginError');
  errEl.textContent = '';
  if (!user || !pass) { errEl.textContent = 'Enter username and password'; return; }
  var btn = document.getElementById('loginBtn');
  btn.disabled = true; btn.textContent = 'Signing in...';
  try {
    var res = await fetch(API + '/auth/login', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ username: user, password: pass })
    });
    var data = await res.json();
    if (!res.ok) throw new Error(data.error || 'Login failed');
    TOKEN = data.token;
    currentUser = data.username;
    localStorage.setItem('token', TOKEN);
    localStorage.setItem('currentUser', currentUser);
    localStorage.setItem('role', data.role);
    showApp();
    showToast('Welcome, ' + currentUser, 'success');
  } catch (e) {
    errEl.textContent = e.message;
  } finally {
    btn.disabled = false; btn.textContent = 'Sign In';
  }
}

function logout() {
  TOKEN = '';
  currentUser = '';
  localStorage.removeItem('token');
  localStorage.removeItem('role');
  localStorage.removeItem('currentUser');
  stopAutoRefresh();
  showLogin();
}

function showLogin() {
  document.getElementById('loginScreen').classList.remove('hidden');
  document.getElementById('appShell').classList.add('hidden');
}

function showApp() {
  document.getElementById('loginScreen').classList.add('hidden');
  document.getElementById('appShell').classList.remove('hidden');
  var el = document.getElementById('userDisplay');
  if (el) el.textContent = currentUser;
  loadOrcSettings();
  loadVMs();
  startAutoRefresh();
  showAdminTab();
}

async function loadOrcSettings() {
  try {
    var data = await api('/admin/settings');
    orchSettings = data || {};
    // Populate settings fields if Admin tab has been rendered
    var fields = {
      orchestrator_url: 'settingOrcUrl',
      gi_base_zip_path: 'settingGiZip',
      db_base_zip_path: 'settingDbZip',
      gi_home_base: 'settingGiHomeBase',
      db_home_base: 'settingDbHomeBase',
      patches_base_path: 'settingPatchesBase'
    };
    Object.keys(fields).forEach(function(key) {
      var el = document.getElementById(fields[key]);
      if (el && orchSettings[key]) el.value = orchSettings[key];
    });
  } catch(e) { /* settings optional */ }
}

async function saveOrcSettings() {
  var body = {
    orchestrator_url: (document.getElementById('settingOrcUrl') || {}).value || '',
    gi_base_zip_path: (document.getElementById('settingGiZip') || {}).value || '',
    db_base_zip_path: (document.getElementById('settingDbZip') || {}).value || '',
    gi_home_base: (document.getElementById('settingGiHomeBase') || {}).value || '',
    db_home_base: (document.getElementById('settingDbHomeBase') || {}).value || '',
    patches_base_path: (document.getElementById('settingPatchesBase') || {}).value || ''
  };
  try {
    await api('/admin/settings', { method: 'PUT', body: JSON.stringify(body) });
    orchSettings = body;
    var msg = document.getElementById('settingsMsg');
    if (msg) { msg.textContent = 'Saved'; setTimeout(function() { msg.textContent = ''; }, 3000); }
    showToast('Orchestrator settings saved', 'success');
  } catch(e) {
    showToast('Failed to save settings: ' + e.message, 'error');
  }
}

// -- Tab Navigation --
document.querySelectorAll('.nav-btn').forEach(function(btn) {
  btn.addEventListener('click', function() {
    document.querySelectorAll('.nav-btn').forEach(function(b) { b.classList.remove('active'); });
    document.querySelectorAll('.tab-content').forEach(function(t) { t.classList.remove('active'); });
    btn.classList.add('active');
    document.getElementById('tab-' + btn.dataset.tab).classList.add('active');
    if (btn.dataset.tab === 'jobs') loadJobs(); if (btn.dataset.tab === 'admin') { loadUsers(); loadOrcSettings(); } if (btn.dataset.tab === 'patches') loadPatches();
  });
});

// -- VM Dashboard --
async function loadVMs() {
  var grid = document.getElementById('vmGrid');
  grid.innerHTML = '<div class="loading-state"><div class="spinner"></div><p>Loading VMs...</p></div>';
  try {
    vms = await api('/vms');
    renderVMs(vms);
    document.getElementById('vmCount').textContent = vms.length + ' VM' + (vms.length !== 1 ? 's' : '');
  } catch (e) {
    if (e.message === 'Session expired') return;
    grid.innerHTML = '<div class="empty-state"><div class="empty-icon"><svg width="48" height="48" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5"><rect x="2" y="3" width="20" height="14" rx="2"/><line x1="8" y1="21" x2="16" y2="21"/><line x1="12" y1="17" x2="12" y2="21"/></svg></div><h3>Could not load VMs</h3><p>Check your connection and try again</p><button class="btn btn-sm btn-secondary" onclick="loadVMs()">Retry</button></div>';
    showToast('Failed to load VMs: ' + e.message, 'error');
  }
}

function renderVMs(list) {
  var grid = document.getElementById('vmGrid');
  document.getElementById('vmCount').textContent = list.length + ' VM' + (list.length !== 1 ? 's' : '');
  if (!list.length) {
    grid.innerHTML = '<div class="empty-state"><div class="empty-icon"><svg width="48" height="48" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5"><rect x="2" y="3" width="20" height="14" rx="2"/><line x1="8" y1="21" x2="16" y2="21"/><line x1="12" y1="17" x2="12" y2="21"/></svg></div><h3>No VMs found</h3><p>Try adjusting your search or filters</p></div>';
    return;
  }
  grid.innerHTML = list.map(function(vm) {
    var mode = vm.execution_mode || 'agent';
    var agentOnline = false;
    if (mode === 'agent' && vm.agent_last_seen) {
      var seenMs = new Date(vm.agent_last_seen + 'Z').getTime();
      agentOnline = (Date.now() - seenMs) < 30000;
    }
    var agentBadge = mode === 'agent'
      ? '<span class="agent-status-dot ' + (agentOnline ? 'agent-online' : 'agent-offline') + '" title="Agent ' + (agentOnline ? 'online' : 'offline') + '">&#9679;</span>'
      : '';
    var modeBadge = '<span class="exec-mode-badge exec-mode-' + mode + '">' + mode.toUpperCase() + '</span>';
    return '<div class="vm-card" data-id="' + vm.id + '">' +
      '<div class="vm-card-header">' +
        '<span class="vm-hostname">' + esc(vm.hostname) + '</span>' +
        '<div style="display:flex;gap:6px;align-items:center">' + agentBadge + modeBadge + '<span class="vm-env env-' + vm.environment + '">' + vm.environment + '</span></div>' +
      '</div>' +
      '<div class="vm-details">' +
        '<span class="vm-detail-label">IP</span><span class="vm-detail-value">' + esc(vm.ip) + '</span>' +
        '<span class="vm-detail-label">Role</span><span class="vm-detail-value">' + (vm.node_role || '\u2014') + '</span>' +
        '<span class="vm-detail-label">Patch</span><span class="vm-detail-value"><span class="patch-badge">' + (vm.patch_target || '19.26') + '</span></span>' +
        '<span class="vm-detail-label">Last Job</span><span class="vm-detail-value">' + (vm.last_status ? statusBadge(vm.last_status) : '\u2014') + '</span>' +
      '</div>' +
      '<div class="vm-card-actions">' +
        '<button class="btn btn-sm btn-secondary" onclick="deleteVm(\'' + vm.id + '\',\'' + esc(vm.hostname) + '\')" title="Delete VM">' +
          '<svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><polyline points="3 6 5 6 21 6"/><path d="M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6m3 0V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2"/></svg>' +
          '</button>' +
        '<button class="btn btn-sm btn-secondary" onclick="deployAgent(\'' + vm.id + '\',\'' + esc(vm.hostname) + '\')" title="Deploy/Update Agent">' +
          '<svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><polyline points="16 16 12 12 8 16"/><line x1="12" y1="12" x2="12" y2="21"/><path d="M20.39 18.39A5 5 0 0 0 18 9h-1.26A8 8 0 1 0 3 16.3"/></svg>' +
          '</button>' +
        '<button class="btn btn-sm btn-primary" onclick="openModal(\'' + vm.id + '\')">' +
          '<svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><polygon points="5 3 19 12 5 21 5 3"/></svg>' +
          ' Run Job</button>' +
      '</div>' +
    '</div>';
  }).join('');
}

// -- Search & Filter --
document.getElementById('vmSearch').addEventListener('input', filterVMs);
document.getElementById('envFilter').addEventListener('change', filterVMs);
document.getElementById('refreshVMs').addEventListener('click', function() {
  loadVMs();
  showToast('Dashboard refreshed', 'info');
});

function filterVMs() {
  var q = document.getElementById('vmSearch').value.toLowerCase();
  var env = document.getElementById('envFilter').value;
  var filtered = vms.filter(function(vm) {
    var matchQ = !q || vm.hostname.toLowerCase().includes(q) || vm.ip.includes(q) || (vm.node_role||'').toLowerCase().includes(q);
    var matchEnv = !env || vm.environment === env;
    return matchQ && matchEnv;
  });
  renderVMs(filtered);
}

// -- Job Launcher Modal --
async function openModal(vmId) {
  selectedVm = vms.find(function(v) { return v.id === vmId; });
  if (!selectedVm) return;
  document.getElementById('modalTitle').textContent = 'Run Operation - ' + selectedVm.hostname;
  document.getElementById('modalVmInfo').innerHTML =
    '<strong>' + esc(selectedVm.hostname) + '</strong> (' + esc(selectedVm.ip) + ')<br>' +
    'Environment: ' + selectedVm.environment + ' | Role: ' + (selectedVm.node_role || '-') + ' | Patch: ' + (selectedVm.patch_target || '19.26');

  await loadOperations();
  var catSel = document.getElementById('opCategory');
  catSel.innerHTML = '<option value="">-- Select Category --</option>';
  if (opsCache) {
    var keys = Object.keys(opsCache);
    for (var k = 0; k < keys.length; k++) {
      var opt = document.createElement('option');
      opt.value = keys[k];
      opt.textContent = opsCache[keys[k]].label;
      catSel.appendChild(opt);
    }
  }
  var opSel = document.getElementById('opSelect');
  opSel.innerHTML = '<option value="">-- Select a category first --</option>';
  opSel.disabled = true;
  var metaEl = document.getElementById('opMeta');
  if (metaEl) metaEl.classList.add('hidden');
  document.getElementById('dryRunCheck').checked = false;
  document.getElementById('preflightResult').classList.add('hidden');
  document.getElementById('preflightBtn').disabled = true;
  document.getElementById('executeBtn').disabled = true;
  document.getElementById('launchModal').classList.remove('hidden');
}

function closeModal() {
  document.getElementById('launchModal').classList.add('hidden');
  selectedVm = null;
}

document.getElementById('opSelect').addEventListener('change', function() {
  var op = document.getElementById('opSelect').value;
  document.getElementById('preflightBtn').disabled = !op;
  document.getElementById('executeBtn').disabled = !op;
  document.getElementById('preflightResult').classList.add('hidden');
});

// -- Preflight --
document.getElementById('preflightBtn').addEventListener('click', async function() {
  var op = document.getElementById('opSelect').value;
  if (!op || !selectedVm) return;
  var box = document.getElementById('preflightResult');
  box.classList.remove('hidden','preflight-ok','preflight-warn','preflight-block');
  box.textContent = 'Running preflight checks...';
  try {
    var pf = await api('/jobs/preflight', {
      method: 'POST',
      body: JSON.stringify({ vmId: selectedVm.id, operation: op, dbUniqueName: (document.getElementById('dbUniqueName') || {}).value || '' })
    });
    var html = '';
    if (pf.vmLocked) {
      box.classList.add('preflight-block');
      html = '<strong>BLOCKED</strong> - VM is locked by ' + esc(pf.lockDetails.created_by || 'unknown');
      box.innerHTML = html;
      document.getElementById('executeBtn').disabled = true;
      return;
    }
    if (pf.causesDowntime) {
      box.classList.add('preflight-warn');
      html = '<strong>WARNING: Downtime Operation</strong><br>';
      html += 'This operation will cause service interruption.<br>';
      if (pf.warnings && pf.warnings.length) {
        for (var w = 0; w < pf.warnings.length; w++) html += '- ' + esc(pf.warnings[w]) + '<br>';
      }
      if (pf.rollbackAvailable) html += 'Rollback is available.<br>';
      html += '<br>Click <strong>Execute</strong> to confirm and proceed.';
      box.innerHTML = html;
      document.getElementById('executeBtn').disabled = false;
      document.getElementById('executeBtn').dataset.confirmed = '1';
    } else {
      box.classList.add('preflight-ok');
      html = '<strong>All checks passed</strong><br>';
      if (pf.warnings && pf.warnings.length) {
        for (var w = 0; w < pf.warnings.length; w++) html += '- ' + esc(pf.warnings[w]) + '<br>';
      }
      html += 'Ready to execute.';
      box.innerHTML = html;
      document.getElementById('executeBtn').disabled = false;
      document.getElementById('executeBtn').dataset.confirmed = '0';
    }
  } catch(e) {
    box.classList.add('preflight-block');
    box.innerHTML = '<strong>Preflight failed:</strong> ' + esc(e.message || 'Unknown error');
    document.getElementById('executeBtn').disabled = true;
  }
});

document.getElementById('executeBtn').addEventListener('click', async function() {
  var op = document.getElementById('opSelect').value;
  if (!op || !selectedVm) return;
  var dryRun = document.getElementById('dryRunCheck').checked;
  var needsConfirm = document.getElementById('executeBtn').dataset.confirmed === '1';

  if (needsConfirm && !dryRun) {
    if (!confirm('This is a DOWNTIME operation on ' + selectedVm.hostname + '. Are you sure you want to proceed?')) return;
  }

  var box = document.getElementById('preflightResult');
  box.classList.remove('preflight-ok','preflight-warn','preflight-block');
  box.classList.remove('hidden');
  box.textContent = 'Launching job...';

  try {
    // Check if DB Unique Name is required
    var opOpt = document.getElementById('opSelect').options[document.getElementById('opSelect').selectedIndex];
    var dbUniqueName = '';
    if (opOpt && opOpt.dataset.needsDb === '1') {
      var dbInput = document.getElementById('dbUniqueName');
      dbUniqueName = dbInput ? dbInput.value.trim() : '';
      if (!dbUniqueName) {
        box.classList.add('preflight-block');
        box.innerHTML = '<strong>Error:</strong> DB Unique Name is required for this operation.';
        return;
      }
    }
    var body = {
      vmId: selectedVm.id,
      operation: op,
      dryRun: dryRun,
      dbUniqueName: dbUniqueName,
      confirmationToken: 'CONFIRMED'
    };
    var result = await api('/jobs', {
      method: 'POST',
      body: JSON.stringify(body)
    });
    box.classList.add('preflight-ok');
    box.innerHTML = 'Job started: <strong>' + result.jobId + '</strong>';
    showToast('Job launched on ' + selectedVm.hostname + (dryRun ? ' (dry-run)' : ''), 'success');
    closeModal();
    if (typeof openLogViewer === 'function') openLogViewer(result.jobId, selectedVm.hostname, op);
    loadJobs();
  } catch(e) {
    box.classList.add('preflight-block');
    box.innerHTML = '<strong>Failed:</strong> ' + esc(e.message || 'Unknown error');
  }
});

// -- Log Viewer --
function openLogViewer(jobId, hostname, operation) {
  activeLogJobId = jobId;
  document.getElementById('logModalTitle').textContent = 'Logs \u2014 ' + hostname + ' \u2014 ' + operation;
  document.getElementById('logOutput').innerHTML = '';
  document.getElementById('jobMeta').innerHTML =
    '<span>Job: ' + jobId.slice(0,8) + '\u2026</span>' +
    '<span>Host: ' + esc(hostname) + '</span>' +
    '<span>Op: ' + operation + '</span>' +
    '<span id="logJobStatus" class="status-badge status-running">\u25CF Running</span>';
  document.getElementById('logModal').classList.remove('hidden');
  loadLogs(jobId);
  connectLogWS(jobId);
  startLogPolling(jobId);
}

function closeLogModal() {
  stopLogPolling();
  document.getElementById('logModal').classList.add('hidden');
  activeLogJobId = null;
  if (ws) { ws.close(); ws = null; }
}

async function loadLogs(jobId) {
  try {
    var logs = await api('/logs/' + jobId);
    if (Array.isArray(logs)) { logs.forEach(function(l) { appendLogLine(l); }); }
  } catch (e) { /* will get via WS */ }
}

function appendLogLine(log) {
  var pre = document.getElementById('logOutput');
  var cls = log.stream === 'stderr' ? 'log-line-stderr' :
            log.stream === 'system' ? 'log-line-system' : 'log-line-stdout';
  var line = document.createElement('span');
  line.className = cls;
  line.textContent = (log.ts || '') + ' ' + (log.line || '') + '\n';
  pre.appendChild(line);
  var container = document.getElementById('logContainer');
  container.scrollTop = container.scrollHeight;
}

function connectLogWS(jobId) {
  if (ws) ws.close();
  ws = new WebSocket(WS_URL + '?token=' + encodeURIComponent(TOKEN));
  ws.onopen = function() {
    updateConnStatus(true);
    ws.send(JSON.stringify({ action: 'subscribe', jobId: jobId }));
  };
  ws.onclose = function() { updateConnStatus(false); checkJobStatus(jobId); };
  ws.onerror = function() { updateConnStatus(false); };
  ws.onmessage = function(evt) {
    try {
      var msg = JSON.parse(evt.data);
      if (msg.type === 'log') { appendLogLine(msg); }
      else if (msg.type === 'done') {
        updateJobStatus(msg.status);
        if (msg.status === 'success') { showToast('Job completed successfully', 'success'); if (ws) ws.close(); }
        else if (msg.status === 'failed') { showToast('Job failed', 'error'); if (ws) ws.close(); }
      }
    } catch (e) { appendLogLine({ stream:'stdout', line:evt.data, ts:'' }); }
  };
}

async function checkJobStatus(jobId) {
  try { var job = await api('/jobs/' + jobId); updateJobStatus(job.status); } catch (e) {}
}

function updateJobStatus(status) {
  var el = document.getElementById('logJobStatus');
  if (!el) return;
  el.className = 'status-badge status-' + status;
  var labels = { success:'\u2714 Success', failed:'\u2718 Failed', running:'\u25CF Running' };
  el.textContent = labels[status] || status;
}

function updateConnStatus(connected) {
  var el = document.getElementById('connStatus');
  if (!el) return;
  el.className = 'conn-badge ' + (connected ? 'connected' : 'disconnected');
  el.innerHTML = '\u25CF ' + (connected ? 'Connected' : 'Disconnected');
}

// -- Job History --
function openClearHistoryModal() {
  // Populate VM checkboxes from loaded vms list
  var list = document.getElementById('clearVmList');
  list.innerHTML = vms.length
    ? vms.map(function(v) {
        return '<label style="display:flex;align-items:center;gap:8px;font-weight:normal">' +
          '<input type="checkbox" class="clear-vm-check" value="' + v.id + '" />' +
          esc(v.hostname) + ' <span style="color:var(--text-muted);font-size:12px">(' + esc(v.ip) + ')</span></label>';
      }).join('')
    : '<span style="color:var(--text-muted);font-size:13px">No VMs loaded</span>';
  document.getElementById('clearHistoryError').textContent = '';
  document.getElementById('clearHistoryModal').classList.remove('hidden');
}

function closeClearHistoryModal() {
  document.getElementById('clearHistoryModal').classList.add('hidden');
}

async function confirmClearHistory() {
  var errEl = document.getElementById('clearHistoryError');
  errEl.textContent = '';

  var statuses = [];
  if (document.getElementById('clearStatusSuccess').checked) statuses.push('success');
  if (document.getElementById('clearStatusFailed').checked) statuses.push('failed');
  if (document.getElementById('clearStatusCancelled').checked) statuses.push('cancelled');
  if (!statuses.length) { errEl.textContent = 'Select at least one status to clear.'; return; }

  var before = document.getElementById('clearBeforeDate').value || null;
  var checkedVms = Array.from(document.querySelectorAll('.clear-vm-check:checked')).map(function(c) { return c.value; });

  try {
    var result = await api('/jobs/history', {
      method: 'DELETE',
      body: JSON.stringify({ before: before, vmIds: checkedVms.length ? checkedVms : null, statuses: statuses })
    });
    closeClearHistoryModal();
    showToast('Deleted ' + result.deleted + ' job record(s)', 'success');
    loadJobs();
  } catch(e) {
    errEl.textContent = e.message || 'Failed to clear history';
  }
}

async function loadJobs() {
  var tbody = document.getElementById('jobsBody');
  tbody.innerHTML = '<tr><td colspan="6" class="loading"><div class="spinner" style="margin:0 auto"></div></td></tr>';
  try {
    var jobs = await api('/jobs');
    var statusFilter = document.getElementById('jobStatusFilter').value;
    var filtered = statusFilter ? jobs.filter(function(j) { return j.status === statusFilter; }) : jobs;
    if (!filtered.length) {
      tbody.innerHTML = '<tr><td colspan="6" class="loading"><div class="empty-state-inline"><svg width="32" height="32" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5"><path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"/><polyline points="14 2 14 8 20 8"/></svg><p>No jobs found</p></div></td></tr>';
      return;
    }
    tbody.innerHTML = filtered.map(function(j) {
      return '<tr>' +
        '<td><span class="mono">' + esc(j.hostname || '\u2014') + '</span></td>' +
        '<td>' + esc(j.operation) + '</td>' +
        '<td>' + statusBadge(j.status) + '</td>' +
        '<td>' + formatDate(j.started_at) + '</td>' +
        '<td>' + duration(j.started_at, j.finished_at) + '</td>' +
        '<td><button class="btn btn-sm btn-secondary" onclick="openLogViewer(\'' + j.id + '\',\'' + esc(j.hostname||'') + '\',\'' + j.operation + '\')">' +
          '<svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"/><polyline points="14 2 14 8 20 8"/></svg>' +
          ' Logs</button></td></tr>';
    }).join('');
  } catch (e) {
    if (e.message === 'Session expired') return;
    tbody.innerHTML = '<tr><td colspan="6" class="loading">Failed to load jobs</td></tr>';
    showToast('Failed to load jobs: ' + e.message, 'error');
  }
}

document.getElementById('jobStatusFilter').addEventListener('change', loadJobs);
document.getElementById('refreshJobs').addEventListener('click', function() { loadJobs(); showToast('Jobs refreshed','info'); });

// -- Auto Refresh --
function startAutoRefresh() {
  stopAutoRefresh();
  if (autoRefreshMs <= 0) { updateAutoRefreshBadge(); return; }
  autoRefreshTimer = setInterval(function() {
    loadVMs();
    var jobsTab = document.getElementById('tab-jobs');
    if (jobsTab && jobsTab.classList.contains('active')) loadJobs();
  }, autoRefreshMs);
  updateAutoRefreshBadge();
}

function stopAutoRefresh() {
  if (autoRefreshTimer) { clearInterval(autoRefreshTimer); autoRefreshTimer = null; }
}

function setAutoRefresh(ms) {
  autoRefreshMs = ms;
  localStorage.setItem('autoRefreshMs', ms);
  startAutoRefresh();
  showAdminTab();
  var label = ms === 0 ? 'Off' : (ms / 1000) + 's';
  showToast('Auto-refresh set to ' + label, 'info');
  // Update active state on buttons
  document.querySelectorAll('.refresh-opt').forEach(function(b) {
    b.classList.toggle('active', parseInt(b.dataset.ms) === ms);
  });
}

function updateAutoRefreshBadge() {
  var el = document.getElementById('autoRefreshStatus');
  if (!el) return;
  el.textContent = autoRefreshMs === 0 ? 'Auto-refresh: Off' : 'Auto-refresh: ' + (autoRefreshMs/1000) + 's';
}

// -- Helpers --
function statusBadge(status) {
  var icons = { success:'\u2714', failed:'\u2718', running:'\u25CF', pending:'\u25CB' };
  return '<span class="status-badge status-' + status + '">' + (icons[status]||'\u25CB') + ' ' + status + '</span>';
}

function formatDate(d) {
  if (!d || d === "null" || d === "undefined") return "-";
  var s = String(d).replace(" ", "T");
  if (!/Z$/.test(s) && !/[+-]\d{2}:?\d{2}$/.test(s)) s += "Z";
  var dt = new Date(s);
  if (isNaN(dt.getTime())) return d;
  return dt.toLocaleString("en-ZA", { day:"2-digit", month:"short", year:"numeric", hour:"2-digit", minute:"2-digit" });
}

function duration(start, end) {
  if (!start || !end) return '\u2014';
  var ms = new Date(end + 'Z') - new Date(start + 'Z');
  var s = Math.floor(ms / 1000);
  if (s < 60) return s + 's';
  var m = Math.floor(s / 60);
  return m + 'm ' + (s % 60) + 's';
}

function esc(str) {
  var d = document.createElement('div');
  d.textContent = str || '';
  return d.innerHTML;
}


// -- VM Management --
function openAddVmModal() {
  document.getElementById('addVmModal').classList.remove('hidden');
  document.getElementById('addVmTab').dataset.mode = 'single';
  document.getElementById('singleVmForm').classList.remove('hidden');
  document.getElementById('bulkVmForm').classList.add('hidden');
  document.querySelectorAll('.add-vm-tab').forEach(function(b) {
    b.classList.toggle('active', b.dataset.mode === 'single');
  });
  // Reset form
  document.getElementById('addVmHostname').value = '';
  document.getElementById('addVmIp').value = '';
  document.getElementById('addVmSshUser').value = 'oracle';
  document.getElementById('addVmSshPort').value = '22';
  document.getElementById('addVmRole').value = 'UNKNOWN';
  document.getElementById('addVmEnv').value = 'UAT';
  document.getElementById('addVmPatch').value = '19.26';
  document.getElementById('bulkVmText').value = '';
  document.getElementById('bulkVmPatch').value = '19.26';
  document.getElementById('addVmError').textContent = '';
}

function closeAddVmModal() {
  document.getElementById('addVmModal').classList.add('hidden');
}

function switchAddVmTab(mode) {
  document.querySelectorAll('.add-vm-tab').forEach(function(b) {
    b.classList.toggle('active', b.dataset.mode === mode);
  });
  document.getElementById('singleVmForm').classList.toggle('hidden', mode !== 'single');
  document.getElementById('bulkVmForm').classList.toggle('hidden', mode !== 'bulk');
}

async function addSingleVm() {
  var errEl = document.getElementById('addVmError');
  errEl.textContent = '';
  var hostname = document.getElementById('addVmHostname').value.trim();
  var ip = document.getElementById('addVmIp').value.trim();
  if (!hostname || !ip) { errEl.textContent = 'Hostname and IP are required'; return; }
  try {
    await api('/vms', {
      method: 'POST',
      body: JSON.stringify({
        hostname: hostname,
        ip: ip,
        ssh_user: document.getElementById('addVmSshUser').value.trim() || 'oracle',
        ssh_port: parseInt(document.getElementById('addVmSshPort').value) || 22,
        node_role: document.getElementById('addVmRole').value,
        environment: document.getElementById('addVmEnv').value,
        patch_target: document.getElementById('addVmPatch').value,
        execution_mode: document.getElementById('addVmExecMode').value || 'agent',
        stage_path: document.getElementById('addVmStagePath').value.trim() || null
      })
    });
    showToast('VM ' + hostname + ' added', 'success');
    closeAddVmModal();
    loadVMs();
  } catch (e) {
    errEl.textContent = 'Failed: ' + e.message;
    showToast('Failed to add VM: ' + e.message, 'error');
  }
}

async function bulkImportVms() {
  var errEl = document.getElementById('addVmError');
  errEl.textContent = '';
  var text = document.getElementById('bulkVmText').value.trim();
  var patchTarget = document.getElementById('bulkVmPatch').value;
  var bulkEnv = document.getElementById('bulkVmEnv').value;
  if (!text) { errEl.textContent = 'Paste VM list'; return; }
  var lines = text.split('\n').filter(function(l) { return l.trim(); });
  var vmList = [];
  for (var i = 0; i < lines.length; i++) {
    var parts = lines[i].trim().split(/[,\t;|]+/);
    if (parts.length < 2) { errEl.textContent = 'Line ' + (i+1) + ': need at least hostname,ip'; return; }
    var vmObj = {
      hostname: parts[0].trim(),
      ip: parts[1].trim(),
      environment: bulkEnv,
      patch_target: patchTarget
    };
    if (parts[2]) vmObj.ssh_user = parts[2].trim();
    if (parts[3]) vmObj.node_role = parts[3].trim();
    vmList.push(vmObj);
  }
  try {
    var result = await api('/vms/bulk', {
      method: 'POST',
      body: JSON.stringify({ vms: vmList })
    });
    showToast(result.imported + ' VMs imported', 'success');
    closeAddVmModal();
    loadVMs();
  } catch (e) {
    errEl.textContent = 'Import failed: ' + e.message;
    showToast('Bulk import failed: ' + e.message, 'error');
  }
}

async function deployAgent(vmId, hostname) {
  if (!confirm('Deploy/update agent on ' + hostname + '?\n\nThis will upload the latest insight-agent.py and restart the service.')) return;
  showToast('Deploying agent to ' + hostname + '...', 'info');
  try {
    var result = await api('/admin/vms/' + vmId + '/deploy-agent', { method: 'POST', body: '{}' });
    showToast('Agent deployed to ' + hostname + ' — status: ' + (result.serviceStatus || result.output || 'ok'), 'success');
    setTimeout(loadVMs, 3000);
  } catch(e) {
    showToast('Deploy failed: ' + e.message, 'error');
  }
}

async function deleteVm(vmId, hostname) {
  if (!confirm('Delete VM ' + hostname + '?')) return;
  try {
    await api('/vms/' + vmId, { method: 'DELETE' });
    showToast(hostname + ' deleted', 'success');
    loadVMs();
  } catch (e) {
    showToast('Delete failed: ' + e.message, 'error');
  }
}


// -- Dynamic Operations --
var opsCache = null;

async function loadOperations() {
  if (opsCache) return opsCache;
  try {
    opsCache = await api('/jobs/operations');
    return opsCache;
  } catch(e) { showToast('Failed to load operations', 'error'); return null; }
}

function loadOpsForCategory() {
  var catSel = document.getElementById('opCategory');
  var opSel = document.getElementById('opSelect');
  var metaEl = document.getElementById('opMeta');
  var catKey = catSel.value;
  opSel.innerHTML = '<option value="">-- Select Operation --</option>';
  opSel.disabled = true;
  metaEl.classList.add('hidden');
  document.getElementById('preflightBtn').disabled = true;
  document.getElementById('executeBtn').disabled = true;

  if (!catKey || !opsCache || !opsCache[catKey]) return;
  var items = opsCache[catKey].items;
  for (var i = 0; i < items.length; i++) {
    var opt = document.createElement('option');
    opt.value = items[i].key;
    opt.textContent = items[i].label;
    if (items[i].downtime) opt.textContent += ' ⚠';
    opt.dataset.downtime = items[i].downtime ? '1' : '0';
    opt.dataset.needsDb = items[i].needsDbName ? '1' : '0';
    opSel.appendChild(opt);
  }
  opSel.disabled = false;
  opSel.onchange = function() {
    var sel = opSel.options[opSel.selectedIndex];
    if (!sel || !sel.value) { metaEl.classList.add('hidden'); return; }
    var html = '';
    if (sel.dataset.downtime === '1') {
      html += '<span class="op-warn"><svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M10.29 3.86L1.82 18a2 2 0 001.71 3h16.94a2 2 0 001.71-3L13.71 3.86a2 2 0 00-3.42 0z"/><line x1="12" y1="9" x2="12" y2="13"/><line x1="12" y1="17" x2="12.01" y2="17"/></svg> Downtime operation — requires confirmation</span>';
    }
    if (sel.dataset.needsDb === '1') {
      html += '<div class="db-name-group" style="margin-top:8px;">' +
        '<label for="dbUniqueName" style="font-weight:600;display:block;margin-bottom:4px;">DB Unique Name <span style="color:#e74c3c;">*</span></label>' +
        '<input type="text" id="dbUniqueName" placeholder="e.g. ORCL_PRD" style="width:100%;padding:8px;border:1px solid #555;border-radius:4px;background:#1e1e1e;color:#e0e0e0;font-family:monospace;" />' +
        '</div>';
    }
    if (html) { metaEl.innerHTML = html; metaEl.classList.remove('hidden'); }
    else { metaEl.classList.add('hidden'); }
    document.getElementById('preflightBtn').disabled = false;
  };
}


// -- Log Polling --
var logPollTimer = null;
var logPollJobId = null;
var logPollOffset = 0;

function startLogPolling(jobId) {
  stopLogPolling();
  logPollJobId = jobId;
  logPollOffset = 0;
  fetchLogsIncremental();
  logPollTimer = setInterval(fetchLogsIncremental, 2000);
}

function stopLogPolling() {
  if (logPollTimer) { clearInterval(logPollTimer); logPollTimer = null; }
  logPollJobId = null;
  logPollOffset = 0;
}

async function fetchLogsIncremental() {
  if (!logPollJobId) return;
  try {
    var logs = await api('/logs/' + logPollJobId + '?offset=' + logPollOffset);
    if (Array.isArray(logs) && logs.length) {
      logs.forEach(function(l) { appendLogLine(l); });
      logPollOffset += logs.length;
    }
    var job = await api('/jobs/' + logPollJobId);
    if (job && (job.status === 'success' || job.status === 'failed' || job.status === 'cancelled')) {
      updateJobStatus(job.status);
      stopLogPolling();
    }
  } catch(e) { /* silent */ }
}

// -- Init --
initTheme();
if (TOKEN) {
  // Validate existing token
  fetch(API + '/vms', { headers: { 'Authorization': 'Bearer ' + TOKEN } })
    .then(function(r) { if (r.ok) showApp(); else logout(); })
    .catch(function() { logout(); });
} else {
  showLogin();
}

document.getElementById('launchModal').addEventListener('click', function(e) { if (e.target === e.currentTarget) closeModal(); });
document.getElementById('logModal').addEventListener('click', function(e) { if (e.target === e.currentTarget) closeLogModal(); });
document.addEventListener('keydown', function(e) {
  if (e.key === 'Escape') { closeModal(); closeLogModal(); }
  if (e.key === 'Enter' && !document.getElementById('loginScreen').classList.contains('hidden')) doLogin();
});

// --- Admin Panel -----------------------------------------------
function showAdminTab() {
    var role = localStorage.getItem('role');
    var tab = document.getElementById('adminTab');
    if (tab) tab.style.display = (role === 'admin') ? '' : 'none';
}

function loadUsers() {
    api('/admin/users').then(function(users) {
        var tbody = document.querySelector('#usersTable tbody');
        tbody.innerHTML = '';
        users.forEach(function(u) {
            var tr = document.createElement('tr');
            var statusClass = u.enabled ? 'status-ok' : 'status-error';
            var statusText = u.enabled ? 'Active' : 'Disabled';
            var lastLogin = u.last_login || 'Never';
            tr.innerHTML = '<td><strong>' + esc(u.username) + '</strong></td>'
                + '<td><span class="env-badge env-' + esc(u.role) + '">' + esc(u.role) + '</span></td>'
                + '<td><span class="' + statusClass + '">' + statusText + '</span></td>'
                + '<td>' + esc(lastLogin) + '</td>'
                + '<td class="action-btns">'
                + (u.username !== 'admin' ? '<button class="btn btn-xs btn-secondary" onclick="toggleUser(\'' + u.id + '\')">' + (u.enabled ? 'Disable' : 'Enable') + '</button> ' : '')
                + '<button class="btn btn-xs btn-secondary" onclick="resetPassword(\'' + u.id + '\',\'' + esc(u.username) + '\')">Reset Pwd</button> '
                + (u.username !== 'admin' ? '<button class="btn btn-xs btn-danger" onclick="deleteUser(\'' + u.id + '\',\'' + esc(u.username) + '\')">Delete</button>' : '')
                + '</td>';
            tbody.appendChild(tr);
        });
    }).catch(function(e) { showToast('Failed to load users: ' + e.message, 'error'); });
}

function openCreateUserModal() {
    document.getElementById('createUserModal').classList.remove('hidden');
    document.getElementById('newUsername').value = '';
    document.getElementById('newUserPwd').value = '';
    document.getElementById('newUserRole').value = 'operator';
    document.getElementById('createUserError').textContent = '';
}
function closeCreateUserModal() {
    document.getElementById('createUserModal').classList.add('hidden');
}

function createUser() {
    var errEl = document.getElementById('createUserError');
    var username = document.getElementById('newUsername').value.trim();
    var password = document.getElementById('newUserPwd').value;
    var role = document.getElementById('newUserRole').value;
    if (!username || !password) { errEl.textContent = 'Username and password are required'; return; }
    api('/admin/users', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ username: username, password: password, role: role })
    }).then(function() {
        closeCreateUserModal();
        showToast('User ' + username + ' created', 'success');
        loadUsers();
    }).catch(function(e) { errEl.textContent = e.message; });
}

function toggleUser(id) {
    api('/admin/users/' + id + '/toggle', { method: 'PUT' })
    .then(function(r) { showToast(r.message, 'success'); loadUsers(); })
    .catch(function(e) { showToast(e.message, 'error'); });
}

function deleteUser(id, username) {
    if (!confirm('Delete user "' + username + '"? This cannot be undone.')) return;
    api('/admin/users/' + id, { method: 'DELETE' })
    .then(function(r) { showToast(r.message, 'success'); loadUsers(); })
    .catch(function(e) { showToast(e.message, 'error'); });
}

function resetPassword(id, username) {
    var newPwd = prompt('Enter new password for ' + username + ' (min 6 chars):');
    if (!newPwd) return;
    api('/admin/users/' + id + '/password', {
        method: 'PUT',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ password: newPwd })
    }).then(function(r) { showToast(r.message, 'success'); })
    .catch(function(e) { showToast(e.message, 'error'); });
}

function changeMyPassword() {
    var msgEl = document.getElementById('pwdMsg');
    var curr = document.getElementById('myCurrentPwd').value;
    var newP = document.getElementById('myNewPwd').value;
    var conf = document.getElementById('myConfirmPwd').value;
    msgEl.textContent = '';
    msgEl.style.color = '';
    if (!curr || !newP) { msgEl.textContent = 'All fields are required'; msgEl.style.color = '#e74c3c'; return; }
    if (newP !== conf) { msgEl.textContent = 'New passwords do not match'; msgEl.style.color = '#e74c3c'; return; }
    api('/admin/change-password', {
        method: 'PUT',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ currentPassword: curr, newPassword: newP })
    }).then(function() {
        msgEl.textContent = 'Password changed successfully!';
        msgEl.style.color = '#27ae60';
        document.getElementById('myCurrentPwd').value = '';
        document.getElementById('myNewPwd').value = '';
        document.getElementById('myConfirmPwd').value = '';
    }).catch(function(e) { msgEl.textContent = e.message; msgEl.style.color = '#e74c3c'; });
}

// ---------------------------------------------------------------
// PATCH CATALOG + SOFTWARE STAGING
// ---------------------------------------------------------------

var patchCatalog = [];
var patchTransfers = [];
var editingPatchId = null;

async function loadPatches() {
    var tbody = document.getElementById('patchCatalogBody');
    if (!tbody) return;
    tbody.innerHTML = '<tr><td colspan="9" class="loading"><div class="spinner" style="margin:0 auto"></div></td></tr>';
    try {
        var typeFilter = document.getElementById('patchTypeFilter') ? document.getElementById('patchTypeFilter').value : '';
        var statusFilter = document.getElementById('patchStatusFilter') ? document.getElementById('patchStatusFilter').value : '';
        var searchQ = document.getElementById('patchSearch') ? document.getElementById('patchSearch').value.trim() : '';
        var qs = '?';
        if (typeFilter) qs += 'type=' + encodeURIComponent(typeFilter) + '&';
        if (statusFilter) qs += 'is_downloaded=' + (statusFilter === 'local' ? 'true' : 'false') + '&';
        if (searchQ) qs += 'q=' + encodeURIComponent(searchQ) + '&';
        patchCatalog = await api('/patches' + qs);
        renderPatchCatalog();
    } catch (e) {
        if (e.message === 'Session expired') return;
        tbody.innerHTML = '<tr><td colspan="9" class="loading">Failed to load patches</td></tr>';
        showToast('Failed to load patches: ' + e.message, 'error');
    }
}

function renderPatchCatalog() {
    var tbody = document.getElementById('patchCatalogBody');
    var countEl = document.getElementById('patchCount');
    if (countEl) countEl.textContent = patchCatalog.length + ' patch' + (patchCatalog.length !== 1 ? 'es' : '');
    if (!patchCatalog.length) {
        tbody.innerHTML = '<tr><td colspan="9" class="loading"><div class="empty-state-inline">' +
            '<svg width="32" height="32" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5">' +
            '<path d="M20 7l-8-4-8 4m16 0l-8 4m8-4v10l-8 4m0-10L4 7m8 4v10M4 7v10l8 4"/></svg>' +
            '<p>No patches in catalog</p></div></td></tr>';
        return;
    }
    tbody.innerHTML = patchCatalog.map(function(p) {
        var dlBadge = p.is_downloaded
            ? '<span class="patch-dl-badge dl-yes" title="Available locally">\u25CF Local</span>'
            : '<span class="patch-dl-badge dl-no" title="Not downloaded">\u25CB Remote</span>';
        var typeBadge = '<span class="patch-type-badge ptype-' + (p.patch_type || 'RU').toLowerCase() + '">' + esc(p.patch_type || 'RU') + '</span>';
        var sizeStr = p.file_size_bytes > 0 ? formatBytes(p.file_size_bytes) : '\u2014';
        var paths = [];
        if (p.gi_base_zip) paths.push('GI: ' + p.gi_base_zip);
        if (p.db_base_zip) paths.push('DB: ' + p.db_base_zip);
        if (p.opatch_zip) paths.push('OP: ' + p.opatch_zip);
        var pathStr = paths.length ? '<span class="mono" style="font-size:11px">' + esc(paths.join(' | ')) + '</span>' : '\u2014';
        return '<tr>' +
            '<td><strong class="mono">' + esc(p.version) + '</strong></td>' +
            '<td>' + typeBadge + '</td>' +
            '<td>' + esc(p.description || '\u2014') + '</td>' +
            '<td>' + esc(p.platform || 'Linux-x86-64') + '</td>' +
            '<td style="max-width:300px;overflow:hidden;text-overflow:ellipsis">' + pathStr + '</td>' +
            '<td>' + esc(p.patch_search_root || '\u2014') + '</td>' +
            '<td>' + sizeStr + '</td>' +
            '<td>' + dlBadge + '</td>' +
            '<td class="action-btns">' +
                '<button class="btn btn-xs btn-secondary" onclick="togglePatchDownloaded(\'' + p.id + '\')" title="Toggle local/remote">' +
                    (p.is_downloaded ? '\u2193' : '\u2191') + '</button> ' +
                '<button class="btn btn-xs btn-secondary" onclick="openEditPatchModal(\'' + p.id + '\')" title="Edit">\u270E</button> ' +
                '<button class="btn btn-xs btn-danger" onclick="deletePatch(\'' + p.id + '\',\'' + esc(p.version) + '\')" title="Delete">\u2716</button>' +
            '</td></tr>';
    }).join('');
}

function formatBytes(bytes) {
    if (bytes === 0) return '0 B';
    var k = 1024;
    var sizes = ['B', 'KB', 'MB', 'GB'];
    var i = Math.floor(Math.log(bytes) / Math.log(k));
    return parseFloat((bytes / Math.pow(k, i)).toFixed(1)) + ' ' + sizes[i];
}

async function togglePatchDownloaded(id) {
    try {
        var result = await api('/patches/' + id + '/toggle-downloaded', { method: 'PUT' });
        showToast(result.message, 'success');
        loadPatches();
    } catch (e) { showToast('Failed: ' + e.message, 'error'); }
}

async function deletePatch(id, version) {
    if (!confirm('Delete patch version ' + version + ' from catalog? VMs linked to it will be unlinked.')) return;
    try {
        await api('/patches/' + id, { method: 'DELETE' });
        showToast('Patch ' + version + ' deleted', 'success');
        loadPatches();
    } catch (e) { showToast('Delete failed: ' + e.message, 'error'); }
}

function openAddPatchModal() {
    editingPatchId = null;
    document.getElementById('patchModalTitle').textContent = 'Add Patch Version';
    document.getElementById('patchForm').reset();
    document.getElementById('patchIsDownloaded').checked = false;
    document.getElementById('patchSupersedes').value = '';
    document.getElementById('patchPrereqOpatch').value = '';
    document.getElementById('patchPrereqPatches').value = '';
    document.getElementById('patchModalError').textContent = '';
    // Pre-fill base binary paths from orchestrator settings (falls back to known defaults)
    var giZipDefault = orchSettings.gi_base_zip_path || '/backup/oracle_install/gi/V982068-01.zip';
    var dbZipDefault = orchSettings.db_base_zip_path || '/backup/oracle_install/db/V982063-01.zip';
    var giHomeBase   = orchSettings.gi_home_base      || '/grid/oracle/product';
    var dbHomeBase   = orchSettings.db_home_base      || '/app/oracle/product';
    var patchesBase  = orchSettings.patches_base_path || '/backup/patches';
    document.getElementById('patchGiBaseZip').value = giZipDefault;
    document.getElementById('patchDbBaseZip').value = dbZipDefault;
    // Auto-populate new homes when version is typed
    var versionInput = document.getElementById('patchVersion');
    versionInput.oninput = function() {
        var v = versionInput.value.trim();
        if (v) {
            document.getElementById('patchNewGiHome').value = giHomeBase + '/' + v;
            document.getElementById('patchNewDbHome').value = dbHomeBase + '/' + v;
            document.getElementById('patchSearchRoot').value = patchesBase + '/p' + v;
        }
    };
    document.getElementById('patchModal').classList.remove('hidden');
}

function openEditPatchModal(id) {
    var p = patchCatalog.find(function(x) { return x.id === id; });
    if (!p) return;
    editingPatchId = id;
    document.getElementById('patchModalTitle').textContent = 'Edit Patch \u2014 ' + p.version;
    document.getElementById('patchVersion').value = p.version || '';
    document.getElementById('patchType').value = p.patch_type || 'RU';
    document.getElementById('patchDescription').value = p.description || '';
    document.getElementById('patchPlatform').value = p.platform || 'Linux-x86-64';
    document.getElementById('patchReleaseDate').value = p.release_date || '';
    document.getElementById('patchGiBaseZip').value = p.gi_base_zip || orchSettings.gi_base_zip_path || '/backup/oracle_install/gi/V982068-01.zip';
    document.getElementById('patchDbBaseZip').value = p.db_base_zip || orchSettings.db_base_zip_path || '/backup/oracle_install/db/V982063-01.zip';
    document.getElementById('patchNewGiHome').value = p.new_gi_home || (orchSettings.gi_home_base || '/grid/oracle/product') + '/' + (p.version || '');
    document.getElementById('patchNewDbHome').value = p.new_db_home || (orchSettings.db_home_base || '/app/oracle/product') + '/' + (p.version || '');
    document.getElementById('patchSearchRoot').value = p.patch_search_root || '';
    document.getElementById('patchRuDir').value = p.ru_dir || '';
    document.getElementById('patchOpatchZip').value = p.opatch_zip || '';
    document.getElementById('patchFileName').value = p.file_name || '';
    document.getElementById('patchFileSize').value = p.file_size_bytes || '';
    document.getElementById('patchChecksum').value = p.checksum_sha256 || '';
    document.getElementById('patchSourceUrl').value = p.source_url || '';
    document.getElementById('patchIsDownloaded').checked = p.is_downloaded;
    document.getElementById('patchSupersedes').value = (p.supersedes || []).join(', ');
    document.getElementById('patchPrereqOpatch').value = (p.prerequisites || {}).minOpatchVersion || '';
    document.getElementById('patchPrereqPatches').value = ((p.prerequisites || {}).requiredPatches || []).join(', ');
    document.getElementById('patchModalError').textContent = '';
    document.getElementById('patchModal').classList.remove('hidden');
}

function closePatchModal() {
    document.getElementById('patchModal').classList.add('hidden');
    editingPatchId = null;
}

async function savePatch() {
    var errEl = document.getElementById('patchModalError');
    errEl.textContent = '';
    var version = document.getElementById('patchVersion').value.trim();
    if (!version) { errEl.textContent = 'Version is required (e.g. 19.29)'; return; }

    var supersedesStr = document.getElementById('patchSupersedes').value.trim();
    var supersedes = supersedesStr ? supersedesStr.split(/[,\s]+/).filter(Boolean) : [];
    var prereqPatchesStr = document.getElementById('patchPrereqPatches').value.trim();
    var prereqPatches = prereqPatchesStr ? prereqPatchesStr.split(/[,\s]+/).filter(Boolean) : [];

    var body = {
        version: version,
        patch_type: document.getElementById('patchType').value,
        description: document.getElementById('patchDescription').value.trim(),
        platform: document.getElementById('patchPlatform').value.trim() || 'Linux-x86-64',
        release_date: document.getElementById('patchReleaseDate').value || null,
        gi_base_zip: document.getElementById('patchGiBaseZip').value.trim(),
        db_base_zip: document.getElementById('patchDbBaseZip').value.trim(),
        new_gi_home: document.getElementById('patchNewGiHome').value.trim(),
        new_db_home: document.getElementById('patchNewDbHome').value.trim(),
        patch_search_root: document.getElementById('patchSearchRoot').value.trim(),
        ru_dir: document.getElementById('patchRuDir').value.trim(),
        opatch_zip: document.getElementById('patchOpatchZip').value.trim(),
        file_name: document.getElementById('patchFileName').value.trim(),
        file_size_bytes: parseInt(document.getElementById('patchFileSize').value) || 0,
        checksum_sha256: document.getElementById('patchChecksum').value.trim(),
        source_url: document.getElementById('patchSourceUrl').value.trim(),
        is_downloaded: document.getElementById('patchIsDownloaded').checked,
        supersedes: supersedes,
        prerequisites: {
            minOpatchVersion: document.getElementById('patchPrereqOpatch').value.trim(),
            requiredPatches: prereqPatches
        }
    };

    try {
        if (editingPatchId) {
            await api('/patches/' + editingPatchId, { method: 'PUT', body: JSON.stringify(body) });
            showToast('Patch ' + version + ' updated', 'success');
        } else {
            await api('/patches', { method: 'POST', body: JSON.stringify(body) });
            showToast('Patch ' + version + ' added to catalog', 'success');
        }
        closePatchModal();
        loadPatches();
    } catch (e) { errEl.textContent = 'Failed: ' + e.message; }
}

// -- Transfers --
async function loadTransfers() {
    var tbody = document.getElementById('transfersBody');
    if (!tbody) return;
    tbody.innerHTML = '<tr><td colspan="7" class="loading"><div class="spinner" style="margin:0 auto"></div></td></tr>';
    try {
        var hostFilter = document.getElementById('transferHostFilter') ? document.getElementById('transferHostFilter').value.trim() : '';
        var statusFilter = document.getElementById('transferStatusFilter') ? document.getElementById('transferStatusFilter').value : '';
        var qs = '?';
        if (hostFilter) qs += 'target_host=' + encodeURIComponent(hostFilter) + '&';
        if (statusFilter) qs += 'status=' + encodeURIComponent(statusFilter) + '&';
        patchTransfers = await api('/patches/transfers/all' + qs);
        renderTransfers();
    } catch (e) {
        if (e.message === 'Session expired') return;
        tbody.innerHTML = '<tr><td colspan="7" class="loading">Failed to load transfers</td></tr>';
        showToast('Failed to load transfers: ' + e.message, 'error');
    }
}

function renderTransfers() {
    var tbody = document.getElementById('transfersBody');
    var countEl = document.getElementById('transferCount');
    if (countEl) countEl.textContent = patchTransfers.length + ' transfer' + (patchTransfers.length !== 1 ? 's' : '');
    if (!patchTransfers.length) {
        tbody.innerHTML = '<tr><td colspan="7" class="loading"><div class="empty-state-inline">' +
            '<svg width="32" height="32" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5">' +
            '<path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/><polyline points="7 10 12 15 17 10"/><line x1="12" y1="15" x2="12" y2="3"/></svg>' +
            '<p>No transfers recorded</p></div></td></tr>';
        return;
    }
    tbody.innerHTML = patchTransfers.map(function(t) {
        var statusCls = 'xfer-' + (t.status || 'PENDING').toLowerCase();
        var statusIcon = { PENDING:'\u25CB', TRANSFERRING:'\u25C9', EXTRACTING:'\u2699', VERIFYING_CHECKSUM:'\u27F3', STAGED:'\u2714', FAILED:'\u2718' };
        var progressBar = '';
        if (t.status === 'TRANSFERRING' && t.total_bytes > 0) {
            progressBar = '<div class="xfer-progress-bar"><div class="xfer-progress-fill" style="width:' + t.progress_pct + '%"></div></div>' +
                '<span class="xfer-pct">' + t.progress_pct + '%</span>';
        } else if (t.status === 'STAGED') {
            progressBar = '<div class="xfer-progress-bar"><div class="xfer-progress-fill" style="width:100%;background:var(--accent)"></div></div>' +
                '<span class="xfer-pct">100%</span>';
        }
        var checksumBadge = t.checksum_verified ? ' <span class="checksum-ok" title="Checksum verified">\u2611</span>' : '';
        return '<tr>' +
            '<td><span class="mono">' + esc(t.patch_version || '\u2014') + '</span> ' +
                '<span class="patch-type-badge ptype-' + (t.patch_type || 'ru').toLowerCase() + '">' + esc(t.patch_type || '') + '</span></td>' +
            '<td>' + esc(t.target_host) + '</td>' +
            '<td><span class="xfer-status ' + statusCls + '">' + (statusIcon[t.status] || '\u25CB') + ' ' + t.status + '</span>' + checksumBadge + '</td>' +
            '<td>' + progressBar + '</td>' +
            '<td><span class="mono" title="' + esc(t.source_path || '') + ' \u2192 ' + esc(t.target_stage_path || '') + '">' +
                esc(t.target_stage_path || '\u2014') + '</span></td>' +
            '<td>' + esc(t.transfer_method || 'SCP') + '</td>' +
            '<td class="action-btns">' +
                (t.status === 'FAILED' ? '<button class="btn btn-xs btn-secondary" onclick="retryTransfer(\'' + t.id + '\')">Retry</button> ' : '') +
                '<button class="btn btn-xs btn-danger" onclick="cancelTransfer(\'' + t.id + '\')" title="Cancel">\u2716</button>' +
            '</td></tr>';
    }).join('');
}

async function retryTransfer(id) {
    try {
        await api('/patches/transfers/' + id + '/retry', { method: 'POST' });
        showToast('Transfer queued for retry', 'success');
        loadTransfers();
    } catch (e) { showToast('Retry failed: ' + e.message, 'error'); }
}

async function cancelTransfer(id) {
    if (!confirm('Cancel this transfer?')) return;
    try {
        await api('/patches/transfers/' + id, { method: 'DELETE' });
        showToast('Transfer cancelled', 'success');
        loadTransfers();
    } catch (e) { showToast('Cancel failed: ' + e.message, 'error'); }
}

async function openCreateTransferModal() {
    document.getElementById("createTransferModal").classList.remove("hidden");
    document.getElementById("createTransferError").textContent = "";
    document.getElementById("transferStagePath").value = "/grid/stage/patches";
    document.getElementById("transferMethod").value = "API";

    // Populate patch version dropdown from API
    var sel = document.getElementById("transferPatchSelect");
    sel.innerHTML = "<option value=\"\">Loading...</option>";
    try {
        var patches = await api("/patches");
        sel.innerHTML = "<option value=\"\">-- Select Patch Version --</option>";
        patches.forEach(function(p) {
            var label = p.version + " (" + (p.patch_type || "RU") + ")";
            if (p.file_name) label += " \u2014 " + p.file_name;
            var opt = document.createElement("option");
            opt.value = p.id;
            opt.textContent = label;
            sel.appendChild(opt);
        });
    } catch(e) {
        sel.innerHTML = "<option value=\"\">Failed to load patches</option>";
    }

    // Populate target host dropdown from loaded VMs
    var hostSel = document.getElementById("transferTargetHost");
    hostSel.innerHTML = "<option value=\"\">-- Select Target VM --</option>";
    var vmList = typeof vms !== "undefined" ? vms : [];
    if (!vmList.length) {
        try { vmList = await api("/vms"); } catch(e) { vmList = []; }
    }
    vmList.forEach(function(vm) {
        var opt = document.createElement("option");
        opt.value = vm.hostname;
        opt.textContent = vm.hostname + " (" + vm.ip + ") \u2014 " + (vm.environment || "dev");
        hostSel.appendChild(opt);
    });
}
function closeCreateTransferModal() {
    document.getElementById('createTransferModal').classList.add('hidden');
}

async function createTransfer() {
    var errEl = document.getElementById('createTransferError');
    errEl.textContent = '';
    var patchId = document.getElementById('transferPatchSelect').value;
    var targetHost = document.getElementById('transferTargetHost').value.trim();
    var fileTypeEl = document.getElementById('transferFileType');
    var fileType = fileTypeEl ? fileTypeEl.value : 'ru_patch';
    if (!patchId || !targetHost) { errEl.textContent = 'Patch and target host are required'; return; }

    if (fileType === 'all') {
        var patch = (typeof patchCatalog !== 'undefined' ? patchCatalog : []).find(function(p) { return p.id === patchId; });
        var types = [];
        if (patch && patch.patch_search_root) types.push('ru_patch');
        if (patch && patch.opatch_zip) types.push('opatch');
        if (patch && patch.gi_base_zip) types.push('gi_base');
        if (patch && patch.db_base_zip) types.push('db_base');
        if (!types.length) { errEl.textContent = 'No files available for this patch version'; return; }
        try {
            for (var i = 0; i < types.length; i++) {
                await api('/patches/transfers', {
                    method: 'POST',
                    body: JSON.stringify({
                        patch_id: patchId,
                        target_host: targetHost,
                        target_stage_path: document.getElementById('transferStagePath').value.trim() || '/grid/stage/patches',
                        transfer_method: document.getElementById('transferMethod').value,
                        file_type: types[i]
                    })
                });
            }
            showToast(types.length + ' transfers created', 'success');
            closeCreateTransferModal();
            loadTransfers();
        } catch (e) { errEl.textContent = 'Failed: ' + e.message; }
    } else {
        try {
            await api('/patches/transfers', {
                method: 'POST',
                body: JSON.stringify({
                    patch_id: patchId,
                    target_host: targetHost,
                    target_stage_path: document.getElementById('transferStagePath').value.trim() || '/grid/stage/patches',
                    transfer_method: document.getElementById('transferMethod').value,
                    file_type: fileType
                })
            });
            showToast('Transfer created', 'success');
            closeCreateTransferModal();
            loadTransfers();
        } catch (e) { errEl.textContent = 'Failed: ' + e.message; }
    }
}

function switchPatchSubTab(tab) {
    document.querySelectorAll('.patch-sub-tab').forEach(function(b) {
        b.classList.toggle('active', b.dataset.subtab === tab);
    });
    document.getElementById('patchCatalogPanel').classList.toggle('hidden', tab !== 'catalog');
    document.getElementById('patchTransfersPanel').classList.toggle('hidden', tab !== 'transfers');
    if (tab === 'catalog') loadPatches();
    if (tab === 'transfers') loadTransfers();
}

function openBulkPatchModal() {
    document.getElementById('bulkPatchModal').classList.remove('hidden');
    document.getElementById('bulkPatchText').value = '';
    document.getElementById('bulkPatchError').textContent = '';
}
function closeBulkPatchModal() {
    document.getElementById('bulkPatchModal').classList.add('hidden');
}

async function bulkImportPatches() {
    var errEl = document.getElementById('bulkPatchError');
    errEl.textContent = '';
    var text = document.getElementById('bulkPatchText').value.trim();
    if (!text) { errEl.textContent = 'Paste patch data'; return; }
    var lines = text.split('\n').filter(function(l) { return l.trim() && !l.trim().startsWith('#'); });
    var patches = [];
    for (var i = 0; i < lines.length; i++) {
        var parts = lines[i].trim().split(/[,\t|]+/);
        if (parts.length < 1) { errEl.textContent = 'Line ' + (i+1) + ': need at least version'; return; }
        patches.push({
            version: parts[0].trim(),
            patch_type: parts[1] ? parts[1].trim().toUpperCase() : 'RU',
            description: parts[2] ? parts[2].trim() : '',
            gi_base_zip: parts[3] ? parts[3].trim() : '',
            db_base_zip: parts[4] ? parts[4].trim() : '',
            patch_search_root: parts[5] ? parts[5].trim() : '',
            opatch_zip: parts[6] ? parts[6].trim() : ''
        });
    }
    try {
        var result = await api('/patches/bulk', { method: 'POST', body: JSON.stringify({ patches: patches }) });
        showToast(result.imported + ' patches imported', 'success');
        closeBulkPatchModal();
        loadPatches();
    } catch (e) { errEl.textContent = 'Import failed: ' + e.message; }
}

// ========== SCHEDULES ==========
var allSchedules = [];
var allMaintWindows = [];

async function loadSchedules() {
  try {
    allSchedules = await api('/schedules');
    document.getElementById('schedCount').textContent = allSchedules.length;
    renderSchedules();
  } catch (e) { console.error('loadSchedules:', e); }
}

function renderSchedules() {
  var b = document.getElementById('schedJobsBody');
  if (!allSchedules.length) {
    b.innerHTML = '<tr><td colspan="7" style="text-align:center;color:var(--text-dim)">No schedules</td></tr>';
    return;
  }
  b.innerHTML = allSchedules.map(function(s) {
    var vn = (s.vm_names && s.vm_names.length) ? s.vm_names.join(', ') : '-';
    var sd = '-';
    if (s.scheduled_at) {
      var _d = new Date(String(s.scheduled_at || '').replace(' ', 'T'));
      if (isNaN(_d.getTime())) _d = new Date(String(s.scheduled_at || '').replace(' ', 'T') + 'Z');
      sd = !isNaN(_d.getTime()) ? _d.toLocaleString('en-ZA', {day:'2-digit', month:'short', year:'numeric', hour:'2-digit', minute:'2-digit'}) : s.scheduled_at;
    }
    var sc = s.status === 'COMPLETED' ? 'status-online' : s.status === 'RUNNING' ? 'status-warning' : s.status === 'FAILED' ? 'status-error' : 'status-pending';
    var act = '';
    if (s.status === 'PENDING') {
      act = '<button class="btn btn-sm btn-secondary" onclick="editSchedule(\'' + s.id + '\')">Edit</button> ';
      act += '<button class="btn btn-sm btn-danger" onclick="deleteSchedule(\'' + s.id + '\')">Delete</button>';
    } else if (s.status === 'FAILED') {
      act = '<button class="btn btn-sm btn-secondary" onclick="retrySchedule(\'' + s.id + '\')">Retry</button>';
    }
    return '<tr>' +
      '<td>' + (s.name || s.operation) + '</td>' +
      '<td><span class="op-badge">' + s.operation + '</span></td>' +
      '<td>' + vn + '</td>' +
      '<td>' + sd + '</td>' +
      '<td>' + (s.execution_mode || 'parallel') + '</td>' +
      '<td><span class="' + sc + '">' + s.status + '</span></td>' +
      '<td>' + act + '</td></tr>';
  }).join('');
}

function openScheduleModal(editId) {
  document.getElementById('scheduleModal').classList.remove('hidden');
  document.getElementById('schedError').textContent = '';
  document.getElementById('schedName').value = '';
  document.getElementById('schedDatetime').value = '';
  document.getElementById('schedNotes').value = '';
  document.getElementById('schedExecMode').value = 'parallel';
  document.getElementById('schedModalTitle').textContent = editId ? 'Edit Schedule' : 'New Schedule';
  document.getElementById('schedSubmitBtn').setAttribute('data-edit-id', editId || '');
  document.getElementById('schedSubmitBtn').textContent = editId ? 'Update Schedule' : 'Create Schedule';
  populateSchedOps();
  populateSchedVms();
  populateSchedPatches();
  if (editId) {
    var s = allSchedules.find(function(x) { return x.id === editId; });
    if (s) {
      document.getElementById('schedName').value = s.name || '';
      document.getElementById('schedOperation').value = s.operation || '';
      if (s.scheduled_at) {
        var _ed = new Date(String(s.scheduled_at || '').replace(' ', 'T'));
        if (isNaN(_ed.getTime())) _ed = new Date(String(s.scheduled_at || '').replace(' ', 'T') + 'Z');
        document.getElementById('schedDatetime').value = !isNaN(_ed.getTime()) ? new Date(_ed.getTime() - _ed.getTimezoneOffset() * 60000).toISOString().substring(0, 16) : '';
      } else { document.getElementById('schedDatetime').value = ''; }
      document.getElementById('schedExecMode').value = s.execution_mode || 'parallel';
      document.getElementById('schedNotes').value = s.notes || '';
      toggleSchedPatchVersion();
      if (s.patch_version_id) document.getElementById('schedPatchVersion').value = s.patch_version_id;
      try {
        var ids = JSON.parse(s.vm_ids || '[]');
        ids.forEach(function(id) {
          var cb = document.querySelector('#schedVmList input[value="' + id + '"]');
          if (cb) cb.checked = true;
        });
      } catch (e) {}
    }
  }
}

function closeScheduleModal() {
  document.getElementById('scheduleModal').classList.add('hidden');
}

function populateSchedOps() {
  var sel = document.getElementById('schedOperation');
  sel.innerHTML = '<option value="">Select operation...</option>';
  var ops = ['gi_precheck','db_precheck','gi_install','db_install','gi_rollback','db_rollback','gi_switchback','db_switchback','full_patch','full_rollback'];
  ops.forEach(function(o) {
    sel.innerHTML += '<option value="' + o + '">' + o.replace(/_/g, ' ').toUpperCase() + '</option>';
  });
}

function toggleSchedPatchVersion() {
  var op = document.getElementById('schedOperation').value;
  var show = op && !/rollback/i.test(op);
  document.getElementById('schedPatchVersionGroup').style.display = show ? 'block' : 'none';
}

function populateSchedVms() {
  var container = document.getElementById('schedVmList');
  var vmList = (typeof vms !== 'undefined') ? vms : [];
  if (!vmList.length) {
    container.innerHTML = '<div style="color:var(--text-dim)">No VMs loaded</div>';
    return;
  }
  container.innerHTML = vmList.map(function(vm) {
    return '<label style="display:flex;align-items:center;gap:6px;padding:4px 0;cursor:pointer">' +
      '<input type="checkbox" value="' + vm.id + '"> ' + vm.hostname +
      ' <span style="color:var(--text-dim);font-size:11px">(' + (vm.db_version || vm.environment || '-') + ')</span></label>';
  }).join('');
}

async function populateSchedPatches() {
  var sel = document.getElementById('schedPatchVersion');
  sel.innerHTML = '<option value="">Select patch...</option>';
  try {
    var patches = await api('/patches');
    patches.forEach(function(p) {
      sel.innerHTML += '<option value="' + p.id + '">' + p.version + ' (' + (p.patch_type || 'RU') + ') ' + (p.file_name || '') + '</option>';
    });
  } catch (e) { console.error('loadPatchVersions:', e); }
}

async function submitSchedule() {
  var errEl = document.getElementById('schedError');
  errEl.textContent = '';
  var editId = document.getElementById('schedSubmitBtn').getAttribute('data-edit-id');
  var name = document.getElementById('schedName').value.trim();
  var operation = document.getElementById('schedOperation').value;
  var scheduledAt = document.getElementById('schedDatetime').value;
  var execMode = document.getElementById('schedExecMode').value;
  var notes = document.getElementById('schedNotes').value.trim();
  var patchVersionId = document.getElementById('schedPatchVersion').value;
  var vmIds = [];
  document.querySelectorAll('#schedVmList input:checked').forEach(function(cb) { vmIds.push(cb.value); });
  if (!operation) { errEl.textContent = 'Select an operation'; return; }
  if (!vmIds.length) { errEl.textContent = 'Select at least one VM'; return; }
  if (!scheduledAt) { errEl.textContent = 'Set a date/time'; return; }
  var payload = {
    name: name, operation: operation, vm_ids: vmIds, scheduled_at: new Date(scheduledAt).toISOString(),
    execution_mode: execMode, notes: notes, patch_version_id: patchVersionId
  };
  try {
    if (editId) {
      await api('/schedules/' + editId, { method: 'PUT', body: JSON.stringify(payload) });
      showToast('Schedule updated', 'success');
    } else {
      await api('/schedules', { method: 'POST', body: JSON.stringify(payload) });
      showToast('Schedule created', 'success');
    }
    closeScheduleModal();
    loadSchedules();
  } catch (e) { errEl.textContent = 'Failed: ' + e.message; }
}

function editSchedule(id) { openScheduleModal(id); }

async function deleteSchedule(id) {
  if (!confirm('Delete this schedule?')) return;
  try {
    await api('/schedules/' + id, { method: 'DELETE' });
    showToast('Schedule deleted', 'success');
    loadSchedules();
  } catch (e) { showToast('Delete failed: ' + e.message, 'error'); }
}

async function retrySchedule(id) {
  try {
    await api('/schedules/' + id, { method: 'PUT', body: JSON.stringify({ status: 'PENDING' }) });
    showToast('Schedule reset to PENDING', 'success');
    loadSchedules();
  } catch (e) { showToast('Retry failed: ' + e.message, 'error'); }
}

function switchSchedSubTab(tab) {
  document.querySelectorAll('#tab-schedules .patch-sub-tab').forEach(function(b) {
    b.classList.toggle('active', b.dataset.subtab === tab);
  });
  document.getElementById('subtab-one-time').style.display = tab === 'one-time' ? 'block' : 'none';
  document.getElementById('subtab-maintenance').style.display = tab === 'maintenance' ? 'block' : 'none';
  if (tab === 'one-time') loadSchedules();
  if (tab === 'maintenance') loadMaintWindows();
}

// ========== MAINTENANCE WINDOWS ==========
async function loadMaintWindows() {
  try {
    allMaintWindows = await api('/schedules/maintenance/all');
    document.getElementById('maintCount').textContent = allMaintWindows.length;
    renderMaintWindows();
  } catch (e) { console.error('loadMaintWindows:', e); }
}

function renderMaintWindows() {
  var body = document.getElementById('maintBody');
  if (!body) return;
  if (!allMaintWindows.length) {
    body.innerHTML = '<tr><td colspan="7" style="text-align:center;color:var(--text-dim)">No maintenance windows</td></tr>';
    return;
  }
  body.innerHTML = allMaintWindows.map(function(m) {
    var vmCount = '-';
    try { vmCount = JSON.parse(m.vm_ids || '[]').length + ' VMs'; } catch (e) {}
    var statusBadge = m.is_active ? '<span class="status-online">Active</span>' : '<span class="status-error">Disabled</span>';
    return '<tr>' +
      '<td>' + m.name + '</td>' +
      '<td><code>' + m.cron_expression + '</code></td>' +
      '<td>' + vmCount + '</td>' +
      '<td>' + (m.next_run || '-') + '</td>' +
      '<td>' + (m.execution_mode || 'sequential') + '</td>' +
      '<td>' + statusBadge + '</td>' +
      '<td>' +
        '<button class="btn btn-sm btn-secondary" onclick="toggleMaintWindow(\'' + m.id + '\',' + (m.is_active ? 0 : 1) + ')">' + (m.is_active ? 'Disable' : 'Enable') + '</button> ' +
        '<button class="btn btn-sm btn-danger" onclick="deleteMaintWindow(\'' + m.id + '\')">Delete</button>' +
      '</td></tr>';
  }).join('');
}

function openMaintModal() {
  document.getElementById('maintWindowModal').classList.remove('hidden');
  document.getElementById('maintError').textContent = '';
  document.getElementById('maintName').value = '';
  document.getElementById('maintCronExpr').value = '';
  document.getElementById('maintDesc').value = '';
  document.getElementById('maintOps').value = '';
  document.getElementById('maintNotes').value = '';
  populateMaintVmList();
  populateMaintPatchVersions();
}

function closeMaintModal() {
  document.getElementById('maintWindowModal').classList.add('hidden');
}

function populateMaintVmList() {
  var container = document.getElementById('maintVmList');
  var vmList = (typeof vms !== 'undefined') ? vms : [];
  if (!vmList.length) {
    container.innerHTML = '<div style="color:var(--text-dim)">No VMs loaded</div>';
    return;
  }
  container.innerHTML = vmList.map(function(vm) {
    return '<label style="display:flex;align-items:center;gap:6px;padding:4px 0;cursor:pointer">' +
      '<input type="checkbox" value="' + vm.id + '"> ' + vm.hostname + '</label>';
  }).join('');
}

async function populateMaintPatchVersions() {
  var sel = document.getElementById('maintPatchVersion');
  sel.innerHTML = '<option value="">Latest available</option>';
  try {
    var patches = await api('/patches');
    patches.forEach(function(p) {
      sel.innerHTML += '<option value="' + p.id + '">' + p.version + ' (' + (p.patch_type || 'RU') + ')</option>';
    });
  } catch (e) {}
}

function applyCronPreset() {
  var preset = document.getElementById('maintCronPreset').value;
  if (preset) document.getElementById('maintCronExpr').value = preset;
}

async function submitMaintWindow() {
  var errEl = document.getElementById('maintError');
  errEl.textContent = '';
  var name = document.getElementById('maintName').value.trim();
  var cron = document.getElementById('maintCronExpr').value.trim();
  var vmIds = [];
  document.querySelectorAll('#maintVmList input:checked').forEach(function(cb) { vmIds.push(cb.value); });
  if (!name) { errEl.textContent = 'Name is required'; return; }
  if (!cron) { errEl.textContent = 'CRON expression is required'; return; }
  if (!vmIds.length) { errEl.textContent = 'Select at least one VM'; return; }
  var payload = {
    name: name, cron_expression: cron, vm_ids: vmIds,
    description: document.getElementById('maintDesc').value.trim(),
    operations: document.getElementById('maintOps').value.trim(),
    execution_mode: document.getElementById('maintExecMode').value,
    patch_version_id: document.getElementById('maintPatchVersion').value,
    notes: document.getElementById('maintNotes').value.trim()
  };
  try {
    await api('/schedules/maintenance', { method: 'POST', body: JSON.stringify(payload) });
    showToast('Maintenance window created', 'success');
    closeMaintModal();
    loadMaintWindows();
  } catch (e) { errEl.textContent = 'Failed: ' + e.message; }
}

async function toggleMaintWindow(id, newState) {
  try {
    await api('/schedules/maintenance/' + id + '/toggle', { method: 'PUT', body: JSON.stringify({ is_active: newState }) });
    showToast(newState ? 'Window enabled' : 'Window disabled', 'success');
    loadMaintWindows();
  } catch (e) { showToast('Toggle failed: ' + e.message, 'error'); }
}

async function deleteMaintWindow(id) {
  if (!confirm('Delete this maintenance window?')) return;
  try {
    await api('/schedules/maintenance/' + id, { method: 'DELETE' });
    showToast('Window deleted', 'success');
    loadMaintWindows();
  } catch (e) { showToast('Delete failed: ' + e.message, 'error'); }
}

// ========== SCHEDULE FROM DASHBOARD ==========
function openScheduleFromDashboard() {
  var vmId = document.getElementById('modalVmInfo').getAttribute('data-vm-id');
  var op = document.getElementById('opSelect').value;
  var patchVer = document.getElementById('patchVersionSelect') ? document.getElementById('patchVersionSelect').value : '';
  closeModal();
  openScheduleModal();
  if (op) document.getElementById('schedOperation').value = op;
  toggleSchedPatchVersion();
  if (patchVer) document.getElementById('schedPatchVersion').value = patchVer;
  if (vmId) {
    setTimeout(function() {
      var cb = document.querySelector('#schedVmList input[value="' + vmId + '"]');
      if (cb) cb.checked = true;
    }, 200);
  }
}

// Auto-load schedules when tab is clicked
document.addEventListener('DOMContentLoaded', function() {
  var schedTab = document.getElementById('schedulesTab');
  if (schedTab) schedTab.addEventListener('click', function() { loadSchedules(); });
});

// ========== TRANSFER FILE TYPE ==========
function updateTransferSourceInfo() {
    var patchId = document.getElementById('transferPatchSelect').value;
    var fileType = document.getElementById('transferFileType').value;
    var infoEl = document.getElementById('transferFileInfo');
    if (!patchId) { infoEl.textContent = ''; return; }

    // Find patch from loaded data
    var patch = (typeof patchCatalog !== 'undefined' ? patchCatalog : []).find(function(p) { return p.id === patchId; });
    if (!patch) { infoEl.textContent = ''; return; }

    var info = '';
    if (fileType === 'ru_patch') {
        info = patch.patch_search_root ? '?? ' + patch.patch_search_root : '?? No RU patch path configured';
    } else if (fileType === 'opatch') {
        info = patch.opatch_zip ? '?? ' + patch.opatch_zip : '?? No OPatch path configured';
    } else if (fileType === 'gi_base') {
        info = patch.gi_base_zip ? '?? ' + patch.gi_base_zip : '?? No GI base path configured';
    } else if (fileType === 'db_base') {
        info = patch.db_base_zip ? '?? ' + patch.db_base_zip : '?? No DB base path configured';
    } else if (fileType === 'all') {
        var parts = [];
        if (patch.patch_search_root) parts.push('RU ?');
        if (patch.opatch_zip) parts.push('OPatch ?');
        if (patch.gi_base_zip) parts.push('GI ?');
        if (patch.db_base_zip) parts.push('DB ?');
        info = parts.length ? '?? Will transfer: ' + parts.join(', ') : '?? No files configured';
    }
    infoEl.innerHTML = info;
}

// Store patch catalog for lookup
var patchCatalog = [];

// Override openCreateTransferModal to store patches
var _origOpenTransferModal = openCreateTransferModal;
openCreateTransferModal = async function() {
    document.getElementById("createTransferModal").classList.remove("hidden");
    document.getElementById("createTransferError").textContent = "";
    document.getElementById("transferStagePath").value = "/grid/stage/patches";
    document.getElementById("transferMethod").value = "API";
    document.getElementById("transferFileType").value = "ru_patch";
    document.getElementById("transferFileInfo").textContent = "";

    var sel = document.getElementById("transferPatchSelect");
    sel.innerHTML = "<option value=\"\">Loading...</option>";
    try {
        patchCatalog = await api("/patches");
        sel.innerHTML = "<option value=\"\">-- Select Patch Version --</option>";
        patchCatalog.forEach(function(p) {
            var label = p.version + " (" + (p.patch_type || "RU") + ")";
            var files = [];
            if (p.patch_search_root) files.push("RU");
            if (p.opatch_zip) files.push("OPatch");
            if (p.gi_base_zip) files.push("GI");
            if (p.db_base_zip) files.push("DB");
            if (files.length) label += " � " + files.join(", ");
            var opt = document.createElement("option");
            opt.value = p.id;
            opt.textContent = label;
            sel.appendChild(opt);
        });
    } catch(e) {
        sel.innerHTML = "<option value=\"\">Failed to load patches</option>";
    }

    sel.onchange = updateTransferSourceInfo;

    var hostSel = document.getElementById("transferTargetHost");
    hostSel.innerHTML = "<option value=\"\">-- Select Target VM --</option>";
    var vmList = typeof vms !== "undefined" ? vms : [];
    if (!vmList.length) {
        try { vmList = await api("/vms"); } catch(e) { vmList = []; }
    }
    vmList.forEach(function(vm) {
        var opt = document.createElement("option");
        opt.value = vm.hostname;
        opt.textContent = vm.hostname + " (" + vm.ip + ") � " + (vm.node_role || "unknown");
        hostSel.appendChild(opt);
    });
};

// [CLEANED] duplicate createTransfer override removed
