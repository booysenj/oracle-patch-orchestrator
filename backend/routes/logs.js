const express = require('express');
const { getJobLogs } = require('../lib/job-runner');
const router = express.Router();

router.get('/:jobId', (req, res) => {
    const { since, limit } = req.query;
    res.json(getJobLogs(req.params.jobId, {
        since, limit: limit ? parseInt(limit) : 1000
    }));
});

module.exports = router;
