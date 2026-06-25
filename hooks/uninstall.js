#!/usr/bin/env node
// Removes the status-bar hooks from every configured instance's settings.json.
// Leaves all other hooks intact.

const fs = require("fs");
const os = require("os");
const path = require("path");
const cp = require("child_process");

const home = os.homedir();
// Match the dir, not "update.js": the narrower marker used to orphan the lifecycle hooks.
const sbDir = path.join(home, ".claude", "statusbar");
const MARKER = sbDir;
const registryPath = path.join(sbDir, "instances.json");

function expandPath(p) {
  let s = String(p || "").trim();
  if (s === "~" || s.startsWith("~/")) s = path.join(home, s.slice(1));
  s = s.replace(/\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?/g, (m, name) => process.env[name] || m);
  return s;
}

// Tear down the desktop watcher LaunchAgent (best-effort; safe if absent).
const AGENT_LABEL = "com.local.claudestatusbar.watcher";
const agentPlist = path.join(home, "Library", "LaunchAgents", AGENT_LABEL + ".plist");
try { cp.execSync(`launchctl bootout gui/${process.getuid()}/${AGENT_LABEL}`, { stdio: "ignore" }); } catch {}
if (fs.existsSync(agentPlist)) { fs.rmSync(agentPlist); console.log("Removed desktop watcher LaunchAgent."); }
try { cp.execSync("pkill -x ClaudeStatusBar", { stdio: "ignore" }); } catch {}

// Collect the settings.json paths to clean: every configured instance, plus the default
// ~/.claude as a safety net (covers installs that predate the registry).
const settingsPaths = new Set([path.join(home, ".claude", "settings.json")]);
try {
  const registry = JSON.parse(fs.readFileSync(registryPath, "utf8"));
  for (const inst of registry.instances || []) {
    const cd = expandPath(inst.configDir);
    if (cd) settingsPaths.add(path.join(cd, "settings.json"));
  }
} catch {}

let cleaned = 0;
for (const settingsPath of settingsPaths) {
  if (!fs.existsSync(settingsPath)) continue;
  let settings;
  try { settings = JSON.parse(fs.readFileSync(settingsPath, "utf8")); } catch { continue; }
  for (const evt of Object.keys(settings.hooks || {})) {
    settings.hooks[evt] = (settings.hooks[evt] || [])
      .map((e) => ({ ...e, hooks: (e.hooks || []).filter((h) => !(h.command || "").includes(MARKER)) }))
      .filter((e) => (e.hooks || []).length > 0);
    if (settings.hooks[evt].length === 0) delete settings.hooks[evt];
  }
  fs.writeFileSync(settingsPath, JSON.stringify(settings, null, 2) + "\n");
  console.log("Removed status-bar hooks from", settingsPath);
  cleaned++;
}
if (!cleaned) console.log("No settings.json found; nothing to do.");
