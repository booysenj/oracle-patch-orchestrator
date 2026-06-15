const Database = require('better-sqlite3');
const path = require('path');
const fs = require('fs');

const DB_PATH = process.env.DB_PATH || path.join(__dirname, '..', 'data', 'orchestrator.db');
let db;

function getDB() {
    if (!db) {
        fs.mkdirSync(path.dirname(DB_PATH), { recursive: true });
        db = new Database(DB_PATH);
        db.pragma('journal_mode = WAL');
    }
    return db;
}

function initDB() {
    const d = getDB();
    d.exec(`
        CREATE TABLE IF NOT EXISTS vms (
            id          TEXT PRIMARY KEY,
            hostname    TEXT NOT NULL,
            ip          TEXT NOT NULL,
            ssh_user    TEXT NOT NULL DEFAULT 'root',
            ssh_port    INTEGER NOT NULL DEFAULT 22,
            node_role   TEXT NOT NULL DEFAULT 'UNKNOWN',
            environment TEXT NOT NULL DEFAULT 'UAT',
            patch_target TEXT NOT NULL DEFAULT '19.26',
            script_path TEXT NOT NULL DEFAULT '/home/oracle/os-patching-auto-1.sh',
            enabled     INTEGER NOT NULL DEFAULT 1,
            created_at  TEXT DEFAULT (datetime('now')),
            updated_at  TEXT DEFAULT (datetime('now'))
        );
        CREATE TABLE IF NOT EXISTS jobs (
            id          TEXT PRIMARY KEY,
            vm_id       TEXT NOT NULL REFERENCES vms(id),
            operation   TEXT NOT NULL,
            phase       TEXT NOT NULL,
            status      TEXT NOT NULL DEFAULT 'pending',
            dry_run     INTEGER NOT NULL DEFAULT 0,
            started_at  TEXT,
            finished_at TEXT,
            exit_code   INTEGER,
            created_at  TEXT DEFAULT (datetime('now')),
            created_by  TEXT
        );
        CREATE TABLE IF NOT EXISTS job_logs (
            id      INTEGER PRIMARY KEY AUTOINCREMENT,
            job_id  TEXT NOT NULL REFERENCES jobs(id),
            ts      TEXT DEFAULT (datetime('now')),
            stream  TEXT DEFAULT 'stdout',
            line    TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_jobs_vm ON jobs(vm_id);
        CREATE INDEX IF NOT EXISTS idx_jobs_status ON jobs(status);
        CREATE INDEX IF NOT EXISTS idx_logs_job ON job_logs(job_id);
    `);
    console.log('[db] Initialised at', DB_PATH);
}

module.exports = { getDB, initDB };
