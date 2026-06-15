const { jobEvents } = require('./job-runner');
const jwt = require('jsonwebtoken');
const JWT_SECRET = process.env.JWT_SECRET || 'CHANGE-ME-use-a-real-secret';

function attachWSS(wss) {
    wss.on('connection', (ws, req) => {
        const url = new URL(req.url, 'http://localhost');
        const token = url.searchParams.get('token');
        if (!token) { ws.close(4001, 'Token required'); return; }
        try { jwt.verify(token, JWT_SECRET); }
        catch { ws.close(4003, 'Invalid token'); return; }

        let subscribedJobId = null;
        const logHandler = (data) => {
            if (ws.readyState === ws.OPEN)
                ws.send(JSON.stringify({ type: 'log', ...data }));
        };
        const doneHandler = (data) => {
            if (ws.readyState === ws.OPEN)
                ws.send(JSON.stringify({ type: 'done', ...data }));
        };

        ws.on('message', (msg) => {
            try {
                const parsed = JSON.parse(msg);
                if (parsed.action === 'subscribe' && parsed.jobId) {
                    if (subscribedJobId) {
                        jobEvents.removeListener(`log:${subscribedJobId}`, logHandler);
                        jobEvents.removeListener(`done:${subscribedJobId}`, doneHandler);
                    }
                    subscribedJobId = parsed.jobId;
                    jobEvents.on(`log:${subscribedJobId}`, logHandler);
                    jobEvents.on(`done:${subscribedJobId}`, doneHandler);
                    ws.send(JSON.stringify({ type: 'subscribed', jobId: subscribedJobId }));
                }
            } catch { /* ignore malformed */ }
        });

        ws.on('close', () => {
            if (subscribedJobId) {
                jobEvents.removeListener(`log:${subscribedJobId}`, logHandler);
                jobEvents.removeListener(`done:${subscribedJobId}`, doneHandler);
            }
        });
    });
}

module.exports = { attachWSS };
