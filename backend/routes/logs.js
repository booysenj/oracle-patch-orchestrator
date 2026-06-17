const express = require('express');
const { getJobLogs } = require('../lib/job-runner');
const router = express.Router();

router.get('/:jobId', (req, res) => {
    const { since, limit, offset } = req.query;
    res.json(getJobLogs(req.params.jobId, {
        since, limit: limit ? parseInt(limit) : 1000, offset: offset ? parseInt(offset) : 0
    }));
});

module.exports = router;
