const express = require('express');
const { createJob, cancelJob, getJob, listJobs, OPERATION_PHASES } = require('../lib/job-runner');
const { runPreflightChecks } = require('../lib/preflight');
const { logAudit, getAuditLog } = require('../lib/audit');
const router = express.Router();

router.get('/operations', (_req, res) => {
    res.json({
        staging: { label: 'Software Staging', items: [
            { key: 'stage_software', label: 'Stage Software Check', downtime: false },
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
        const { vmId, operation, dryRun, dbUniqueName, confirmationToken } = req.body;
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
            vmId, operation, dryRun: !!dryRun,
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
