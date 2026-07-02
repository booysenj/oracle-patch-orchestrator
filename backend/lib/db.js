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
    try { d.exec(`ALTER TABLE jobs ADD COLUMN meta TEXT`); } catch(_) {}
    try { d.exec(`ALTER TABLE jobs ADD COLUMN env TEXT`); } catch(_) {}
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
    try { d.exec(`ALTER TABLE vms ADD COLUMN rollback_gi_home TEXT`); } catch(_) {}
    try { d.exec(`ALTER TABLE vms ADD COLUMN rollback_db_home TEXT`); } catch(_) {}
    // OS identity — populated by agent discovery; used in runtime config so script never hardcodes them
    try { d.exec(`ALTER TABLE vms ADD COLUMN oracle_user TEXT`); } catch(_) {}
    try { d.exec(`ALTER TABLE vms ADD COLUMN grid_user TEXT`); } catch(_) {}
    try { d.exec(`ALTER TABLE vms ADD COLUMN oinstall_group TEXT`); } catch(_) {}
    try { d.exec(`ALTER TABLE vms ADD COLUMN scan_name TEXT`); } catch(_) {}
    try { d.exec(`ALTER TABLE vms ADD COLUMN scan_port INTEGER`); } catch(_) {}
    try { d.exec(`ALTER TABLE vms ADD COLUMN mail_to TEXT`); } catch(_) {}
    try { d.exec(`ALTER TABLE vms ADD COLUMN mail_from TEXT`); } catch(_) {}
    // 'downloading' | 'extracting' — lets the UI distinguish "download done, now
    // unzipping" from a stalled 100%, since bytes_transferred alone can't show that.
    try { d.exec(`ALTER TABLE patch_transfers ADD COLUMN phase TEXT DEFAULT ''`); } catch(_) {}
    // Set when a job fails specifically because a required staged file was missing
    // and a [TRANSFER_RESET] fired to re-stage it in the background. Lets Job History
    // show "auto re-staging" instead of a plain Failed badge for these self-heal cases.
    try { d.exec(`ALTER TABLE jobs ADD COLUMN retry_reset_file_type TEXT`); } catch(_) {}
    // Explicit home path for gi_deinstall_home/db_deinstall_home — these target a
    // specific tracked installed_homes row, not the VM's usual NEW_GI_HOME/NEW_DB_HOME.
    try { d.exec(`ALTER TABLE jobs ADD COLUMN target_home_path TEXT`); } catch(_) {}
    // patch_reports migrations — run before CREATE TABLE so existing DBs get the columns
    try { d.exec(`ALTER TABLE patch_reports ADD COLUMN subject TEXT`); } catch(_) {}
    try { d.exec(`ALTER TABLE patch_reports ADD COLUMN html_content TEXT NOT NULL DEFAULT ''`); } catch(_) {}

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
    // installed_homes: tracks every Oracle home this app has installed, so a manually
    // deinstalled home (freeing disk space outside the app) can be detected and its
    // stale vms.new_db_home/new_gi_home reference auto-cleared instead of lingering
    // forever and misleading the patch-version picker.
    d.exec(`
        CREATE TABLE IF NOT EXISTS installed_homes (
            id                    TEXT PRIMARY KEY,
            vm_id                 TEXT NOT NULL REFERENCES vms(id),
            home_type             TEXT NOT NULL,
            home_path             TEXT NOT NULL,
            patch_version_id      TEXT,
            installed_at          TEXT DEFAULT (datetime('now')),
            installed_by_job_id   TEXT,
            last_verified_at      TEXT,
            last_verified_exists  INTEGER,
            first_seen_missing_at TEXT,
            status                TEXT DEFAULT 'active',
            cleared_at            TEXT,
            UNIQUE(vm_id, home_path)
        );
        CREATE INDEX IF NOT EXISTS idx_installed_homes_vm ON installed_homes(vm_id);
        CREATE INDEX IF NOT EXISTS idx_installed_homes_status ON installed_homes(status);
    `);
    console.log('[db] Initialised at', DB_PATH);
}

module.exports = { getDB, initDB };
