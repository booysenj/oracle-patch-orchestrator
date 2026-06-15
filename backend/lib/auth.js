const jwt = require('jsonwebtoken');
const bcrypt = require('bcryptjs');
const { getDB } = require('./db');

const JWT_SECRET = process.env.JWT_SECRET || 'CHANGE-ME-use-a-real-secret';
const TOKEN_EXPIRY = '8h';

function loginRoute(req, res) {
    const { username, password } = req.body;
    const db = getDB();
    const user = db.prepare('SELECT * FROM users WHERE username = ? AND enabled = 1').get(username);
    if (!user || !bcrypt.compareSync(password, user.password)) {
        return res.status(401).json({ error: 'Invalid credentials' });
    }
    db.prepare('UPDATE users SET last_login = datetime(\'now\') WHERE id = ?').run(user.id);
    const token = jwt.sign(
        { username: user.username, role: user.role, userId: user.id },
        JWT_SECRET, { expiresIn: TOKEN_EXPIRY }
    );
    res.json({ token, username: user.username, role: user.role });
}

function authenticateToken(req, res, next) {
    const authHeader = req.headers['authorization'];
    const token = authHeader && authHeader.split(' ')[1];
    if (!token) return res.status(401).json({ error: 'Token required' });
    jwt.verify(token, JWT_SECRET, (err, user) => {
        if (err) return res.status(403).json({ error: 'Invalid or expired token' });
        req.user = user;
        next();
    });
}

function requireAdmin(req, res, next) {
    if (req.user.role !== 'admin') {
        return res.status(403).json({ error: 'Admin access required' });
    }
    next();
}

module.exports = { loginRoute, authenticateToken, requireAdmin };
