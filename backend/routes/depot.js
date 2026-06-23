const express = require('express');
const router = express.Router();
const path = require('path');
const fs = require('fs');
const { spawn } = require('child_process');
const { v4: uuidv4 } = require('uuid');
const { getDB } = require('../lib/db');

const DEPOT_BASE = path.join(__dirname, '..', '..', 'depot');

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
            error       TEXT,
            created_at  TEXT DEFAULT (datetime('now')),
            updated_at  TEXT DEFAULT (datetime('now'))
        )`);
    } catch(_) {}
}

function depotUpdate(patch_id, fields) {
    try {
        const db = getDB();
        const sets = Object.keys(fields).map(k => k + '=?').concat("updated_at=datetime('now')").join(',');
        db.prepare(`UPDATE depot SET ${sets} WHERE patch_id=?`).run(...Object.values(fields), patch_id);
    } catch(_) {}
}

function extractZip(zipPath, destDir, patch_id, statusField) {
    return new Promise((resolve) => {
        if (!zipPath || !fs.existsSync(zipPath)) {
            depotUpdate(patch_id, { [statusField]: 'skipped' });
            return resolve(true);
        }
        fs.mkdirSync(destDir, { recursive: true });
        depotUpdate(patch_id, { [statusField]: 'extracting' });
        const proc = spawn('unzip', ['-o', '-q', zipPath, '-d', destDir]);
        proc.on('close', code => {
            depotUpdate(patch_id, { [statusField]: code === 0 ? 'ready' : 'failed' });
            resolve(code === 0);
        });
        proc.on('error', () => { depotUpdate(patch_id, { [statusField]: 'failed' }); resolve(false); });
    });
}

async function runExtraction(patch, depotPath, patch_id) {
    try {
        fs.mkdirSync(depotPath, { recursive: true });

        await extractZip(patch.gi_base_zip || null, path.join(depotPath, 'gi'), patch_id, 'gi_status');
        await extractZip(patch.db_base_zip || null, path.join(depotPath, 'db'), patch_id, 'db_status');

        // RU: find largest non-opatch zip in patch_search_root
        let ruZip = null;
        const ruRoot = patch.patch_search_root || '';
        if (ruRoot && fs.existsSync(ruRoot)) {
            const stat = fs.statSync(ruRoot);
            const scanDir = stat.isDirectory() ? ruRoot : path.dirname(ruRoot);
            const zips = fs.readdirSync(scanDir)
                .filter(f => f.endsWith('.zip') && !f.startsWith('p6880880'))
                .map(f => ({ f, size: fs.statSync(path.join(scanDir, f)).size }))
                .sort((a, b) => b.size - a.size);
            if (zips.length) ruZip = path.join(scanDir, zips[0].f);
        }
        await extractZip(ruZip, path.join(depotPath, 'ru'), patch_id, 'ru_status');

        // OPatch: use configured path or find in same dir as RU
        let opatchZip = patch.opatch_zip || null;
        if (!opatchZip && ruRoot && fs.existsSync(ruRoot)) {
            const scanDir = fs.statSync(ruRoot).isDirectory() ? ruRoot : path.dirname(ruRoot);
            const op = fs.readdirSync(scanDir).find(f => f.startsWith('p6880880') && f.endsWith('.zip'));
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
        FROM depot d LEFT JOIN patches p ON d.patch_id = p.id
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
    const patch = db.prepare('SELECT * FROM patches WHERE id=?').get(patch_id);
    if (!patch) return res.status(404).json({ error: 'Patch not found' });

    const existing = db.prepare('SELECT * FROM depot WHERE patch_id=?').get(patch_id);
    if (existing && existing.status === 'extracting') {
        return res.json({ id: existing.id, status: 'extracting' });
    }

    const depotPath = path.join(DEPOT_BASE, patch.version || patch_id);
    if (existing) {
        db.prepare("UPDATE depot SET status='extracting',gi_status='pending',db_status='pending',ru_status='pending',opatch_status='pending',error=NULL,depot_path=?,updated_at=datetime('now') WHERE patch_id=?")
          .run(depotPath, patch_id);
        setImmediate(() => runExtraction(patch, depotPath, patch_id));
        return res.json({ id: existing.id, status: 'extracting', depot_path: depotPath });
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
router.delete('/:patchId', (req, res) => {
    ensureDepotTable();
    const db = getDB();
    const row = db.prepare('SELECT * FROM depot WHERE patch_id=? OR id=?').get(req.params.patchId, req.params.patchId);
    if (!row) return res.status(404).json({ error: 'Not found' });
    if (row.depot_path && fs.existsSync(row.depot_path)) {
        try { fs.rmSync(row.depot_path, { recursive: true, force: true }); } catch(e) {}
    }
    db.prepare('DELETE FROM depot WHERE id=?').run(row.id);
    res.json({ ok: true });
});

// GET /api/depot/:patchId/tar/:type  — stream tar of depot subdirectory to agent
// type: gi | db | ru | opatch
router.get('/:patchId/tar/:type', (req, res) => {
    ensureDepotTable();
    const row = getDB().prepare('SELECT * FROM depot WHERE patch_id=? OR id=?').get(req.params.patchId, req.params.patchId);
    if (!row) return res.status(404).json({ error: 'Depot not found' });
    if (row.status !== 'ready' && row.status !== 'partial') {
        return res.status(409).json({ error: 'Depot not ready: ' + row.status });
    }
    const subDir = path.join(row.depot_path, req.params.type);
    if (!fs.existsSync(subDir)) return res.status(404).json({ error: 'Depot component not found: ' + req.params.type });

    const stat = fs.statSync(subDir);
    if (!stat.isDirectory()) return res.status(400).json({ error: 'Not a directory' });

    res.setHeader('Content-Type', 'application/x-tar');
    res.setHeader('X-Transfer-Type', 'tar');
    res.setHeader('X-Depot-Type', req.params.type);

    // Stream tar -C subDir -cf - .
    const tar = spawn('tar', ['-C', subDir, '-cf', '-', '.']);
    tar.stdout.pipe(res);
    tar.on('error', (e) => { if (!res.headersSent) res.status(500).json({ error: String(e) }); });
    req.on('close', () => tar.kill());
});

module.exports = router;
