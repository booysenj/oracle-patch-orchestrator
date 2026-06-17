const { getDB } = require('./db');

function initAuditTable() {
    getDB().exec(`
        CREATE TABLE IF NOT EXISTS audit_log (
            id         INTEGER PRIMARY KEY AUTOINCREMENT,
            ts         TEXT DEFAULT (datetime('now')),
            username   TEXT NOT NULL,
            action     TEXT NOT NULL,
            vm_id      TEXT,
            job_id     TEXT,
            details    TEXT,
            ip_address TEXT
        );
        CREATE INDEX IF NOT EXISTS idx_audit_ts ON audit_log(ts);
    `);
}

function logAudit({ username, action, vmId, jobId, details, ipAddress }) {
    getDB().prepare(
        `INSERT INTO audit_log (username, action, vm_id, job_id, details, ip_address)
         VALUES (?, ?, ?, ?, ?, ?)`
    ).run(username, action, vmId || null, jobId || null, details || null, ipAddress || null);
}

function getAuditLog({ limit = 100, vmId, username } = {}) {
    let sql = `SELECT a.*, v.hostname FROM audit_log a
               LEFT JOIN vms v ON a.vm_id = v.id WHERE 1=1`;
    const params = [];
    if (vmId) { sql += ' AND a.vm_id = ?'; params.push(vmId); }
    if (username) { sql += ' AND a.username = ?'; params.push(username); }
    sql += ' ORDER BY a.ts DESC LIMIT ?';
    params.push(limit);
    return getDB().prepare(sql).all(...params);
}

module.exports = { initAuditTable, logAudit, getAuditLog };
