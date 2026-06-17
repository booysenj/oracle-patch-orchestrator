// scheduler-ui.js - Schedule & Maintenance Window UI
// Loaded after patches-ui.js

var schedulesList = [];
var maintWindowsList = [];
var allVmsList = [];

// ---- Load VMs for picker ----
async function loadVmsForScheduler() {
    if (allVmsList.length) return allVmsList;
    try {
        allVmsList = await api('/vms');
    } catch(e) { allVmsList = []; }
    return allVmsList;
}

// ---- SCHEDULE MODAL ----
async function openScheduleModal(presetOp, presetVmIds) {
    await loadVmsForScheduler();
    var modal = document.getElementById('scheduleModal');
    if (!modal) return;

    // Populate VM checkboxes
    var vmList = document.getElementById('schedVmList');
    vmList.innerHTML = allVmsList.map(function(vm) {
        var checked = (presetVmIds && presetVmIds.indexOf(vm.id) >= 0) ? ' checked' : '';
        return '<label class="sched-vm-item"><input type="checkbox" value="' + vm.id + '"' + checked +
            ' data-hostname="' + esc(vm.hostname) + '"> ' + esc(vm.hostname) + '</label>';
    }).join('');

    // Populate operation dropdown
    var opSel = document.getElementById('schedOperation');
    if (opSel && opSel.options.length <= 1) {
        var ops = ['gi_precheck','db_precheck','gi_install','db_install',
            'gi_switch','db_switch','stage_software','full_patch',
            'gi_rollback','db_rollback','precheck','health_check'];
        ops.forEach(function(op) {
            var o = document.createElement('option');
            o.value = op; o.textContent = op.replace(/_/g,' ').toUpperCase();
            opSel.appendChild(o);
        });
    }
    if (presetOp) opSel.value = presetOp;

    // Populate patch version dropdown
    await loadPatchVersionsForScheduler();

    // Set default datetime to tomorrow 02:00
    var dtInput = document.getElementById('schedDatetime');
    if (dtInput && !dtInput.value) {
        var tomorrow = new Date();
        tomorrow.setDate(tomorrow.getDate() + 1);
        tomorrow.setHours(2, 0, 0, 0);
        dtInput.value = tomorrow.toISOString().slice(0, 16);
    }

    // Show/hide patch version based on operation
    toggleSchedPatchVersion();

    document.getElementById('schedError').textContent = '';
    modal.classList.remove('hidden');
}

function closeScheduleModal() {
    document.getElementById('scheduleModal').classList.add('hidden');
}

async function loadPatchVersionsForScheduler() {
    var sel = document.getElementById('schedPatchVersion');
    if (!sel) return;
    try {
        var patches = await api('/patches?is_downloaded=true');
        sel.innerHTML = '<option value="">-- No patch version --</option>';
        patches.forEach(function(p) {
            var opt = document.createElement('option');
            opt.value = p.id;
            opt.textContent = 'v' + p.version + ' (' + (p.patch_type || 'RU') + ')';
            sel.appendChild(opt);
        });
    } catch(e) {
        sel.innerHTML = '<option value="">Failed to load</option>';
    }
}

function toggleSchedPatchVersion() {
    var op = document.getElementById('schedOperation').value;
    var pvGroup = document.getElementById('schedPatchVersionGroup');
    var isRollback = /rollback/i.test(op);
    var needsPatch = /install|patch|stage|precheck|switch/i.test(op) && !isRollback;
    if (pvGroup) pvGroup.classList.toggle('hidden', !needsPatch);

    var rollbackNote = document.getElementById('schedRollbackNote');
    if (rollbackNote) rollbackNote.classList.toggle('hidden', !isRollback);
}

async function submitSchedule() {
    var errEl = document.getElementById('schedError');
    errEl.textContent = '';

    var vmChecks = document.querySelectorAll('#schedVmList input[type="checkbox"]:checked');
    var vmIds = Array.from(vmChecks).map(function(c) { return c.value; });
    if (!vmIds.length) { errEl.textContent = 'Select at least one VM'; return; }

    var operation = document.getElementById('schedOperation').value;
    if (!operation) { errEl.textContent = 'Select an operation'; return; }

    var dt = document.getElementById('schedDatetime').value;
    if (!dt) { errEl.textContent = 'Select date and time'; return; }

    var name = document.getElementById('schedName').value.trim() ||
        (operation.replace(/_/g,' ') + ' - ' + vmIds.length + ' VM(s)');

    var mode = document.getElementById('schedExecMode').value || 'parallel';
    var notes = document.getElementById('schedNotes').value.trim();
    var pvId = '';
    var pvGroup = document.getElementById('schedPatchVersionGroup');
    if (pvGroup && !pvGroup.classList.contains('hidden')) {
        pvId = document.getElementById('schedPatchVersion').value;
    }

    var btn = document.getElementById('schedSubmitBtn');
    btn.disabled = true; btn.textContent = 'Scheduling...';

    try {
        var result = await api('/schedules', {
            method: 'POST',
            body: JSON.stringify({
                name: name,
                vm_ids: vmIds,
                operation: operation,
                patch_version_id: pvId,
                scheduled_at: new Date(dt).toISOString(),
                timezone: 'Africa/Johannesburg',
                execution_mode: mode,
                notes: notes
            })
        });
        showToast('Scheduled: ' + name + ' at ' + dt, 'success');
        closeScheduleModal();
        loadScheduledJobs();
    } catch(e) {
        errEl.textContent = e.message;
        showToast('Schedule failed: ' + e.message, 'error');
    } finally {
        btn.disabled = false; btn.textContent = 'Schedule Job';
    }
}

// ---- SCHEDULED JOBS LIST ----
async function loadScheduledJobs() {
    var tbody = document.getElementById('schedJobsBody');
    if (!tbody) return;
    tbody.innerHTML = '<tr><td colspan="7" class="loading"><div class="spinner" style="margin:0 auto"></div></td></tr>';
    try {
        schedulesList = await api('/schedules');
        renderScheduledJobs();
    } catch(e) {
        tbody.innerHTML = '<tr><td colspan="7" class="loading">Failed to load schedules</td></tr>';
    }
}

function renderScheduledJobs() {
    var tbody = document.getElementById('schedJobsBody');
    var countEl = document.getElementById('schedCount');
    if (countEl) countEl.textContent = schedulesList.length + ' schedule' + (schedulesList.length !== 1 ? 's' : '');

    if (!schedulesList.length) {
        tbody.innerHTML = '<tr><td colspan="7" class="loading"><div class="empty-state-inline">' +
            '<p>No scheduled jobs. Click "Schedule Job" to create one.</p></div></td></tr>';
        return;
    }

    tbody.innerHTML = schedulesList.map(function(s) {
        var statusClass = 'status-' + s.status.toLowerCase();
        var statusBadge = '<span class="status-badge ' + statusClass + '">' + esc(s.status) + '</span>';

        var vmNames = (s.vm_names || []).join(', ') || '-';
        if (vmNames.length > 40) vmNames = vmNames.substring(0, 37) + '...';

        var schedDate = formatDate(s.scheduled_at);
        var actions = '';
        if (s.status === 'PENDING') {
            actions = '<button class="btn btn-xs btn-danger" onclick="cancelSchedule(\'' + s.id + '\')">Cancel</button>';
        }

        return '<tr>' +
            '<td>' + esc(s.name || s.operation) + '</td>' +
            '<td>' + esc(s.operation.replace(/_/g,' ').toUpperCase()) + '</td>' +
            '<td><span class="mono" style="font-size:12px">' + esc(vmNames) + '</span></td>' +
            '<td>' + schedDate + '</td>' +
            '<td>' + esc(s.execution_mode || 'parallel') + '</td>' +
            '<td>' + statusBadge + '</td>' +
            '<td class="action-btns">' + actions + '</td></tr>';
    }).join('');
}

async function cancelSchedule(id) {
    if (!confirm('Cancel this scheduled job?')) return;
    try {
        await api('/schedules/' + id, { method: 'DELETE' });
        showToast('Schedule cancelled', 'success');
        loadScheduledJobs();
    } catch(e) {
        showToast('Failed: ' + e.message, 'error');
    }
}

// ---- MAINTENANCE WINDOWS ----
async function loadMaintenanceWindows() {
    var tbody = document.getElementById('maintWindowsBody');
    if (!tbody) return;
    tbody.innerHTML = '<tr><td colspan="8" class="loading"><div class="spinner" style="margin:0 auto"></div></td></tr>';
    try {
        maintWindowsList = await api('/schedules/maintenance/all');
        renderMaintenanceWindows();
    } catch(e) {
        tbody.innerHTML = '<tr><td colspan="8" class="loading">Failed to load maintenance windows</td></tr>';
    }
}

function renderMaintenanceWindows() {
    var tbody = document.getElementById('maintWindowsBody');
    var countEl = document.getElementById('maintCount');
    if (countEl) countEl.textContent = maintWindowsList.length + ' window' + (maintWindowsList.length !== 1 ? 's' : '');

    if (!maintWindowsList.length) {
        tbody.innerHTML = '<tr><td colspan="8" class="loading"><div class="empty-state-inline">' +
            '<p>No maintenance windows configured. Click "New Maintenance Window" to create one.</p></div></td></tr>';
        return;
    }

    tbody.innerHTML = maintWindowsList.map(function(mw) {
        var activeBadge = mw.is_active
            ? '<span class="status-badge status-success">Active</span>'
            : '<span class="status-badge status-pending">Inactive</span>';

        var vmNames = (mw.vm_names || []).join(', ') || '-';
        if (vmNames.length > 30) vmNames = vmNames.substring(0, 27) + '...';

        var ops = [];
        try { ops = JSON.parse(mw.operations || '[]'); } catch(e) {}

        var nextRun = mw.next_run ? formatDate(mw.next_run) : '-';
        var lastRun = mw.last_run ? formatDate(mw.last_run) : 'Never';

        return '<tr>' +
            '<td><strong>' + esc(mw.name) + '</strong>' +
                (mw.description ? '<br><span style="font-size:12px;color:var(--text-dim)">' + esc(mw.description) + '</span>' : '') + '</td>' +
            '<td><code style="font-size:12px">' + esc(mw.cron_expression) + '</code></td>' +
            '<td>' + ops.map(function(o){return esc(o.replace(/_/g,' '));}).join(', ') + '</td>' +
            '<td><span class="mono" style="font-size:12px">' + esc(vmNames) + '</span></td>' +
            '<td>' + esc(mw.execution_mode || 'sequential') + '</td>' +
            '<td>' + nextRun + '</td>' +
            '<td>' + activeBadge + '</td>' +
            '<td class="action-btns">' +
                '<button class="btn btn-xs btn-secondary" onclick="toggleMaintWindow(\'' + mw.id + '\')">' +
                    (mw.is_active ? 'Disable' : 'Enable') + '</button> ' +
                '<button class="btn btn-xs btn-danger" onclick="deleteMaintWindow(\'' + mw.id + '\',\'' + esc(mw.name) + '\')">Delete</button>' +
            '</td></tr>';
    }).join('');
}

async function toggleMaintWindow(id) {
    try {
        var result = await api('/schedules/maintenance/' + id + '/toggle', { method: 'PUT' });
        showToast(result.message, 'success');
        loadMaintenanceWindows();
    } catch(e) {
        showToast('Failed: ' + e.message, 'error');
    }
}

async function deleteMaintWindow(id, name) {
    if (!confirm('Delete maintenance window "' + name + '"?')) return;
    try {
        await api('/schedules/maintenance/' + id, { method: 'DELETE' });
        showToast('Maintenance window deleted', 'success');
        loadMaintenanceWindows();
    } catch(e) {
        showToast('Failed: ' + e.message, 'error');
    }
}

// ---- NEW MAINTENANCE WINDOW MODAL ----
var cronPresets = [];

async function openMaintWindowModal() {
    await loadVmsForScheduler();
    var modal = document.getElementById('maintWindowModal');
    if (!modal) return;

    // Load cron presets
    if (!cronPresets.length) {
        try { cronPresets = await api('/schedules/maintenance/cron-presets'); } catch(e) { cronPresets = []; }
    }

    // Populate VM checkboxes
    var vmList = document.getElementById('maintVmList');
    vmList.innerHTML = allVmsList.map(function(vm) {
        return '<label class="sched-vm-item"><input type="checkbox" value="' + vm.id + '"' +
            ' data-hostname="' + esc(vm.hostname) + '"> ' + esc(vm.hostname) + '</label>';
    }).join('');

    // Populate cron presets
    var presetSel = document.getElementById('maintCronPreset');
    if (presetSel && presetSel.options.length <= 1) {
        cronPresets.forEach(function(p) {
            var o = document.createElement('option');
            o.value = p.cron;
            o.textContent = p.label + ' (' + p.cron + ')';
            presetSel.appendChild(o);
        });
    }

    // Populate operation checkboxes
    var opsDiv = document.getElementById('maintOps');
    if (opsDiv && !opsDiv.children.length) {
        var ops = ['gi_precheck','db_precheck','gi_install','db_install',
            'gi_switch','db_switch','stage_software','full_patch','health_check'];
        opsDiv.innerHTML = ops.map(function(op) {
            return '<label class="sched-vm-item"><input type="checkbox" value="' + op + '"> ' +
                op.replace(/_/g,' ').toUpperCase() + '</label>';
        }).join('');
    }

    document.getElementById('maintError').textContent = '';
    modal.classList.remove('hidden');
}

function closeMaintWindowModal() {
    document.getElementById('maintWindowModal').classList.add('hidden');
}

function applyCronPreset() {
    var sel = document.getElementById('maintCronPreset');
    var input = document.getElementById('maintCronExpr');
    if (sel.value) input.value = sel.value;
}

async function submitMaintWindow() {
    var errEl = document.getElementById('maintError');
    errEl.textContent = '';

    var name = document.getElementById('maintName').value.trim();
    if (!name) { errEl.textContent = 'Name is required'; return; }

    var cronExpr = document.getElementById('maintCronExpr').value.trim();
    if (!cronExpr) { errEl.textContent = 'Cron expression is required'; return; }

    var vmChecks = document.querySelectorAll('#maintVmList input[type="checkbox"]:checked');
    var vmIds = Array.from(vmChecks).map(function(c) { return c.value; });
    if (!vmIds.length) { errEl.textContent = 'Select at least one VM'; return; }

    var opChecks = document.querySelectorAll('#maintOps input[type="checkbox"]:checked');
    var operations = Array.from(opChecks).map(function(c) { return c.value; });
    if (!operations.length) { errEl.textContent = 'Select at least one operation'; return; }

    var mode = document.getElementById('maintExecMode').value || 'sequential';
    var desc = document.getElementById('maintDesc').value.trim();
    var notes = document.getElementById('maintNotes').value.trim();

    var pvId = '';
    var pvSel = document.getElementById('maintPatchVersion');
    if (pvSel) pvId = pvSel.value;

    var btn = document.getElementById('maintSubmitBtn');
    btn.disabled = true; btn.textContent = 'Creating...';

    try {
        var result = await api('/schedules/maintenance', {
            method: 'POST',
            body: JSON.stringify({
                name: name,
                description: desc,
                vm_ids: vmIds,
                operations: operations,
                patch_version_id: pvId,
                cron_expression: cronExpr,
                timezone: 'Africa/Johannesburg',
                execution_mode: mode,
                notes: notes
            })
        });
        showToast('Maintenance window created: ' + name, 'success');
        closeMaintWindowModal();
        loadMaintenanceWindows();
    } catch(e) {
        errEl.textContent = e.message;
        showToast('Failed: ' + e.message, 'error');
    } finally {
        btn.disabled = false; btn.textContent = 'Create Window';
    }
}

// ---- SCHEDULE SUB-TAB SWITCHING ----
function switchScheduleSubTab(tab) {
    document.querySelectorAll('.sched-sub-tab').forEach(function(b) {
        b.classList.toggle('active', b.dataset.subtab === tab);
    });
    var panels = ['schedJobsPanel', 'maintWindowsPanel'];
    var tabs = ['scheduled', 'maintenance'];
    for (var i = 0; i < panels.length; i++) {
        var el = document.getElementById(panels[i]);
        if (el) el.classList.toggle('hidden', tabs[i] !== tab);
    }
    if (tab === 'scheduled') loadScheduledJobs();
    if (tab === 'maintenance') loadMaintenanceWindows();
}

// ---- Hook into main tab switching ----
var _origSwitchTab = typeof switchTab === 'function' ? switchTab : null;
switchTab = function(tab) {
    if (_origSwitchTab) _origSwitchTab(tab);
    if (tab === 'schedules') {
        loadScheduledJobs();
    }
};
