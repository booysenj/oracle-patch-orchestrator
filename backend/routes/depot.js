const express = require('express');
const router = express.Router();
const path = require('path');
const fs = require('fs');
const { spawn } = require('child_process');
const { v4: uuidv4 } = require('uuid');
const { getDB } = require('../lib/db');

const DEFAULT_DEPOT_BASE = path.join(__dirname, '..', '..', 'depot');

function getDepotBase() {
    try {
        const row = getDB().prepare("SELECT value FROM app_settings WHERE key='depot_base_path'").get();
        if (row && row.value && row.value.trim()) return row.value.trim();
    } catch(_) {}
    return process.env.DEPOT_PATH || DEFAULT_DEPOT_BASE;
}

// Shared base software lives here — extracted once, reused by all RU versions
function getSharedBase() { return path.join(getDepotBase(), '_shared'); }

function ensureDepotTable() {
    try {
        getDB().exec(`CREATE TABLE IF NOT EXISTS depot (
            id          TEXT PRIMARY KEY,
            patch_id    TEXT,
            version     TEXT,
            status      TEXT DEFAULT 'pending',
            gi_status   TEXT DEFAULT 'pending',
            db_status   TEXT DEFAULT 'pending',
            ru_status   TEXT DEFAULT 'pending',
            opatch_status TEXT DEFAULT 'pending',
            depot_path  TEXT,
            shared_gi_path TEXT,
            shared_db_path TEXT,
            error       TEXT,
            created_at  TEXT DEFAULT (datetime('now')),
            updated_at  TEXT DEFAULT (datetime('now'))
        )`);
        try { getDB().exec(`ALTER TABLE depot ADD COLUMN shared_gi_path TEXT`); } catch(_) {}
        try { getDB().exec(`ALTER TABLE depot ADD COLUMN shared_db_path TEXT`); } catch(_) {}
    } catch(_) {}
}

function depotUpdate(patch_id, fields) {
    try {
        const db = getDB();
        const sets = Object.keys(fields).map(k => k + '=?').concat("updated_at=datetime('now')").join(',');
        db.prepare(`UPDATE depot SET ${sets} WHERE patch_id=?`).run(...Object.values(fields), patch_id);
    } catch(_) {}
}

// Returns a stable directory name derived from the zip filename (without extension)
// e.g. /backup/oracle_install/db/V982063-01.zip → "V982063-01"
function zipKey(zipPath) {
    return path.basename(zipPath, '.zip');
}

const MAX_EXTRACT_RETRIES = 3;

// Run unzip with auto-retry: on failure, wipe the partial destDir and retry.
// Returns true on success, false after all retries exhausted.
function unzipWithRetry(zipPath, destDir, attempt) {
    return new Promise((resolve) => {
        const proc = spawn('unzip', ['-o', '-q', zipPath, '-d', destDir]);
        proc.on('close', code => {
            if (code === 0) return resolve(true);
            console.error(`[DEPOT] unzip failed (exit ${code}) for ${zipPath}, attempt ${attempt}/${MAX_EXTRACT_RETRIES}`);
            // Wipe partial output so next attempt starts clean
            try { fs.rmSync(destDir, { recursive: true, force: true }); } catch(_) {}
            if (attempt < MAX_EXTRACT_RETRIES) {
                console.log(`[DEPOT] Retrying extraction of ${path.basename(zipPath)}...`);
                fs.mkdirSync(destDir, { recursive: true });
                unzipWithRetry(zipPath, destDir, attempt + 1).then(resolve);
            } else {
                resolve(false);
            }
        });
        proc.on('error', (e) => {
            console.error(`[DEPOT] unzip spawn error for ${zipPath}:`, e.message);
            try { fs.rmSync(destDir, { recursive: true, force: true }); } catch(_) {}
            resolve(false);
        });
    });
}

// Extract a zip to destDir, but ONLY if the sentinel file doesn't exist yet.
// sentinelFile is a file that proves the extraction is complete (e.g. runInstaller, gridSetup.sh).
// Returns: 'ready' | 'skipped' | 'failed'
async function extractZipShared(zipPath, destDir, sentinelFile) {
    if (!zipPath || !fs.existsSync(zipPath)) return 'skipped';

    // Already extracted — reuse
    if (fs.existsSync(path.join(destDir, sentinelFile))) return 'ready';

    fs.mkdirSync(destDir, { recursive: true });
    const ok = await unzipWithRetry(zipPath, destDir, 1);
    if (!ok) return 'failed';

    // Verify sentinel exists after extraction
    if (!fs.existsSync(path.join(destDir, sentinelFile))) {
        console.error(`[DEPOT] Sentinel ${sentinelFile} not found after extraction of ${zipPath} — marking failed`);
        try { fs.rmSync(destDir, { recursive: true, force: true }); } catch(_) {}
        return 'failed';
    }
    return 'ready';
}

async function extractZip(zipPath, destDir, patch_id, statusField) {
    if (!zipPath || !fs.existsSync(zipPath)) {
        depotUpdate(patch_id, { [statusField]: 'skipped' });
        return true;
    }
    fs.mkdirSync(destDir, { recursive: true });
    depotUpdate(patch_id, { [statusField]: 'extracting' });
    const ok = await unzipWithRetry(zipPath, destDir, 1);
    depotUpdate(patch_id, { [statusField]: ok ? 'ready' : 'failed' });
    return ok;
}

async function runExtraction(patch, depotPath, patch_id) {
    try {
        fs.mkdirSync(depotPath, { recursive: true });
        fs.mkdirSync(getSharedBase(), { recursive: true });

        // -------------------------------------------------------
        // GI BASE: extract once into _shared/gi/<zip-name>/
        // Sentinel: gridSetup.sh (present in any GI base zip)
        // -------------------------------------------------------
        let giStatus = 'skipped';
        let sharedGiPath = null;
        if (patch.gi_base_zip && fs.existsSync(patch.gi_base_zip)) {
            const giKey = zipKey(patch.gi_base_zip);
            sharedGiPath = path.join(getSharedBase(), 'gi', giKey);
            const giAlready = fs.existsSync(path.join(sharedGiPath, 'gridSetup.sh'));
            if (!giAlready) depotUpdate(patch_id, { gi_status: 'extracting', shared_gi_path: sharedGiPath });
            giStatus = await extractZipShared(patch.gi_base_zip, sharedGiPath, 'gridSetup.sh');
            depotUpdate(patch_id, { gi_status: giStatus, shared_gi_path: sharedGiPath });
        } else {
            depotUpdate(patch_id, { gi_status: 'skipped' });
        }

        // -------------------------------------------------------
        // DB BASE: extract once into _shared/db/<zip-name>/
        // Sentinel: runInstaller (present in any DB base zip)
        // -------------------------------------------------------
        let dbStatus = 'skipped';
        let sharedDbPath = null;
        if (patch.db_base_zip && fs.existsSync(patch.db_base_zip)) {
            const dbKey = zipKey(patch.db_base_zip);
            sharedDbPath = path.join(getSharedBase(), 'db', dbKey);
            const dbAlready = fs.existsSync(path.join(sharedDbPath, 'runInstaller'));
            if (!dbAlready) depotUpdate(patch_id, { db_status: 'extracting', shared_db_path: sharedDbPath });
            dbStatus = await extractZipShared(patch.db_base_zip, sharedDbPath, 'runInstaller');
            depotUpdate(patch_id, { db_status: dbStatus, shared_db_path: sharedDbPath });
        } else {
            depotUpdate(patch_id, { db_status: 'skipped' });
        }

        // -------------------------------------------------------
        // RU: version-specific — always extract fresh per version
        // -------------------------------------------------------
        let ruZip = null;
        const ruRoot = patch.patch_search_root || '';
        if (ruRoot && fs.existsSync(ruRoot)) {
            const stat = fs.statSync(ruRoot);
            const scanDir = stat.isDirectory() ? ruRoot : path.dirname(ruRoot);
            const zips = fs.readdirSync(scanDir)
                .filter(f => f.endsWith('.zip') && !/^p688088/i.test(f) && !/^p\d+_190000_/i.test(f))
                .map(f => ({ f, size: fs.statSync(path.join(scanDir, f)).size }))
                .sort((a, b) => b.size - a.size);
            if (zips.length) ruZip = path.join(scanDir, zips[0].f);
        }
        await extractZip(ruZip, path.join(depotPath, 'ru'), patch_id, 'ru_status');

        // -------------------------------------------------------
        // OPatch: version-specific (each RU ships its own OPatch)
        // -------------------------------------------------------
        let opatchZip = patch.opatch_zip || null;
        if (!opatchZip && ruRoot && fs.existsSync(ruRoot)) {
            const scanDir = fs.statSync(ruRoot).isDirectory() ? ruRoot : path.dirname(ruRoot);
            const op = fs.readdirSync(scanDir).find(f => /^p688088/i.test(f) && f.endsWith('.zip'));
            if (op) opatchZip = path.join(scanDir, op);
        }
        await extractZip(opatchZip, path.join(depotPath, 'opatch'), patch_id, 'opatch_status');

        const row = getDB().prepare('SELECT * FROM depot WHERE patch_id=?').get(patch_id);
        const statuses = [row.gi_status, row.db_status, row.ru_status, row.opatch_status];
        const overall = statuses.some(s => s === 'failed') ? 'partial'
                      : statuses.every(s => s === 'ready' || s === 'skipped') ? 'ready' : 'partial';
        depotUpdate(patch_id, { status: overall });
    } catch(e) {
        depotUpdate(patch_id, { status: 'failed', error: String(e) });
    }
}

// GET /api/depot
router.get('/', (req, res) => {
    ensureDepotTable();
    const rows = getDB().prepare(`
        SELECT d.*, p.version as patch_version, p.description, p.gi_base_zip, p.db_base_zip
        FROM depot d LEFT JOIN patch_versions p ON d.patch_id = p.id
        ORDER BY d.created_at DESC
    `).all();
    res.json(rows);
});

// POST /api/depot/extract  { patch_id }
router.post('/extract', (req, res) => {
    ensureDepotTable();
    const db = getDB();
    const { patch_id } = req.body || {};
    if (!patch_id) return res.status(400).json({ error: 'patch_id required' });
    const patch = db.prepare('SELECT * FROM patch_versions WHERE id=?').get(patch_id);
    if (!patch) return res.status(404).json({ error: 'Patch not found' });

    const existing = db.prepare('SELECT * FROM depot WHERE patch_id=?').get(patch_id);
    if (existing && existing.status === 'extracting') {
        return res.json({ id: existing.id, status: 'extracting' });
    }

    const depotPath = path.join(getDepotBase(), patch.version || patch_id);
    if (existing) {
        // Re-extract: only reset RU + OPatch (version-specific).
        // GI + DB base are shared across versions — keep their status unless the shared dir is gone.
        const giGone = existing.shared_gi_path && !fs.existsSync(path.join(existing.shared_gi_path, 'gridSetup.sh'));
        const dbGone = existing.shared_db_path && !fs.existsSync(path.join(existing.shared_db_path, 'runInstaller'));
        db.prepare(`UPDATE depot SET
            status='extracting',
            ${giGone ? "gi_status='pending'," : ''}
            ${dbGone ? "db_status='pending'," : ''}
            ru_status='pending',
            opatch_status='pending',
            error=NULL,
            depot_path=?,
            updated_at=datetime('now')
            WHERE patch_id=?`).run(depotPath, patch_id);
        setImmediate(() => runExtraction(patch, depotPath, patch_id));
        return res.json({ id: existing.id, status: 'extracting', depot_path: depotPath, note: 'GI/DB base reused from shared depot' });
    }

    const id = uuidv4();
    db.prepare("INSERT INTO depot (id,patch_id,version,status,depot_path) VALUES (?,?,?,?,?)")
      .run(id, patch_id, patch.version, 'extracting', depotPath);
    setImmediate(() => runExtraction(patch, depotPath, patch_id));
    res.json({ id, status: 'extracting', depot_path: depotPath });
});

// GET /api/depot/:patchId/status
router.get('/:patchId/status', (req, res) => {
    ensureDepotTable();
    const row = getDB().prepare('SELECT * FROM depot WHERE patch_id=? OR id=?').get(req.params.patchId, req.params.patchId);
    if (!row) return res.status(404).json({ error: 'Not found' });
    res.json(row);
});

// DELETE /api/depot/:patchId
// Note: only deletes the per-version content (RU + OPatch). Shared GI/DB base is NOT deleted
// since other patch versions reference the same extraction.
router.delete('/:patchId', (req, res) => {
    ensureDepotTable();
    const db = getDB();
    const row = db.prepare('SELECT * FROM depot WHERE patch_id=? OR id=?').get(req.params.patchId, req.params.patchId);
    if (!row) return res.status(404).json({ error: 'Not found' });
    if (row.depot_path && fs.existsSync(row.depot_path)) {
        try { fs.rmSync(row.depot_path, { recursive: true, force: true }); } catch(e) {}
    }
    db.prepare('DELETE FROM depot WHERE id=?').run(row.id);
    res.json({ ok: true, note: 'Shared GI/DB base preserved in _shared/ — use Re-extract on all versions to clear' });
});

// GET /api/depot/:patchId/tar/:type  — stream tar of depot subdirectory to agent
// type: gi | db | ru | opatch
// For gi and db, serves from the shared extraction if available
router.get('/:patchId/tar/:type', (req, res) => {
    ensureDepotTable();
    const row = getDB().prepare('SELECT * FROM depot WHERE patch_id=? OR id=?').get(req.params.patchId, req.params.patchId);
    if (!row) return res.status(404).json({ error: 'Depot not found' });
    if (row.status !== 'ready' && row.status !== 'partial') {
        return res.status(409).json({ error: 'Depot not ready: ' + row.status });
    }

    const type = req.params.type;
    let subDir;
    if (type === 'gi' && row.shared_gi_path && fs.existsSync(row.shared_gi_path)) {
        subDir = row.shared_gi_path;
    } else if (type === 'db' && row.shared_db_path && fs.existsSync(row.shared_db_path)) {
        subDir = row.shared_db_path;
    } else {
        subDir = path.join(row.depot_path, type);
    }

    if (!fs.existsSync(subDir)) return res.status(404).json({ error: 'Depot component not found: ' + type });

    const stat = fs.statSync(subDir);
    if (!stat.isDirectory()) return res.status(400).json({ error: 'Not a directory' });

    res.setHeader('Content-Type', 'application/x-tar');
    res.setHeader('X-Transfer-Type', 'tar');
    res.setHeader('X-Depot-Type', type);

    const tar = spawn('tar', ['-C', subDir, '-cf', '-', '.']);
    tar.stdout.pipe(res);
    tar.on('error', (e) => { if (!res.headersSent) res.status(500).json({ error: String(e) }); });
    req.on('close', () => tar.kill());
});

module.exports = router;
