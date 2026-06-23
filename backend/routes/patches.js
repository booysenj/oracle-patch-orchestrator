const express = require('express');
const { executeApiTransfer } = require('../lib/transfer-executor');
const { v4: uuidv4 } = require('uuid');
const { getDB } = require('../lib/db');

function initPatchTables() {
    const db = getDB();
    // Extend existing patch_versions with extra columns if missing
    const cols = db.prepare("PRAGMA table_info(patch_versions)").all().map(c => c.name);
    if (!cols.includes('patch_type'))
        db.exec("ALTER TABLE patch_versions ADD COLUMN patch_type TEXT DEFAULT 'RU'");
    if (!cols.includes('description'))
        db.exec("ALTER TABLE patch_versions ADD COLUMN description TEXT DEFAULT ''");
    if (!cols.includes('platform'))
        db.exec("ALTER TABLE patch_versions ADD COLUMN platform TEXT DEFAULT 'Linux-x86-64'");
    if (!cols.includes('release_date'))
        db.exec("ALTER TABLE patch_versions ADD COLUMN release_date TEXT");
    if (!cols.includes('file_name'))
        db.exec("ALTER TABLE patch_versions ADD COLUMN file_name TEXT DEFAULT ''");
    if (!cols.includes('file_size_bytes'))
        db.exec("ALTER TABLE patch_versions ADD COLUMN file_size_bytes INTEGER DEFAULT 0");
    if (!cols.includes('checksum_sha256'))
        db.exec("ALTER TABLE patch_versions ADD COLUMN checksum_sha256 TEXT DEFAULT ''");
    if (!cols.includes('source_url'))
        db.exec("ALTER TABLE patch_versions ADD COLUMN source_url TEXT DEFAULT ''");
    if (!cols.includes('is_downloaded'))
        db.exec("ALTER TABLE patch_versions ADD COLUMN is_downloaded INTEGER DEFAULT 0");
    if (!cols.includes('new_gi_home'))
        db.exec("ALTER TABLE patch_versions ADD COLUMN new_gi_home TEXT DEFAULT ''");
    if (!cols.includes('new_db_home'))
        db.exec("ALTER TABLE patch_versions ADD COLUMN new_db_home TEXT DEFAULT ''");
    if (!cols.includes('supersedes'))
        db.exec("ALTER TABLE patch_versions ADD COLUMN supersedes TEXT DEFAULT '[]'");
    if (!cols.includes('prerequisites'))
        db.exec("ALTER TABLE patch_versions ADD COLUMN prerequisites TEXT DEFAULT '{}'");
    if (!cols.includes('updated_at'))
        db.exec("ALTER TABLE patch_versions ADD COLUMN updated_at TEXT DEFAULT (datetime('now'))");
    if (!cols.includes('ojvm_zip'))
        db.exec("ALTER TABLE patch_versions ADD COLUMN ojvm_zip TEXT DEFAULT ''");

    // Migrate patch_transfers if it already exists
    try {
        const tcols = db.prepare("PRAGMA table_info(patch_transfers)").all().map(c => c.name);
        if (!tcols.includes('file_name'))
            db.exec("ALTER TABLE patch_transfers ADD COLUMN file_name TEXT DEFAULT ''");
    } catch(_) {}

    // Create transfers table
    db.exec(`
        CREATE TABLE IF NOT EXISTS patch_transfers (
            id              TEXT PRIMARY KEY,
            run_id          TEXT,
            patch_id        TEXT NOT NULL REFERENCES patch_versions(id),
            source_path     TEXT DEFAULT '',
            file_name       TEXT DEFAULT '',
            target_host     TEXT NOT NULL,
            target_stage_path TEXT DEFAULT '',
            status          TEXT NOT NULL DEFAULT 'PENDING',
            bytes_transferred INTEGER DEFAULT 0,
            total_bytes     INTEGER DEFAULT 0,
            transfer_method TEXT DEFAULT 'SCP',
            checksum_verified INTEGER DEFAULT 0,
            started_at      TEXT,
            completed_at    TEXT,
            error_message   TEXT DEFAULT '',
            retry_count     INTEGER DEFAULT 0,
            created_at      TEXT DEFAULT (datetime('now'))
        );
        CREATE INDEX IF NOT EXISTS idx_transfer_patch ON patch_transfers(patch_id);
        CREATE INDEX IF NOT EXISTS idx_transfer_status ON patch_transfers(status);
        CREATE INDEX IF NOT EXISTS idx_transfer_run ON patch_transfers(run_id);
        CREATE INDEX IF NOT EXISTS idx_transfer_host ON patch_transfers(target_host);
    `);
    console.log('[db] Patch catalog extensions + transfer tables initialised');
    _autoPopulateOjvmZip(db);
    _resumePendingTransfers(db);
}

function _resumePendingTransfers(db) {
    // Any transfer stuck in TRANSFERRING was killed by a server restart — reset to PENDING so the user can retry
    try {
        var stuck = db.prepare("UPDATE patch_transfers SET status='PENDING', bytes_transferred=0, started_at=NULL WHERE status='TRANSFERRING'").run();
        if (stuck.changes > 0) console.log('[transfer] Reset', stuck.changes, 'stuck TRANSFERRING -> PENDING on startup');
    } catch(e) {}
}

function _autoPopulateOjvmZip(db) {
    const fs = require('fs');
    const pathMod = require('path');
    // Build candidate directories: software_repo_root/ojvm first, then common fallback
    var candidates = [];
    try {
        var s = db.prepare("SELECT value FROM app_settings WHERE key='software_repo_root'").get();
        if (s && s.value) candidates.push(pathMod.join(s.value, 'ojvm'));
    } catch(e) {}
    candidates.push('/backup/patches/ojvm');
    for (var i = 0; i < candidates.length; i++) {
        var dir = candidates[i];
        try {
            if (!fs.existsSync(dir)) continue;
            var files = fs.readdirSync(dir)
                .filter(function(f) { return /^p\d+_190000.*\.zip$/i.test(f) && !/^p688088/i.test(f); })
                .sort();
            if (!files.length) continue;
            var ojvmPath = pathMod.join(dir, files[0]);
            var r = db.prepare("UPDATE patch_versions SET ojvm_zip=? WHERE ojvm_zip IS NULL OR ojvm_zip=''").run(ojvmPath);
            if (r.changes > 0)
                console.log('[db] Auto-populated ojvm_zip =', ojvmPath, 'across', r.changes, 'patch version(s)');
            break;
        } catch(e) {}
    }
}

const router = express.Router();

module.exports = function (authenticateToken) {
    initPatchTables();

    // --- PATCH CATALOG CRUD ---------------------------------------

    // GET /api/patches - list/search
    router.get('/', authenticateToken, (req, res) => {
        const db = getDB();
        let sql = 'SELECT * FROM patch_versions WHERE 1=1';
        const params = [];

        if (req.query.type) {
            if (req.query.type === 'GI_BASE') {
                sql += " AND (patch_type='GI_BASE' OR (gi_base_zip IS NOT NULL AND gi_base_zip!=''))";
            } else if (req.query.type === 'DB_BASE') {
                sql += " AND (patch_type='DB_BASE' OR (db_base_zip IS NOT NULL AND db_base_zip!=''))";
            } else if (req.query.type === 'OPATCH') {
                sql += " AND (patch_type='OPATCH' OR (opatch_zip IS NOT NULL AND opatch_zip!=''))";
            } else if (req.query.type === 'OJVM') {
                sql += " AND (patch_type='OJVM' OR (ojvm_zip IS NOT NULL AND ojvm_zip!=''))";
            } else {
                sql += ' AND patch_type = ?';
                params.push(req.query.type);
            }
        }
        if (req.query.version) {
            sql += ' AND version = ?';
            params.push(req.query.version);
        }
        if (req.query.platform) {
            sql += ' AND platform = ?';
            params.push(req.query.platform);
        }
        if (req.query.is_downloaded !== undefined) {
            sql += ' AND is_downloaded = ?';
            params.push(req.query.is_downloaded === 'true' ? 1 : 0);
        }
        if (req.query.q) {
            sql += ' AND (version LIKE ? OR description LIKE ? OR file_name LIKE ? OR gi_base_zip LIKE ? OR db_base_zip LIKE ?)';
            const q = '%' + req.query.q + '%';
            params.push(q, q, q, q, q);
        }

        sql += " ORDER BY CAST(REPLACE(version, '.', '') AS INTEGER) ASC";
        try {
            const rows = db.prepare(sql).all(...params);
            const result = rows.map(r => ({
                ...r,
                is_downloaded: !!r.is_downloaded,
                supersedes: JSON.parse(r.supersedes || '[]'),
                prerequisites: JSON.parse(r.prerequisites || '{}')
            }));
            res.json(result);
        } catch (e) {
            res.status(500).json({ error: e.message });
        }
    });

    // GET /api/patches/types - distinct types for dropdown
    router.get('/types', authenticateToken, (req, res) => {
        const db = getDB();
        try {
            const types = db.prepare('SELECT DISTINCT patch_type FROM patch_versions WHERE patch_type IS NOT NULL ORDER BY patch_type').all();
            res.json(types.map(t => t.patch_type));
        } catch (e) {
            res.status(500).json({ error: e.message });
        }
    });

    // GET /api/patches/versions - distinct versions for dropdown
    router.get('/versions', authenticateToken, (req, res) => {
        const db = getDB();
        try {
            const versions = db.prepare('SELECT DISTINCT version FROM patch_versions ORDER BY version DESC').all();
            res.json(versions.map(v => v.version));
        } catch (e) {
            res.status(500).json({ error: e.message });
        }
    });

    // GET /api/patches/:id - single patch
    router.get('/:id', authenticateToken, (req, res, next) => {
        var skip = ['reports','transfers','settings','types','versions','scan','relocate','bulk'];
        if (skip.indexOf(req.params.id) >= 0) return next();
        const db = getDB();
        try {
            const row = db.prepare('SELECT * FROM patch_versions WHERE id = ?').get(req.params.id);
            if (!row) return res.status(404).json({ error: 'Patch not found' });
            row.is_downloaded = !!row.is_downloaded;
            row.supersedes = JSON.parse(row.supersedes || '[]');
            row.prerequisites = JSON.parse(row.prerequisites || '{}');
            res.json(row);
        } catch (e) {
            res.status(500).json({ error: e.message });
        }
    });

    // POST /api/patches - create patch
    router.post('/', authenticateToken, (req, res) => {
        const db = getDB();
        const id = uuidv4();
        const b = req.body;
        try {
            db.prepare(`INSERT INTO patch_versions
                (id, version, patch_type, description, platform, release_date,
                 gi_base_zip, db_base_zip, patch_search_root, ru_dir, opatch_zip, ojvm_zip,
                 file_name, file_size_bytes, checksum_sha256, source_url,
                 is_downloaded, supersedes, prerequisites)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            `).run(
                id,
                b.version || '',
                b.patch_type || 'RU',
                b.description || '',
                b.platform || 'Linux-x86-64',
                b.release_date || null,
                b.gi_base_zip || '',
                b.db_base_zip || '',
                b.patch_search_root || '',
                b.ru_dir || '',
                b.opatch_zip || '',
                b.ojvm_zip || '',
                b.file_name || '',
                b.file_size_bytes || 0,
                b.checksum_sha256 || '',
                b.source_url || '',
                b.is_downloaded ? 1 : 0,
                JSON.stringify(b.supersedes || []),
                JSON.stringify(b.prerequisites || {})
            );
            res.status(201).json({ id, message: 'Patch registered' });
        } catch (e) {
            res.status(500).json({ error: e.message });
        }
    });

    // POST /api/patches/bulk - bulk import
    router.post('/bulk', authenticateToken, (req, res) => {
        const db = getDB();
        const patches = req.body.patches;
        if (!Array.isArray(patches) || !patches.length) {
            return res.status(400).json({ error: 'patches array required' });
        }
        const insert = db.prepare(`INSERT INTO patch_versions
            (id, version, patch_type, description, platform, release_date,
             gi_base_zip, db_base_zip, patch_search_root, ru_dir, opatch_zip,
             file_name, file_size_bytes, checksum_sha256, source_url,
             is_downloaded, supersedes, prerequisites)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        `);
        let imported = 0;
        const tx = db.transaction(() => {
            for (const b of patches) {
                insert.run(
                    uuidv4(),
                    b.version || '',
                    b.patch_type || 'RU',
                    b.description || '',
                    b.platform || 'Linux-x86-64',
                    b.release_date || null,
                    b.gi_base_zip || '',
                    b.db_base_zip || '',
                    b.patch_search_root || '',
                    b.ru_dir || '',
                    b.opatch_zip || '',
                    b.file_name || '',
                    b.file_size_bytes || 0,
                    b.checksum_sha256 || '',
                    b.source_url || '',
                    b.is_downloaded ? 1 : 0,
                    JSON.stringify(b.supersedes || []),
                    JSON.stringify(b.prerequisites || {})
                );
                imported++;
            }
        });
        try {
            tx();
            res.json({ imported, message: imported + ' patches imported' });
        } catch (e) {
            res.status(500).json({ error: e.message });
        }
    });

    // PUT /api/patches/:id - update patch
    router.put('/:id', authenticateToken, (req, res) => {
        const db = getDB();
        const b = req.body;
        try {
            const existing = db.prepare('SELECT id FROM patch_versions WHERE id = ?').get(req.params.id);
            if (!existing) return res.status(404).json({ error: 'Patch not found' });

            db.prepare(`UPDATE patch_versions SET
                version=?, patch_type=?, description=?, platform=?, release_date=?,
                gi_base_zip=?, db_base_zip=?, patch_search_root=?, ru_dir=?, opatch_zip=?, ojvm_zip=?,
                file_name=?, file_size_bytes=?, checksum_sha256=?, source_url=?,
                is_downloaded=?, supersedes=?, prerequisites=?,
                updated_at=datetime('now')
                WHERE id=?
            `).run(
                b.version || '',
                b.patch_type || 'RU',
                b.description || '',
                b.platform || 'Linux-x86-64',
                b.release_date || null,
                b.gi_base_zip || '',
                b.db_base_zip || '',
                b.patch_search_root || '',
                b.ru_dir || '',
                b.opatch_zip || '',
                b.ojvm_zip || '',
                b.file_name || '',
                b.file_size_bytes || 0,
                b.checksum_sha256 || '',
                b.source_url || '',
                b.is_downloaded ? 1 : 0,
                JSON.stringify(b.supersedes || []),
                JSON.stringify(b.prerequisites || {}),
                req.params.id
            );
            res.json({ message: 'Patch updated' });
        } catch (e) {
            res.status(500).json({ error: e.message });
        }
    });

    // DELETE /api/patches/:id
    router.delete('/:id', authenticateToken, (req, res) => {
        const db = getDB();
        try {
            // Unlink any VMs pointing to this patch version
            db.prepare('UPDATE vms SET target_patch_version_id = NULL WHERE target_patch_version_id = ?').run(req.params.id);
            // Delete transfers
            db.prepare('DELETE FROM patch_transfers WHERE patch_id = ?').run(req.params.id);
            const r = db.prepare('DELETE FROM patch_versions WHERE id = ?').run(req.params.id);
            if (r.changes === 0) return res.status(404).json({ error: 'Patch not found' });
            res.json({ message: 'Patch deleted' });
        } catch (e) {
            res.status(500).json({ error: e.message });
        }
    });

    // PUT /api/patches/:id/toggle-downloaded
    router.put('/:id/toggle-downloaded', authenticateToken, (req, res) => {
        const db = getDB();
        try {
            const row = db.prepare('SELECT is_downloaded FROM patch_versions WHERE id = ?').get(req.params.id);
            if (!row) return res.status(404).json({ error: 'Patch not found' });
            const newVal = row.is_downloaded ? 0 : 1;
            db.prepare("UPDATE patch_versions SET is_downloaded=?, updated_at=datetime('now') WHERE id=?").run(newVal, req.params.id);
            res.json({ is_downloaded: !!newVal, message: newVal ? 'Marked as downloaded' : 'Marked as not downloaded' });
        } catch (e) {
            res.status(500).json({ error: e.message });
        }
    });

    // --- TRANSFER TRACKING ----------------------------------------

    // GET /api/patches/transfers/all
    router.get('/transfers/all', authenticateToken, (req, res) => {
        const db = getDB();
        let sql = `SELECT t.*, p.version as patch_version, p.patch_type, p.file_name as patch_file_name,
                          p.description as patch_description, p.gi_base_zip, p.db_base_zip
                   FROM patch_transfers t
                   LEFT JOIN patch_versions p ON t.patch_id = p.id
                   WHERE 1=1`;
        const params = [];

        if (req.query.run_id) { sql += ' AND t.run_id = ?'; params.push(req.query.run_id); }
        if (req.query.target_host) { sql += ' AND t.target_host = ?'; params.push(req.query.target_host); }
        if (req.query.status) { sql += ' AND t.status = ?'; params.push(req.query.status); }
        if (req.query.patch_id) { sql += ' AND t.patch_id = ?'; params.push(req.query.patch_id); }

        sql += ' ORDER BY t.created_at DESC';
        try {
            const rows = db.prepare(sql).all(...params);
            res.json(rows.map(r => ({
                ...r,
                checksum_verified: !!r.checksum_verified,
                progress_pct: r.total_bytes > 0 ? Math.round((r.bytes_transferred / r.total_bytes) * 100) : 0
            })));
        } catch (e) {
            res.status(500).json({ error: e.message });
        }
    });

    // POST /api/patches/transfers
    router.post('/transfers', authenticateToken, (req, res) => {
        const db = getDB();
        const id = uuidv4();
        const b = req.body;
        if (!b.patch_id || !b.target_host) {
            return res.status(400).json({ error: 'patch_id and target_host required' });
        }
        const patch = db.prepare('SELECT * FROM patch_versions WHERE id = ?').get(b.patch_id);
        if (!patch) return res.status(404).json({ error: 'Patch not found in catalog' });

        // Resolve source path based on file_type
        var sourcePath = '';
        var fileType = b.file_type || 'ru_patch';
        if (fileType === 'opatch') {
            sourcePath = patch.opatch_zip || '';
        } else if (fileType === 'gi_base') {
            sourcePath = patch.gi_base_zip || '';
        } else if (fileType === 'db_base') {
            sourcePath = patch.db_base_zip || '';
        } else if (fileType === 'ojvm') {
            sourcePath = patch.ojvm_zip || '';
        } else {
            sourcePath = patch.patch_search_root || '';
        }
        if (!sourcePath) return res.status(400).json({ error: 'No file path configured for type: ' + fileType });

        try {
            db.prepare(`INSERT INTO patch_transfers
                (id, run_id, patch_id, source_path, target_host, target_stage_path,
                 status, total_bytes, transfer_method, file_type)
                VALUES (?,?,?,?,?,?,?,?,?,?)
            `).run(
                id, b.run_id || null, b.patch_id,
                sourcePath,
                b.target_host,
                b.target_stage_path || '/grid/stage/patches',
                'PENDING',
                patch.file_size_bytes || 0,
                b.transfer_method || 'SCP',
            fileType
            );
            res.status(201).json({ id, message: "Transfer created", method: b.transfer_method || "SCP" });
            // Agent polls for PENDING transfers and pulls the file — no push needed.
        } catch (e) {
            res.status(500).json({ error: e.message });
        }
    });

    // GET /api/patches/transfers/:id
    router.get('/transfers/:id', authenticateToken, (req, res) => {
        const db = getDB();
        try {
            const row = db.prepare(`SELECT t.*, p.version as patch_version, p.patch_type, p.file_name as patch_file_name
                FROM patch_transfers t
                LEFT JOIN patch_versions p ON t.patch_id = p.id
                WHERE t.id = ?`).get(req.params.id);
            if (!row) return res.status(404).json({ error: 'Transfer not found' });
            row.checksum_verified = !!row.checksum_verified;
            row.progress_pct = row.total_bytes > 0 ? Math.round((row.bytes_transferred / row.total_bytes) * 100) : 0;
            res.json(row);
        } catch (e) {
            res.status(500).json({ error: e.message });
        }
    });

    // PUT /api/patches/transfers/:id - update status/progress
    router.put('/transfers/:id', authenticateToken, (req, res) => {
        const db = getDB();
        const b = req.body;
        try {
            const existing = db.prepare('SELECT id FROM patch_transfers WHERE id = ?').get(req.params.id);
            if (!existing) return res.status(404).json({ error: 'Transfer not found' });

            const sets = [];
            const vals = [];
            if (b.status !== undefined) { sets.push('status=?'); vals.push(b.status); }
            if (b.bytes_transferred !== undefined) { sets.push('bytes_transferred=?'); vals.push(b.bytes_transferred); }
            if (b.checksum_verified !== undefined) { sets.push('checksum_verified=?'); vals.push(b.checksum_verified ? 1 : 0); }
            if (b.error_message !== undefined) { sets.push('error_message=?'); vals.push(b.error_message); }
            if (b.status === 'TRANSFERRING') { sets.push("started_at=datetime('now')"); }
            if (b.status === 'STAGED' || b.status === 'FAILED') { sets.push("completed_at=datetime('now')"); }

            if (!sets.length) return res.status(400).json({ error: 'Nothing to update' });
            vals.push(req.params.id);
            db.prepare('UPDATE patch_transfers SET ' + sets.join(',') + ' WHERE id=?').run(...vals);
            res.json({ message: 'Transfer updated' });
        } catch (e) {
            res.status(500).json({ error: e.message });
        }
    });

    // POST /api/patches/transfers/:id/retry
    router.post('/transfers/:id/retry', authenticateToken, (req, res) => {
        const db = getDB();
        try {
            const row = db.prepare('SELECT * FROM patch_transfers WHERE id = ?').get(req.params.id);
            if (!row) return res.status(404).json({ error: 'Transfer not found' });
            if (!['FAILED','PENDING'].includes(row.status)) return res.status(400).json({ error: 'Can only retry FAILED transfers' });
            db.prepare(`UPDATE patch_transfers SET
                status='PENDING', bytes_transferred=0, checksum_verified=0,
                error_message='', started_at=NULL, completed_at=NULL,
                retry_count=retry_count+1
                WHERE id=?`).run(req.params.id);
            res.json({ message: 'Transfer queued for retry' });
            // Agent polls for PENDING transfers and pulls the file itself —
            // no need to push; just leaving it as PENDING is sufficient.
        } catch (e) {
            res.status(500).json({ error: e.message });
        }
    });

    // DELETE /api/patches/transfers/:id
    router.delete('/transfers/:id', authenticateToken, (req, res) => {
        const db = getDB();
        try {
            const r = db.prepare('DELETE FROM patch_transfers WHERE id = ?').run(req.params.id);
            if (r.changes === 0) return res.status(404).json({ error: 'Transfer not found' });
            res.json({ message: 'Transfer cancelled' });
        } catch (e) {
            res.status(500).json({ error: e.message });
        }
    });

    
    // --- APP SETTINGS ---
    (function() {
        const db = getDB();
        db.exec("CREATE TABLE IF NOT EXISTS app_settings (key TEXT PRIMARY KEY, value TEXT NOT NULL, updated_at TEXT DEFAULT (datetime('now')))");
        db.exec("CREATE TABLE IF NOT EXISTS patch_reports (id TEXT PRIMARY KEY, job_id TEXT, hostname TEXT DEFAULT '', report_type TEXT DEFAULT 'precheck', operation TEXT DEFAULT '', result TEXT DEFAULT 'UNKNOWN', content TEXT DEFAULT '', created_at TEXT DEFAULT (datetime('now')))");
        db.exec("CREATE INDEX IF NOT EXISTS idx_report_host ON patch_reports(hostname)");
        db.exec("CREATE INDEX IF NOT EXISTS idx_report_type ON patch_reports(report_type)");
    })();

    // GET /api/patches/settings/repo
    router.get('/settings/repo', authenticateToken, (req, res) => {
        const db = getDB();
        try {
            const row = db.prepare("SELECT value, updated_at FROM app_settings WHERE key = 'software_repo_root'").get();
            res.json({ software_repo_root: row ? row.value : '', updated_at: row ? row.updated_at : null });
        } catch (e) { res.status(500).json({ error: e.message }); }
    });

    // PUT /api/patches/settings/repo
    router.put('/settings/repo', authenticateToken, (req, res) => {
        const db = getDB();
        const root = (req.body.software_repo_root || '').trim();
        try {
            db.prepare("INSERT OR REPLACE INTO app_settings (key, value, updated_at) VALUES ('software_repo_root', ?, datetime('now'))").run(root);
            res.json({ message: 'Repo root set to ' + root });
        } catch (e) { res.status(500).json({ error: e.message }); }
    });

    // POST /api/patches/scan
    router.post('/scan', authenticateToken, (req, res) => {
        const fs = require('fs');
        const pathMod = require('path');
        const db = getDB();
        let root = (req.body.root_path || '').trim();
        if (!root) {
            const s = db.prepare("SELECT value FROM app_settings WHERE key = 'software_repo_root'").get();
            root = s ? s.value : '';
        }
        if (!root) {
            return res.status(400).json({ error: 'No root path provided and none configured' });
        }
        try {
            if (!fs.existsSync(root) || !fs.statSync(root).isDirectory()) {
                return res.status(400).json({ error: 'Directory not found: ' + root });
            }
        } catch (e) { return res.status(400).json({ error: 'Cannot access: ' + e.message }); }

        db.prepare("INSERT OR REPLACE INTO app_settings (key, value, updated_at) VALUES ('software_repo_root', ?, datetime('now'))").run(root);

        function walk(dir, depth) {
            if (depth > 3) return [];
            var results = [];
            try {
                var entries = fs.readdirSync(dir, { withFileTypes: true });
                for (var i = 0; i < entries.length; i++) {
                    var full = pathMod.join(dir, entries[i].name);
                    if (entries[i].isFile()) {
                        try {
                            var st = fs.statSync(full);
                            results.push({ name: entries[i].name, path: full, size: st.size, relDir: pathMod.relative(root, dir) });
                        } catch(e){}
                    } else if (entries[i].isDirectory()) {
                        results = results.concat(walk(full, depth + 1));
                    }
                }
            } catch(e){}
            return results;
        }

        // Support two layouts:
        //   Flat:  {root}/p19.30/{ru_zip, opatch}, {root}/oracle_install/{gi,db}/
        //   Split: {root}/patches/p19.30/, {root}/oracle_install/{gi,db}/  (e.g. /backup)
        //   Pure flat: all zips under {root}/p19.30/ with GI/DB base zips in same tree
        //
        // Determine effective sub-roots for patches and base software.
        var patchesRoot = root;
        var installRoot = root;
        var patchesSub = pathMod.join(root, 'patches');
        var installSub = pathMod.join(root, 'oracle_install');
        if (fs.existsSync(patchesSub) && fs.statSync(patchesSub).isDirectory()) patchesRoot = patchesSub;
        if (fs.existsSync(installSub) && fs.statSync(installSub).isDirectory()) installRoot = installSub;

        // Walk the patches subtree (RU patches, OPatch, possibly GI/DB base in flat layout)
        var patchFiles = walk(patchesRoot, 0);
        // Also walk the install subtree when it's separate from patchesRoot
        var installFiles = (installRoot !== patchesRoot) ? walk(installRoot, 0) : [];
        var allFiles = patchFiles.concat(installFiles);
        var zips = allFiles.filter(function(f) { return /\.(zip|ZIP)$/i.test(f.name); });

        function classify(f) {
            var n = f.name;
            var sz = f.size || 0;
            if (/^V982068/i.test(n)) return Object.assign({}, f, { type: 'GI_BASE', field: 'gi_base_zip' });
            if (/^V982063/i.test(n)) return Object.assign({}, f, { type: 'DB_BASE', field: 'db_base_zip' });
            // OPatch: patch number 6880880 (may appear as p6880880 or p688088 with one digit missing in some releases)
            if (/^p688088\d?_.*\.zip$/i.test(n)) return Object.assign({}, f, { type: 'OPATCH', field: 'opatch_zip' });
            // OJVM: p*_190000_* but small (< 500 MB) — RU patches are always 1 GB+
            if (/^p\d+_190000_.*\.zip$/i.test(n) && sz > 0 && sz < 500 * 1024 * 1024) {
                return Object.assign({}, f, { type: 'OJVM', field: 'ojvm_zip' });
            }
            if (/^p\d+.*\.zip$/i.test(n)) return Object.assign({}, f, { type: 'RU', field: 'ru' });
            return Object.assign({}, f, { type: 'UNKNOWN', field: null });
        }

        var classified = zips.map(classify);
        var groups = {};
        // Collect shared base zips found in oracle_install/ (no version in their path)
        var sharedGiZip = '';
        var sharedDbZip = '';

        for (var c = 0; c < classified.length; c++) {
            var fl = classified[c];
            // Is this file from the oracle_install subtree? If so, treat as shared base.
            var isInstallTree = (installRoot !== patchesRoot) &&
                fl.path.startsWith(installRoot + pathMod.sep);
            if (isInstallTree) {
                if (fl.field === 'gi_base_zip' && !sharedGiZip) sharedGiZip = fl.path;
                if (fl.field === 'db_base_zip' && !sharedDbZip) sharedDbZip = fl.path;
                // OPatch from install tree still treated as shared below
                continue;
            }

            var version = '_root';
            var parts = fl.relDir.split(pathMod.sep);
            for (var p = 0; p < parts.length; p++) {
                var m = parts[p].match(/^p?(\d+\.\d+)/);
                if (m) { version = m[1]; break; }
            }
            if (!groups[version]) {
                groups[version] = { version: version, files: [], total_size: 0,
                    gi_base_zip: '', db_base_zip: '', opatch_zip: '', ojvm_zip: '', patch_search_root: '', ru_dir: '' };
            }
            groups[version].files.push({ name: fl.name, type: fl.type, path: fl.path, size: fl.size });
            groups[version].total_size += fl.size;
            if (fl.field === 'gi_base_zip') groups[version].gi_base_zip = fl.path;
            if (fl.field === 'db_base_zip') groups[version].db_base_zip = fl.path;
            if (fl.field === 'opatch_zip') groups[version].opatch_zip = fl.path;
            if (fl.field === 'ojvm_zip') groups[version].ojvm_zip = fl.path;
        }

        // Backfill shared GI/DB base zips into every version group that doesn't have one
        Object.keys(groups).forEach(function(version) {
            if (version === '_root') return;
            if (!groups[version].gi_base_zip && sharedGiZip) groups[version].gi_base_zip = sharedGiZip;
            if (!groups[version].db_base_zip && sharedDbZip) groups[version].db_base_zip = sharedDbZip;
        });

        // Locate patch_search_root and ru_dir for each version group.
        // Check both patchesRoot/p{ver} and patchesRoot/{ver}.
        Object.keys(groups).forEach(function(version) {
            if (version === '_root') return;
            var searchRoots = [
                pathMod.join(patchesRoot, 'p' + version),
                pathMod.join(patchesRoot, version),
                pathMod.join(root, 'p' + version),
                pathMod.join(root, version)
            ];
            for (var s = 0; s < searchRoots.length; s++) {
                if (fs.existsSync(searchRoots[s])) {
                    groups[version].patch_search_root = searchRoots[s];
                    try {
                        var subdirs = fs.readdirSync(searchRoots[s], { withFileTypes: true })
                            .filter(function(e) { return e.isDirectory() && /^\d+$/.test(e.name); });
                        if (subdirs.length > 0) groups[version].ru_dir = pathMod.join(searchRoots[s], subdirs[0].name);
                    } catch(e){}
                    break;
                }
            }
        });

        // Detect shared OJVM zip — check {root}/ojvm, {patchesRoot}/ojvm
        var sharedOjvmZip = '';
        var ojvmCandidates = [pathMod.join(root, 'ojvm'), pathMod.join(patchesRoot, 'ojvm')];
        for (var oi = 0; oi < ojvmCandidates.length; oi++) {
            var ojvmSubdir = ojvmCandidates[oi];
            try {
                if (fs.existsSync(ojvmSubdir)) {
                    var ojvmFiles = fs.readdirSync(ojvmSubdir)
                        .filter(function(f) { return /^p\d+_190000.*\.zip$/i.test(f) && !/^p6880880/i.test(f); })
                        .sort();
                    if (ojvmFiles.length) { sharedOjvmZip = pathMod.join(ojvmSubdir, ojvmFiles[0]); break; }
                }
            } catch(e) {}
        }

        var imported = 0;
        var upsertStmt = db.prepare(
            "INSERT OR REPLACE INTO patch_versions (id, version, patch_type, description, gi_base_zip, db_base_zip, opatch_zip, ojvm_zip, patch_search_root, ru_dir, file_size_bytes, is_downloaded) " +
            "VALUES (coalesce((SELECT id FROM patch_versions WHERE version = ?), lower(hex(randomblob(16)))), ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1)"
        );

        Object.keys(groups).forEach(function(version) {
            if (version === '_root') return;
            var g = groups[version];
            // If the patch has RU content (patch_search_root), it's an RU even if it also
            // has base zips backfilled from oracle_install/ (those are shared, not version-specific)
            var ptype = 'RU';
            var hasOwnGi = g.gi_base_zip && g.gi_base_zip !== sharedGiZip;
            var hasOwnDb = g.db_base_zip && g.db_base_zip !== sharedDbZip;
            if (!g.patch_search_root && hasOwnGi) ptype = 'GI_BASE';
            else if (!g.patch_search_root && hasOwnDb) ptype = 'DB_BASE';
            // Prefer per-version OJVM found inline; fall back to shared ojvm/ subdirectory
            var ojvmForVersion = g.ojvm_zip || sharedOjvmZip;
            upsertStmt.run(version, version, ptype, 'Scanned from ' + root,
                g.gi_base_zip, g.db_base_zip, g.opatch_zip, ojvmForVersion,
                g.patch_search_root, g.ru_dir, g.total_size);
            imported++;
        });

        // Backfill any already-registered versions missing ojvm_zip
        if (sharedOjvmZip) {
            db.prepare("UPDATE patch_versions SET ojvm_zip=? WHERE ojvm_zip IS NULL OR ojvm_zip=''").run(sharedOjvmZip);
        }

        res.json({
            message: 'Scan complete: ' + imported + ' patch version(s) imported',
            total_files_found: allFiles.length,
            zip_files_found: zips.length,
            versions_imported: imported,
            classified: classified.map(function(f) { return { name: f.name, type: f.type, size: f.size }; })
        });
    });

    router.post('/relocate', authenticateToken, (req, res) => {
        const db = getDB();
        var oldRoot = (req.body.old_root || '').trim();
        var newRoot = (req.body.new_root || '').trim();
        var pathCols = ['gi_base_zip','db_base_zip','patch_search_root','ru_dir','opatch_zip'];
        var affected = 0;
        var tx = db.transaction(function() {
            for (var i = 0; i < pathCols.length; i++) {
                var col = pathCols[i];
                var r = db.prepare('UPDATE patch_versions SET ' + col + ' = REPLACE(' + col + ', ?, ?), updated_at=datetime("now") WHERE ' + col + ' LIKE ?').run(oldRoot, newRoot, oldRoot + '%');
                affected += r.changes;
            }
            var oldN = oldRoot.slice(0,-1);
            var newN = newRoot.slice(0,-1);
            for (var i = 0; i < pathCols.length; i++) {
                var col = pathCols[i];
                db.prepare('UPDATE patch_versions SET ' + col + ' = REPLACE(' + col + ', ?, ?), updated_at=datetime("now") WHERE ' + col + ' LIKE ? AND ' + col + ' NOT LIKE ?').run(oldN, newN, oldN + '%', newRoot + '%');
            }
            db.prepare('UPDATE patch_transfers SET source_path = REPLACE(source_path, ?, ?) WHERE source_path LIKE ?').run(oldRoot, newRoot, oldRoot + '%');
            db.prepare("INSERT OR REPLACE INTO app_settings (key, value, updated_at) VALUES ('software_repo_root', ?, datetime('now'))").run(newRoot);
        });
        try { tx(); res.json({ affected: affected, message: 'Relocated ' + affected + ' path(s) from ' + oldRoot + ' to ' + newRoot }); }
        catch (e) { res.status(500).json({ error: e.message }); }
    });

    // GET /api/patches/reports
    router.get('/reports', authenticateToken, (req, res) => {
        const db = getDB();
        var sql = 'SELECT * FROM patch_reports WHERE 1=1';
        var params = [];
        if (req.query.report_type) { sql += ' AND report_type = ?'; params.push(req.query.report_type); }
        if (req.query.hostname) { sql += ' AND hostname = ?'; params.push(req.query.hostname); }
        if (req.query.q) { sql += ' AND (hostname LIKE ? OR operation LIKE ? OR content LIKE ?)'; var q='%'+req.query.q+'%'; params.push(q,q,q); }
        sql += ' ORDER BY created_at DESC LIMIT 200';
        try { res.json(db.prepare(sql).all.apply(db.prepare(sql), params)); }
        catch (e) { res.status(500).json({ error: e.message }); }
    });

    // GET /api/patches/reports/:id
    router.get('/reports/:id', authenticateToken, (req, res) => {
        const db = getDB();
        try {
            var row = db.prepare('SELECT * FROM patch_reports WHERE id = ?').get(req.params.id);
            res.json(row);
        } catch (e) { res.status(500).json({ error: e.message }); }
    });

    // POST /api/patches/reports - agent posts precheck/postcheck HTML report
    router.post('/reports', authenticateToken, (req, res) => {
        const db = getDB();
        var b = req.body;
        var id = uuidv4();
        try {
            db.prepare('INSERT INTO patch_reports (id, job_id, hostname, report_type, operation, result, content) VALUES (?,?,?,?,?,?,?)').run(
                id, b.job_id || '', b.hostname || '', b.report_type || 'precheck', b.operation || '', b.result || 'UNKNOWN', b.content || '');
            res.status(201).json({ id: id, message: 'Report saved' });
        } catch (e) { res.status(500).json({ error: e.message }); }
    });


    return router;
};
