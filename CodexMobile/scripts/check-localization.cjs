// 检查自有 UI 的字面量入口及已登记词条；不扫描第三方终端实现或测试正文。
const fs = require('node:fs');
const path = require('node:path');
const { literals } = require('./lib/swift-literals.cjs');
const root = path.resolve(__dirname, '../CodexMobile');
const catalog = JSON.parse(fs.readFileSync(path.join(root, 'Localizable.xcstrings')));
const permissions = JSON.parse(fs.readFileSync(path.join(root, 'InfoPlist.xcstrings')));
const failures = [];
const project = fs.readFileSync(path.resolve(__dirname, '../CodexMobile.xcodeproj/project.pbxproj'), 'utf8');
for (const [name, phase] of [['AppLanguageTests.swift', 'CC9279F10CC29F0557B8C955'], ['LocalizationUITests.swift', '328D9BFFDCB2BC75D1E050D5']]) {
  const sources = project.match(new RegExp(`${phase} /\\* Sources \\*/ = \\{([\\s\\S]*?)\\n\\t\\t\\};`))?.[1];
  if (!sources?.includes(`/* ${name} in Sources */`)) failures.push(`test target does not compile ${name}`);
}
const labels = new Set(['Remodex', 'Codex', 'Git', 'Bridge', 'Windows', 'macOS', 'Liquid Glass', 'ssh', 'user@hostname', 'Ctrl-C', 'remodex/my-feature', 'feature-name', 'main', 'GPT-5.3-Codex']);
const formats = new Set(['git/%@', 'Remodex %@', 'P%@', 'A- %@ pt', 'A+ %@ pt', '\\u{00A0}%@']);
function values(value) {
  if (!value || typeof value !== 'object') return [];
  if (value.stringUnit) return [value.stringUnit];
  return Object.values(value).flatMap(values);
}
const placeholders = value => [...value.matchAll(/%(?:\d+\$)?(?:lld|ld|d|u|f|@)/g)].map(m => m[0]).sort().join(',');
for (const [name, resource] of [['Localizable', catalog], ['InfoPlist', permissions]]) {
  if (resource.sourceLanguage !== 'en') failures.push(`${name}: source language must be en`);
  for (const [key, item] of Object.entries(resource.strings)) {
    const en = values(item.localizations?.en), zh = values(item.localizations?.['zh-Hans']);
    if (!en.length || !zh.length) { failures.push(`${name}: missing language: ${key}`); continue; }
    for (const unit of [...en, ...zh]) {
      if (unit.state !== 'translated' || !unit.value) failures.push(`${name}: untranslated: ${key}`);
      if (placeholders(unit.value) !== placeholders(en[0].value)) failures.push(`${name}: placeholder mismatch: ${key}`);
    }
  }
}
function files(directory) {
  return fs.readdirSync(directory, { withFileTypes: true }).flatMap(entry => {
    if (entry.name === 'Vendor') return [];
    const file = path.join(directory, entry.name);
    return entry.isDirectory() ? files(file) : file.endsWith('.swift') ? [file] : [];
  });
}
for (const file of files(root)) {
  if (/Preview|Fixture/.test(path.basename(file))) continue;
  // #Preview 和明确的 DEBUG 预览样本不是发行界面文案。
  const text = fs.readFileSync(file, 'utf8').split('#Preview')[0];
  for (const item of literals(text)) {
    const before = text.slice(text.lastIndexOf('\n', item.start) + 1, item.start);
    if (!/\b(?:Text|Button|Label|Section|Picker|Toggle|TextField|SecureField|NavigationLink|Menu|ProgressView|ContentUnavailableView|navigationTitle|navigationBarTitle|accessibilityLabel|accessibilityHint|alert|confirmationDialog|help|L10n\.string|L10n\.format|L10n\.count)\(\s*$/.test(before)) continue;
    let key = item.parts.map(part => typeof part === 'string' ? part : '%@').join('');
    if (!/[A-Za-z\u4e00-\u9fff]/.test(key) || labels.has(key) || formats.has(key)) continue;
    try { key = JSON.parse('"' + key + '"'); } catch { /* Swift Unicode 转义由明确白名单处理。 */ }
    if (!catalog.strings[key]) failures.push(`${path.relative(root, file)}:${text.slice(0, item.start).split('\n').length}: missing catalog key: ${key}`);
  }
}
if (failures.length) { console.error(failures.join('\n')); process.exitCode = 1; }
else console.log(`localization_catalog_and_ui_literals_passed: ${Object.keys(catalog.strings).length} entries, 2 languages, ${Object.keys(permissions.strings).length} permissions`);
