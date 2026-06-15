// transfer-api.js — Orchestrator-side API transfer method
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const http = require('http');
const https = require('https');
const { getDB } = require('./db');

// Compute SHA-256 of a file
function computeChecksum(filePath) {
    return new Promise((resolve, reject) => {
        const hash = crypto.createHash('sha256');
        const stream = fs.createReadStream(filePath);
        stream.on('data', chunk => hash.update(chunk));
        stream.on('end', () => resolve(hash.digest('hex')));
        stream.on('error', reject);
    });
}

// Stream file to agent via API
async function transferViaAgent(agentHost, agentPort, filePath, destPath, agentSecret, onProgress) {
    const filename = path.basename(filePath);
    const stat = fs.statSync(filePath);
    const totalBytes = stat.size;

    // Compute checksum first
    const checksum = await computeChecksum(filePath);

    return new Promise((resolve, reject) => {
        const options = {
            hostname: agentHost,
            port: agentPort || 4001,
            path: '/api/agent/transfer',
            method: 'POST',
            headers: {
                'X-Agent-Secret': agentSecret,
                'X-Checksum-SHA256': checksum,
                'X-Dest-Path': destPath,
                'X-Filename': filename,
                'Content-Type': 'application/octet-stream',
                'Content-Length': totalBytes
            }
        };

        const transport = options.port === 443 ? https : http;
        const req = transport.request(options, (res) => {
            let body = '';
            res.on('data', chunk => body += chunk);
            res.on('end', () => {
                try {
                    const result = JSON.parse(body);
                    if (res.statusCode >= 400) {
                        reject(new Error(result.error || `HTTP ${res.statusCode}`));
                    } else {
                        resolve(result);
                    }
                } catch (e) {
                    reject(new Error(`Invalid response: ${body}`));
                }
            });
        });

        req.on('error', reject);

        // Stream the file with progress tracking
        const readStream = fs.createReadStream(filePath);
        let bytesSent = 0;
        let lastPct = 0;

        readStream.on('data', (chunk) => {
            bytesSent += chunk.length;
            const pct = Math.round((bytesSent / totalBytes) * 100);
            if (pct !== lastPct && onProgress) {
                lastPct = pct;
                onProgress({ percent: pct, bytesSent, totalBytes });
            }
        });

        readStream.pipe(req);
    });
}

// Setup transfer API routes on the orchestrator
function setupTransferRoutes(app, authenticateToken, wsBroadcast) {
    const AGENT_SECRET = process.env.AGENT_SECRET || '';

    // Create a transfer job
    app.post('/api/transfers', authenticateToken, async (req, res) => {
        try {
            const { patch_id, vm_id, method, dest_path } = req.body;
            const db = getDB();

            // Get VM details
            const vm = db.prepare('SELECT * FROM vms WHERE id = ?').get(vm_id);
            if (!vm) return res.status(404).json({ error: 'VM not found' });

            // Get patch details
            const patch = db.prepare('SELECT * FROM patches WHERE id = ?').get(patch_id);
            if (!patch) return res.status(404).json({ error: 'Patch not found' });

            // Determine source file path from patch catalog
            const sourcePath = patch.patch_search_root || patch.gi_base_zip || patch.db_base_zip;
            if (!sourcePath) return res.status(400).json({ error: 'No source file path in patch catalog' });

            const transferId = 'xfer-' + Date.now() + '-' + Math.random().toString(36).substr(2, 6);
            const stagePath = dest_path || '/u01/stage/patches';
            const transferMethod = method || 'api';

            // Insert transfer record
            db.prepare(`INSERT INTO transfers (id, patch_id, vm_id, method, source_path, dest_path, status, created_by)
                        VALUES (?, ?, ?, ?, ?, ?, 'pending', ?)`).run(
                transferId, patch_id, vm_id, transferMethod, sourcePath, stagePath, req.user.username
            );

            // If API method, start async transfer
            if (transferMethod === 'api') {
                setImmediate(async () => {
                    try {
                        db.prepare("UPDATE transfers SET status = 'transferring', started_at = datetime('now') WHERE id = ?").run(transferId);
                        if (wsBroadcast) wsBroadcast({ type: 'transfer-status', transferId, status: 'transferring', percent: 0 });

                        const result = await transferViaAgent(
                            vm.ip_address || vm.hostname,
                            vm.agent_port || 4001,
                            sourcePath,
                            stagePath,
                            AGENT_SECRET,
                            (progress) => {
                                db.prepare("UPDATE transfers SET progress = ?, bytes_sent = ? WHERE id = ?")
                                    .run(progress.percent, progress.bytesSent, transferId);
                                if (wsBroadcast) wsBroadcast({
                                    type: 'transfer-progress', transferId,
                                    percent: progress.percent,
                                    bytesSent: progress.bytesSent,
                                    totalBytes: progress.totalBytes
                                });
                            }
                        );

                        db.prepare(`UPDATE transfers SET status = 'completed', progress = 100,
                                    bytes_sent = ?, checksum_ok = 1, completed_at = datetime('now')
                                    WHERE id = ?`).run(result.size, transferId);
                        if (wsBroadcast) wsBroadcast({ type: 'transfer-status', transferId, status: 'completed', percent: 100 });

                    } catch (err) {
                        db.prepare("UPDATE transfers SET status = 'failed', error = ? WHERE id = ?")
                            .run(err.message, transferId);
                        if (wsBroadcast) wsBroadcast({ type: 'transfer-status', transferId, status: 'failed', error: err.message });
                    }
                });
            }

            res.json({ id: transferId, status: 'pending', method: transferMethod });
        } catch (err) {
            res.status(500).json({ error: err.message });
        }
    });

    // List transfers
    app.get('/api/transfers', authenticateToken, (req, res) => {
        const db = getDB();
        const transfers = db.prepare(`
            SELECT t.*, v.hostname as vm_hostname, p.version as patch_version
            FROM transfers t
            LEFT JOIN vms v ON t.vm_id = v.id
            LEFT JOIN patches p ON t.patch_id = p.id
            ORDER BY t.created_at DESC
        `).all();
        res.json(transfers);
    });

    // Get single transfer
    app.get('/api/transfers/:id', authenticateToken, (req, res) => {
        const db = getDB();
        const transfer = db.prepare('SELECT * FROM transfers WHERE id = ?').get(req.params.id);
        if (!transfer) return res.status(404).json({ error: 'Transfer not found' });
        res.json(transfer);
    });

    // Cancel a transfer
    app.delete('/api/transfers/:id', authenticateToken, (req, res) => {
        const db = getDB();
        db.prepare("UPDATE transfers SET status = 'cancelled' WHERE id = ? AND status IN ('pending','transferring')")
            .run(req.params.id);
        res.json({ status: 'cancelled' });
    });
}

module.exports = { setupTransferRoutes, transferViaAgent, computeChecksum };
