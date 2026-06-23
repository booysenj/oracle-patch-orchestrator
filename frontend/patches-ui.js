// patches-ui.js - Patch Catalog UI extensions
// Loaded after app.js

function renderPatchCatalog() {
    var grid = document.getElementById('patchGrid');
    if (!grid) return;
    var countEl = document.getElementById('patchCount');
    if (countEl) countEl.textContent = patchCatalog.length + ' patch' + (patchCatalog.length !== 1 ? 'es' : '');
    if (!patchCatalog.length) {
        grid.innerHTML = '<div class="empty-state"><div class="empty-icon">' +
            '<svg width="48" height="48" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5">' +
            '<path d="M20 7l-8-4-8 4m16 0l-8 4m8-4v10l-8 4m0-10L4 7m8 4v10M4 7v10l8 4"/></svg>' +
            '</div><h3>No patches in catalog</h3><p>Add patches manually or scan your repo</p></div>';
        return;
    }
    grid.innerHTML = patchCatalog.map(function(p) {
        var dlBadge = p.is_downloaded
            ? '<span class="patch-dl-badge dl-yes">\u25CF Local</span>'
            : '<span class="patch-dl-badge dl-no">\u25CB Remote</span>';
        var typeBadge = '<span class="patch-type-badge ptype-' + (p.patch_type || 'ru').toLowerCase() + '">' +
            esc(p.patch_type || 'RU') + '</span>';
        var paths = [];
        if (p.gi_base_zip) paths.push('GI: ' + p.gi_base_zip.split('/').pop());
        if (p.db_base_zip) paths.push('DB: ' + p.db_base_zip.split('/').pop());
        if (p.ojvm_zip) paths.push('OJVM: ' + p.ojvm_zip.split('/').pop());
        if (p.opatch_zip) paths.push('OP: ' + p.opatch_zip.split('/').pop());
        if (p.patch_search_root) paths.push('Root: ' + p.patch_search_root);
        var pathsHtml = paths.length
            ? paths.map(function(x) { return '<div class="patch-path-line">' + esc(x) + '</div>'; }).join('')
            : '<span style="color:var(--text-muted)">No paths set</span>';
        var sizeStr = p.file_size_bytes > 0 ? formatBytes(p.file_size_bytes) : '';
        return '<div class="vm-card patch-card">' +
            '<div class="vm-card-header">' +
                '<span class="vm-hostname">v' + esc(p.version) + '</span>' + typeBadge +
            '</div>' +
            '<div class="patch-desc">' + esc(p.description || 'No description') + '</div>' +
            '<div class="vm-details">' +
                '<span class="vm-detail-label">Platform</span><span class="vm-detail-value">' + esc(p.platform || 'Linux-x86-64') + '</span>' +
                '<span class="vm-detail-label">Status</span><span class="vm-detail-value">' + dlBadge + '</span>' +
                (sizeStr ? '<span class="vm-detail-label">Size</span><span class="vm-detail-value">' + sizeStr + '</span>' : '') +
            '</div>' +
            '<div class="patch-paths">' + pathsHtml + '</div>' +
            '<div class="vm-card-actions">' +
                '<button class="btn btn-sm btn-secondary" onclick="togglePatchDownloaded(\'' + p.id + '\')">' +
                    (p.is_downloaded ? 'Mark Remote' : 'Mark Local') + '</button>' +
                '<button class="btn btn-sm btn-secondary" onclick="openEditPatchModal(\'' + p.id + '\')">Edit</button>' +
                '<button class="btn btn-sm btn-secondary" id="depotBtn-' + p.id + '" onclick="extractToDepot(\'' + p.id + '\',\'' + esc(p.version) + '\')" title="Extract zips to orchestrator depot for fast VM staging">⬇ Depot</button>' +
                '<button class="btn btn-sm btn-danger" onclick="deletePatch(\'' + p.id + '\',\'' + esc(p.version) + '\')">Del</button>' +
            '</div>' +
        '</div>';
    }).join('');
}

function switchPatchSubTab(tab) {
    document.querySelectorAll('.patch-sub-tab').forEach(function(b) {
        b.classList.toggle('active', b.dataset.subtab === tab);
    });
    var panels = ['patchCatalogPanel', 'patchTransfersPanel', 'patchDepotPanel', 'patchReportsPanel'];
    var tabs   = ['catalog', 'transfers', 'depot', 'reports'];
    for (var i = 0; i < panels.length; i++) {
        var el = document.getElementById(panels[i]);
        if (el) el.classList.toggle('hidden', tabs[i] !== tab);
    }
    if (tab === 'catalog') loadPatches();
    if (tab === 'transfers') loadTransfers();
    if (tab === 'depot') loadDepot();
    if (tab === 'reports') loadReports();
}

async function scanPatchRepo() {
    try {
        var settings = await api('/patches/settings/repo');
        document.getElementById('scanRepoPath').value = settings.software_repo_root || '/backup';
    } catch(e) {
        document.getElementById('scanRepoPath').value = '/backup';
    }
    var resultEl = document.getElementById('scanRepoResult');
    if (resultEl) resultEl.classList.add('hidden');
    var errEl = document.getElementById('scanRepoError');
    if (errEl) errEl.textContent = '';
    document.getElementById('scanRepoModal').classList.remove('hidden');
}

function closeScanRepoModal() {
    document.getElementById('scanRepoModal').classList.add('hidden');
}

async function doScanRepo() {
    var errEl = document.getElementById('scanRepoError');
    var resultEl = document.getElementById('scanRepoResult');
    var btn = document.getElementById('scanRepoBtn');
    errEl.textContent = '';
    var rootPath = document.getElementById('scanRepoPath').value.trim();
    if (!rootPath) { errEl.textContent = 'Path is required'; return; }
    btn.disabled = true; btn.textContent = 'Scanning...';
    try {
        var result = await api('/patches/scan', {
            method: 'POST',
            body: JSON.stringify({ root_path: rootPath })
        });
        resultEl.classList.remove('hidden');
        var html = '<strong style="color:var(--accent)">' + esc(result.message) + '</strong><br>';
        html += '<span style="color:var(--text-dim)">Files: ' + result.total_files_found + ' | ZIPs: ' + result.zip_files_found + '</span>';
        if (result.classified && result.classified.length) {
            html += '<div style="margin-top:8px;max-height:200px;overflow:auto;font-size:12px">';
            for (var i = 0; i < result.classified.length; i++) {
                var f = result.classified[i];
                html += '<div><span class="patch-type-badge ptype-' + f.type.toLowerCase() + '">' +
                    f.type + '</span> ' + esc(f.name) + ' (' + formatBytes(f.size) + ')</div>';
            }
            html += '</div>';
        }
        resultEl.innerHTML = html;
        showToast(result.message, 'success');
        loadPatches();
    } catch (e) {
        errEl.textContent = e.message;
        showToast('Scan failed: ' + e.message, 'error');
    } finally {
        btn.disabled = false; btn.textContent = 'Scan & Import';
    }
}

async function relocatePatches(oldRoot, newRoot) {
    try {
        var result = await api('/patches/relocate', {
            method: 'POST',
            body: JSON.stringify({ old_root: oldRoot, new_root: newRoot })
        });
        showToast(result.message, 'success');
        loadPatches();
    } catch (e) {
        showToast('Relocate failed: ' + e.message, 'error');
    }
}

// ---- PRECHECK REPORTS ----
var reportsList = [];

async function loadReports() {
    var tbody = document.getElementById('reportsBody');
    if (!tbody) return;
    tbody.innerHTML = '<tr><td colspan="6" class="loading"><div class="spinner" style="margin:0 auto"></div></td></tr>';
    try {
        var typeFilter = document.getElementById('reportTypeFilter') ? document.getElementById('reportTypeFilter').value : '';
        var searchQ = document.getElementById('reportSearch') ? document.getElementById('reportSearch').value.trim() : '';
        var qs = '?';
        if (typeFilter) qs += 'report_type=' + encodeURIComponent(typeFilter) + '&';
        if (searchQ) qs += 'q=' + encodeURIComponent(searchQ) + '&';
        reportsList = await api('/patches/reports' + qs);
        renderReports();
    } catch (e) {
        if (e.message === 'Session expired') return;
        tbody.innerHTML = '<tr><td colspan="6" class="loading">Failed to load reports</td></tr>';
    }
}

function renderReports() {
    var tbody = document.getElementById('reportsBody');
    var countEl = document.getElementById('reportCount');
    if (countEl) countEl.textContent = reportsList.length + ' report' + (reportsList.length !== 1 ? 's' : '');
    if (!reportsList.length) {
        tbody.innerHTML = '<tr><td colspan="6" class="loading"><div class="empty-state-inline">' +
            '<p>No reports yet. Reports are generated during precheck/postcheck runs.</p></div></td></tr>';
        return;
    }
    tbody.innerHTML = reportsList.map(function(r) {
        var resultBadge = r.result === 'PASS'
            ? '<span class="status-badge status-success">PASS</span>'
            : r.result === 'FAIL'
            ? '<span class="status-badge status-failed">FAIL</span>'
            : '<span class="status-badge status-pending">' + esc(r.result) + '</span>';
        return '<tr>' +
            '<td><span class="mono">' + esc(r.hostname || '-') + '</span></td>' +
            '<td>' + esc(r.report_type || 'precheck') + '</td>' +
            '<td>' + esc(r.operation || '-') + '</td>' +
            '<td>' + resultBadge + '</td>' +
            '<td>' + formatDate(r.created_at) + '</td>' +
            '<td class="action-btns">' +
                '<button class="btn btn-xs btn-secondary" onclick="viewReport(\'' + r.id + '\')">View</button> ' +
                '<button class="btn btn-xs btn-secondary" onclick="printReportById(\'' + r.id + '\')">Print</button>' +
            '</td></tr>';
    }).join('');
}

async function viewReport(id) {
    try {
        var report = await api('/patches/reports/' + id);
        document.getElementById('reportViewerTitle').textContent =
            (report.report_type || 'Report') + ' - ' + (report.hostname || 'Unknown') + ' - ' + (report.operation || '');
        var contentEl = document.getElementById('reportViewerContent');
        if (report.content && (report.content.indexOf('<') >= 0)) {
            contentEl.innerHTML = report.content;
        } else {
            contentEl.innerHTML = '<pre style="white-space:pre-wrap;color:var(--text)">' + esc(report.content || 'No content') + '</pre>';
        }
        document.getElementById('reportViewerModal').classList.remove('hidden');
    } catch (e) {
        showToast('Failed to load report: ' + e.message, 'error');
    }
}

function closeReportViewer() {
    document.getElementById('reportViewerModal').classList.add('hidden');
}

function printReport() {
    var content = document.getElementById('reportViewerContent').innerHTML;
    var win = window.open('', '_blank');
    win.document.write('<html><head><title>Precheck Report</title>');
    win.document.write('<style>body{font-family:monospace;padding:20px}table{border-collapse:collapse;width:100%}td,th{border:1px solid #ccc;padding:6px 10px;text-align:left}.PASS{color:green;font-weight:bold}.FAIL{color:red;font-weight:bold}</style>');
    win.document.write('</head><body>');
    win.document.write(content);
    win.document.write('</body></html>');
    win.document.close();
    win.print();
}

async function printReportById(id) {
    try {
        var report = await api('/patches/reports/' + id);
        var win = window.open('', '_blank');
        win.document.write('<html><head><title>' + esc(report.report_type || 'Report') + '</title>');
        win.document.write('<style>body{font-family:monospace;padding:20px}table{border-collapse:collapse;width:100%}td,th{border:1px solid #ccc;padding:6px 10px;text-align:left}.PASS{color:green;font-weight:bold}.FAIL{color:red;font-weight:bold}</style>');
        win.document.write('</head><body>');
        if (report.content && report.content.indexOf('<') >= 0) {
            win.document.write(report.content);
        } else {
            win.document.write('<pre>' + esc(report.content || 'No content') + '</pre>');
        }
        win.document.write('</body></html>');
        win.document.close();
        win.print();
    } catch (e) {
        showToast('Failed to print report: ' + e.message, 'error');
    }
}

// ---- PATCH VERSION PICKER IN JOB MODAL ----
var PATCH_OPS = ['gi_install','db_install','gi_precheck','db_precheck',
    'gi_switch','db_switch','stage_software','full_patch',
    'install','precheck','switch','stage'];

async function loadPatchVersionsForModal() {
    var sel = document.getElementById('patchVersionSelect');
    if (!sel) return;
    try {
        var patches = await api('/patches?is_downloaded=true');
        sel.innerHTML = '<option value="">-- Select Patch Version --</option>';
        patches.forEach(function(p) {
            var opt = document.createElement('option');
            opt.value = p.id;
            opt.textContent = 'v' + p.version + ' (' + (p.patch_type || 'RU') + ')' +
                (p.description ? ' - ' + p.description : '');
            opt.dataset.version = p.version;
            sel.appendChild(opt);
        });
        if (typeof selectedVm !== 'undefined' && selectedVm && selectedVm.target_patch_version_id) {
            sel.value = selectedVm.target_patch_version_id;
        }
        sel.onchange = function() {
            var infoEl = document.getElementById('patchVersionInfo');
            if (!infoEl) return;
            var pv = patches.find(function(pp) { return pp.id === sel.value; });
            if (!pv) { infoEl.innerHTML = ''; return; }
            var info = [];
            if (pv.gi_base_zip) info.push('GI: ' + pv.gi_base_zip);
            if (pv.db_base_zip) info.push('DB: ' + pv.db_base_zip);
            if (pv.opatch_zip) info.push('OPatch: ' + pv.opatch_zip);
            if (pv.patch_search_root) info.push('Search: ' + pv.patch_search_root);
            if (pv.new_gi_home) info.push('NEW_GI_HOME: ' + pv.new_gi_home);
            if (pv.new_db_home) info.push('NEW_DB_HOME: ' + pv.new_db_home);
            infoEl.innerHTML = info.length ? info.map(function(x) { return '<div>' + esc(x) + '</div>'; }).join('') : '';
        };
    } catch (e) {
        sel.innerHTML = '<option value="">Failed to load patches</option>';
    }
}

// Show patch version picker when operation category needs it
var _origOpenJobModal = typeof openJobModal === 'function' ? openJobModal : null;
if (_origOpenJobModal) {
    openJobModal = function() {
        _origOpenJobModal.apply(this, arguments);
        var pvGroup = document.getElementById('patchVersionGroup');
        if (pvGroup) {
            pvGroup.classList.remove('hidden');
            loadPatchVersionsForModal();
        }
    };
}

// Intercept job creation to include patchVersionId
var _baseApiPatches = api;
api = async function(path, opts) {
    if (path === '/jobs' && opts && opts.method === 'POST' && opts.body) {
        try {
            var body = JSON.parse(opts.body);
            var pvSel = document.getElementById('patchVersionSelect');
            if (pvSel && pvSel.value) {
                body.patchVersionId = pvSel.value;
            }
            opts.body = JSON.stringify(body);
        } catch(e) {}
    }
    return _baseApiPatches(path, opts);
};

// ── Software Depot ──────────────────────────────────────────────────────────

var _depotPollTimers = {};

function depotComponentBadge(st) {
    if (!st || st === 'pending')    return '<span style="color:var(--text-dim)">—</span>';
    if (st === 'extracting')        return '<span style="color:var(--warning)">⟳ Extracting</span>';
    if (st === 'ready')             return '<span style="color:var(--success)">✔ Ready</span>';
    if (st === 'skipped')           return '<span style="color:var(--text-dim)">— N/A</span>';
    if (st === 'failed')            return '<span style="color:var(--danger)">✘ Failed</span>';
    return '<span>' + st + '</span>';
}

function depotOverallBadge(st) {
    var map = {
        pending:    '<span class="status-badge status-pending">Pending</span>',
        extracting: '<span class="status-badge status-running">⟳ Extracting…</span>',
        ready:      '<span class="status-badge status-success">✔ Ready</span>',
        partial:    '<span class="status-badge status-warn">⚠ Partial</span>',
        failed:     '<span class="status-badge status-failed">✘ Failed</span>'
    };
    return map[st] || '<span class="status-badge">' + (st||'—') + '</span>';
}

async function loadDepot() {
    var tbody = document.getElementById('depotBody');
    var empty = document.getElementById('depotEmpty');
    if (!tbody) return;
    try {
        var rows = await api('/depot');
        if (!rows || !rows.length) {
            tbody.innerHTML = '';
            if (empty) empty.classList.remove('hidden');
            return;
        }
        if (empty) empty.classList.add('hidden');
        tbody.innerHTML = rows.map(function(d) {
            return '<tr>' +
                '<td><strong>' + esc(d.patch_version || d.version || '—') + '</strong></td>' +
                '<td style="color:var(--text-dim);font-size:12px">' + esc(d.description || '—') + '</td>' +
                '<td>' + depotComponentBadge(d.gi_status) + '</td>' +
                '<td>' + depotComponentBadge(d.db_status) + '</td>' +
                '<td>' + depotComponentBadge(d.ru_status) + '</td>' +
                '<td>' + depotComponentBadge(d.opatch_status) + '</td>' +
                '<td>' + depotOverallBadge(d.status) + '</td>' +
                '<td>' +
                    '<button class="btn btn-sm btn-secondary" onclick="extractToDepotById(\'' + d.patch_id + '\',\'' + esc(d.patch_version||d.version) + '\')" title="Re-extract">↺ Re-extract</button> ' +
                    '<button class="btn btn-sm btn-danger" onclick="deleteDepot(\'' + d.id + '\',\'' + esc(d.patch_version||d.version) + '\')">Del</button>' +
                '</td>' +
            '</tr>';
        }).join('');
        // Auto-refresh rows that are still extracting
        rows.forEach(function(d) {
            if (d.status === 'extracting') pollDepotStatus(d.patch_id);
        });
    } catch(e) {
        if (tbody) tbody.innerHTML = '<tr><td colspan="8" style="color:var(--danger)">Error loading depot: ' + esc(String(e)) + '</td></tr>';
    }
}

function pollDepotStatus(patch_id) {
    if (_depotPollTimers[patch_id]) return; // already polling
    _depotPollTimers[patch_id] = setInterval(async function() {
        try {
            var d = await api('/depot/' + patch_id + '/status');
            if (d.status !== 'extracting') {
                clearInterval(_depotPollTimers[patch_id]);
                delete _depotPollTimers[patch_id];
                loadDepot();
                showToast('Depot extraction ' + (d.status === 'ready' ? 'complete ✔' : d.status) + ' — v' + (d.version||''), d.status === 'ready' ? 'success' : 'warning');
            }
        } catch(_) {}
    }, 4000);
}

async function extractToDepot(patch_id, version) {
    await extractToDepotById(patch_id, version);
}

async function extractToDepotById(patch_id, version) {
    if (!confirm('Extract v' + version + ' to orchestrator depot?\n\nThis unzips GI base, DB base, RU and OPatch on the server. Large files — may take 10–20 minutes.')) return;
    try {
        var r = await api('/depot/extract', { method:'POST', body: JSON.stringify({ patch_id }) });
        showToast('Extraction started for v' + version, 'info');
        switchPatchSubTab('depot');
        loadDepot();
        pollDepotStatus(patch_id);
    } catch(e) {
        showToast('Extract failed: ' + (e.message||e), 'error');
    }
}

async function deleteDepot(id, version) {
    if (!confirm('Delete depot for v' + version + '?\n\nThis removes the extracted files from the orchestrator disk.')) return;
    try {
        await api('/depot/' + id, { method: 'DELETE' });
        showToast('Depot v' + version + ' deleted', 'success');
        loadDepot();
    } catch(e) {
        showToast('Delete failed: ' + (e.message||e), 'error');
    }
}
