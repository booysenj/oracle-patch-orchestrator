// scheduler-jobs.js - Wires scheduler tick to create Dashboard jobs
const { getDB } = require('./db');
const { createJob } = require('./job-runner');
const { exec } = require('child_process');

const DOWNTIME_OPS = new Set([
    'gi_oh_switch','gi_rollback','db_oh_switch','db_rollback',
    'gi_upgrade_upgrade','db_upgrade_upgrade','db_upgrade_rollback',
    'cluster_stop_dbs','cluster_reboot','remote_shutdown_apps_then_db'
]);

function getSetting(db, key) {
    const row = db.prepare('SELECT value FROM app_settings WHERE key = ?').get(key);
    return row ? row.value : '';
}

function sendPreNotificationEmail(schedule, mailTo, mailFrom) {
    const vmIds = JSON.parse(schedule.vm_ids || '[]');
    const db = getDB();
    const vmNames = vmIds.map(id => {
        const v = db.prepare('SELECT hostname FROM vms WHERE id = ?').get(id);
        return v ? v.hostname : id;
    }).join(', ');

    const scheduledLocal = new Date(schedule.scheduled_at).toLocaleString('en-ZA', { timeZone: 'Africa/Johannesburg' });
    const subject = `[Downtime Alert] ${schedule.operation.toUpperCase()} on ${vmNames} scheduled in ~4 hours`;
    const body = [
        `SCHEDULED DOWNTIME NOTIFICATION`,
        ``,
        `Operation : ${schedule.operation}`,
        `Target VMs: ${vmNames}`,
        `Scheduled : ${scheduledLocal} (SAST)`,
        `Created by: ${schedule.created_by || 'unknown'}`,
        schedule.notes ? `Notes     : ${schedule.notes}` : '',
        ``,
        `This operation causes downtime. If you need to cancel it, log in to the`,
        `Patch Orchestrator and cancel the scheduled job before it fires.`,
    ].filter(l => l !== undefined).join('\n');

    const cmd = `printf '%s\n' "To: ${mailTo}" "From: ${mailFrom}" "Subject: ${subject}" "" "${body.replace(/'/g, "'\\''")}" | sendmail -t`;
    exec(cmd, (err) => {
        if (err) console.error('[SCHEDULER] Pre-notification email failed:', err.message);
        else console.log(`[SCHEDULER] Pre-notification sent to ${mailTo} for schedule "${schedule.name}"`);
    });
}

function fireScheduleAsJob(schedule, wsBroadcast) {
    const db = getDB();
    const vmIds = JSON.parse(schedule.vm_ids || '[]');
    if (!vmIds.length) {
        console.error('[SCHEDULER] Schedule "' + schedule.name + '" has no target VMs — marking failed');
        db.prepare("UPDATE scheduled_jobs SET status = 'failed', last_error = 'No target VMs configured' WHERE id = ?").run(schedule.id);
        return null;
    }

    // Parse per-VM DB name map: { vmId: ["db1", "db2"] }
    let dbNamesMap = {};
    try { if (schedule.db_unique_names_map) dbNamesMap = JSON.parse(schedule.db_unique_names_map); } catch(_) {}

    const jobIds = [];
    const errors = [];
    for (const vmId of vmIds) {
        // Determine which DB names to target for this VM
        const vmDbNames = dbNamesMap[vmId];
        const targets = (vmDbNames && vmDbNames.length)
            ? vmDbNames
            : (schedule.db_unique_name ? [schedule.db_unique_name] : ['']);

        for (const dbName of targets) {
            try {
                const result = createJob({
                    vmId,
                    operation: schedule.operation,
                    dryRun: false,
                    createdBy: 'scheduler:' + schedule.name,
                    patchVersionId: schedule.patch_version_id || '',
                    dbUniqueName: dbName
                });
                jobIds.push(result.jobId);
                console.log('[SCHEDULER] Schedule "' + schedule.name + '" -> Job ' + result.jobId + ' queued for VM ' + vmId + (dbName ? ' db=' + dbName : ''));
            } catch (err) {
                console.error('[SCHEDULER] Failed to create job for VM ' + vmId + ' db=' + dbName + ':', err.message);
                errors.push(vmId + (dbName ? '[' + dbName + ']' : '') + ': ' + err.message);
            }
        }
    }

    if (!jobIds.length) {
        db.prepare("UPDATE scheduled_jobs SET status = 'failed', last_error = ? WHERE id = ?")
            .run(errors.join('; '), schedule.id);
        return null;
    }

    db.prepare("UPDATE scheduled_jobs SET status = 'triggered', job_id = ?, triggered_at = datetime('now'), started_at = datetime('now') WHERE id = ?")
        .run(jobIds.join(','), schedule.id);

    if (wsBroadcast) {
        wsBroadcast({ type: 'schedule-fired', scheduleId: schedule.id, scheduleName: schedule.name, jobIds, operation: schedule.operation });
    }
    return jobIds[0];
}

function checkDueSchedules(wsBroadcast) {
    const db = getDB();
    const now = new Date().toISOString();
    const due = db.prepare("SELECT * FROM scheduled_jobs WHERE status = 'PENDING' AND scheduled_at <= ?").all(now);
    if (due.length > 0) {
        console.log('[SCHEDULER] checkDueSchedules: found ' + due.length + ' due at ' + now);
    }
    for (const sched of due) {
        console.log('[SCHEDULER] Firing: "' + sched.name + '" (' + sched.operation + ') scheduled_at=' + sched.scheduled_at);
        fireScheduleAsJob(sched, wsBroadcast);
    }
    return due.length;
}

// Auto-fail jobs that have been running or queued longer than the timeout.
// Queued timeout: 30 min (agent not reachable / never picked up)
// Running timeout: 180 min — db_install / gi_install with AutoUpgrade can take 1-2 hours
function timeoutStaleJobs() {
    const db = getDB();

    // Select-then-update (rather than a bulk UPDATE) so each timed-out job gets a
    // system-stream job_logs row explaining why -- the previous bulk UPDATE left zero
    // logs for a timed-out job, identical to the silent-failure gap found and fixed
    // for the transfer-gate fast-fail path (see agent.js). Without this, a job that
    // times out here shows 'Failed' in the UI with completely empty Logs and Report
    // tabs, no indication of what actually happened.
    const stuckRunning = db.prepare(`
        SELECT id FROM jobs WHERE status = 'running' AND started_at < datetime('now', '-180 minutes')
    `).all();
    const stuckQueued = db.prepare(`
        SELECT id FROM jobs WHERE status = 'queued' AND created_at < datetime('now', '-30 minutes')
    `).all();

    const updStmt = db.prepare("UPDATE jobs SET status='failed', exit_code=-1, finished_at=datetime('now') WHERE id=?");
    const logStmt = db.prepare("INSERT INTO job_logs (job_id, stream, line) VALUES (?, 'system', ?)");

    stuckRunning.forEach((j) => {
        updStmt.run(j.id);
        logStmt.run(j.id, 'Job timed out after running for over 180 minutes with no completion signal from the agent.');
    });
    stuckQueued.forEach((j) => {
        updStmt.run(j.id);
        logStmt.run(j.id, 'Job timed out after sitting queued for over 30 minutes — the agent never picked it up, or required transfers never staged in time.');
    });

    const total = stuckRunning.length + stuckQueued.length;
    if (total > 0) {
        console.log(`[SCHEDULER] Timed out ${stuckRunning.length} running + ${stuckQueued.length} queued stale job(s)`);
    }
    return total;
}

// Send a pre-notification email ~4 hours before any scheduled downtime operation.
// Fires once per schedule (notification_sent_at guards against duplicate sends).
function checkPreDowntimeNotifications() {
    const db = getDB();
    let mailTo, mailFrom;
    try {
        mailTo   = getSetting(db, 'mail_to');
        mailFrom = getSetting(db, 'mail_from');
    } catch(_) { return; }
    if (!mailTo) return;

    // Window: scheduled_at between now+3h45m and now+4h15m
    const windowStart = new Date(Date.now() + 3 * 60 * 60 * 1000 + 45 * 60 * 1000).toISOString();
    const windowEnd   = new Date(Date.now() + 4 * 60 * 60 * 1000 + 15 * 60 * 1000).toISOString();

    let pending;
    try {
        pending = db.prepare(`
            SELECT * FROM scheduled_jobs
            WHERE status = 'PENDING'
              AND scheduled_at >= ? AND scheduled_at <= ?
              AND (notification_sent_at IS NULL OR notification_sent_at = '')
        `).all(windowStart, windowEnd);
    } catch(_) { return; }

    for (const sched of pending) {
        if (!DOWNTIME_OPS.has(sched.operation)) continue;
        sendPreNotificationEmail(sched, mailTo, mailFrom || 'noreply@patch-orchestrator');
        db.prepare("UPDATE scheduled_jobs SET notification_sent_at = datetime('now') WHERE id = ?").run(sched.id);
    }
}

// Auto-clear installed_homes rows that have been confirmed missing (deinstalled outside
// the app) for longer than the configured threshold. Opt-in: stale_home_cleanup_days
// unset/blank/0 means disabled — never auto-clear without an explicit setting.
function cleanupStaleHomes() {
    const db = getDB();
    let days;
    try { days = parseInt(getSetting(db, 'stale_home_cleanup_days'), 10); } catch(_) { return 0; }
    if (!days || days <= 0) return 0;

    let stale;
    try {
        stale = db.prepare(`
            SELECT * FROM installed_homes
            WHERE status = 'active' AND first_seen_missing_at IS NOT NULL
              AND first_seen_missing_at < datetime('now', '-' || ? || ' days')
        `).all(days);
    } catch(_) { return 0; }

    for (const home of stale) {
        db.prepare("UPDATE installed_homes SET status='cleared', cleared_at=datetime('now') WHERE id=?").run(home.id);
        // Clear the matching stale reference so the patch-version picker stops offering
        // a home that no longer exists (the bug this whole feature exists to fix).
        const field = home.home_type === 'gi' ? 'new_gi_home' : 'new_db_home';
        db.prepare(`UPDATE vms SET ${field} = '' WHERE id = ? AND ${field} = ?`).run(home.vm_id, home.home_path);
    }
    if (stale.length) console.log('[SCHEDULER] Cleared ' + stale.length + ' stale installed_homes row(s)');
    return stale.length;
}

module.exports = { fireScheduleAsJob, checkDueSchedules, timeoutStaleJobs, checkPreDowntimeNotifications, cleanupStaleHomes };
