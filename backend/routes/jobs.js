const express = require('express');
const { createJob, cancelJob, getJob, listJobs, OPERATION_PHASES } = require('../lib/job-runner');
const { runPreflightChecks } = require('../lib/preflight');
const { logAudit, getAuditLog } = require('../lib/audit');
const router = express.Router();

router.get('/operations', (_req, res) => {
    res.json({
        staging: { label: 'Software Staging', items: [
            { key: 'stage_software', label: 'Stage Software', downtime: false },
        ]},
        gi: { label: 'GI Operations (19c patching)', items: [
            { key: 'gi_precheck', label: 'GI Precheck', downtime: false },
            { key: 'gi_install',  label: 'GI Install',  downtime: false },
            { key: 'gi_switch',   label: 'GI Switch (immediate)', downtime: true },
            { key: 'gi_rollback', label: 'GI Rollback', downtime: true },
        ]},
        db: { label: 'DB Operations (19c patching)', items: [
            { key: 'db_precheck',  label: 'DB Precheck',  downtime: false },
            { key: 'db_install',   label: 'DB Install',   downtime: false },
            { key: 'db_switch',    label: 'DB Switch (immediate)', downtime: true, needsDbName: true },
            { key: 'db_rollback',  label: 'DB Rollback',  downtime: true, needsDbName: true },
            { key: 'db_ojvm_only', label: 'DB OJVM Only', downtime: false },
        ]},
        gi_upgrade: { label: 'GI Upgrade (19c to 23/26ai)', items: [
            { key: 'gi_upgrade_precheck', label: 'GI Upgrade Precheck', downtime: false },
            { key: 'gi_upgrade_install',  label: 'GI Upgrade Install',  downtime: false },
            { key: 'gi_upgrade_upgrade',  label: 'GI Upgrade Switch',   downtime: true },
        ]},
        db_upgrade: { label: 'DB Upgrade (19c to 23/26ai)', items: [
            { key: 'db_upgrade_precheck', label: 'DB Upgrade Precheck', downtime: false },
            { key: 'db_upgrade_install',  label: 'DB Upgrade Install',  downtime: false },
            { key: 'db_upgrade_upgrade',  label: 'DB Upgrade Deploy',   downtime: true },
            { key: 'db_upgrade_rollback', label: 'DB Upgrade Rollback', downtime: true },
        ]},
        cluster: { label: 'Cluster Maintenance', items: [
            { key: 'cluster_precheck',      label: 'Cluster Precheck',       downtime: false },
            { key: 'cluster_stop_dbs',       label: 'Stop Local DBs',        downtime: true },
            { key: 'cluster_os_patch',       label: 'OS Patch',              downtime: false },
            { key: 'cluster_reboot',         label: 'Reboot Node',           downtime: true },
            { key: 'cluster_postreboot_db',  label: 'Post-Reboot DB Start',  downtime: false },
            { key: 'setup_patchuser',        label: 'Setup Patchuser (SSH)', downtime: false },
        ]},
        ssh_remote: { label: 'SSH Remote Orchestration', items: [
            { key: 'remote_shutdown_apps_then_db', label: 'Remote Shutdown APPs then DB', downtime: true },
            { key: 'batched_startup',              label: 'Batched Startup (DB+APPs)', downtime: false },
        ]},
    });
});

router.post('/preflight', (req, res) => {
    const { vmId, operation } = req.body;
    if (!vmId || !operation) return res.status(400).json({ error: 'vmId and operation required' });
    res.json(runPreflightChecks(vmId, operation));
});

router.get('/audit', (req, res) => {
    const { limit, vm_id, username } = req.query;
    res.json(getAuditLog({ limit: limit ? parseInt(limit) : 100, vmId: vm_id, username }));
});

router.get('/', (req, res) => {
    const { vm_id, status, limit } = req.query;
    res.json(listJobs({ vmId: vm_id, status, limit: limit ? parseInt(limit) : 50 }));
});

router.get('/:id', (req, res) => {
    const job = getJob(req.params.id);
    if (!job) return res.status(404).json({ error: 'Job not found' });
    res.json(job);
});

router.post('/', (req, res) => {
    try {
        const { vmId, operation, dryRun, verbose, applyOjvm, dbUniqueName, confirmationToken } = req.body;
        if (!vmId || !operation) {
            return res.status(400).json({ error: 'vmId and operation are required' });
        }

        const preflight = runPreflightChecks(vmId, operation);

        if (preflight.vmLocked) {
            logAudit({
                username: req.user.username, action: 'job_blocked_by_lock',
                vmId, details: `Blocked: ${operation} - VM locked by ${preflight.lockDetails.created_by}`,
                ipAddress: req.ip
            });
            return res.status(409).json({ error: 'VM is locked', lock: preflight.lockDetails });
        }

        if (preflight.causesDowntime && confirmationToken !== 'CONFIRMED') {
            return res.status(428).json({
                error: 'Downtime operation requires explicit confirmation',
                causesDowntime: true, warnings: preflight.warnings,
                rollbackAvailable: preflight.rollbackAvailable
            });
        }

        const result = createJob({
            vmId, operation, dryRun: !!dryRun, verbose: !!verbose, applyOjvm: !!applyOjvm,
            dbUniqueName: dbUniqueName || '',
            createdBy: req.user.username
        });

        logAudit({
            username: req.user.username, action: 'job_created',
            vmId, jobId: result.jobId,
            details: `${operation}${dryRun ? ' (dry-run)' : ''} - phase: ${result.phase}`,
            ipAddress: req.ip
        });

        res.status(201).json({ ...result, preflight });
    } catch (err) {
        res.status(400).json({ error: err.message });
    }
});

// DELETE /api/jobs/history — purge completed/failed jobs matching filters
// Body: { before: 'YYYY-MM-DD', vmIds: ['id1',...], statuses: ['success','failed'] }
router.delete('/history', (req, res) => {
    const { before, vmIds, statuses } = req.body;
    const db = require('../lib/db').getDB();

    const allowedStatuses = ['success', 'failed', 'cancelled', 'running', 'queued'];
    const filterStatuses = (Array.isArray(statuses) && statuses.length)
        ? statuses.filter(s => allowedStatuses.includes(s))
        : ['success', 'failed', 'cancelled'];

    if (!filterStatuses.length) return res.status(400).json({ error: 'No valid statuses specified' });

    // Force-stop any running/queued jobs before deleting them
    const activeStatuses = filterStatuses.filter(s => s === 'running' || s === 'queued');
    if (activeStatuses.length) {
        const ap = activeStatuses.map(() => '?').join(',');
        db.prepare(`UPDATE jobs SET status='failed', exit_code=-99, finished_at=datetime('now') WHERE status IN (${ap})`).run(...activeStatuses);
    }

    const placeholders = filterStatuses.map(() => '?').join(',');
    const params = [...filterStatuses];
    let where = `status IN (${placeholders})`;

    if (before) {
        where += ` AND created_at < ?`;
        params.push(before);
    }

    if (Array.isArray(vmIds) && vmIds.length) {
        const vmPlaceholders = vmIds.map(() => '?').join(',');
        where += ` AND vm_id IN (${vmPlaceholders})`;
        params.push(...vmIds);
    }

    const jobIds = db.prepare(`SELECT id FROM jobs WHERE ${where}`).all(...params).map(r => r.id);
    if (!jobIds.length) return res.json({ deleted: 0 });

    const idPlaceholders = jobIds.map(() => '?').join(',');
    db.prepare(`DELETE FROM job_logs WHERE job_id IN (${idPlaceholders})`).run(...jobIds);
    const result = db.prepare(`DELETE FROM jobs WHERE id IN (${idPlaceholders})`).run(...jobIds);

    logAudit({
        username: req.user?.username || 'admin', action: 'job_history_cleared',
        details: `Deleted ${result.changes} job(s) — before: ${before || 'any'}, statuses: ${filterStatuses.join(',')}`,
        ipAddress: req.ip
    });

    res.json({ deleted: result.changes });
});

router.post('/:id/cancel', (req, res) => {
    try {
        const result = cancelJob(req.params.id);
        logAudit({
            username: req.user.username, action: 'job_cancelled',
            jobId: req.params.id, ipAddress: req.ip
        });
        res.json(result);
    } catch (err) { res.status(400).json({ error: err.message }); }
});

module.exports = router;
