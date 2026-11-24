// Run only against a fresh, signed-out test profile on this Mac.
import assert from 'node:assert/strict';
import { spawn, execFileSync } from 'node:child_process';
import { mkdir, mkdtemp, writeFile } from 'node:fs/promises';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { setTimeout as pause } from 'node:timers/promises';

const installed = resolve(process.argv[2]), scratch = resolve(process.argv[3]);
const { privatePipe, styleCodex } = await import(pathToFileURL(join(installed, 'Contents/Resources/controller.mjs')));
const cli = join(installed, 'Contents/MacOS/rainbow');
const bundle = execFileSync(cli, ['codex-path'], { encoding: 'utf8' }).trim();
const executable = execFileSync('/usr/libexec/PlistBuddy', ['-c', 'Print :CFBundleExecutable', join(bundle, 'Contents/Info.plist')], { encoding: 'utf8' }).trim();
const root = await mkdtemp(join(scratch, 'renderer-test-'));
const env = {
    HOME: process.env.HOME, USER: process.env.USER, PATH: '/usr/bin:/bin:/usr/sbin:/sbin',
    CODEX_HOME: join(root, 'codex'), CODEX_RAINBOW_STATE_DIR: join(root, 'colors'),
    CODEX_ELECTRON_USER_DATA_PATH: join(root, 'profile')
};
for (const key of ['CODEX_HOME', 'CODEX_ELECTRON_USER_DATA_PATH']) await mkdir(env[key], { mode: 0o700 });
const ids = Array.from({ length: 80 }, (_, i) => '018f0000-' + i.toString(16).padStart(4, '0') + '-7000-8000-000000000001');
await writeFile(join(env.CODEX_HOME, 'session_index.jsonl'), ids.map((id, i) => JSON.stringify({ id, thread_name: 'Example ' + i })).join('\n') + '\n');
const child = spawn(join(bundle, 'Contents/MacOS', executable), [
    '--remote-debugging-pipe', '--user-data-dir=' + env.CODEX_ELECTRON_USER_DATA_PATH
], { env, stdio: ['ignore', 'ignore', 'ignore', 'pipe', 'pipe'] });
const exited = new Promise(resolve => child.on('exit', resolve));
const pipe = privatePipe(child);
const styling = styleCodex(pipe, cli, env);
async function waitFor(check) {
    const end = Date.now() + 25000;
    while (Date.now() < end && !pipe.closed) {
        const value = await check();
        if (value) return value;
        await pause(150);
    }
    throw Error('Isolated renderer did not reach the expected state');
}
try {
    const target = await waitFor(async () => (await pipe.send('Target.getTargets')).targetInfos.find(t => t.type === 'page' && t.url === 'app://-/index.html'));
    const { sessionId } = await pipe.send('Target.attachToTarget', { targetId: target.targetId, flatten: true });
    const send = (method, params) => pipe.send(method, params, sessionId);
    const evaluate = async expression => {
        const reply = await send('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true });
        assert.ok(!reply.exceptionDetails, reply.exceptionDetails?.exception?.description || 'fixture evaluation failed');
        return reply.result.value;
    };
    const makeRows = async () => {
        await waitFor(() => evaluate('Boolean(document.body)'));
        const empty = await evaluate(`!document.querySelector('[data-app-action-sidebar-thread-row]')`);
        assert.equal(empty, true, 'Expected a signed-out isolated renderer');
        return evaluate(`(() => {
            const pane = document.createElement('div');
            pane.id = 'sample-sidebar';
            pane.style.cssText = 'position:fixed;z-index:2147483647;inset:30px auto auto 30px;width:300px;height:350px;overflow:auto;background:#232323;color:white;font:15px system-ui;padding:8px;border-radius:10px;';
            for (const [i,id] of ${JSON.stringify(ids)}.entries()) {
                const row = document.createElement('div'), label = document.createElement('span');
                row.setAttribute('data-app-action-sidebar-thread-row','');
                row.setAttribute('data-app-action-sidebar-thread-id','local:fixture:'+id);
                row.style.cssText = 'padding:8px;margin-bottom:2px;border-radius:6px;line-height:20px;';
                label.textContent = 'Example chat ' + (i + 1);
                row.append(label); pane.append(row);
            }
            document.body.append(pane);
            return pane.childElementCount;
        })()`);
    };
    const paints = () => evaluate("Array.from(document.querySelector('#sample-sidebar').children, row => getComputedStyle(row).backgroundImage)");
    assert.equal(await makeRows(), ids.length);
    const initial = await waitFor(async () => { const p = await paints(); return !p.includes('none') && new Set(p).size === 8 && p; });
    execFileSync(cli, ['set', 'turquoise', ids[0]], { env });
    await waitFor(async () => (await paints())[0] === initial[4]);
    const loaderId = (await send('Page.getFrameTree')).frameTree.frame.loaderId;
    await send('Page.reload');
    await waitFor(async () => (await send('Page.getFrameTree')).frameTree.frame.loaderId !== loaderId);
    await makeRows();
    await waitFor(async () => (await paints())[0] === initial[4]);
    await send('Page.bringToFront');
    await evaluate(`(() => {
        const pane = document.querySelector('#sample-sidebar'), rows = [...pane.children];
        const fills = rows.map(row => getComputedStyle(row).backgroundImage);
        const offsets = rows.map(row => row.firstChild.getBoundingClientRect().top - row.getBoundingClientRect().top);
        const result = {movingFrames:0, travel:0, drops:0, drift:0, samples:0};
        let previous = pane.scrollTop, running = true;
        function frame() {
            const top = pane.scrollTop, bounds = pane.getBoundingClientRect();
            if (top !== previous) { result.movingFrames++; result.travel += Math.abs(top-previous); }
            previous = top;
            rows.forEach((row,i) => {
                const rect = row.getBoundingClientRect();
                if (rect.bottom < bounds.top || rect.top > bounds.bottom) return;
                result.samples++;
                if (getComputedStyle(row).backgroundImage !== fills[i]) result.drops++;
                result.drift = Math.max(result.drift, Math.abs(row.firstChild.getBoundingClientRect().top - rect.top - offsets[i]));
            });
            if (running) requestAnimationFrame(frame);
        }
        frame();
        window.finishSample = () => { running=false; return result; };
    })()`);
    for (const distance of [-1400, 1100]) {
        await send('Input.synthesizeScrollGesture', { x: 140, y: 170, yDistance: distance, speed: 4200, gestureSourceType: 'mouse' });
        await pause(150);
    }
    const metrics = await evaluate('window.finishSample()');
    assert.ok(metrics.movingFrames >= 8 && metrics.travel > 800 && metrics.samples > 100, JSON.stringify(metrics));
    assert.equal(metrics.drops, 0);
    assert.ok(metrics.drift < 0.5);
    const png = await send('Page.captureScreenshot', { format: 'png', clip: {x:30,y:30,width:300,height:350,scale:1} });
    await writeFile(join(root, 'rows.png'), Buffer.from(png.data, 'base64'), { mode: 0o600 });
    console.log(JSON.stringify({ rows: ids.length, shades: new Set(initial).size, liveOverride: true, reload: true, ...metrics, screenshot:join(root,'rows.png') }));
} finally {
    await pipe.send('Browser.close').catch(() => {});
    await Promise.race([exited, pause(2000)]);
    if (child.exitCode === null && child.signalCode === null) child.kill('SIGTERM');
    await exited;
    await styling;
}
