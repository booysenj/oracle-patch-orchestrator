const { Client } = require('ssh2');
const fs = require('fs');
const EventEmitter = require('events');

const DEFAULT_KEY_PATH = process.env.SSH_KEY_PATH || '/root/.ssh/id_rsa';

class SSHManager extends EventEmitter {
    constructor() {
        super();
        this.connections = new Map();
    }

    exec(vmConfig, command) {
        const emitter = new EventEmitter();
        const conn = new Client();
        const keyPath = vmConfig.ssh_key_path || DEFAULT_KEY_PATH;

        let privateKey;
        try {
            privateKey = fs.readFileSync(keyPath);
        } catch (err) {
            process.nextTick(() => {
                emitter.emit('stderr', `ERROR: Cannot read SSH key at ${keyPath}: ${err.message}\n`);
                emitter.emit('close', 1);
            });
            return emitter;
        }

        conn.on('ready', () => {
            this.connections.set(vmConfig.id, conn);
            conn.exec(command, { pty: true }, (err, stream) => {
                if (err) {
                    emitter.emit('stderr', `SSH exec error: ${err.message}\n`);
                    emitter.emit('close', 1);
                    conn.end();
                    return;
                }
                stream.on('data', (data) => emitter.emit('stdout', data.toString()));
                stream.stderr.on('data', (data) => emitter.emit('stderr', data.toString()));
                stream.on('close', (code) => {
                    emitter.emit('close', code || 0);
                    this.connections.delete(vmConfig.id);
                    conn.end();
                });
            });
        });

        conn.on('error', (err) => {
            emitter.emit('stderr', `SSH connection error to ${vmConfig.hostname}: ${err.message}\n`);
            emitter.emit('close', 1);
            this.connections.delete(vmConfig.id);
        });

        conn.connect({
            host: vmConfig.ip,
            port: vmConfig.ssh_port || 22,
            username: vmConfig.ssh_user || 'root',
            privateKey,
            readyTimeout: 30000,
            keepaliveInterval: 10000
        });

        emitter._conn = conn;
        emitter._vmId = vmConfig.id;
        return emitter;
    }

    cancel(vmId) {
        const conn = this.connections.get(vmId);
        if (conn) { conn.end(); this.connections.delete(vmId); return true; }
        return false;
    }
}

module.exports = new SSHManager();
