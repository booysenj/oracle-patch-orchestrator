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

module.exports = { fireScheduleAsJob, checkDueSchedules };
