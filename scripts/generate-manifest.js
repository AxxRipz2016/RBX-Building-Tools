/**
 * Генерирует Launcher/manifest.lua для удалённой загрузки.
 * node scripts/generate-manifest.js
 */
const fs = require("fs");
const path = require("path");

const root = path.join(__dirname, "..");
const outFile = path.join(root, "Launcher", "manifest.lua");

const skipRootDirs = new Set([
	"node_modules",
	".git",
	"Build",
	"scripts",
	"ServerScriptService",
	"StarterPlayerScripts",
]);

const skipDirNames = new Set([
	"bin",
	"examples",
	"benchmarks",
	"testez",
	"lemur",
	"spec",
	"modules",
]);

const skipFile =
	/(\.spec\.lua$|\.bench\.lua$|\/spec\.lua$|ToolInitializer|PluginInitializer|AutomaticUpdating|ServerAPIEndpoint|DescendantCounter\.server|LocalAPIEndpoint\.client\.lua$|Launcher\/|generate-manifest)/;

function walk(dir, base = "") {
	const entries = [];
	for (const name of fs.readdirSync(dir)) {
		const full = path.join(dir, name);
		const rel = base ? `${base}/${name}` : name;
		if (fs.statSync(full).isDirectory()) {
			if (!base && skipRootDirs.has(name)) continue;
			if (skipDirNames.has(name)) continue;
			entries.push(...walk(full, rel.replace(/\\/g, "/")));
		} else if (name.endsWith(".lua") && !skipFile.test(rel.replace(/\\/g, "/"))) {
			entries.push(rel.replace(/\\/g, "/"));
		}
	}
	return entries;
}

const paths = walk(root).sort((a, b) => a.length - b.length || a.localeCompare(b));

const body =
	"-- Автоген: node scripts/generate-manifest.js\nreturn {\n" +
	paths.map((p) => `\t"${p}",`).join("\n") +
	"\n}\n";

fs.writeFileSync(outFile, body, "utf8");
console.log(`Wrote ${paths.length} paths to Launcher/manifest.lua`);
