import fs from "fs";
import path from "path";

const corePath = path.join(import.meta.dirname, "..", "Core/init.lua");
const raw = fs.readFileSync(corePath, "utf8").replace(/\r\n/g, "\n").replace(/\r/g, "\n");

const PREAMBLE =
  'local require = (_G.__bt_require or __bt_require)\n' +
  'local script = (_G.__bt_script or (typeof(script) == "Instance" and script) or __bt_script)\n';

function fullBody(raw) {
  let s = PREAMBLE + raw.replace(/^local script = [^\n]+\n/m, "local script = Tool:WaitForChild('Core')\n");
  s = s.replace(/^local Core = getfenv\(0\)\r?\n?/m, "local Core = (_G.Core or Core)\n");
  s = s.replace(/getfenv\s*\(\s*0\s*\)/g, "Core");
  s = s.replace(/Tool = script\.Parent;/g, "Tool = _G.__bt_tool or Tool;");
  for (const child of ["Security", "History", "Selection", "Targeting"]) {
    const via = `require(Tool:WaitForChild('Core'):WaitForChild('${child}'))`;
    s = s.replace(new RegExp(`${child} = require\\(script\\.${child}\\)`, "g"), `${child} = ${via}`);
  }
  return s;
}

const body = fullBody(raw);
const lines = body.split("\n");
console.log("modern markers:", raw.includes("BT remote Core"), raw.includes("function Core.EnsureUI"));
for (let i = 702; i <= 722; i++) {
  console.log(`${i}: ${lines[i - 1] ?? ""}`);
}
const bad = /^\s*end\s*;?\s*$/.test(lines[707] ?? "");
console.log("line708 is bare end?", bad);
