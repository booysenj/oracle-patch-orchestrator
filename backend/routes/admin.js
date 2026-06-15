const express = require('express');
const router = express.Router();
const bcrypt = require('bcryptjs');
const { v4: uuidv4 } = require('uuid');
const { getDB } = require('../lib/db');
const { requireAdmin } = require('../lib/auth');

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

module.exports = router;
