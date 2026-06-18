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
            id              TEXT PRIMARY KEY,
            hostname        TEXT NOT NULL,
            ip              TEXT NOT NULL,
            ssh_user        TEXT NOT NULL DEFAULT 'root',
            ssh_port        INTEGER NOT NULL DEFAULT 22,
            node_role       TEXT NOT NULL DEFAULT 'UNKNOWN',
            environment     TEXT NOT NULL DEFAULT 'UAT',
            patch_target    TEXT NOT NULL DEFAULT '19.26',
            script_path     TEXT NOT NULL DEFAULT '/home/oracle/os-patching-auto-1.sh',
            execution_mode  TEXT NOT NULL DEFAULT 'agent',
            agent_last_seen TEXT,
            enabled         INTEGER NOT NULL DEFAULT 1,
            created_at      TEXT DEFAULT (datetime('now')),
            updated_at      TEXT DEFAULT (datetime('now'))
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
    // Migrate existing DBs — safe to run repeatedly (SQLite ignores duplicate column errors)
    try { d.exec(`ALTER TABLE vms ADD COLUMN execution_mode TEXT NOT NULL DEFAULT 'agent'`); } catch(_) {}
    try { d.exec(`ALTER TABLE vms ADD COLUMN agent_last_seen TEXT`); } catch(_) {}
    try { d.exec(`ALTER TABLE jobs ADD COLUMN db_unique_name TEXT`); } catch(_) {}
    try { d.exec(`ALTER TABLE jobs ADD COLUMN script_hash TEXT`); } catch(_) {}
    try { d.exec(`ALTER TABLE vms ADD COLUMN stage_path TEXT`); } catch(_) {}
    try { d.exec(`CREATE UNIQUE INDEX IF NOT EXISTS idx_patch_versions_unique ON patch_versions(version, patch_type)`); } catch(_) {}
    // VM discovery columns — auto-populated by agent on each poll
    try { d.exec(`ALTER TABLE vms ADD COLUMN db_unique_name TEXT`); } catch(_) {}
    try { d.exec(`ALTER TABLE vms ADD COLUMN database_role TEXT`); } catch(_) {}
    try { d.exec(`ALTER TABLE vms ADD COLUMN cluster_name TEXT`); } catch(_) {}
    try { d.exec(`ALTER TABLE vms ADD COLUMN mounts_json TEXT`); } catch(_) {}
    try { d.exec(`ALTER TABLE vms ADD COLUMN last_discovery_at TEXT`); } catch(_) {}
    try { d.exec(`ALTER TABLE vms ADD COLUMN preferred_staging_mount TEXT`); } catch(_) {}
    try { d.exec(`ALTER TABLE vms ADD COLUMN static_json TEXT`); } catch(_) {}
    try { d.exec(`ALTER TABLE vms ADD COLUMN dynamic_json TEXT`); } catch(_) {}
    // Populated by [DISCOVERY_JSON] lines emitted during precheck
    try { d.exec(`ALTER TABLE vms ADD COLUMN switchover_status TEXT`); } catch(_) {}
    try { d.exec(`ALTER TABLE vms ADD COLUMN cluster_type TEXT`); } catch(_) {}
    try { d.exec(`ALTER TABLE vms ADD COLUMN db_version TEXT`); } catch(_) {}
    try { d.exec(`ALTER TABLE vms ADD COLUMN crs_version TEXT`); } catch(_) {}
    try { d.exec(`ALTER TABLE vms ADD COLUMN nodes_json TEXT`); } catch(_) {}
    try { d.exec(`ALTER TABLE vms ADD COLUMN current_db_home TEXT`); } catch(_) {}
    try { d.exec(`ALTER TABLE vms ADD COLUMN mail_to TEXT`); } catch(_) {}
    try { d.exec(`ALTER TABLE vms ADD COLUMN mail_from TEXT`); } catch(_) {}
    // patch_reports: stores full HTML reports emitted by the shell script via [HTML_REPORT] log lines
    d.exec(`
        CREATE TABLE IF NOT EXISTS patch_reports (
            id          TEXT PRIMARY KEY,
            job_id      TEXT,
            hostname    TEXT,
            operation   TEXT,
            subject     TEXT,
            result      TEXT DEFAULT 'unknown',
            html_content TEXT NOT NULL,
            created_at  TEXT DEFAULT (datetime('now'))
        );
        CREATE INDEX IF NOT EXISTS idx_reports_job ON patch_reports(job_id);
        CREATE INDEX IF NOT EXISTS idx_reports_host ON patch_reports(hostname);
    `);
    // discoveries: stores structured JSON emitted by [DISCOVERY_JSON] log lines
    d.exec(`
        CREATE TABLE IF NOT EXISTS discoveries (
            id          TEXT PRIMARY KEY,
            job_id      TEXT,
            hostname    TEXT,
            type        TEXT,
            payload     TEXT NOT NULL,
            created_at  TEXT DEFAULT (datetime('now'))
        );
        CREATE INDEX IF NOT EXISTS idx_discoveries_job  ON discoveries(job_id);
        CREATE INDEX IF NOT EXISTS idx_discoveries_host ON discoveries(hostname);
        CREATE INDEX IF NOT EXISTS idx_discoveries_type ON discoveries(type);
    `);
    console.log('[db] Initialised at', DB_PATH);
}

module.exports = { getDB, initDB };
