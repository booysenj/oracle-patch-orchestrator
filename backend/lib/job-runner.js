const { v4: uuidv4 } = require('uuid');
const { getDB } = require('./db');
const sshManager = require('./ssh-manager');
const EventEmitter = require('events');
const jobEvents = new EventEmitter();
jobEvents.setMaxListeners(100);

// Maps UI operation names to the exact phase args the shell script expects
const OPERATION_PHASES = {
    gi_precheck: 'gi_precheck', gi_install: 'gi_install', gi_switch: 'gi_switch',
    gi_switch_scheduled: 'gi_switch_scheduled', gi_rollback: 'gi_rollback',
    db_precheck: 'db_precheck', db_install: 'db_install', db_switch: 'db_switch',
    db_switch_scheduled: 'db_switch_scheduled', db_rollback: 'db_rollback',
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

function createJob({ vmId, operation, dryRun = false, verbose = false, applyOjvm = false, createdBy = 'system', dbUniqueName = '' }) {
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

    // Agent mode: insert as 'queued' — the Python agent polls and picks it up
    if ((vm.execution_mode || 'agent') === 'agent') {
        db.prepare(
            `INSERT INTO jobs (id, vm_id, operation, phase, status, dry_run, verbose, apply_ojvm, created_by, db_unique_name)
             VALUES (?, ?, ?, ?, 'queued', ?, ?, ?, ?, ?)`
        ).run(jobId, vmId, operation, phase, dryRun ? 1 : 0, verbose ? 1 : 0, applyOjvm ? 1 : 0, createdBy, dbUniqueName || '');
        return { jobId, vmId, operation, phase, dryRun, verbose, applyOjvm, mode: 'agent' };
    }

    // SSH mode: execute immediately via SSH (legacy / direct-network environments)
    db.prepare(
        `INSERT INTO jobs (id, vm_id, operation, phase, status, dry_run, verbose, apply_ojvm, created_by, db_unique_name)
         VALUES (?, ?, ?, ?, 'pending', ?, ?, ?, ?, ?)`
    ).run(jobId, vmId, operation, phase, dryRun ? 1 : 0, verbose ? 1 : 0, applyOjvm ? 1 : 0, createdBy, dbUniqueName || '');
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
