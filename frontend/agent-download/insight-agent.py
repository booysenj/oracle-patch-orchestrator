#!/usr/bin/env python3
import os, sys, time, json as json_mod, subprocess, threading, signal

try:
    import requests
except ImportError:
    import urllib.request, urllib.error
    class _Resp:
        def __init__(self, r):
            self.status_code = r.getcode()
            self._body = r.read().decode()
        def json(self):
            return json_mod.loads(self._body)
    class requests:
        @staticmethod
        def get(url, **kw):
            req = urllib.request.Request(url, headers=kw.get('headers', {}))
            return _Resp(urllib.request.urlopen(req, timeout=kw.get('timeout', 30)))
        @staticmethod
        def post(url, json=None, **kw):
            data = json_mod.dumps(json).encode() if json else None
            req = urllib.request.Request(url, data=data, headers={**kw.get('headers', {}), 'Content-Type': 'application/json'})
            return _Resp(urllib.request.urlopen(req, timeout=kw.get('timeout', 30)))

API_URL = os.environ.get('INSIGHT_API_URL', 'http://172.16.36.95:4000')
AGENT_TOKEN = os.environ.get('INSIGHT_AGENT_TOKEN', '')
HOSTNAME = os.environ.get('INSIGHT_HOSTNAME', os.uname()[1].split('.')[0])
POLL_INTERVAL = int(os.environ.get('INSIGHT_POLL_INTERVAL', '5'))
LOG_BATCH_SIZE = 5
LOG_FLUSH_INTERVAL = 2  # seconds — flush partial batches so UI stays live

HEADERS = {
    'Authorization': 'Bearer ' + AGENT_TOKEN,
    'Content-Type': 'application/json'
}

running = True

def signal_handler(sig, frame):
    global running
    print('[agent] Received signal %d, shutting down...' % sig)
    running = False

signal.signal(signal.SIGTERM, signal_handler)
signal.signal(signal.SIGINT, signal_handler)

def poll():
    try:
        r = requests.get(
            API_URL + '/api/agent/poll?hostname=' + HOSTNAME,
            headers=HEADERS, timeout=10
        )
        if r.status_code != 200:
            print('[agent] Poll error: HTTP %d' % r.status_code)
            return None
        data = r.json()
        if data.get('noJob'):
            return None
        return data
    except Exception as e:
        print('[agent] Poll failed: %s' % e)
        return None

def send_logs(job_id, lines):
    try:
        requests.post(
            API_URL + '/api/agent/' + job_id + '/logs',
            json={'lines': lines},
            headers=HEADERS, timeout=10
        )
    except Exception as e:
        print('[agent] Log send failed: %s' % e)

def complete_job(job_id, exit_code):
    try:
        requests.post(
            API_URL + '/api/agent/' + job_id + '/complete',
            json={'exitCode': exit_code},
            headers=HEADERS, timeout=10
        )
    except Exception as e:
        print('[agent] Complete failed: %s' % e)

def execute_job(job):
    job_id = job['jobId']
    script = job['scriptPath']
    phase_arg = job['phaseArg']
    dry_run = job.get('dryRun', False)
    node_role = job.get('nodeRole', '')

    env = os.environ.copy()
    if dry_run:
        env['DRYRUN'] = 'true'
    if node_role:
        env['INSIGHT_NODE_ROLE'] = node_role
    if job.get('env'):
        env.update(job['env'])

    cmd = 'bash %s %s' % (script, phase_arg)
    print('[agent] Executing: %s' % cmd)

    try:
        proc = subprocess.Popen(
            cmd, shell=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            env=env, bufsize=1, universal_newlines=True
        )

        log_buffer = []
        job_done = threading.Event()

        def stream_output(pipe, stream_name):
            for line in pipe:
                line = line.rstrip('\n')
                if line:
                    log_buffer.append({'stream': stream_name, 'line': line})
                    if len(log_buffer) >= LOG_BATCH_SIZE:
                        batch = log_buffer[:]
                        del log_buffer[:]
                        send_logs(job_id, batch)

        def flush_periodically():
            while not job_done.wait(timeout=LOG_FLUSH_INTERVAL):
                if log_buffer:
                    batch = log_buffer[:]
                    del log_buffer[:]
                    send_logs(job_id, batch)

        t_out = threading.Thread(target=stream_output, args=(proc.stdout, 'stdout'))
        t_err = threading.Thread(target=stream_output, args=(proc.stderr, 'stderr'))
        t_flush = threading.Thread(target=flush_periodically, daemon=True)
        t_out.start()
        t_err.start()
        t_flush.start()

        proc.wait()
        t_out.join()
        t_err.join()
        job_done.set()

        if log_buffer:
            send_logs(job_id, log_buffer)

        print('[agent] Job %s finished with exit code %d' % (job_id, proc.returncode))
        complete_job(job_id, proc.returncode)

    except Exception as e:
        print('[agent] Execution error: %s' % e)
        send_logs(job_id, [{'stream': 'stderr', 'line': 'Agent error: %s' % e}])
        complete_job(job_id, 1)

def main():
    print('[agent] Starting - hostname=%s api=%s poll=%ds' % (HOSTNAME, API_URL, POLL_INTERVAL))
    if not AGENT_TOKEN:
        print('[agent] ERROR: INSIGHT_AGENT_TOKEN not set')
        sys.exit(1)

    while running:
        job = poll()
        if job:
            execute_job(job)
        else:
            time.sleep(POLL_INTERVAL)

    print('[agent] Stopped.')

if __name__ == '__main__':
    main()
