const { spawn } = require('node:child_process');

// 必须在任何大型模块导入前安装父管道监听；此模块只依赖 Node 内建能力。
function supervise(script) {
  let child, stopping = false, bootstrap = '';
  const killGroup = signal => {
    if (!child?.pid) return;
    try { process.kill(-child.pid, signal); }
    catch (error) { if (error.code !== 'ESRCH') process.exitCode = 1; }
  };
  const stop = () => {
    if (stopping) return;
    stopping = true;
    clearTimeout(deadline);
    if (!child) { process.exit(0); return; }
    child.stdin.end(); killGroup('SIGTERM');
    const timer = setTimeout(() => killGroup('SIGKILL'), 2000); timer.unref();
  };
  const deadline = setTimeout(() => { console.error('[remodex] activation_required'); process.exit(1); }, 10000);
  process.stdin.on('end', stop); process.stdin.on('close', stop);
  process.on('SIGTERM', stop); process.on('SIGINT', stop);
  process.stdin.on('data', chunk => {
    if (stopping) return;
    if (child) { child.stdin.write(chunk); return; }
    bootstrap += chunk.toString('utf8');
    if (bootstrap.length > 16384) { console.error('[remodex] activation_failed'); process.exit(1); }
    if (!bootstrap.includes('\n')) return;
    try { JSON.parse(bootstrap.slice(0, bootstrap.indexOf('\n'))); }
    catch { console.error('[remodex] activation_failed'); process.exit(1); }
    clearTimeout(deadline);
    child = spawn(process.execPath, [script, 'worker'], { detached: true, stdio: ['pipe', 'inherit', 'inherit'], env: process.env });
    child.on('error', () => { console.error('[remodex] worker_spawn_failed'); process.exit(1); });
    child.on('exit', code => { killGroup('SIGKILL'); process.exit(code ?? 1); });
    child.stdin.on('error', stop);
    child.stdin.write(bootstrap); bootstrap = '';
  });
  process.stdin.resume();
}
module.exports = { supervise };
