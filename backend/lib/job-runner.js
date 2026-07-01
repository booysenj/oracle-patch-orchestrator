const { v4: uuidv4 } = require('uuid');
const { getDB } = require('./db');
const sshManager = require('./ssh-manager');
const EventEmitter = require('events');
const jobEvents = new EventEmitter();
jobEvents.setMaxListeners(100);

// Maps UI operation names to the exact phase args the shell script expects
const OPERATION_PHASES = {
    gi_precheck: 'gi_precheck', gi_install: 'gi_install', gi_oh_switch: 'gi_oh_switch',
    gi_oh_switch_scheduled: 'gi_oh_switch_scheduled', gi_rollback: 'gi_rollback',
    db_precheck: 'db_precheck', db_install: 'db_install', db_oh_switch: 'db_oh_switch',
    db_oh_switch_scheduled: 'db_oh_switch_scheduled', db_rollback: 'db_rollback',
    db_ojvm_only: 'db_ojvm_only',
    cluster_precheck: 'cluster_precheck', cluster_stop_dbs: 'cluster_stop_dbs',
    cluster_os_patch: 'cluster_os_patch', cluster_reboot: 'cluster_reboot',
    cluster_postreboot_db: 'cluster_postreboot_db',
    shutdown_services: 'shutdown_services', startup_services: 'startup_services',
    stage_software: 'stage_software',
    gi_upgrade_precheck: 'gi_upgrade_precheck', gi_upgrade_install: 'gi_upgrade_install',
    gi_upgrade_upgrade: 'gi_upgrade_upgrade',
    db_upgrade_precheck: 'db_upgrade_precheck', db_upgrade_install: 'db_upgrade_install',
    db_upgrade_upgrade: 'db_upgrade_upgrade', db_upgrade_rollback: 'db_upgrade_rollback',
    setup_patchuser: 'setup_patchuser',
    remote_shutdown_apps_then_db: 'remote_shutdown_apps_then_db',
    batched_startup: 'batched_startup'
};

function createJob({ vmId, operation, dryRun = false, verbose = false, applyOjvm = false, createdBy = 'system', dbUniqueName = '', patchVersionId = '' }) {
    const db = getDB();
    const vm = db.prepare('SELECT * FROM vms WHERE id = ?').get(vmId);
    if (!vm) throw new Error(`VM not found: ${vmId}`);
    if (!vm.enabled) throw new Error(`VM is disabled: ${vm.hostname}`);
    const phase = OPERATION_PHASES[operation];
    if (!phase) throw new Error(`Unknown operation: ${operation}`);
    const jobId = uuidv4();

    // Ensure optional columns exist (safe on old DBs)
    try { db.exec('ALTER TABLE jobs ADD COLUMN verbose INTEGER DEFAULT 0'); } catch(_) {}
    try { db.exec('ALTER TABLE jobs ADD COLUMN apply_ojvm INTEGER DEFAULT 0'); } catch(_) {}
    try { db.exec("ALTER TABLE jobs ADD COLUMN target_patch_version_id TEXT DEFAULT ''"); } catch(_) {}

    const pvId = patchVersionId || '';

    // Agent mode: insert as 'queued' — the Python agent polls and picks it up
    if ((vm.execution_mode || 'agent') === 'agent') {
        db.prepare(
            `INSERT INTO jobs (id, vm_id, operation, phase, status, dry_run, verbose, apply_ojvm, created_by, db_unique_name, target_patch_version_id)
             VALUES (?, ?, ?, ?, 'queued', ?, ?, ?, ?, ?, ?)`
        ).run(jobId, vmId, operation, phase, dryRun ? 1 : 0, verbose ? 1 : 0, applyOjvm ? 1 : 0, createdBy, dbUniqueName || '', pvId);

        // Queue file transfers for install and stage_software operations.
        // For install ops: job stays 'queued' and the poll endpoint gates release
        // until all required transfers are STAGED (see agent.js poll handler).
        // For stage_software: same transfers are queued so the user can pre-stage
        // before the install window without running the installer.
        const isGiOp  = operation === 'gi_install' || operation === 'gi_upgrade_install' || operation === 'stage_software';
        const isDbOp  = operation === 'db_install' || operation === 'db_upgrade_install' || operation === 'stage_software';
        const isInstallOp = operation === 'gi_install' || operation === 'db_install' ||
                            operation === 'gi_upgrade_install' || operation === 'db_upgrade_install' ||
                            operation === 'stage_software';
        // Prechecks only auto-fetch the RU — it unzips to a safe staging directory
        // (not the live home), unlike gi_base/db_base/opatch which unzip straight into
        // NEW_GI_HOME/NEW_DB_HOME and would be unsafe to pre-populate before an install
        // is actually decided on. This lets `RU Directory` resolve to PASS during
        // gi_precheck/db_precheck instead of just reporting it missing.
        const isGiPrecheck = operation === 'gi_precheck';
        const isDbPrecheck = operation === 'db_precheck';
        const isPrecheckOp = isGiPrecheck || isDbPrecheck;
        if (pvId && (isInstallOp || isPrecheckOp)) {
            try {
                const pv = db.prepare('SELECT * FROM patch_versions WHERE id = ?').get(pvId);
                if (pv) {
                    const stmtTransfer = db.prepare(`INSERT OR IGNORE INTO patch_transfers
                        (id, patch_id, source_path, target_host, target_stage_path, status, file_type, transfer_method)
                        VALUES (?, ?, ?, ?, ?, 'PENDING', ?, 'API')`);
                    const stmtStaged = db.prepare(
                        "SELECT 1 FROM patch_transfers WHERE patch_id=? AND target_host=? AND file_type=? AND status='STAGED'"
                    );

                    var pvVer = pv.version || '';
                    function _stageRoot(home) {
                        if (!home) return '';
                        var p = home.split('/').filter(Boolean);
                        return p.length ? '/' + p[0] + '/software' : '';
                    }
                    var vmStage = vm.stage_path || vm.preferred_staging_mount || '';
                    var giStage = vmStage || _stageRoot(vm.old_gi_home) || '/grid/software';
                    var dbStage = vmStage || _stageRoot(vm.old_db_home || vm.current_db_home) || '/app/software';

                    // GI base zip — unzipped into NEW_GI_HOME by the agent (X-Unzip-To header)
                    if (isGiOp && pv.gi_base_zip && vm.old_gi_home) {
                        if (!stmtStaged.get(pvId, vm.hostname, 'gi_base'))
                            stmtTransfer.run(uuidv4(), pvId, pv.gi_base_zip, vm.hostname, giStage, 'gi_base');
                    }

                    // DB base zip — unzipped into NEW_DB_HOME by the agent (X-Unzip-To header)
                    if (isDbOp && pv.db_base_zip) {
                        if (!stmtStaged.get(pvId, vm.hostname, 'db_base'))
                            stmtTransfer.run(uuidv4(), pvId, pv.db_base_zip, vm.hostname, dbStage, 'db_base');
                    }

                    // RU patch zip — unzipped to staging so patch-number subdir is findable via PATCH_SEARCH_ROOTS.
                    // Queued for prechecks too (RU stages safely, unlike gi_base/db_base/opatch).
                    if (pv.patch_search_root || pv.opatch_zip) {
                        var ruSrc = pv.patch_search_root || '';
                        var ruStage = ((isGiOp || isGiPrecheck) ? giStage : dbStage) + (pvVer ? '/p' + pvVer : '/patches');
                        if (ruSrc && !stmtStaged.get(pvId, vm.hostname, 'ru_patch'))
                            stmtTransfer.run(uuidv4(), pvId, ruSrc, vm.hostname, ruStage, 'ru_patch');

                        // OPatch zip — unzipped into NEW_GI_HOME or NEW_DB_HOME to replace the bundled OPatch.
                        // Not queued for prechecks: it unzips straight into the live home, which shouldn't
                        // be pre-populated before an install is actually decided on.
                        if (!isPrecheckOp) {
                            var opSrc = pv.opatch_zip || '';
                            var opStage = isGiOp ? giStage : dbStage;
                            if (opSrc && !stmtStaged.get(pvId, vm.hostname, 'opatch'))
                                stmtTransfer.run(uuidv4(), pvId, opSrc, vm.hostname, opStage, 'opatch');
                        }
                    }
                }
            } catch(_e) { console.error('[job-runner] transfer queue error:', _e.message); }
        }

        return { jobId, vmId, operation, phase, dryRun, verbose, applyOjvm, mode: 'agent' };
    }

    // SSH mode: execute immediately via SSH (legacy / direct-network environments)
    db.prepare(
        `INSERT INTO jobs (id, vm_id, operation, phase, status, dry_run, verbose, apply_ojvm, created_by, db_unique_name, target_patch_version_id)
         VALUES (?, ?, ?, ?, 'pending', ?, ?, ?, ?, ?, ?)`
    ).run(jobId, vmId, operation, phase, dryRun ? 1 : 0, verbose ? 1 : 0, applyOjvm ? 1 : 0, createdBy, dbUniqueName || '', pvId);
    const envVars = [];
    if (dryRun) envVars.push('DRYRUN=true');
    if (applyOjvm) envVars.push('APPLY_OJVM=true');
    envVars.push(`INSIGHT_NODE_ROLE=${vm.node_role}`);
    const bashCmd = verbose ? 'bash -x' : 'bash';
    const cmd = [...envVars, bashCmd, vm.script_path, phase].join(' ');
    db.prepare(`UPDATE jobs SET status = 'running', started_at = datetime('now') WHERE id = ?`).run(jobId);
    const logInsert = db.prepare(`INSERT INTO job_logs (job_id, stream, line) VALUES (?, ?, ?)`);
    const session = sshManager.exec(vm, cmd);
    session.on('stdout', (data) => {
        for (const line of data.split('\n')) {
            if (line.trim()) {
                logInsert.run(jobId, 'stdout', line);
                jobEvents.emit(`log:${jobId}`, { stream: 'stdout', line, ts: new Date().toISOString() });
            }
        }
    });
    session.on('stderr', (data) => {
        for (const line of data.split('\n')) {
            if (line.trim()) {
                logInsert.run(jobId, 'stderr', line);
                jobEvents.emit(`log:${jobId}`, { stream: 'stderr', line, ts: new Date().toISOString() });
            }
        }
    });
    session.on('close', (exitCode) => {
        const status = exitCode === 0 ? 'success' : 'failed';
        db.prepare(`UPDATE jobs SET status = ?, exit_code = ?, finished_at = datetime('now') WHERE id = ?`).run(status, exitCode, jobId);
        jobEvents.emit(`done:${jobId}`, { status, exitCode });
    });
    return { jobId, vmId, operation, phase, dryRun, mode: 'ssh' };
}

function cancelJob(jobId) {
    const db = getDB();
    const job = db.prepare('SELECT * FROM jobs WHERE id = ?').get(jobId);
    if (!job) throw new Error(`Job not found: ${jobId}`);
    if (!['running', 'queued'].includes(job.status)) throw new Error(`Job cannot be cancelled (status: ${job.status})`);
    if (job.status === 'running') sshManager.cancel(job.vm_id);
    db.prepare(`UPDATE jobs SET status = 'cancelled', finished_at = datetime('now') WHERE id = ?`).run(jobId);
    return { cancelled: true, jobId };
}

function getJob(jobId) { return getDB().prepare('SELECT * FROM jobs WHERE id = ?').get(jobId); }

function listJobs({ vmId, status, limit = 50 } = {}) {
    let sql = 'SELECT j.*, v.hostname, v.ip FROM jobs j JOIN vms v ON j.vm_id = v.id WHERE 1=1';
    const params = [];
    if (vmId) { sql += ' AND j.vm_id = ?'; params.push(vmId); }
    if (status) { sql += ' AND j.status = ?'; params.push(status); }
    sql += ' ORDER BY j.created_at DESC LIMIT ?';
    params.push(limit);
    return getDB().prepare(sql).all(...params);
}

function getJobLogs(jobId, { since, limit = 500, offset = 0 } = {}) {
    let sql = 'SELECT * FROM job_logs WHERE job_id = ?';
    const params = [jobId];
    if (since) { sql += ' AND ts > ?'; params.push(since); }
    sql += ' ORDER BY id ASC LIMIT ? OFFSET ?';
    params.push(limit, offset);
    return getDB().prepare(sql).all(...params);
}

module.exports = { createJob, cancelJob, getJob, listJobs, getJobLogs, jobEvents, OPERATION_PHASES };
