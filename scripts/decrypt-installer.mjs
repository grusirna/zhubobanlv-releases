import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";
import { pipeline } from "node:stream/promises";
import { Readable } from "node:stream";
import { execFileSync } from "node:child_process";
import { pathToFileURL } from "node:url";

const inputs = JSON.parse(process.env.INSTALLER_TRANSFER_INPUTS ?? "null");
if (inputs?.schemaVersion !== "streamer.installer.inputs.v1") throw new Error("Invalid installer inputs");
const repo = "grusirna/zhubobanlv-releases";
const gh = args => JSON.parse(execFileSync("gh", args, { encoding: "utf8", windowsHide: true, timeout: 120_000 }));
const root = path.resolve(process.env.RUNNER_TEMP, "installer-" + process.env.BUILD_RUN_ID);
fs.mkdirSync(root);
const hash = async file => {
  const digest = crypto.createHash("sha256");
  for await (const chunk of fs.createReadStream(file)) digest.update(chunk);
  return digest.digest("hex");
};
for (const [kind, item] of [["candidate", inputs.candidate], ["baseline", inputs.baseline]]) {
  if (!item || !/^[a-f0-9]{64}$/.test(item.sha256) || !/^[a-f0-9]{64}$/.test(item.encryptedSha256) ||
      !Number.isSafeInteger(item.sizeBytes) || item.sizeBytes <= 0 || item.sizeBytes > 1024 ** 3 ||
      !/^\d+\.\d+\.\d+$/.test(item.productVersion) ||
      !/^[-a-zA-Z0-9.]+\.enc$/.test(item.encryptedFilename) ||
      (kind === "candidate" && item.productVersion !== process.env.PRODUCT_VERSION) ||
      (kind === "baseline" && item.productVersion !== "0.1.14") ||
      item.encryptedFilename !== (kind === "candidate" ? `ZhuBoBanLv-Setup-${item.productVersion}-x64.exe.enc` : "acceptance-baseline-0.1.14.exe.enc")) throw new Error("Invalid installer capability");
  const folder = path.join(root, kind);
  fs.mkdirSync(folder);
  if (kind === "candidate") {
    if (!/^\d+$/.test(item.artifactId) || !/^\d+$/.test(item.runId)) throw new Error("Invalid candidate artifact input");
    const metadata = gh(["api", `repos/${repo}/actions/artifacts/${item.artifactId}`]);
    if (metadata.workflow_run?.id !== Number(item.runId) || metadata.expired || metadata.digest !== item.artifactDigest ||
        !metadata.name.startsWith("candidate-" + item.runId + "-")) throw new Error("Candidate artifact identity mismatch");
    execFileSync("gh", ["run", "download", item.runId, "--repo", repo, "--name", metadata.name, "--dir", folder], { stdio: "pipe", windowsHide: true, timeout: 180_000 });
  } else {
    if (!/^\d+$/.test(item.releaseId) || !/^\d+$/.test(item.assetId)) throw new Error("Invalid baseline asset input");
    const url = new URL(item.downloadURL);
    const expiry = Date.parse(item.downloadExpiresAt);
    if (url.protocol !== "https:" || url.username || url.password ||
        !(url.hostname === "release-assets.githubusercontent.com" || url.hostname.endsWith(".blob.core.windows.net")) ||
        !Number.isFinite(expiry) || expiry <= Date.now() || expiry > Date.now() + 2 * 3600_000)
      throw new Error("Invalid single-asset download capability");
    const response = await fetch(url, { redirect: "error", signal: AbortSignal.timeout(180_000) });
    if (response.status !== 200 || Number(response.headers.get("content-length")) !== item.sizeBytes)
      throw new Error("Baseline encrypted download failed");
    await pipeline(Readable.fromWeb(response.body), fs.createWriteStream(path.join(folder, item.encryptedFilename), { flags: "wx" }));
  }
  const encrypted = path.join(folder, item.encryptedFilename);
  if (await hash(encrypted) !== item.encryptedSha256) throw new Error("Installer ciphertext mismatch");
  const key = Buffer.from(item.key, "base64"), iv = Buffer.from(item.iv, "base64"), tag = Buffer.from(item.tag, "base64");
  if (key.length !== 32 || iv.length !== 12 || tag.length !== 16) throw new Error("Invalid bounded decryption key");
  const decipher = crypto.createDecipheriv("aes-256-gcm", key, iv);
  decipher.setAuthTag(tag);
  const installer = path.join(folder, `ZhuBoBanLv-Setup-${item.productVersion}-x64.exe`);
  await pipeline(fs.createReadStream(encrypted), decipher, fs.createWriteStream(installer, { flags: "wx" }));
  key.fill(0);
  if (fs.statSync(installer).size !== item.sizeBytes || await hash(installer) !== item.sha256) throw new Error("Installer plaintext mismatch");
}
const report = JSON.parse(fs.readFileSync(path.join(root, "candidate/build-report.json"), "utf8"));
const { validateBuildReport } = await import(pathToFileURL(path.join(process.env.INSTALLER_TOOL_ROOT, "scripts/release-gates.mjs")));
validateBuildReport(report, { sourceRevision: inputs.candidate.sourceRevision, productVersion: process.env.PRODUCT_VERSION, runId: inputs.candidate.buildRunId });
if (report.artifact.sha256 !== inputs.candidate.sha256 || report.artifact.sizeBytes !== inputs.candidate.sizeBytes)
  throw new Error("Installer differs from the passed build report");
fs.mkdirSync(path.join(root, "results"));
fs.writeFileSync(path.join(root, "results/installer-identity.json"), JSON.stringify({ sourceRevision: report.sourceRevision, productVersion: report.productVersion, buildRunId: report.runId, artifactSha256: report.artifact.sha256, toolRevision: process.env.SOURCE_REVISION, workflowRunId: process.env.GITHUB_RUN_ID }));
delete process.env.INSTALLER_TRANSFER_INPUTS;
console.log(JSON.stringify({ status: "pass", phase: "installer-inputs" }));
