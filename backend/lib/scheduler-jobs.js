// scheduler-jobs.js - Wires scheduler tick to create Dashboard jobs
const { getDB } = require('./db');

async function fireScheduleAsJob(schedule, wsBroadcast) {
    const db = getDB();
    const jobId = 'job-' + Date.now() + '-' + Math.random().toString(36).substr(2, 6);

    try {
        const vmIds = JSON.parse(schedule.vm_ids || '[]');

        db.prepare(`INSERT INTO jobs (id, operation, patch_version, vm_ids, exec_mode, status, notes, created_by, created_at)
                    VALUES (?, ?, ?, ?, ?, 'pending', ?, ?, datetime('now'))`).run(
            jobId,
            schedule.operation,
            schedule.patch_version || null,
            schedule.vm_ids,
            schedule.exec_mode || 'serial',
            'Triggered by schedule: ' + schedule.name,
            schedule.created_by || 'scheduler'
        );

        db.prepare("UPDATE scheduled_jobs SET status = 'triggered', job_id = ?, triggered_at = datetime('now') WHERE id = ?")
            .run(jobId, schedule.id);

        console.log('[SCHEDULER] Schedule "' + schedule.name + '" fired -> Job ' + jobId);

        if (wsBroadcast) {
            wsBroadcast({
                type: 'schedule-fired',
                scheduleId: schedule.id,
                scheduleName: schedule.name,
                jobId: jobId,
                operation: schedule.operation
            });
        }
        return jobId;
    } catch (err) {
        console.error('[SCHEDULER] Failed to fire schedule:', err.message);
        db.prepare("UPDATE scheduled_jobs SET status = 'failed' WHERE id = ?").run(schedule.id);
        return null;
    }
}

function checkDueSchedules(wsBroadcast) {
    const db = getDB();
    const now = new Date().toISOString();
    const due = db.prepare("SELECT * FROM scheduled_jobs WHERE status = 'PENDING' AND scheduled_at <= ?").all(now);
    for (const sched of due) {
        fireScheduleAsJob(sched, wsBroadcast);
    }
    return due.length;
}

// Auto-fail jobs that have been running or queued longer than the timeout.
// Queued timeout: 30 min (agent not reachable / never picked up)
// Running timeout: 120 min (script hung or agent died mid-job)
function timeoutStaleJobs() {
    const db = getDB();

    const stuckRunning = db.prepare(`
        UPDATE jobs SET status = 'failed', exit_code = -1,
            finished_at = datetime('now')
        WHERE status = 'running'
          AND started_at < datetime('now', '-30 minutes')
    `).run();

    const stuckQueued = db.prepare(`
        UPDATE jobs SET status = 'failed', exit_code = -1,
            finished_at = datetime('now')
        WHERE status = 'queued'
          AND created_at < datetime('now', '-30 minutes')
    `).run();

    const total = stuckRunning.changes + stuckQueued.changes;
    if (total > 0) {
        console.log(`[SCHEDULER] Timed out ${stuckRunning.changes} running + ${stuckQueued.changes} queued stale job(s)`);
    }
    return total;
}

module.exports = { fireScheduleAsJob, checkDueSchedules, timeoutStaleJobs };
