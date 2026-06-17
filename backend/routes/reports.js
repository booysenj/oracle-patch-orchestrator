const express = require('express');
const jwt = require('jsonwebtoken');
const { getDB } = require('../lib/db');
const JWT_SECRET = process.env.JWT_SECRET || 'CHANGE-ME-use-a-real-secret';

// Auth that also accepts ?token= query param (for iframe src URLs)
function authFlexible(req, res, next) {
    const authHeader = req.headers['authorization'];
    const token = (authHeader && authHeader.split(' ')[1]) || req.query.token;
    if (!token) return res.status(401).json({ error: 'Token required' });
    jwt.verify(token, JWT_SECRET, (err, user) => {
        if (err) return res.status(403).json({ error: 'Invalid or expired token' });
        req.user = user;
        next();
    });
}

module.exports = function(authenticateToken) {
    const router = express.Router();

    // List reports with optional filters
    router.get('/', authenticateToken, (req, res) => {
        const db = getDB();
        const { hostname, operation, type, q, limit } = req.query;
        let sql = 'SELECT id, job_id, hostname, operation, subject, result, created_at FROM patch_reports WHERE 1=1';
        const params = [];
        if (hostname) { sql += ' AND hostname LIKE ?'; params.push('%' + hostname + '%'); }
        if (operation) { sql += ' AND operation = ?'; params.push(operation); }
        if (type) { sql += ' AND subject LIKE ?'; params.push('%' + type + '%'); }
        if (q) { sql += ' AND (hostname LIKE ? OR subject LIKE ? OR operation LIKE ?)'; params.push('%'+q+'%','%'+q+'%','%'+q+'%'); }
        sql += ' ORDER BY created_at DESC LIMIT ?';
        params.push(parseInt(limit) || 200);
        res.json(db.prepare(sql).all(...params));
    });

    // Get full HTML content for one report (accepts ?token= for iframe embedding)
    router.get('/:id/html', authFlexible, (req, res) => {
        const db = getDB();
        const row = db.prepare('SELECT html_content, subject FROM patch_reports WHERE id = ?').get(req.params.id);
        if (!row) return res.status(404).json({ error: 'Report not found' });
        res.setHeader('Content-Type', 'text/html; charset=utf-8');
        res.send(row.html_content);
    });

    // Delete a report
    router.delete('/:id', authenticateToken, (req, res) => {
        const db = getDB();
        db.prepare('DELETE FROM patch_reports WHERE id = ?').run(req.params.id);
        res.json({ ok: true });
    });

    return router;
};
