// pnpm deploy 的根包自引用可能仍指向源码；移除这个不参与运行时解析的生成链接，
// 再拒绝任何悬空或逃逸到工作区的依赖链接。仅接受显式生成物目录。
const fs = require('node:fs');
const path = require('node:path');
if (!process.argv[2]) throw new Error('Missing generated Bridge bundle directory');
const root = fs.realpathSync(process.argv[2]);
if (root === path.resolve(__dirname, '../../phodex-bridge')) throw new Error('Not a generated bundle');
const manifest = JSON.parse(fs.readFileSync(path.join(root, 'package.json'), 'utf8'));
if (manifest.name !== 'remodex') throw new Error('Unexpected bundle package');
const selfLink = path.join(root, 'node_modules/.pnpm/node_modules/remodex');
try {
  if (!fs.lstatSync(selfLink).isSymbolicLink()) throw new Error('Unexpected root self-reference');
  fs.unlinkSync(selfLink);
} catch (error) {
  if (error.code !== 'ENOENT') throw error;
}
function check(directory) {
  for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
    const candidate = path.join(directory, entry.name);
    if (entry.isSymbolicLink()) {
      const target = fs.realpathSync(candidate);
      if (!target.startsWith(root + path.sep)) throw new Error('Dependency escapes bundle: ' + path.relative(root, candidate));
    } else if (entry.isDirectory()) check(candidate);
  }
}
check(root);
require(path.join(root, 'src'));
require(require.resolve('@remodex/protocol', { paths: [root] }));
console.log('Bridge bundle dependencies verified');
