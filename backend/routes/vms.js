const express = require('express');
const { v4: uuidv4 } = require('uuid');
const { getDB } = require('../lib/db');
const router = express.Router();

router.get('/', (_req, res) => {
    res.json(getDB().prepare('SELECT * FROM vms ORDER BY environment, hostname').all());
});

router.get('/:id', (req, res) => {
    const vm = getDB().prepare('SELECT * FROM vms WHERE id = ?').get(req.params.id);
    if (!vm) return res.status(404).json({ error: 'VM not found' });
    res.json(vm);
});

router.post('/', (req, res) => {
    const { hostname, ip, ssh_user, ssh_port, node_role, environment, script_path, patch_target, execution_mode, stage_path } = req.body;
    if (!hostname || !ip) return res.status(400).json({ error: 'hostname and ip required' });
    const id = uuidv4();
    getDB().prepare(
        `INSERT INTO vms (id, hostname, ip, ssh_user, ssh_port, node_role, environment, script_path, patch_target, execution_mode, stage_path)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`
    ).run(id, hostname, ip, ssh_user || 'oracle', ssh_port || 22,
          node_role || 'UNKNOWN', environment || 'UAT',
          script_path || '/home/oracle/os-patching-auto-1.sh',
          patch_target || '19.26',
          execution_mode || 'agent',
          stage_path || null);
    res.status(201).json({ id, hostname, ip });
});

router.put('/:id', (req, res) => {
    const db = getDB();
    const existing = db.prepare('SELECT * FROM vms WHERE id = ?').get(req.params.id);
    if (!existing) return res.status(404).json({ error: 'VM not found' });
    const { hostname, ip, ssh_user, ssh_port, node_role, environment, script_path, patch_target, enabled, execution_mode, stage_path } = req.body;
    db.prepare(
        `UPDATE vms SET hostname=?, ip=?, ssh_user=?, ssh_port=?, node_role=?,
         environment=?, script_path=?, patch_target=?, enabled=?, execution_mode=?, stage_path=?, updated_at=datetime('now') WHERE id=?`
    ).run(
        hostname || existing.hostname,
        ip || existing.ip,
        ssh_user || existing.ssh_user,
        ssh_port || existing.ssh_port,
        node_role || existing.node_role,
        environment || existing.environment,
        script_path || existing.script_path,
        patch_target || existing.patch_target,
        enabled !== undefined ? (enabled ? 1 : 0) : existing.enabled,
        execution_mode || existing.execution_mode || 'agent',
        stage_path !== undefined ? stage_path : existing.stage_path,
        req.params.id
    );
    res.json({ updated: true });
});

// Discovery snapshot for a VM — returns parsed mounts + static inventory
router.get('/:id/discovery', (req, res) => {
    const vm = getDB().prepare('SELECT * FROM vms WHERE id = ?').get(req.params.id);
    if (!vm) return res.status(404).json({ error: 'VM not found' });
    res.json({
        id: vm.id,
        hostname: vm.hostname,
        last_discovery_at: vm.last_discovery_at || null,
        db_unique_name: vm.db_unique_name || null,
        database_role: vm.database_role || null,
        switchover_status: vm.switchover_status || null,
        cluster_type: vm.cluster_type || null,
        db_version: vm.db_version || null,
        cluster_name: vm.cluster_name || null,
        crs_version: vm.crs_version || null,
        nodes: vm.nodes_json ? JSON.parse(vm.nodes_json) : [],
        old_gi_home: vm.old_gi_home || null,
        old_db_home: vm.old_db_home || null,
        preferred_staging_mount: vm.preferred_staging_mount || null,
        mounts: vm.mounts_json ? JSON.parse(vm.mounts_json) : [],
        static: vm.static_json ? JSON.parse(vm.static_json) : {},
        dynamic: vm.dynamic_json ? JSON.parse(vm.dynamic_json) : {},
    });
});

// Resolved configuration for a VM — derived paths the orchestrator will pass to the script
router.get('/:id/resolved-config', (req, res) => {
    const db = getDB();
    const vm = db.prepare('SELECT * FROM vms WHERE id = ?').get(req.params.id);
    if (!vm) return res.status(404).json({ error: 'VM not found' });

    let pv = null;
    if (vm.target_patch_version_id) {
        pv = db.prepare('SELECT * FROM patch_versions WHERE id = ?').get(vm.target_patch_version_id);
    }

    let giHomeBase = '', dbHomeBase = '';
    try {
        let r = db.prepare("SELECT value FROM app_settings WHERE key = 'gi_home_base'").get();
        if (r && r.value) giHomeBase = r.value.replace(/\/$/, '');
        r = db.prepare("SELECT value FROM app_settings WHERE key = 'db_home_base'").get();
        if (r && r.value) dbHomeBase = r.value.replace(/\/$/, '');
    } catch(_) {}

    function deriveHome(explicit, pvVal, base, version) {
        if (explicit) return explicit;
        if (pvVal) return pvVal;
        if (base && version) return base + '/' + version;
        return '';
    }
    const pvVersion = (pv && pv.version) ? pv.version : '';
    const newGiHome = vm.old_gi_home
        ? deriveHome(vm.new_gi_home, pv && pv.new_gi_home, giHomeBase, pvVersion)
        : '';
    const newDbHome = deriveHome(vm.new_db_home, pv && pv.new_db_home, dbHomeBase, pvVersion);
    const stagingDropDir = vm.preferred_staging_mount || '/home/oracle/staging';

    // These match the hardcoded defaults in os-patch-auto.sh
    const patchSearchRoots = ['/grid/software', '/app/software', '/app/software/db_software/patches', '/staging/software'];
    const ojvmZipDir = stagingDropDir.replace(/\/$/, '') + '/db_software/ojvm';

    res.json({
        oldGiHome: vm.old_gi_home || '',
        newGiHome,
        oldDbHome: vm.old_db_home || '',
        newDbHome,
        stagingDropDir,
        patchSearchRoots,
        ojvmZipDir,
        patchVersion: pvVersion,
        precheckGiHome: newGiHome ? newGiHome + '-precheck' : '',
        precheckDbHome: newDbHome ? newDbHome + '-precheck' : '',
    });
});

// Allow DBA to manually override discovery-populated fields
router.patch('/:id/config', (req, res) => {
    const allowed = ['old_gi_home', 'new_gi_home', 'old_db_home', 'new_db_home',
                     'db_unique_name', 'preferred_staging_mount', 'cluster_name',
                     'mail_to', 'mail_from', 'node_role', 'environment', 'patch_target'];
    const updates = {};
    for (const k of allowed) {
        if (req.body[k] !== undefined) updates[k] = req.body[k];
    }
    if (!Object.keys(updates).length) return res.status(400).json({ error: 'Nothing to update' });
    const cols = Object.keys(updates).map(k => k + ' = ?').join(', ');
    const vals = [...Object.values(updates), req.params.id];
    getDB().prepare('UPDATE vms SET ' + cols + ' WHERE id = ?').run(...vals);
    res.json({ ok: true, updated: Object.keys(updates) });
});

router.delete('/:id', (req, res) => {
    const result = getDB().prepare('DELETE FROM vms WHERE id = ?').run(req.params.id);
    if (result.changes === 0) return res.status(404).json({ error: 'VM not found' });
    res.json({ deleted: true });
});

// Bulk import VMs
router.post('/bulk', (req, res) => {
    const { vms: vmList } = req.body;
    if (!Array.isArray(vmList) || !vmList.length) {
        return res.status(400).json({ error: 'vms array required' });
    }
    const db = getDB();
    const stmt = db.prepare(
        `INSERT INTO vms (id, hostname, ip, ssh_user, ssh_port, node_role, environment, script_path, patch_target, execution_mode)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`
    );
    const results = [];
    const insertMany = db.transaction((list) => {
        for (const vm of list) {
            if (!vm.hostname || !vm.ip) { results.push({ hostname: vm.hostname, error: 'hostname and ip required' }); continue; }
            const id = uuidv4();
            stmt.run(id, vm.hostname, vm.ip, vm.ssh_user || 'oracle', vm.ssh_port || 22,
                     vm.node_role || 'UNKNOWN', vm.environment || 'UAT',
                     vm.script_path || '/home/oracle/os-patching-auto-1.sh',
                     vm.patch_target || '19.26',
                     vm.execution_mode || 'agent');
            results.push({ id, hostname: vm.hostname, ip: vm.ip });
        }
    });
    insertMany(vmList);
    res.status(201).json({ imported: results.length, results });
});

module.exports = router;
