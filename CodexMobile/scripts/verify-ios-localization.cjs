const fs = require('node:fs');
const path = require('node:path');
const { execFileSync } = require('node:child_process');
const app = process.argv[2];
if (!app || !fs.statSync(app).isDirectory()) throw new Error('app_bundle_required');
const plist = file => JSON.parse(execFileSync('plutil', ['-convert', 'json', '-o', '-', file], { encoding: 'utf8' }));
const info = plist(path.join(app, 'Info.plist'));
const pkg = require('../../package.json');
if (info.CFBundleShortVersionString !== pkg.version.split('-')[0] || String(info.CFBundleVersion) !== String(pkg.iosBuildNumber)) throw new Error('ios_version_mismatch');
if (info.RemodexReleaseVersion !== pkg.version || info.RemodexSourceSHA !== process.env.GITHUB_SHA) throw new Error('ios_source_identity_mismatch');
for (const [language, label] of [['en', 'Settings'], ['zh-Hans', '设置']]) {
  const folder = path.join(app, `${language}.lproj`);
  const strings = plist(path.join(folder, 'Localizable.strings'));
  if (strings.Settings !== label) throw new Error(`missing_compiled_translation:${language}`);
  const permissions = plist(path.join(folder, 'InfoPlist.strings'));
  for (const key of ['NSCameraUsageDescription', 'NSLocalNetworkUsageDescription', 'NSMicrophoneUsageDescription', 'NSPhotoLibraryUsageDescription', 'NSPhotoLibraryAddUsageDescription']) {
    if (typeof permissions[key] !== 'string' || !permissions[key].length) throw new Error(`missing_permission_translation:${language}:${key}`);
    if (language === 'zh-Hans' && !/[\u4e00-\u9fff]/.test(permissions[key])) throw new Error(`untranslated_permission:${key}`);
  }
}
console.log(`compiled_ios_localization_verified: ${pkg.version}, build ${pkg.iosBuildNumber}, ${info.RemodexSourceSHA}`);
