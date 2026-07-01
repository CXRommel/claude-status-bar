#!/usr/bin/env node
// Installs the status-bar hooks into each configured instance's settings.json (merging,
// never clobbering existing hooks) and copies the hook scripts to ~/.claude/statusbar/.
// Re-runnable: existing status-bar hooks are stripped before re-adding.
//
// Multi-instance: the set of instances is read from ~/.claude/statusbar/instances.json
// (seeded with just the "default" ~/.claude instance on first run). Each instance is a
// { name, configDir, label } entry; we wire the hooks into <configDir>/settings.json so
// every `claude-*` variant reports its own status.

const fs = require("fs");
const os = require("os");
const path = require("path");
const cp = require("child_process");

const home = os.homedir();
const sbDir = path.join(home, ".claude", "statusbar");
const MARKER = sbDir; // every hook command we add points inside this dir
const updateDest = path.join(sbDir, "update.js");
const lifecycleDest = path.join(sbDir, "lifecycle.js");
const registryPath = path.join(sbDir, "instances.json");
const node = process.execPath;

// Expand a leading ~ and any $ENV / ${ENV} references in a configured path.
function expandPath(p) {
  let s = String(p || "").trim();
  if (s === "~" || s.startsWith("~/")) s = path.join(home, s.slice(1));
  s = s.replace(/\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?/g, (m, name) => process.env[name] || m);
  return s;
}

// Derive an instance label from a config dir, matching the hook scripts' instanceLabel().
function labelFor(configDir) {
  const base = path.basename(String(configDir).replace(/[\/\\]+$/, "")).replace(/^\.+/, "");
  const safe = base.replace(/[^A-Za-z0-9_.-]/g, "").slice(0, 64);
  // The default ~/.claude dir maps to "default" (its CLAUDE_CONFIG_DIR is unset at runtime).
  return path.resolve(expandPath(configDir)) === path.join(home, ".claude") ? "default" : (safe || "default");
}

// Retire the old 0.0.2 background watcher LaunchAgent on upgrade (0.0.3+ self-quits).
const OLD_AGENT_LABEL = "com.local.claudestatusbar.watcher";
const oldAgentPlist = path.join(home, "Library", "LaunchAgents", OLD_AGENT_LABEL + ".plist");
try { cp.execSync(`launchctl bootout gui/${process.getuid()}/${OLD_AGENT_LABEL}`, { stdio: "ignore" }); } catch {}
if (fs.existsSync(oldAgentPlist)) { fs.rmSync(oldAgentPlist); console.log("Removed old desktop watcher LaunchAgent."); }

fs.mkdirSync(sbDir, { recursive: true });
fs.rmSync(path.join(sbDir, "watcher.sh"), { force: true });
// Retire pre-multi-session artifacts (single global state + empty liveness markers).
fs.rmSync(path.join(sbDir, "state.json"), { force: true });
fs.rmSync(path.join(sbDir, "sessions.d"), { recursive: true, force: true });
fs.copyFileSync(path.join(__dirname, "update.js"), updateDest);
fs.copyFileSync(path.join(__dirname, "lifecycle.js"), lifecycleDest);

// Seed the instance registry on first run with just the default ~/.claude instance.
// Users add more instances by duplicating the entry (one per CLAUDE_CONFIG_DIR alias).
// The "_comment" key is ignored by the registry parsers (app + this installer).
if (!fs.existsSync(registryPath)) {
  const seed = {
    _comment: "One entry per Claude instance — each a distinct CLAUDE_CONFIG_DIR. Duplicate the Default line to track an alias, e.g. { \"name\": \"Work\", \"configDir\": \"~/.claude-work\", \"label\": \"claude-work\" }. configDir accepts ~ and $ENV. Re-run this installer (or update the app) after editing so hooks reach the new dir.",
    instances: [{ name: "Default", configDir: "~/.claude", label: "default" }],
  };
  fs.writeFileSync(registryPath, JSON.stringify(seed, null, 2) + "\n");
  console.log("Seeded instance registry:", registryPath);
}

let registry = { instances: [] };
try { registry = JSON.parse(fs.readFileSync(registryPath, "utf8")); } catch (e) {
  console.error("Could not parse", registryPath, "- falling back to the default instance.", e.message);
}
let instances = Array.isArray(registry.instances) ? registry.instances : [];
if (!instances.length) instances = [{ name: "Default", configDir: "~/.claude", label: "default" }];

const cmd = (evt) => `${node} ${updateDest} ${evt}`;
const life = (evt) => `${node} ${lifecycleDest} ${evt}`;

const stripOurs = (arr) =>
  (arr || [])
    .map((entry) => ({
      ...entry,
      hooks: (entry.hooks || []).filter((h) => !(h.command || "").includes(MARKER)),
    }))
    .filter((entry) => (entry.hooks || []).length > 0);

function installInto(settingsPath) {
  fs.mkdirSync(path.dirname(settingsPath), { recursive: true });
  let settings = {};
  if (fs.existsSync(settingsPath)) {
    settings = JSON.parse(fs.readFileSync(settingsPath, "utf8"));
    const bak = settingsPath + ".bak-statusbar";
    if (!fs.existsSync(bak)) fs.copyFileSync(settingsPath, bak);
  }
  settings.hooks = settings.hooks || {};

  const addUnmatched = (evt, command) => {
    settings.hooks[evt] = stripOurs(settings.hooks[evt]);
    settings.hooks[evt].push({ hooks: [{ type: "command", command }] });
  };
  const addMatched = (evt, command) => {
    settings.hooks[evt] = stripOurs(settings.hooks[evt]);
    settings.hooks[evt].push({ matcher: "*", hooks: [{ type: "command", command }] });
  };

  // Status hooks (drive the animation/label)
  addUnmatched("UserPromptSubmit", cmd("prompt"));
  addMatched("PreToolUse", cmd("pre"));
  addMatched("PostToolUse", cmd("post"));
  addUnmatched("Notification", cmd("notify"));
  addMatched("PermissionRequest", cmd("permreq"));
  addUnmatched("Stop", cmd("stop"));
  // Lifecycle hooks (launch the app on open; the app quits itself when no longer needed)
  addUnmatched("SessionStart", life("start"));
  addUnmatched("SessionEnd", life("end"));

  fs.writeFileSync(settingsPath, JSON.stringify(settings, null, 2) + "\n");
}

for (const inst of instances) {
  const configDir = expandPath(inst.configDir);
  if (!configDir) continue;
  const settingsPath = path.join(configDir, "settings.json");
  const label = inst.label || labelFor(inst.configDir);
  try {
    installInto(settingsPath);
    console.log(`Installed hooks for instance "${inst.name || label}" (${label}) ->`, settingsPath);
  } catch (e) {
    console.error(`Skipped instance "${inst.name || label}" (${settingsPath}):`, e.message);
  }
}

console.log("Scripts:", updateDest, "and", lifecycleDest);
console.log("Registry:", registryPath);
