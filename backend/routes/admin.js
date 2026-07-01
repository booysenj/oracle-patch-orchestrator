const express = require('express');
const router = express.Router();
const bcrypt = require('bcryptjs');
const { v4: uuidv4 } = require('uuid');
const { getDB } = require('../lib/db');
const { requireAdmin } = require('../lib/auth');
const fs = require('fs');
const path = require('path');
const os = require('os');
const { execSync, exec } = require('child_process');

// All admin routes require admin role
router.use(requireAdmin);

// ---------------------------------------------------------------------------
// SSH key management — keypair is stored in app_settings so it survives
// orchestrator migration (move the SQLite file and the key comes with it).
// The orchestrator's own root key is never touched.
// ---------------------------------------------------------------------------
function getOrCreateSshKey(db) {
    try {
        db.exec("CREATE TABLE IF NOT EXISTS app_settings (key TEXT PRIMARY KEY, value TEXT NOT NULL, updated_at TEXT DEFAULT (datetime('now')))");
    } catch(_) {}

    let privRow = db.prepare("SELECT value FROM app_settings WHERE key='ssh_private_key'").get();
    let pubRow  = db.prepare("SELECT value FROM app_settings WHERE key='ssh_public_key'").get();

    if (!privRow || !pubRow) {
        // Generate a dedicated orchestrator keypair and store it in the DB
        const tmp = path.join(os.tmpdir(), '.insight-keygen-' + process.pid);
        try { fs.unlinkSync(tmp); } catch(_) {}
        try { fs.unlinkSync(tmp + '.pub'); } catch(_) {}
        execSync(`ssh-keygen -t ed25519 -f ${tmp} -N "" -q`);
        const priv = fs.readFileSync(tmp, 'utf8');
        const pub  = fs.readFileSync(tmp + '.pub', 'utf8').trim();
        try { fs.unlinkSync(tmp); fs.unlinkSync(tmp + '.pub'); } catch(_) {}
        db.prepare("INSERT OR REPLACE INTO app_settings (key, value, updated_at) VALUES ('ssh_private_key', ?, datetime('now'))").run(priv);
        db.prepare("INSERT OR REPLACE INTO app_settings (key, value, updated_at) VALUES ('ssh_public_key', ?, datetime('now'))").run(pub);
        privRow = { value: priv };
        pubRow  = { value: pub };
    }

    return { priv: privRow.value, pub: pubRow.value };
}

// Write keypair to temp files, return paths + a cleanup function
function writeSshKeyFiles(priv, pub) {
    const base = path.join(os.tmpdir(), '.insight-key-' + process.pid + '-' + Date.now());
    fs.writeFileSync(base,          priv, { mode: 0o600 });
    fs.writeFileSync(base + '.pub', pub,  { mode: 0o644 });
    return {
        keyFile: base,
        pubFile: base + '.pub',
        cleanup() { try { fs.unlinkSync(base); fs.unlinkSync(base + '.pub'); } catch(_) {} }
    };
}

// Write password to a temp file so it never appears on the process list
function withPassFile(password, fn) {
    const tmpPass = path.join(os.tmpdir(), '.insight-ssh-pass-' + process.pid + '-' + Date.now());
    fs.writeFileSync(tmpPass, password, { mode: 0o600 });
    const cleanup = () => { try { fs.unlinkSync(tmpPass); } catch(_) {} };
    return fn(tmpPass, cleanup);
}

// ---------------------------------------------------------------------------
// GET /api/admin/ssh-public-key
// Returns the orchestrator's public key so admins can copy it into
// authorized_keys on target VMs manually.
// ---------------------------------------------------------------------------
router.get('/ssh-public-key', (req, res) => {
    try {
        const { pub } = getOrCreateSshKey(getDB());
        res.json({ public_key: pub });
    } catch(e) {
        res.status(500).json({ error: 'Failed to get/generate SSH key: ' + e.message });
    }
});

// POST /api/admin/ssh-key/regenerate — generate a new keypair (invalidates all VMs)
router.post('/ssh-key/regenerate', (req, res) => {
    try {
        const db = getDB();
        const tmp = path.join(os.tmpdir(), '.insight-keygen-regen-' + process.pid);
        try { fs.unlinkSync(tmp); fs.unlinkSync(tmp + '.pub'); } catch(_) {}
        execSync(`ssh-keygen -t ed25519 -f ${tmp} -N "" -q`);
        const priv = fs.readFileSync(tmp, 'utf8');
        const pub  = fs.readFileSync(tmp + '.pub', 'utf8').trim();
        try { fs.unlinkSync(tmp); fs.unlinkSync(tmp + '.pub'); } catch(_) {}
        db.exec("CREATE TABLE IF NOT EXISTS app_settings (key TEXT PRIMARY KEY, value TEXT NOT NULL, updated_at TEXT DEFAULT (datetime('now')))");
        db.prepare("INSERT OR REPLACE INTO app_settings (key, value, updated_at) VALUES ('ssh_private_key', ?, datetime('now'))").run(priv);
        db.prepare("INSERT OR REPLACE INTO app_settings (key, value, updated_at) VALUES ('ssh_public_key', ?, datetime('now'))").run(pub);
        res.json({ public_key: pub, warning: 'New key generated. You must re-authorise this key on all target VMs.' });
    } catch(e) {
        res.status(500).json({ error: e.message });
    }
});

// ---------------------------------------------------------------------------
// Users
// ---------------------------------------------------------------------------
router.get('/users', (req, res) => {
    const db = getDB();
    const users = db.prepare(
        'SELECT id, username, role, enabled, created_at, updated_at, last_login FROM users ORDER BY created_at'
    ).all();
    res.json(users);
});

router.post('/users', (req, res) => {
    const { username, password, role } = req.body;
    if (!username || !password) return res.status(400).json({ error: 'Username and password are required' });
    if (username.length < 3) return res.status(400).json({ error: 'Username must be at least 3 characters' });
    if (password.length < 6) return res.status(400).json({ error: 'Password must be at least 6 characters' });
    const validRoles = ['admin', 'operator', 'viewer'];
    const userRole = validRoles.includes(role) ? role : 'operator';
    const db = getDB();
    const existing = db.prepare('SELECT id FROM users WHERE username = ?').get(username);
    if (existing) return res.status(409).json({ error: 'Username already exists' });
    const id = uuidv4();
    const hash = bcrypt.hashSync(password, 10);
    db.prepare('INSERT INTO users (id, username, password, role) VALUES (?, ?, ?, ?)').run(id, username, hash, userRole);
    res.status(201).json({ id, username, role: userRole, enabled: 1 });
});

router.put('/users/:id/password', (req, res) => {
    const { password } = req.body;
    if (!password || password.length < 6) return res.status(400).json({ error: 'Password must be at least 6 characters' });
    const db = getDB();
    const user = db.prepare('SELECT id, username FROM users WHERE id = ?').get(req.params.id);
    if (!user) return res.status(404).json({ error: 'User not found' });
    const hash = bcrypt.hashSync(password, 10);
    db.prepare("UPDATE users SET password = ?, updated_at = datetime('now') WHERE id = ?").run(hash, req.params.id);
    res.json({ message: `Password updated for ${user.username}` });
});

router.put('/users/:id/role', (req, res) => {
    const { role } = req.body;
    const validRoles = ['admin', 'operator', 'viewer'];
    if (!validRoles.includes(role)) return res.status(400).json({ error: 'Invalid role. Must be: admin, operator, or viewer' });
    const db = getDB();
    const user = db.prepare('SELECT id, username FROM users WHERE id = ?').get(req.params.id);
    if (!user) return res.status(404).json({ error: 'User not found' });
    db.prepare("UPDATE users SET role = ?, updated_at = datetime('now') WHERE id = ?").run(role, req.params.id);
    res.json({ message: `Role updated to ${role} for ${user.username}` });
});

router.put('/users/:id/toggle', (req, res) => {
    const db = getDB();
    const user = db.prepare('SELECT id, username, enabled FROM users WHERE id = ?').get(req.params.id);
    if (!user) return res.status(404).json({ error: 'User not found' });
    if (user.username === 'admin') return res.status(400).json({ error: 'Cannot disable the admin account' });
    const newState = user.enabled ? 0 : 1;
    db.prepare("UPDATE users SET enabled = ?, updated_at = datetime('now') WHERE id = ?").run(newState, req.params.id);
    res.json({ message: `User ${user.username} ${newState ? 'enabled' : 'disabled'}`, enabled: newState });
});

router.delete('/users/:id', (req, res) => {
    const db = getDB();
    const user = db.prepare('SELECT id, username FROM users WHERE id = ?').get(req.params.id);
    if (!user) return res.status(404).json({ error: 'User not found' });
    if (user.username === 'admin') return res.status(400).json({ error: 'Cannot delete the admin account' });
    db.prepare('DELETE FROM users WHERE id = ?').run(req.params.id);
    res.json({ message: `User ${user.username} deleted` });
});

router.put('/change-password', (req, res) => {
    const { currentPassword, newPassword } = req.body;
    if (!currentPassword || !newPassword) return res.status(400).json({ error: 'Current and new passwords are required' });
    if (newPassword.length < 6) return res.status(400).json({ error: 'New password must be at least 6 characters' });
    const db = getDB();
    const user = db.prepare('SELECT * FROM users WHERE username = ?').get(req.user.username);
    if (!bcrypt.compareSync(currentPassword, user.password)) return res.status(401).json({ error: 'Current password is incorrect' });
    const hash = bcrypt.hashSync(newPassword, 10);
    db.prepare("UPDATE users SET password = ?, updated_at = datetime('now') WHERE id = ?").run(hash, user.id);
    res.json({ message: 'Password changed successfully' });
});

// ---------------------------------------------------------------------------
// Orchestrator settings
// ---------------------------------------------------------------------------
router.get('/settings', (req, res) => {
    const db = getDB();
    try { db.exec("CREATE TABLE IF NOT EXISTS app_settings (key TEXT PRIMARY KEY, value TEXT NOT NULL, updated_at TEXT DEFAULT (datetime('now')))"); } catch(_) {}
    const keys = ['orchestrator_url','gi_base_zip_path','db_base_zip_path','gi_home_base','db_home_base','patches_base_path','mail_to','mail_from','depot_base_path','stale_home_cleanup_days'];
    const result = {};
    for (const key of keys) {
        const row = db.prepare('SELECT value FROM app_settings WHERE key = ?').get(key);
        result[key] = row ? row.value : '';
    }
    res.json(result);
});

router.put('/settings', (req, res) => {
    const db = getDB();
    try { db.exec("CREATE TABLE IF NOT EXISTS app_settings (key TEXT PRIMARY KEY, value TEXT NOT NULL, updated_at TEXT DEFAULT (datetime('now')))"); } catch(_) {}
    const allowed = ['orchestrator_url','gi_base_zip_path','db_base_zip_path','gi_home_base','db_home_base','patches_base_path','mail_to','mail_from','depot_base_path','stale_home_cleanup_days'];
    const stmt = db.prepare("INSERT OR REPLACE INTO app_settings (key, value, updated_at) VALUES (?, ?, datetime('now'))");
    const tx = db.transaction(() => {
        for (const key of allowed) {
            if (req.body[key] !== undefined) stmt.run(key, (req.body[key] || '').trim());
        }
    });
    try { tx(); res.json({ message: 'Settings saved' }); }
    catch(e) { res.status(500).json({ error: e.message }); }
});

// ---------------------------------------------------------------------------
// Agent deployment
// Password security: if a password is provided it is written to a temp file
// (mode 600) and passed to sshpass via -f, so it never appears on the
// process list. The file is deleted immediately after the exec call.
//
// SSH key security: the keypair is stored in app_settings (SQLite) so it
// migrates with the database. The orchestrator's own root key is never read
// or written. Keys are extracted to temp files for use and deleted afterward.
// ---------------------------------------------------------------------------
router.post('/vms/:id/deploy-agent', requireAdmin, (req, res) => {
    const db = getDB();
    const vm = db.prepare('SELECT * FROM vms WHERE id = ?').get(req.params.id);
    if (!vm) return res.status(404).json({ error: 'VM not found' });

    const agentSrc  = path.join(__dirname, '..', '..', 'frontend', 'agent-download', 'insight-agent.py');
    const scriptSrc = path.join(__dirname, '..', 'scripts', 'os-patch-auto.sh');
    const agentToken = process.env.AGENT_SECRET || '';
    let orchestratorUrl = process.env.ORCHESTRATOR_URL || '';
    try {
        const row = db.prepare("SELECT value FROM app_settings WHERE key = 'orchestrator_url'").get();
        if (row && row.value) orchestratorUrl = row.value;
    } catch(_) {}
    if (!orchestratorUrl) orchestratorUrl = `http://172.16.36.95:${process.env.PORT || 4000}`;

    const { sshUser, sshPassword, useSudo } = req.body;
    const sshUsername = (sshUser || 'oracle').trim();
    const sudo = (useSudo || sshUsername !== 'root') ? 'sudo ' : '';
    const target = `${sshUsername}@${vm.ip}`;
    const port = vm.ssh_port || 22;

    const agentDir   = '/opt/insight-agent';
    const agentDest  = `${agentDir}/insight-agent.py`;
    const scriptDest = `${agentDir}/os-patch-auto.sh`;
    const tmpAgent   = '/tmp/.insight-agent-upload.py';
    const tmpScript  = '/tmp/.insight-script-upload.sh';

    const serviceUnit = [
        '[Unit]', 'Description=Insight Patch Agent', 'After=network.target', '',
        '[Service]', 'Type=simple', 'User=oracle',
        `ExecStart=/usr/bin/python3 ${agentDest}`,
        'Restart=always', 'RestartSec=5',
        `Environment=INSIGHT_API_URL=${orchestratorUrl}`,
        `Environment=INSIGHT_AGENT_TOKEN=${agentToken}`,
        `Environment=INSIGHT_HOSTNAME=${vm.hostname}`,
        'StandardOutput=journal', 'StandardError=journal',
        'Environment=PYTHONUNBUFFERED=1', '',
        '[Install]', 'WantedBy=multi-user.target'
    ].join('\n');

    // Get (or generate) the orchestrator's dedicated SSH keypair from the DB
    let keyFiles;
    try {
        const { priv, pub } = getOrCreateSshKey(db);
        keyFiles = writeSshKeyFiles(priv, pub);
    } catch(e) {
        return res.status(500).json({ error: 'SSH key unavailable: ' + e.message });
    }
    const { keyFile, pubFile, cleanup: cleanupKey } = keyFiles;

    const sshOpts = `-o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=10 -o ServerAliveCountMax=3 -i ${keyFile} -p ${port}`;
    const sshCmd  = `ssh ${sshOpts}`;
    const scpCmd  = `scp -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=15 -i ${keyFile} -P ${port}`;

    const setupCmds = [
        `${sudo}mkdir -p ${agentDir}`,
        `${sudo}mv ${tmpAgent} ${agentDest}`,
        `${sudo}mv ${tmpScript} ${scriptDest}`,
        `${sudo}chown oracle ${agentDir} ${agentDest} ${scriptDest}`,
        `${sudo}chmod 750 ${agentDest} ${scriptDest}`,
        `echo '${serviceUnit.replace(/'/g, "'\\''")}' | ${sudo}tee /etc/systemd/system/insight-agent.service > /dev/null`,
        `${sudo}systemctl daemon-reload`,
        `${sudo}systemctl enable insight-agent`,
        `${sudo}systemctl restart insight-agent`,
        'sleep 2 && systemctl is-active insight-agent'
    ].join(' && ');

    const copyCmd = `${scpCmd} '${agentSrc}' '${target}:${tmpAgent}' && ${scpCmd} '${scriptSrc}' '${target}:${tmpScript}'`;

    function done(err, out) {
        cleanupKey();
        if (err) return res.status(500).json({ error: err, output: out });
        try {
            try { db.exec('ALTER TABLE vms ADD COLUMN deploy_ssh_user TEXT'); } catch(_) {}
            db.prepare("UPDATE vms SET script_path = ?, deploy_ssh_user = ?, updated_at = datetime('now') WHERE id = ?")
              .run(scriptDest, sshUsername, vm.id);
        } catch(_) {}
        res.json({ ok: true, hostname: vm.hostname, agentPath: agentDest, scriptPath: scriptDest, output: out });
    }

    function doSetup() {
        exec(`${sshCmd} '${target}' "${setupCmds.replace(/"/g, '\\"')}"`, { timeout: 30000 }, (err, stdout, stderr) => {
            const out = (stdout + stderr).trim();
            if (err) { done('Setup failed: ' + (stderr || err.message), out); return; }
            done(null, out);
        });
    }

    function doCopy(cb) {
        exec(copyCmd, { timeout: 30000 }, cb);
    }

    function installKeyThenCopy(cb) {
        // Check sshpass is available before attempting password-based key install
        exec('which sshpass || command -v sshpass', (wpErr) => {
            if (wpErr) {
                cleanupKey();
                return res.status(500).json({ error: 'sshpass not installed on the orchestrator server. Install it with: yum install sshpass  (or apt-get install sshpass), then retry.' });
            }
            // Password goes to a temp file (mode 600) — never appears in process list
            withPassFile(sshPassword, (tmpPass, cleanupPass) => {
                const copyIdCmd = `sshpass -f ${tmpPass} ssh-copy-id -i ${pubFile} -o StrictHostKeyChecking=no -o PasswordAuthentication=yes -p ${port} '${target}'`;
                exec(copyIdCmd, { timeout: 20000 }, (err, stdout, stderr) => {
                    cleanupPass();
                    if (err) {
                        cleanupKey();
                        const detail = (stderr || '').trim() || err.message;
                        return res.status(500).json({ error: 'SSH key install failed — check username/password. Detail: ' + detail });
                    }
                    doCopy(cb);
                });
            });
        });
    }

    // Try key auth first; if it fails and a password was supplied, install the key then retry
    doCopy((err1, stdout1, stderr1) => {
        if (err1 && sshPassword) { installKeyThenCopy(doSetup); return; }
        if (err1) { cleanupKey(); return res.status(500).json({ error: 'File copy failed: ' + (stderr1 || err1.message) }); }
        doSetup();
    });
});

// Resolved orchestrator URL (for agent deploy scripts shown in UI)
router.get('/orchestrator-url', (req, res) => {
    try {
        const row = getDB().prepare("SELECT value FROM app_settings WHERE key = 'orchestrator_url'").get();
        res.json({ url: (row && row.value) || process.env.ORCHESTRATOR_URL || '' });
    } catch(_) { res.json({ url: '' }); }
});

// Self-update: git pull then restart the service.
// The restart is scheduled 500ms after responding so the HTTP reply reaches the client first.
router.post('/self-update', (req, res) => {
    const appDir = path.resolve(__dirname, '..', '..');
    exec(`git -C ${JSON.stringify(appDir)} pull`, { timeout: 30000 }, (err, stdout, stderr) => {
        const output = (stdout || '') + (stderr || '');
        if (err) return res.status(500).json({ error: 'git pull failed', output });
        res.json({ ok: true, output });
        // Restart after reply is flushed
        setTimeout(() => {
            exec('systemctl restart insight-patch-ui', { timeout: 10000 }, () => {});
        }, 500);
    });
});

module.exports = router;
