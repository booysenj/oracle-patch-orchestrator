const { getDB } = require('./db');

const PREREQUISITES = {
    gi_install:             { requires: 'gi_precheck',          msg: 'Run GI Precheck first' },
    gi_switch:              { requires: 'gi_install',           msg: 'Run GI Install first' },
    gi_rollback:            { requires: 'gi_switch',            msg: 'Only makes sense after GI Switch' },
    db_install:             { requires: 'db_precheck',          msg: 'Run DB Precheck first' },
    db_switch:              { requires: 'db_install',           msg: 'Run DB Install first' },
    db_rollback:            { requires: 'db_switch',            msg: 'Only makes sense after DB Switch' },
    gi_upgrade_install:     { requires: 'gi_upgrade_precheck',  msg: 'Run GI Upgrade Precheck first' },
    gi_upgrade_upgrade:     { requires: 'gi_upgrade_install',   msg: 'Run GI Upgrade Install first' },
    db_upgrade_install:     { requires: 'db_upgrade_precheck',  msg: 'Run DB Upgrade Precheck first' },
    db_upgrade_upgrade:     { requires: 'db_upgrade_install',   msg: 'Run DB Upgrade Install first' },
    cluster_reboot:         { requires: 'cluster_precheck',     msg: 'Run Cluster Precheck first' },
};

const DOWNTIME_OPS = new Set([
    'gi_switch', 'gi_rollback',
    'db_switch', 'db_rollback',
    'gi_upgrade_upgrade',
    'db_upgrade_upgrade', 'db_upgrade_rollback',
    'cluster_stop_dbs', 'cluster_reboot',
    'remote_shutdown_apps_then_db',
]);

const ROLLBACK_MAP = {
    gi_switch:  'gi_rollback',
    db_switch:  'db_rollback',
};

function runPreflightChecks(vmId, operation) {
    const db = getDB();
    const warnings = [];

    const prereq = PREREQUISITES[operation];
    if (prereq) {
        const lastPrereq = db.prepare(
            `SELECT id, status, finished_at FROM jobs
             WHERE vm_id = ? AND operation = ? AND status = 'success'
             ORDER BY finished_at DESC LIMIT 1`
        ).get(vmId, prereq.requires);

        if (!lastPrereq) {
            warnings.push({
                type: 'prerequisite_missing',
                message: prereq.msg,
                requiredOp: prereq.requires,
                severity: 'warning'
            });
        }
    }

    const lastFailure = db.prepare(
        `SELECT id, finished_at, exit_code FROM jobs
         WHERE vm_id = ? AND operation = ? AND status = 'failed'
         ORDER BY finished_at DESC LIMIT 1`
    ).get(vmId, operation);

    if (lastFailure) {
        const failedAt = new Date(lastFailure.finished_at);
        const hoursSince = (Date.now() - failedAt.getTime()) / (1000 * 60 * 60);
        if (hoursSince < 24) {
            warnings.push({
                type: 'recent_failure',
                message: `This operation failed ${Math.round(hoursSince)}h ago (exit code ${lastFailure.exit_code}). Review logs before retrying.`,
                jobId: lastFailure.id,
                severity: 'warning'
            });
        }
    }

    const running = db.prepare(
        `SELECT id, operation, created_by, started_at
         FROM jobs WHERE vm_id = ? AND status = 'running'`
    ).get(vmId);

    return {
        canProceed: true,
        causesDowntime: DOWNTIME_OPS.has(operation),
        rollbackAvailable: ROLLBACK_MAP[operation] || null,
        vmLocked: !!running,
        lockDetails: running || null,
        warnings,
    };
}

module.exports = { runPreflightChecks, DOWNTIME_OPS, ROLLBACK_MAP };
