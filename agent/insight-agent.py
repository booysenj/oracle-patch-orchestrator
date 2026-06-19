#!/usr/bin/env python3
import os, sys, time, json as json_mod, subprocess, threading, signal, hashlib
from http.server import HTTPServer, BaseHTTPRequestHandler

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
AGENT_SECRET = os.environ.get('INSIGHT_AGENT_SECRET', '')
HOSTNAME = os.environ.get('INSIGHT_HOSTNAME', os.uname()[1].split('.')[0])
POLL_INTERVAL = int(os.environ.get('INSIGHT_POLL_INTERVAL', '5'))
FILE_RECV_PORT = int(os.environ.get('INSIGHT_FILE_RECV_PORT', '4001'))
LOG_BATCH_SIZE = 20

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

        def stream_output(pipe, stream_name):
            for line in pipe:
                line = line.rstrip('\n')
                if line:
                    log_buffer.append({'stream': stream_name, 'line': line})
                    if len(log_buffer) >= LOG_BATCH_SIZE:
                        batch = log_buffer[:]
                        del log_buffer[:]
                        send_logs(job_id, batch)

        t_out = threading.Thread(target=stream_output, args=(proc.stdout, 'stdout'))
        t_err = threading.Thread(target=stream_output, args=(proc.stderr, 'stderr'))
        t_out.start()
        t_err.start()

        proc.wait()
        t_out.join()
        t_err.join()

        if log_buffer:
            send_logs(job_id, log_buffer)

        print('[agent] Job %s finished with exit code %d' % (job_id, proc.returncode))
        complete_job(job_id, proc.returncode)

    except Exception as e:
        print('[agent] Execution error: %s' % e)
        send_logs(job_id, [{'stream': 'stderr', 'line': 'Agent error: %s' % e}])
        complete_job(job_id, 1)

class FileReceiveHandler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass  # suppress default access log

    def _send_json(self, code, obj):
        body = json_mod.dumps(obj).encode()
        self.send_response(code)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        if self.path != '/api/agent/transfer':
            self._send_json(404, {'error': 'Not found'})
            return

        # Validate secret
        secret = self.headers.get('X-Agent-Secret', '')
        if AGENT_SECRET and secret != AGENT_SECRET:
            self._send_json(403, {'error': 'Forbidden'})
            return

        dest_dir = self.headers.get('X-Dest-Path', '/tmp')
        filename = self.headers.get('X-Filename', 'transfer.bin')
        expected_checksum = self.headers.get('X-Checksum-SHA256', '')
        content_length = int(self.headers.get('Content-Length', 0))

        dest_path = os.path.join(dest_dir, filename)

        try:
            os.makedirs(dest_dir, exist_ok=True)
        except Exception as e:
            self._send_json(500, {'error': 'Cannot create dest dir: %s' % e})
            return

        sha256 = hashlib.sha256()
        try:
            with open(dest_path, 'wb') as f:
                remaining = content_length
                while remaining > 0:
                    chunk = self.rfile.read(min(65536, remaining))
                    if not chunk:
                        break
                    f.write(chunk)
                    sha256.update(chunk)
                    remaining -= len(chunk)
        except Exception as e:
            self._send_json(500, {'error': 'Write failed: %s' % e})
            return

        actual_checksum = sha256.hexdigest()
        checksum_match = (not expected_checksum) or (actual_checksum == expected_checksum)

        if not checksum_match:
            os.remove(dest_path)
            self._send_json(400, {'error': 'Checksum mismatch', 'expected': expected_checksum, 'actual': actual_checksum})
            return

        print('[agent] Received file: %s -> %s (%d bytes, checksum=%s)' % (
            filename, dest_path, content_length, 'OK' if checksum_match else 'MISMATCH'))
        self._send_json(200, {'ok': True, 'path': dest_path, 'checksumMatch': checksum_match})

    def do_GET(self):
        if self.path == '/health':
            self._send_json(200, {'ok': True, 'hostname': HOSTNAME})
        else:
            self._send_json(404, {'error': 'Not found'})


def start_file_server():
    server = HTTPServer(('0.0.0.0', FILE_RECV_PORT), FileReceiveHandler)
    t = threading.Thread(target=server.serve_forever, daemon=True)
    t.start()
    print('[agent] File receiver listening on port %d' % FILE_RECV_PORT)


def main():
    print('[agent] Starting - hostname=%s api=%s poll=%ds' % (HOSTNAME, API_URL, POLL_INTERVAL))
    if not AGENT_TOKEN:
        print('[agent] ERROR: INSIGHT_AGENT_TOKEN not set')
        sys.exit(1)

    start_file_server()

    while running:
        job = poll()
        if job:
            execute_job(job)
        else:
            time.sleep(POLL_INTERVAL)

    print('[agent] Stopped.')

if __name__ == '__main__':
    main()
