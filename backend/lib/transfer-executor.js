// transfer-executor.js - Executes API-based file transfers to agents
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const http = require('http');

function computeChecksum(filePath) {
    return new Promise((resolve, reject) => {
        const hash = crypto.createHash('sha256');
        const stream = fs.createReadStream(filePath);
        stream.on('data', chunk => hash.update(chunk));
        stream.on('end', () => resolve(hash.digest('hex')));
        stream.on('error', reject);
    });
}

async function executeApiTransfer(db, transferId, agentSecret, wsBroadcast) {
    var t = db.prepare('SELECT t.*, p.patch_search_root, p.gi_base_zip, p.db_base_zip, p.file_size_bytes, p.file_name FROM patch_transfers t LEFT JOIN patch_versions p ON t.patch_id = p.id WHERE t.id = ?').get(transferId);
    if (!t) throw new Error('Transfer not found: ' + transferId);

    // Determine source file
    var sourcePath = t.source_path || t.patch_search_root || t.gi_base_zip || t.db_base_zip;
    if (!sourcePath) {
        db.prepare("UPDATE patch_transfers SET status='FAILED', error_message='No source file path found' WHERE id=?").run(transferId);
        return;
    }

    // Find actual file - if source is a directory, look for the patch file
    var actualFile = sourcePath;
    try {
        var stat = fs.statSync(sourcePath);
        if (stat.isDirectory()) {
            // Look for the patch file in the directory
            var files = fs.readdirSync(sourcePath).filter(function(f) { return f.endsWith('.zip'); });
            if (files.length === 0) throw new Error('No .zip files found in ' + sourcePath);
            if (files.length === 1) {
                actualFile = path.join(sourcePath, files[0]);
            } else {
                // Multiple zips - pick based on file_type
                var ft = t.file_type || 'ru_patch';
                if (ft === 'opatch') {
                    // OPatch is p6880880
                    var match = files.find(function(f) { return f.startsWith('p6880880'); });
                    actualFile = path.join(sourcePath, match || files[0]);
                } else {
                    // RU patch = largest zip (exclude OPatch p6880880)
                    var ruFiles = files.filter(function(f) { return !f.startsWith('p6880880'); });
                    if (ruFiles.length > 0) {
                        actualFile = path.join(sourcePath, ruFiles[0]);
                    } else {
                        actualFile = path.join(sourcePath, files[0]);
                    }
                }
            }
            console.log('[TRANSFER-API] Resolved file_type=' + (t.file_type||'ru_patch') + ' -> ' + path.basename(actualFile));
        }
    } catch (err) {
        db.prepare("UPDATE patch_transfers SET status='FAILED', error_message=? WHERE id=?").run('Source not found: ' + err.message, transferId);
        if (wsBroadcast) wsBroadcast({ type: 'transfer-update', id: transferId, status: 'FAILED', error: err.message });
        return;
    }

    var fileStat = fs.statSync(actualFile);
    var totalBytes = fileStat.size;
    var filename = path.basename(actualFile);

    // Update status to TRANSFERRING
    db.prepare("UPDATE patch_transfers SET status='TRANSFERRING', total_bytes=?, started_at=datetime('now') WHERE id=?").run(totalBytes, transferId);
    if (wsBroadcast) wsBroadcast({ type: 'transfer-update', id: transferId, status: 'TRANSFERRING', totalBytes: totalBytes });

    console.log('[TRANSFER-API] Starting: ' + filename + ' -> ' + t.target_host + ':' + t.target_stage_path + ' (' + Math.round(totalBytes/1048576) + ' MB)');

    try {
        // Compute checksum
        var checksum = await computeChecksum(actualFile);

        // Determine agent port (default 4001)
        var agentPort = 4001;
        var vm = db.prepare('SELECT agent_port FROM vms WHERE hostname = ? OR ip = ?').get(t.target_host, t.target_host);
        if (vm && vm.agent_port) agentPort = vm.agent_port;

        // Stream to agent
        var result = await new Promise(function(resolve, reject) {
            var options = {
                hostname: t.target_host,
                port: agentPort,
                path: '/api/agent/transfer',
                method: 'POST',
                headers: {
                    'X-Agent-Secret': agentSecret,
                    'X-Checksum-SHA256': checksum,
                    'X-Dest-Path': t.target_stage_path || '/u01/stage/patches/',
                    'X-Filename': filename,
                    'Content-Type': 'application/octet-stream',
                    'Content-Length': totalBytes
                },
                timeout: 3600000 // 1 hour timeout for large files
            };

            var req = http.request(options, function(res) {
                var body = '';
                res.on('data', function(chunk) { body += chunk; });
                res.on('end', function() {
                    try {
                        var parsed = JSON.parse(body);
                        if (res.statusCode >= 400) {
                            reject(new Error(parsed.error || 'HTTP ' + res.statusCode));
                        } else {
                            resolve(parsed);
                        }
                    } catch (e) {
                        reject(new Error('Invalid agent response: ' + body.substring(0, 200)));
                    }
                });
            });

            req.on('error', reject);
            req.on('timeout', function() { req.destroy(); reject(new Error('Transfer timed out')); });

            // Stream file with progress updates
            var readStream = fs.createReadStream(actualFile);
            var bytesSent = 0;
            var lastPctReported = 0;

            readStream.on('data', function(chunk) {
                bytesSent += chunk.length;
                var pct = Math.round((bytesSent / totalBytes) * 100);
                // Report progress every 5%
                if (pct >= lastPctReported + 5) {
                    lastPctReported = pct;
                    db.prepare("UPDATE patch_transfers SET bytes_transferred=? WHERE id=?").run(bytesSent, transferId);
                    if (wsBroadcast) wsBroadcast({ type: 'transfer-progress', id: transferId, percent: pct, bytesSent: bytesSent, totalBytes: totalBytes });
                    console.log('[TRANSFER-API] ' + filename + ' -> ' + t.target_host + ': ' + pct + '%');
                }
            });

            readStream.pipe(req);
        });

        // Success
        db.prepare("UPDATE patch_transfers SET status='STAGED', bytes_transferred=?, checksum_verified=1, completed_at=datetime('now') WHERE id=?")
            .run(totalBytes, transferId);
        if (wsBroadcast) wsBroadcast({ type: 'transfer-update', id: transferId, status: 'STAGED', percent: 100 });
        console.log('[TRANSFER-API] Completed: ' + filename + ' -> ' + t.target_host + ' (checksum: ' + (result.checksumMatch ? 'OK' : 'MISMATCH') + ')');

    } catch (err) {
        db.prepare("UPDATE patch_transfers SET status='FAILED', error_message=?, completed_at=datetime('now') WHERE id=?")
            .run(err.message, transferId);
        if (wsBroadcast) wsBroadcast({ type: 'transfer-update', id: transferId, status: 'FAILED', error: err.message });
        console.error('[TRANSFER-API] Failed: ' + filename + ' -> ' + t.target_host + ': ' + err.message);
    }
}

module.exports = { executeApiTransfer, computeChecksum };
