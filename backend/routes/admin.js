const express = require('express');
const router = express.Router();
const bcrypt = require('bcryptjs');
const { v4: uuidv4 } = require('uuid');
const { getDB } = require('../lib/db');
const { requireAdmin } = require('../lib/auth');
const { Client } = require('ssh2');
const fs = require('fs');
const path = require('path');

// All admin routes require admin role
router.use(requireAdmin);

// List all users
router.get('/users', (req, res) => {
    const db = getDB();
    const users = db.prepare(
        'SELECT id, username, role, enabled, created_at, updated_at, last_login FROM users ORDER BY created_at'
    ).all();
    res.json(users);
});

// Create user
router.post('/users', (req, res) => {
    const { username, password, role } = req.body;
    if (!username || !password) {
        return res.status(400).json({ error: 'Username and password are required' });
    }
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

// Change password (admin can change any, or user changes own)
router.put('/users/:id/password', (req, res) => {
    const { password } = req.body;
    if (!password || password.length < 6) {
        return res.status(400).json({ error: 'Password must be at least 6 characters' });
    }
    const db = getDB();
    const user = db.prepare('SELECT id, username FROM users WHERE id = ?').get(req.params.id);
    if (!user) return res.status(404).json({ error: 'User not found' });

    const hash = bcrypt.hashSync(password, 10);
    db.prepare('UPDATE users SET password = ?, updated_at = datetime(\'now\') WHERE id = ?').run(hash, req.params.id);
    res.json({ message: `Password updated for ${user.username}` });
});

// Update user role
router.put('/users/:id/role', (req, res) => {
    const { role } = req.body;
    const validRoles = ['admin', 'operator', 'viewer'];
    if (!validRoles.includes(role)) {
        return res.status(400).json({ error: 'Invalid role. Must be: admin, operator, or viewer' });
    }
    const db = getDB();
    const user = db.prepare('SELECT id, username FROM users WHERE id = ?').get(req.params.id);
    if (!user) return res.status(404).json({ error: 'User not found' });
    db.prepare('UPDATE users SET role = ?, updated_at = datetime(\'now\') WHERE id = ?').run(role, req.params.id);
    res.json({ message: `Role updated to ${role} for ${user.username}` });
});

// Enable/disable user
router.put('/users/:id/toggle', (req, res) => {
    const db = getDB();
    const user = db.prepare('SELECT id, username, enabled FROM users WHERE id = ?').get(req.params.id);
    if (!user) return res.status(404).json({ error: 'User not found' });
    if (user.username === 'admin') return res.status(400).json({ error: 'Cannot disable the admin account' });
    const newState = user.enabled ? 0 : 1;
    db.prepare('UPDATE users SET enabled = ?, updated_at = datetime(\'now\') WHERE id = ?').run(newState, req.params.id);
    res.json({ message: `User ${user.username} ${newState ? 'enabled' : 'disabled'}`, enabled: newState });
});

// Delete user
router.delete('/users/:id', (req, res) => {
    const db = getDB();
    const user = db.prepare('SELECT id, username FROM users WHERE id = ?').get(req.params.id);
    if (!user) return res.status(404).json({ error: 'User not found' });
    if (user.username === 'admin') return res.status(400).json({ error: 'Cannot delete the admin account' });
    db.prepare('DELETE FROM users WHERE id = ?').run(req.params.id);
    res.json({ message: `User ${user.username} deleted` });
});

// Change own password (any authenticated user)
router.put('/change-password', (req, res) => {
    const { currentPassword, newPassword } = req.body;
    if (!currentPassword || !newPassword) {
        return res.status(400).json({ error: 'Current and new passwords are required' });
    }
    if (newPassword.length < 6) return res.status(400).json({ error: 'New password must be at least 6 characters' });
    const db = getDB();
    const user = db.prepare('SELECT * FROM users WHERE username = ?').get(req.user.username);
    if (!bcrypt.compareSync(currentPassword, user.password)) {
        return res.status(401).json({ error: 'Current password is incorrect' });
    }
    const hash = bcrypt.hashSync(newPassword, 10);
    db.prepare('UPDATE users SET password = ?, updated_at = datetime(\'now\') WHERE id = ?').run(hash, user.id);
    res.json({ message: 'Password changed successfully' });
});

// GET /api/admin/settings - orchestrator-level configuration
router.get('/settings', (req, res) => {
    const db = getDB();
    try {
        db.exec("CREATE TABLE IF NOT EXISTS app_settings (key TEXT PRIMARY KEY, value TEXT NOT NULL, updated_at TEXT DEFAULT (datetime('now')))");
    } catch(_) {}
    const keys = ['orchestrator_url','gi_base_zip_path','db_base_zip_path','gi_home_base','db_home_base','patches_base_path'];
    const result = {};
    for (const key of keys) {
        const row = db.prepare('SELECT value FROM app_settings WHERE key = ?').get(key);
        result[key] = row ? row.value : '';
    }
    res.json(result);
});

// PUT /api/admin/settings
router.put('/settings', (req, res) => {
    const db = getDB();
    try {
        db.exec("CREATE TABLE IF NOT EXISTS app_settings (key TEXT PRIMARY KEY, value TEXT NOT NULL, updated_at TEXT DEFAULT (datetime('now')))");
    } catch(_) {}
    const allowed = ['orchestrator_url','gi_base_zip_path','db_base_zip_path','gi_home_base','db_home_base','patches_base_path'];
    const stmt = db.prepare("INSERT OR REPLACE INTO app_settings (key, value, updated_at) VALUES (?, ?, datetime('now'))");
    const tx = db.transaction(() => {
        for (const key of allowed) {
            if (req.body[key] !== undefined) stmt.run(key, (req.body[key] || '').trim());
        }
    });
    try {
        tx();
        res.json({ message: 'Settings saved' });
    } catch (e) {
        res.status(500).json({ error: e.message });
    }
});

// Deploy/update agent on a VM via SSH (SFTP + systemd)
// Pushes both insight-agent.py and os-patch-auto.sh to the target VM.
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
    const sshUsername = (sshUser || 'root').trim();
    const sudo = (useSudo || sshUsername !== 'root') ? 'sudo ' : '';
    const keyPath = process.env.SSH_KEY_PATH || '/root/.ssh/id_rsa';

    let privateKey;
    if (!sshPassword) {
        try { privateKey = fs.readFileSync(keyPath); }
        catch (e) { return res.status(500).json({ error: 'No SSH password provided and cannot read SSH key: ' + e.message }); }
    }

    let agentContent, scriptContent;
    try { agentContent  = fs.readFileSync(agentSrc); }
    catch (e) { return res.status(500).json({ error: 'Cannot read agent: ' + e.message }); }
    try { scriptContent = fs.readFileSync(scriptSrc); }
    catch (e) { return res.status(500).json({ error: 'Cannot read script: ' + e.message }); }

    const agentDir  = '/opt/insight-agent';
    const agentDest = `${agentDir}/insight-agent.py`;
    const scriptDest = `${agentDir}/os-patch-auto.sh`;

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

    // Temp paths any SSH user can write to via SFTP
    const tmpAgent  = '/tmp/.insight-agent-upload.py';
    const tmpScript = '/tmp/.insight-script-upload.sh';

    const conn = new Client();
    conn.on('ready', () => {
        conn.sftp((err, sftp) => {
            if (err) { conn.end(); return res.status(500).json({ error: 'SFTP error: ' + err.message }); }

            // Write both files to /tmp (writable by any user)
            const agentStream = sftp.createWriteStream(tmpAgent);
            agentStream.on('close', () => {
                const scriptStream = sftp.createWriteStream(tmpScript);
                scriptStream.on('close', () => {
                    // Use sudo to move files into /opt/insight-agent and set up systemd
                    const cmds = [
                        `${sudo}mkdir -p ${agentDir}`,
                        `${sudo}mv ${tmpAgent} ${agentDest}`,
                        `${sudo}mv ${tmpScript} ${scriptDest}`,
                        `${sudo}chown oracle:oracle ${agentDir} ${agentDest} ${scriptDest}`,
                        `${sudo}chmod 750 ${agentDest} ${scriptDest}`,
                        `${sudo}tee /etc/systemd/system/insight-agent.service > /dev/null << 'SVCEOF'\n${serviceUnit}\nSVCEOF`,
                        `${sudo}systemctl daemon-reload`,
                        `${sudo}systemctl enable insight-agent`,
                        `${sudo}systemctl restart insight-agent`,
                        'sleep 2 && systemctl is-active insight-agent'
                    ].join(' && ');
                    conn.exec(cmds, (err2, stream) => {
                        if (err2) { conn.end(); return res.status(500).json({ error: err2.message }); }
                        let out = '';
                        stream.on('data', d => { out += d; });
                        stream.stderr.on('data', d => { out += d; });
                        stream.on('close', () => {
                            conn.end();
                            try {
                                try { db.exec('ALTER TABLE vms ADD COLUMN deploy_ssh_user TEXT'); } catch(_) {}
                                db.prepare("UPDATE vms SET script_path = ?, deploy_ssh_user = ?, updated_at = datetime('now') WHERE id = ?")
                                  .run(scriptDest, sshUsername, vm.id);
                            } catch(_) {}
                            res.json({ ok: true, hostname: vm.hostname, agentPath: agentDest, scriptPath: scriptDest, output: out.trim() });
                        });
                    });
                });
                scriptStream.end(scriptContent);
            });
            agentStream.end(agentContent);
        });
    }).on('error', err => res.status(500).json({ error: err.message }))
      .connect({
          host: vm.ip, port: vm.ssh_port || 22, username: sshUsername,
          ...(sshPassword ? { password: sshPassword } : { privateKey }),
          readyTimeout: 10000
      });
});

module.exports = router;
