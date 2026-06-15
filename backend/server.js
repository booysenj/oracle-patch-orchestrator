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
const schedulerRoutes = require('./routes/scheduler');
const { authenticateToken, loginRoute, requireAdmin } = require('./lib/auth');
const { initDB } = require('./lib/db');
const { initAuditTable } = require('./lib/audit');
const { attachWSS } = require('./lib/ws-relay');
const { setupTransferRoutes } = require('./lib/transfer-api');
const { checkDueSchedules } = require('./lib/scheduler-jobs');

const app = express();
const server = http.createServer(app);

app.use(helmet({ contentSecurityPolicy: false, crossOriginEmbedderPolicy: false }));
app.use(cors({ origin: process.env.CORS_ORIGIN || '*' }));
app.use(express.json());
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
});
