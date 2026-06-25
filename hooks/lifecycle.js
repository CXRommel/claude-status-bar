#!/usr/bin/env node
// SessionStart/SessionEnd: launch the app, and track sessions as one file per session id
// in this instance's sessions.d/ (race-free; the app quits itself). Rationale + history in CLAUDE.md.
// Usage: node lifecycle.js <start|end>   (hook JSON, incl. session_id, arrives on stdin)
//
// Multi-instance: sessions and state are namespaced per Claude config dir under
// ~/.claude/statusbar/instances/<label>/ so concurrent instances are tracked independently.

const fs = require("fs");
const os = require("os");
const path = require("path");
const cp = require("child_process");

const BUNDLE_ID = "com.local.claudestatusbar";
const EXEC = "ClaudeStatusBar";
const root = path.join(os.homedir(), ".claude", "statusbar");

// Instance label = sanitized basename of CLAUDE_CONFIG_DIR, or "default" (see update.js).
function instanceLabel() {
  const cfg = (process.env.CLAUDE_CONFIG_DIR || "").trim();
  if (cfg) {
    const base = path.basename(cfg.replace(/[\/\\]+$/, "")).replace(/^\.+/, "");
    const safe = base.replace(/[^A-Za-z0-9_.-]/g, "").slice(0, 64);
    if (safe) return safe;
  }
  return "default";
}

const label = instanceLabel();
const dir = path.join(root, "instances", label);
const sessDir = path.join(dir, "sessions.d");
const statePath = path.join(dir, "state.json");
const event = process.argv[2];

fs.mkdirSync(sessDir, { recursive: true });

const running = () => { try { cp.execSync(`pgrep -x ${EXEC}`, { stdio: "ignore" }); return true; } catch { return false; } };
const safeId = (s) => String(s || "").replace(/[^A-Za-z0-9_.-]/g, "").slice(0, 64) || "unknown";

// Reset a frozen animation when its OWNING session ends/resumes (force-quit fires SessionEnd
// but no Stop). The session-id gate is load-bearing: warmup-churn bursts must not clear a live
// turn. Full rationale in CLAUDE.md.
function clearStaleState(id) {
  try {
    const prev = JSON.parse(fs.readFileSync(statePath, "utf8"));
    if (safeId(prev.sessionId) !== id) return;
    if (!["thinking", "tool", "permission"].includes(prev.state)) return;
    const out = { ...prev, state: "idle", label: "", startedAt: 0, ts: Math.floor(Date.now() / 1000) };
    const tmp = statePath + "." + process.pid + ".tmp";
    fs.writeFileSync(tmp, JSON.stringify(out));
    fs.renameSync(tmp, statePath);
  } catch {}
}

let input = "", done = false;
process.stdin.on("data", (d) => (input += d));
process.stdin.on("end", () => run());
process.stdin.on("error", () => run());
setTimeout(run, 1000); // hooks always pipe stdin, but never hang the session

function run() {
  if (done) return; done = true;
  let id = "";
  try { id = JSON.parse(input).session_id; } catch {}
  id = safeId(id);

  if (event === "start") {
    // If the app isn't running, any leftover session files (across ALL instances) are stale
    // (e.g. a prior crash) — clear them so the count starts honest.
    if (!running()) {
      try {
        const instancesDir = path.join(root, "instances");
        for (const inst of fs.readdirSync(instancesDir)) {
          const sd = path.join(instancesDir, inst, "sessions.d");
          try { for (const f of fs.readdirSync(sd)) fs.rmSync(path.join(sd, f), { force: true }); } catch {}
        }
      } catch {}
    }
    try { fs.writeFileSync(path.join(sessDir, id), ""); } catch {}
    clearStaleState(id);
    cp.spawn("open", ["-g", "-b", BUNDLE_ID], { stdio: "ignore", detached: true }).unref();
  } else if (event === "end") {
    try { fs.rmSync(path.join(sessDir, id), { force: true }); } catch {}
    clearStaleState(id);
  }
  process.exit(0);
}
