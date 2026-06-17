const express = require('express');
const { v4: uuidv4 } = require('uuid');
const { getDB } = require('../lib/db');
const { jobEvents } = require('../lib/job-runner');
const router = express.Router();

const AGENT_SECRET = process.env.AGENT_SECRET || 'change-me';

function authenticateAgent(req, res, next) {
    const auth = req.headers.authorization;
    var expected = 'Bearer ' + AGENT_SECRET;
    if (auth !== expected) {
        return res.status(401).json({ error: 'Invalid agent token' });
    }
    next();
}

router.use(authenticateAgent);

router.get('/poll', (req, res) => {
    var hostname = req.query.hostname;
    if (hostname === undefined) return res.status(400).json({ error: 'hostname required' });

    const db = getDB();
    const vm = db.prepare('SELECT * FROM vms WHERE hostname = ?').get(hostname);
    if (vm === undefined) return res.status(404).json({ error: 'VM not found' });

    // Record heartbeat so dashboard can show agent online/offline status
    db.prepare(`UPDATE vms SET agent_last_seen = datetime('now') WHERE id = ?`).run(vm.id);

    const job = db.prepare(
        'SELECT j.*, v.script_path, v.node_role FROM jobs j JOIN vms v ON j.vm_id = v.id WHERE j.vm_id = ? AND j.status = ? ORDER BY j.created_at ASC LIMIT 1'
    ).get(vm.id, 'queued');

    if (job === undefined) return res.json({ noJob: true });

    db.prepare(
        'UPDATE jobs SET status = ?, started_at = datetime(?) WHERE id = ?'
    ).run('running', 'now', job.id);

    var phaseArg = job.phase;
    const needsDbName = ['db_switch', 'db_rollback', 'db_switch_scheduled', 'db_upgrade_upgrade', 'db_upgrade_rollback'];
    if (needsDbName.indexOf(job.operation) >= 0 && job.db_unique_name) {
        phaseArg = job.phase + ' ' + job.db_unique_name;
    }

    var env = {};
    if (vm.old_gi_home) env.OLD_GI_HOME = vm.old_gi_home;
    if (vm.new_gi_home) env.NEW_GI_HOME = vm.new_gi_home;
    if (vm.old_db_home) env.OLD_DB_HOME = vm.old_db_home;
    if (vm.new_db_home) env.NEW_DB_HOME = vm.new_db_home;

    if (vm.target_patch_version_id) {
        const pv = db.prepare('SELECT * FROM patch_versions WHERE id = ?').get(vm.target_patch_version_id);
        if (pv) {
            if (pv.gi_base_zip) env.GI_BASE_ZIP = pv.gi_base_zip;
            if (pv.db_base_zip) env.DB_BASE_ZIP = pv.db_base_zip;
            if (pv.opatch_zip) env.OPATCH_ZIP = pv.opatch_zip;
            if (pv.patch_search_root) env.PATCH_SEARCH_ROOTS_ENV = pv.patch_search_root;
            if (pv.new_gi_home) env.NEW_GI_HOME = pv.new_gi_home;
            if (pv.new_db_home) env.NEW_DB_HOME = pv.new_db_home;
        }
    }

    res.json({
        jobId: job.id,
        operation: job.operation,
        phase: job.phase,
        scriptPath: job.script_path,
        phaseArg: phaseArg,
        dryRun: job.dry_run,
        nodeRole: job.node_role,
        stagePath: vm.stage_path || null,
        env: env
    });
});

router.post('/:jobId/logs', (req, res) => {
    var jobId = req.params.jobId;
    var lines = req.body.lines;
    if (lines === undefined || lines.length === undefined) return res.status(400).json({ error: 'lines array required' });

    const db = getDB();
    const stmt = db.prepare('INSERT INTO job_logs (job_id, stream, line) VALUES (?, ?, ?)');
    const reportStmt = db.prepare(
        'INSERT INTO patch_reports (id, job_id, hostname, operation, subject, result, html_content) VALUES (?, ?, ?, ?, ?, ?, ?)'
    );

    const insertBatch = db.transaction(function(items) {
        for (var i = 0; i < items.length; i++) {
            var line = items[i].line || '';

            // Intercept [HTML_REPORT] lines — store as a patch report, skip from log view
            if (line.startsWith('[HTML_REPORT] ')) {
                try {
                    var payload = line.slice('[HTML_REPORT] '.length);
                    var pipeIdx = payload.indexOf('|');
                    var subject = pipeIdx >= 0 ? payload.slice(0, pipeIdx) : 'Report';
                    var b64 = pipeIdx >= 0 ? payload.slice(pipeIdx + 1) : payload;
                    var html = Buffer.from(b64, 'base64').toString('utf8');
                    var job = db.prepare('SELECT j.*, v.hostname FROM jobs j LEFT JOIN vms v ON j.vm_id = v.id WHERE j.id = ?').get(jobId);
                    var result = subject.toLowerCase().includes('fail') ? 'failed'
                               : subject.toLowerCase().includes('incomplete') ? 'failed' : 'success';
                    reportStmt.run(uuidv4(), jobId, job ? job.hostname : null, job ? job.operation : null, subject, result, html);
                } catch(e) {
                    console.error('[agent] Failed to store HTML report:', e.message);
                }
                continue; // don't add to job_logs
            }

            stmt.run(jobId, items[i].stream || 'stdout', line);
            jobEvents.emit('log:' + jobId, {
                stream: items[i].stream || 'stdout',
                line: line,
                ts: new Date().toISOString()
            });
        }
    });
    insertBatch(lines);
    res.json({ ok: true, count: lines.length });
});

router.post('/:jobId/complete', (req, res) => {
    var jobId = req.params.jobId;
    var exitCode = req.body.exitCode;

    const db = getDB();
    var status = exitCode === 0 ? 'success' : 'failed';
    db.prepare(
        'UPDATE jobs SET status = ?, exit_code = ?, finished_at = datetime(?) WHERE id = ?'
    ).run(status, exitCode, 'now', jobId);
    jobEvents.emit('done:' + jobId, { status: status, exitCode: exitCode });
    res.json({ ok: true, status: status, exitCode: exitCode });
});

module.exports = router;
