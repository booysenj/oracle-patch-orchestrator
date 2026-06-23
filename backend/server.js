require("dotenv").config({ path: require("path").join(__dirname, "..", ".env") });
const express = require('express');
const http = require('http');
const { WebSocketServer } = require('ws');
const cors = require('cors');
const helmet = require('helmet');
const vmRoutes = require('./routes/vms');
const jobRoutes = require('./routes/jobs');
const logRoutes = require('./routes/logs');
const adminRoutes = require('./routes/admin');
const agentRoutes = require('./routes/agent');
const patchRoutes = require('./routes/patches');
const reportsRoutes = require('./routes/reports');
const schedulerRoutes = require('./routes/scheduler');
const depotRoutes = require('./routes/depot');
const { authenticateToken, loginRoute, requireAdmin } = require('./lib/auth');
const { initDB } = require('./lib/db');
const { initAuditTable } = require('./lib/audit');
const { attachWSS } = require('./lib/ws-relay');
const { setupTransferRoutes } = require('./lib/transfer-api');
const { checkDueSchedules, timeoutStaleJobs, checkPreDowntimeNotifications } = require('./lib/scheduler-jobs');

const app = express();
const server = http.createServer(app);

app.use(helmet({ contentSecurityPolicy: false, crossOriginEmbedderPolicy: false }));
app.use(cors({ origin: process.env.CORS_ORIGIN || '*' }));
app.use(express.json({ limit: '10mb' }));
app.use(express.static(require("path").join(__dirname, "..", "frontend"), { setHeaders: function(res, p) { if (p.endsWith(".js")) res.setHeader("Cache-Control", "no-cache"); } }));

app.get('/api/health', (_req, res) => res.json({
    status: 'ok',
    host: require('os').hostname(),
    uptime: process.uptime()
}));

app.post('/api/auth/login', loginRoute);
app.use('/api/vms', authenticateToken, vmRoutes);
app.use('/api/jobs', authenticateToken, jobRoutes);
app.use('/api/logs', authenticateToken, logRoutes);
app.use('/api/admin', authenticateToken, adminRoutes);
app.use('/api/agent', agentRoutes);
app.use('/api/patches', patchRoutes(authenticateToken));
app.use('/api/reports', reportsRoutes(authenticateToken));
app.use('/api/depot', authenticateToken, depotRoutes);

const wss = new WebSocketServer({ server, path: '/ws/logs' });
attachWSS(wss);

const PORT = process.env.PORT || 4000;
initDB();
initAuditTable();
const { getDB: getDBFn } = require('./lib/db');
app.use('/api/schedules', schedulerRoutes(getDBFn, authenticateToken));

server.listen(PORT, '0.0.0.0', () => {
    console.log('[insight-patch-ui] API listening on :' + PORT);
    console.log('[insight-patch-ui] WebSocket: ws://0.0.0.0:' + PORT + '/ws/logs');

    // Reset any transfers that were mid-flight when the server last stopped — agent will retry
    try {
        const _db = require('./lib/db').getDB();
        const _reset = _db.prepare("UPDATE patch_transfers SET status='PENDING', started_at=NULL WHERE status='TRANSFERRING'").run();
        if (_reset.changes) console.log('[startup] Reset ' + _reset.changes + ' stuck TRANSFERRING transfer(s) to PENDING');
    } catch(_) {}

    // Run immediately on startup to clear any stale jobs, then every 5 minutes
    timeoutStaleJobs();
    setInterval(timeoutStaleJobs, 5 * 60 * 1000);

    const _schedulerTick = () => {
        try {
            const fired = checkDueSchedules();
            if (fired > 0) console.log('[SCHEDULER] Fired ' + fired + ' due schedule(s)');
        } catch (e) {
            console.error('[SCHEDULER] checkDueSchedules error:', e.message);
        }
        try { checkPreDowntimeNotifications(); } catch(e) {}
    };
    // Run once immediately on startup (catches schedules missed during downtime)
    setTimeout(_schedulerTick, 5000);
    setInterval(_schedulerTick, 30 * 1000);
    console.log('[SCHEDULER] Tick started (30s interval, initial check in 5s)');
});
