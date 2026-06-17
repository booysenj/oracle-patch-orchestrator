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
