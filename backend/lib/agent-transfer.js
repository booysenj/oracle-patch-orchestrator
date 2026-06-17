// agent-transfer.js - Agent-side file transfer endpoint
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const os = require('os');

function setupAgentTransfer(app, verifyAgentSecret) {
    app.post('/api/agent/transfer', verifyAgentSecret, async (req, res) => {
        try {
            var destDir = req.headers['x-dest-path'] || '/u01/stage/patches';
            var filename = req.headers['x-filename'] || 'transfer_' + Date.now();
            var expectedHash = req.headers['x-checksum-sha256'] || null;
            var destFile = path.join(destDir, filename);

            fs.mkdirSync(destDir, { recursive: true });

            var tmpFile = path.join(os.tmpdir(), 'agent_upload_' + Date.now());
            var writeStream = fs.createWriteStream(tmpFile);
            var hash = crypto.createHash('sha256');
            var bytesReceived = 0;

            await new Promise(function(resolve, reject) {
                req.on('data', function(chunk) {
                    bytesReceived += chunk.length;
                    writeStream.write(chunk);
                    hash.update(chunk);
                });
                req.on('end', function() { writeStream.end(); resolve(); });
                req.on('error', reject);
                writeStream.on('error', reject);
            });

            var actualHash = hash.digest('hex');
            var checksumMatch = !expectedHash || actualHash === expectedHash;

            if (!checksumMatch) {
                fs.unlinkSync(tmpFile);
                return res.status(422).json({
                    status: 'error',
                    error: 'Checksum mismatch',
                    expected: expectedHash,
                    received: actualHash
                });
            }

            fs.renameSync(tmpFile, destFile);
            var stat = fs.statSync(destFile);

            console.log('[TRANSFER] Received ' + filename + ' -> ' + destFile + ' (' + stat.size + ' bytes, SHA256: ' + actualHash.substring(0,12) + '...)');

            res.json({
                status: 'ok',
                file: destFile,
                size: stat.size,
                checksumMatch: true,
                sha256: actualHash,
                hostname: os.hostname()
            });
        } catch (err) {
            console.error('[TRANSFER] Error:', err.message);
            res.status(500).json({ status: 'error', error: err.message });
        }
    });

    app.get('/api/agent/disk-space', verifyAgentSecret, function(req, res) {
        var targetPath = req.query.path || '/u01/stage';
        var execSync = require('child_process').execSync;
        try {
            var df = execSync('df -B1 ' + targetPath + ' | tail -1').toString().trim().split(/\s+/);
            res.json({
                filesystem: df[0],
                total: parseInt(df[1]),
                used: parseInt(df[2]),
                available: parseInt(df[3]),
                usePct: df[4],
                mountpoint: df[5]
            });
        } catch (err) {
            res.status(500).json({ error: err.message });
        }
    });
}

module.exports = { setupAgentTransfer };
