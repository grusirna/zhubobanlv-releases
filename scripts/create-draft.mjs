import fs from 'node:fs';
import crypto from 'node:crypto';
import { execFileSync } from 'node:child_process';
const repo = 'grusirna/zhubobanlv-releases';
const { SOURCE_REVISION: sha, PRODUCT_VERSION: version, BUILD_RUN_ID: runId } = process.env;
if (!/^[a-f0-9]{40}$/.test(sha ?? '') || !/^\d+\.\d+\.\d+(-[A-Za-z0-9.-]+)?$/.test(version ?? '')) throw new Error('Invalid input');
const report = JSON.parse(fs.readFileSync('candidate/build-report.json','utf8'));
if (report.schemaVersion !== 'streamer.build.v1' || report.sourceRevision !== sha || report.productVersion !== version || report.runId !== runId || report.tests?.total <= 0 || report.tests.passed !== report.tests.total || report.tests.failed !== 0) throw new Error('Invalid build identity');
const names = ['install','dependencies','audit','lint','build','typecheck','tests','coverage','releaseTests','runtime','native','nativeTests','cjs','package','packageSecrets','backend','ui'];
for (const name of names) { const c=report.checks?.[name]; if (c?.status !== 'pass' || c.sourceRevision !== sha || c.productVersion !== version || c.runId !== runId) throw new Error('Incomplete build gate'); }
const filename = `ZhuBoBanLv-Setup-${version}-x64.exe`;
if (report.artifact?.filename !== filename || !/^[a-f0-9]{64}$/.test(report.artifact.sha256)) throw new Error('Invalid installer');
const file = `candidate/${filename}.enc`;
const envelope = JSON.parse(fs.readFileSync(`${file}.json`,'utf8'));
const hash=crypto.createHash('sha256'); for await (const bytes of fs.createReadStream(file)) hash.update(bytes);
if (envelope.sha256 !== report.artifact.sha256 || envelope.encryptedSha256 !== hash.digest('hex')) throw new Error('Invalid transfer');
const gh = args => execFileSync('gh', args, {encoding:'utf8',stdio:['ignore','pipe','pipe']});
const tag=`v${version}`;
const existing=JSON.parse(gh(['api',`repos/${repo}/releases?per_page=100`,'--paginate','--slurp'])).flat().find(release=>release.tag_name===tag);
const files = [file,`${file}.json`,'candidate/build-report.json','candidate/SHA256SUMS'];
if (existing) {
  const metadata = existing.assets.find(asset => asset.name === 'build-report.json');
  if (!metadata) throw new Error('Existing version has no verifiable build identity');
  const previous = JSON.parse(gh(['api',`repos/${repo}/releases/assets/${metadata.id}`,'-H','Accept: application/octet-stream']));
  if (previous.sourceRevision !== sha || previous.productVersion !== version || previous.artifact?.sha256 !== report.artifact.sha256) throw new Error('Same version has a different candidate; overwrite rejected');
  if (!existing.draft) throw new Error('Version is already published and immutable');
  for (const item of files) {
    const name=item.split('/').at(-1);
    const asset=existing.assets.find(asset=>asset.name===name);
    const digest=crypto.createHash('sha256'); for await (const bytes of fs.createReadStream(item)) digest.update(bytes);
    if (asset) {
      if (asset.digest!==`sha256:${digest.digest('hex')}` || asset.size!==fs.statSync(item).size) throw new Error('Existing draft material differs; overwrite rejected');
    } else gh(['release','upload',tag,'--repo',repo,item]);
  }
  console.log(JSON.stringify({status:'draft',version,sourceRevision:sha,runId:previous.runId}));
  process.exit(0);
}
fs.writeFileSync('candidate/draft-notes.md', `主播伴侣 ${version} 云端候选\n\n源码提交：${sha}\n运行：${runId}\n安装器 SHA-256：${report.artifact.sha256}\n自动测试：${report.tests.passed}/${report.tests.total}\n\n等待同哈希宿主六页面、安装升级及数据保留验收。候选附件经过加密，不能作为正式下载。\n`);
gh(['release','create',tag,'--repo',repo,'--target','main','--draft','--title',`主播伴侣 ${version}`,'--notes-file','candidate/draft-notes.md',...files]);
console.log(JSON.stringify({status:'draft',version,sourceRevision:sha,runId}));
