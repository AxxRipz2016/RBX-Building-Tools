import fs from "fs";
import path from "path";

const root = path.resolve(".");
const loaderPath = path.join(root, "Launcher/RemoteLoader.lua");
const corePath = path.join(root, "Core/init.lua");

// Extract Lua helper blocks from RemoteLoader (minimal mirror for Core/init pipeline)
let raw = fs.readFileSync(corePath, "utf8");

function isModern(s) {
  return (
    s.includes("existing:Destroy(") &&
    s.includes("function Core.EnsureUI") &&
    s.includes("__bt_equip_guard") &&
    s.includes("IsBuildingToolModule")
  );
}

function patchCoreReturn(s) {
  return s.replace(/return getfenv\(0\)/g, "return (_G.Core or Core)");
}

function applyCoreEquipSafetyPatches(s) {
  s = s.replace(
    /BuildingToolModule:Equip\(\);/g,
    `if type(BuildingToolModule) == "table" and type(BuildingToolModule.Equip) == "function" then
\t\tlocal __bt_ok, __bt_err = pcall(function()
\t\t\tBuildingToolModule:Equip()
\t\tend)
\t\tif not __bt_ok then
\t\t\twarn("[BT] Equip failed:", __bt_err)
\t\tend
\tend`
  );
  s = s.replace(
    /EquipTool\(initialTool\);/g,
    `do
\tlocal __bt_t = initialTool
\tif type(__bt_t) ~= "table" or type(__bt_t.Equip) ~= "function" then
\t\t__bt_t = (type(Core) == "table" and Core.__bt_defaultMove) or nil
\tend
\tif type(__bt_t) == "table" and type(__bt_t.Equip) == "function" then
\t\tEquipTool(__bt_t)
\telse
\t\twarn("[BT] Enable: Move недоступен, Equip пропущен")
\tend
end`
  );
  return s;
}

function patchCoreUiExports(s) {
  if (s.includes("Core.ToolChanged = ToolChanged")) return s;
  return s.replace(
    /(ToolChanged = Signal\.new\(\)\n)/,
    "$1Core.ToolChanged = ToolChanged\nCore.Mode = Mode\n"
  );
}

function applyMinimalCoreInitRewrites(s) {
  if (!s.includes("Core.SyncAPI = SyncAPI")) {
    s = s.replace(
      "SyncAPI = Tool.SyncAPI;",
      "SyncAPI = Tool.SyncAPI;\nCore.SyncAPI = SyncAPI;"
    );
  }
  s = patchCoreReturn(s);
  s = s.replace(
    /Tool\.Equipped:Connect\(Enable\);/,
    "Tool.Equipped:Connect(function()\n\t\tEnable(Player:GetMouse())\n\tend);"
  );
  s = s.replace(/UI\.Parent = script;/g, "UI.Parent = nil; UI.Enabled = false;");
  if (!s.includes("Mode ~= 'Tool' or (Player.Character")) {
    s = s.replace(
      /(UI\.Parent = UIContainer;)/,
      "if Mode ~= 'Tool' or (Player.Character and Tool.Parent == Player.Character) then\n\t\tUI.Parent = UIContainer;\n\t\tUI.Enabled = true;\n\tend;"
    );
  }
  if (!s.includes("Core.UI = UI\n\tUI.Parent = nil")) {
    s = s.replace(/(Core\.UI = UI\n)/, "$1\tUI.Parent = nil;\n\tUI.Enabled = false;\n");
  }
  s = applyCoreEquipSafetyPatches(s);
  s = patchCoreUiExports(s);
  return s;
}

function patchCoreInitRequires(s) {
  for (const child of ["Security", "History", "Selection", "Targeting"]) {
    const via = `require(Tool:WaitForChild('Core'):WaitForChild('${child}'))`;
    s = s.replace(new RegExp(`${child} = require\\(script\\.${child}\\)`, "g"), `${child} = ${via}`);
    s = s.replace(new RegExp(`require\\(script\\.${child}\\)`, "g"), via);
  }
  return s;
}

const MODULE_ENV_PREAMBLE =
  'local require = (_G.__bt_require or __bt_require)\n' +
  'local script = (_G.__bt_script or (typeof(script) == "Instance" and script) or __bt_script)\n';

function patchRemoteSourceModern(s) {
  if (isModern(s)) return s;
  return s; // legacy omitted in this test unless --legacy flag
}

function rewriteForModuleEnv(s) {
  s = MODULE_ENV_PREAMBLE + s.replace(/^local script = [^\n]+\n/, "local script = Tool:WaitForChild('Core')\n");
  s = s.replace(/^local Core = getfenv\(0\)\r?\n?/, "local Core = (_G.Core or Core)\n");
  s = s.replace(/getfenv\s*\(\s*0\s*\)/g, "Core");
  s = s.replace(/Tool = script\.Parent;/g, "Tool = _G.__bt_tool or Tool;");
  s = patchCoreInitRequires(s);
  s = s.replace(/local Core = getfenv\(0\)/g, "local Core = (_G.Core or Core)");
  if (isModern(s)) {
    s = applyMinimalCoreInitRewrites(s);
  }
  return s;
}

function pipeline(s, label) {
  const p1 = patchRemoteSourceModern(s);
  const p2 = rewriteForModuleEnv(p1);
  const lines = p2.split("\n");
  console.log(`\n=== ${label} === modern=${isModern(s)} lines=${lines.length}`);
  for (let i = 704; i <= 712; i++) {
    console.log(`${i + 1}: ${lines[i] ?? ""}`);
  }
  let depth = 0;
  let bad = null;
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    const opens = (line.match(/\b(function|if|for|while|do|repeat)\b/g) || []).length;
    const closes = (line.match(/\bend\b/g) || []).length;
    depth += opens - closes;
    if (depth < 0 && !bad) bad = { line: i + 1, depth, text: line };
  }
  console.log("balance depth", depth, bad ? `NEG@${bad.line}: ${bad.text}` : "ok");
  if (depth !== 0) console.log("WARN: unbalanced end/function");
  return p2;
}

pipeline(raw, "normal");

// double minimal rewrites (simulate re-patch)
let once = rewriteForModuleEnv(patchRemoteSourceModern(raw));
pipeline(once, "double-rewrite-input");

// simulate stale cache: legacy while-not-UI patch fragment (extra end scenario)
let corrupted = raw.replace(
  /AssignHotkey\(\{ 'LeftShift', 'H' \}, ToggleExplorer\)/,
  "end\nAssignHotkey({ 'LeftShift', 'H' }, ToggleExplorer)"
);
pipeline(corrupted, "corrupted-extra-end-before-708");

console.log("\nRemoteLoader on disk:", fs.statSync(loaderPath).size, "bytes");
