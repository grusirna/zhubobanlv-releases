import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";
import { pipeline } from "node:stream/promises";
import { execFileSync } from "node:child_process";

const identity = JSON.parse(process.env.DIAGNOSTIC_TRANSFER_KEY ?? "null");
if (identity?.schemaVersion !== "streamer.diagnostic.key.v1" ||
    !/^\d+$/.test(identity.runId) || !/^\d+$/.test(identity.artifactId) ||
    identity.productVersion !== process.env.PRODUCT_VERSION ||
    !/^[a-f0-9]{40}$/.test(identity.sourceRevision) ||
    !/^[a-f0-9]{64}$/.test(identity.sha256) || !/^[a-f0-9]{64}$/.test(identity.encryptedSha256) ||
    !/^sha256:[a-f0-9]{64}$/.test(identity.artifactDigest) ||
    !Number.isSafeInteger(identity.sizeBytes) || identity.sizeBytes <= 0 || identity.sizeBytes > 1024 ** 3)
  throw new Error("Invalid diagnostic capability");
const root = path.resolve(process.env.RUNNER_TEMP, "exit-diagnostic-" + process.env.BUILD_RUN_ID);
fs.mkdirSync(root);
const metadata = JSON.parse(execFileSync("gh", ["api", "repos/grusirna/zhubobanlv-releases/actions/artifacts/" + identity.artifactId], { encoding: "utf8", windowsHide: true }));
if (metadata.workflow_run?.id !== Number(identity.runId) || metadata.expired ||
    metadata.digest !== identity.artifactDigest || !metadata.name.startsWith("candidate-" + identity.runId + "-"))
  throw new Error("Diagnostic artifact identity mismatch");
execFileSync("gh", ["run", "download", identity.runId, "--repo", "grusirna/zhubobanlv-releases", "--name", metadata.name, "--dir", root], { stdio: "pipe", windowsHide: true, timeout: 120_000 });
const encrypted = path.join(root, "diagnostic-installer.exe.enc");
const hash = async file => {
  const digest = crypto.createHash("sha256");
  for await (const chunk of fs.createReadStream(file)) digest.update(chunk);
  return digest.digest("hex");
};
if (await hash(encrypted) !== identity.encryptedSha256) throw new Error("Diagnostic ciphertext mismatch");
const key = Buffer.from(identity.key, "base64");
if (key.length !== 32) throw new Error("Invalid diagnostic key");
const decipher = crypto.createDecipheriv("aes-256-gcm", key, Buffer.from(identity.iv, "base64"));
decipher.setAuthTag(Buffer.from(identity.tag, "base64"));
const installer = path.join(root, "candidate.exe");
await pipeline(fs.createReadStream(encrypted), decipher, fs.createWriteStream(installer, { flags: "wx" }));
key.fill(0);
delete process.env.DIAGNOSTIC_TRANSFER_KEY;
if (fs.statSync(installer).size !== identity.sizeBytes || await hash(installer) !== identity.sha256)
  throw new Error("Diagnostic plaintext mismatch");
fs.writeFileSync(path.join(root, "identity.json"), JSON.stringify({ sourceRevision: identity.sourceRevision, productVersion: identity.productVersion, runId: identity.runId, artifactSha256: identity.sha256, diagnosticOnly: true }));
console.log(JSON.stringify({ status: "pass", diagnosticOnly: true }));
