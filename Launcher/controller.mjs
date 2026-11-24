import { execFile, spawn } from 'node:child_process';
import { stat, mkdir, rename, writeFile } from 'node:fs/promises';
import { homedir } from 'node:os';
import { dirname, join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { promisify } from 'node:util';
import { setTimeout as sleep } from 'node:timers/promises';

const run = promisify(execFile);
const localRenderer = url => /^app:\/\/-\/index\.html(?:[?#].*)?$/.test(url);

// Chromium's child-only debugging pipe carries NUL-delimited UTF-8 messages.
// Nothing listens on a port or accepts commands from another process.
export function privatePipe(child) {
    const input = child.stdio[3], output = child.stdio[4];
    const pending = new Map();
    let serial = 0, partial = '', closed = false;
    function close() {
        closed = true;
        for (const request of pending.values()) {
            clearTimeout(request.timer);
            request.reject(new Error('Codex closed the styling pipe'));
        }
        pending.clear();
    }
    child.once('error', close);
    child.once('exit', close);
    input.on('error', close);
    output.on('error', close);
    output.on('end', close);
    output.setEncoding('utf8');
    output.on('data', chunk => {
        const messages = (partial + chunk).split('\0');
        partial = messages.pop();
        for (const raw of messages) {
            const message = JSON.parse(raw);
            const request = pending.get(message.id);
            if (!request) continue;
            clearTimeout(request.timer);
            pending.delete(message.id);
            if (message.error) request.reject(new Error(request.method + ' was rejected'));
            else request.resolve(message.result);
        }
    });
    return {
        get closed() { return closed; },
        send(method, params = {}, sessionId) {
            if (closed) return Promise.reject(new Error('Codex is closed'));
            const id = ++serial;
            return new Promise((resolve, reject) => {
                const timer = setTimeout(() => {
                    pending.delete(id);
                    reject(new Error(method + ' timed out'));
                }, 5000);
                pending.set(id, { method, resolve, reject, timer });
                input.write(JSON.stringify({ id, method, params, sessionId }) + '\0');
            });
        }
    };
}

async function stamp(path) {
    try {
        const file = await stat(path, { bigint: true });
        return [file.ino, file.size, file.mtimeNs].join('/');
    } catch (error) {
        if (error.code === 'ENOENT') return 'absent';
        throw error;
    }
}

// Reading metadata and assigning a color is independent of DOM rendering and scrolling.
export async function styleCodex(pipe, cli, env = process.env, report = () => {}) {
    const index = join(env.CODEX_HOME || join(homedir(), '.codex'), 'session_index.jsonl');
    const colors = join(env.CODEX_RAINBOW_STATE_DIR || join(homedir(), 'Library/Application Support/Codex Rainbow'), 'colors.json');
    const pages = new Map();
    let signature, css, revision = 0;
    async function updatePalette() {
        const indexVersion = await stamp(index);
        if (indexVersion === 'absent') return;
        const version = indexVersion + ':' + await stamp(colors);
        if (version === signature) return;
        const options = { env, encoding: 'utf8', maxBuffer: 32 * 1024 * 1024, timeout: 15000 };
        let next;
        try {
            next = (await run(cli, ['sync-css'], options)).stdout;
            signature = version;
        } catch {
            // Existing assignments remain usable if folder metadata is busy or unavailable.
            next = (await run(cli, ['css'], options)).stdout;
        }
        if (next !== css) {
            css = next;
            revision++;
        }
    }
    async function updatePage(targetId) {
        let page = pages.get(targetId);
        if (!page) {
            const { sessionId } = await pipe.send('Target.attachToTarget', { targetId, flatten: true });
            page = { sessionId };
            pages.set(targetId, page);
        }
        const send = (method, params) => pipe.send(method, params, page.sessionId);
        const { frameTree: { frame } } = await send('Page.getFrameTree');
        if (!localRenderer(frame.url)) return;
        if (!page.enabled) {
            await send('DOM.enable');
            await send('CSS.enable');
            page.enabled = true;
        }
        if (frame.loaderId !== page.loaderId || !page.sheet) {
            const result = await send('CSS.createStyleSheet', { frameId: frame.id, forceNew: true });
            page.sheet = result.styleSheetId;
            page.loaderId = frame.loaderId;
            page.revision = undefined;
        }
        if (revision !== page.revision) {
            await send('CSS.setStyleSheetText', { styleSheetId: page.sheet, text: css });
            page.revision = revision;
        }
    }
    async function forget(id) {
        const page = pages.get(id);
        pages.delete(id);
        if (page) await pipe.send('Target.detachFromTarget', { sessionId: page.sessionId }).catch(() => {});
    }
    while (!pipe.closed) {
        try {
            await updatePalette().catch(() => {});
            const { targetInfos } = await pipe.send('Target.getTargets', { filter: [{ type: 'page' }] });
            const targets = new Set(targetInfos.filter(t => t.type === 'page' && localRenderer(t.url)).map(t => t.targetId));
            for (const id of pages.keys()) if (!targets.has(id)) await forget(id);
            if (css) for (const id of targets) {
                try { await updatePage(id); } catch { await forget(id); }
            }
            const applied = [...pages.values()].filter(page => page.revision === revision).length;
            await report(applied ? 'applied' : (css ? 'waiting-for-renderer' : 'waiting-for-palette'), applied);
        } catch { /* Renderer processes may be replaced or not yet ready. */ }
        if (!pipe.closed) await sleep(750);
    }
}

if (process.argv[1] && pathToFileURL(process.argv[1]).href === import.meta.url) {
    const [app, cli] = process.argv.slice(2);
    const flags = ['--remote-debugging-pipe'];
    if (process.env.CODEX_ELECTRON_USER_DATA_PATH) flags.push('--user-data-dir=' + process.env.CODEX_ELECTRON_USER_DATA_PATH);
    const child = spawn(app, flags, {
        cwd: homedir(), stdio: ['ignore', 'ignore', 'ignore', 'pipe', 'pipe']
    });
    const exit = new Promise(resolve => {
        child.once('error', () => resolve(1));
        child.once('exit', code => resolve(code ?? 1));
    });
    const state = process.env.CODEX_RAINBOW_STATE_DIR || join(homedir(), 'Library/Application Support/Codex Rainbow');
    const file = join(state, 'launcher-status.json');
    const temp = file + '.' + process.pid;
    let previous;
    async function report(status, windows = 0) {
        const record = JSON.stringify({ pid: child.pid, status, windows });
        if (record === previous) return;
        await mkdir(dirname(file), { mode: 0o700, recursive: true });
        await writeFile(temp, record + '\n', { mode: 0o600 });
        await rename(temp, file);
        previous = record;
    }
    await styleCodex(privatePipe(child), cli, process.env, report);
    process.exitCode = await exit;
    await report('closed').catch(() => {});
}
