#!/usr/bin/env node

import { spawnSync } from "node:child_process";
import { appendFileSync, existsSync, mkdirSync, readFileSync, realpathSync } from "node:fs";
import { homedir } from "node:os";
import { basename, dirname, join, resolve } from "node:path";
import { createInterface } from "node:readline/promises";
import { fileURLToPath } from "node:url";

const PATH_MARKER_BEGIN = "# >>> Cairn setup tools PATH >>>";
const PATH_MARKER_END = "# <<< Cairn setup tools PATH <<<";
const SAFE_TOOL_ID = /^[a-z0-9-]+$/;

export function parseNodeMajor(version) {
  const match = String(version ?? "").trim().match(/^v?(\d+)(?:\.|$)/);
  return match ? Number(match[1]) : null;
}

export function parseArgs(argv) {
  const result = { mode: null, toolId: null, catalogPath: null, dryRun: false, yes: false };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === "--all") result.mode = "all";
    else if (arg === "--tool") {
      const toolId = argv[++index];
      if (!toolId || !SAFE_TOOL_ID.test(toolId)) throw new Error("--tool requires a safe tool id");
      result.mode = "tool";
      result.toolId = toolId;
    } else if (arg === "--catalog") {
      result.catalogPath = argv[++index];
      if (!result.catalogPath) throw new Error("--catalog requires a path");
    } else if (arg === "--dry-run") result.dryRun = true;
    else if (arg === "--yes") result.yes = true;
    else throw new Error(`unknown argument: ${arg}`);
  }
  if (!result.mode) throw new Error("choose --all or --tool <id>");
  return result;
}

export function validateCatalog(value) {
  if (!value || typeof value !== "object" || !Array.isArray(value.tools)) {
    throw new Error("setup tool catalog is invalid");
  }
  if (!Number.isInteger(value.minimumNodeMajor) || value.minimumNodeMajor < 18) {
    throw new Error("setup tool catalog has an invalid minimum Node.js version");
  }
  const seen = new Set();
  for (const tool of value.tools) {
    if (!tool || !SAFE_TOOL_ID.test(tool.id ?? "") || seen.has(tool.id)) {
      throw new Error("setup tool catalog contains an invalid or duplicate id");
    }
    seen.add(tool.id);
    if (!tool.name || !tool.category || typeof tool.required !== "boolean") {
      throw new Error(`setup tool ${tool.id} is incomplete`);
    }
  }
  return value;
}

export function cairnDataDir(platform = process.platform, env = process.env) {
  const home = env.HOME || env.USERPROFILE || homedir();
  if (platform === "darwin") return join(home, "Library", "Application Support", "Cairn");
  if (platform === "win32") {
    return join(env.LOCALAPPDATA || join(home, "AppData", "Local"), "Cairn");
  }
  return join(env.XDG_DATA_HOME || join(home, ".local", "share"), "cairn");
}

export function npmPaths(platform = process.platform, env = process.env) {
  const prefix = join(cairnDataDir(platform, env), "tools", "npm");
  return { prefix, bin: platform === "win32" ? prefix : join(prefix, "bin") };
}

export function installPreview(tool, platform = process.platform) {
  const installer = tool.installer;
  if (!installer) return null;
  switch (installer.kind) {
    case "managed-node":
      return "Install Cairn-managed Node.js";
    case "npm-global":
      return `npm install -g ${installer.package}`;
    case "system-package":
      if (platform === "darwin") return `brew install ${installer.macos}`;
      if (platform === "win32") return `winget install --id ${installer.windows}`;
      return `install ${installer.linux} with the detected system package manager`;
    case "aider":
      return "python3 -m pip install aider-install && aider-install";
    case "git-filter-repo":
      return platform === "darwin"
        ? "brew install git-filter-repo"
        : platform === "win32"
          ? "python -m pip install git-filter-repo"
          : "install git-filter-repo with the detected system package manager";
    case "manual":
      return installer[platform === "darwin" ? "macos" : platform === "win32" ? "windows" : "linux"];
    default:
      throw new Error(`unsupported installer strategy: ${installer.kind}`);
  }
}

function resolveCommand(command, platform = process.platform) {
  const lookup = platform === "win32"
    ? spawnSync("where.exe", [command], { encoding: "utf8", windowsHide: true })
    : spawnSync("/bin/sh", ["-lc", 'command -v "$1"', "cairn-setup", command], { encoding: "utf8" });
  if (lookup.status !== 0) return null;
  return String(lookup.stdout ?? "").split(/\r?\n/, 1)[0].trim() || null;
}

function detectTool(tool, platform = process.platform) {
  if (!tool.command) return { ok: false, detail: null };
  const executable = resolveCommand(tool.command, platform);
  if (!executable) return { ok: false, detail: null };
  const result = spawnSync(executable, tool.versionArgs ?? ["--version"], {
    encoding: "utf8",
    windowsHide: true,
  });
  const detail = String(result.stdout || result.stderr || executable).split(/\r?\n/, 1)[0].trim();
  return { ok: result.status === 0, detail: detail || executable };
}

function run(executable, args, options = {}) {
  const rendered = [executable, ...args].join(" ");
  if (options.dryRun) {
    console.log(`  would run: ${rendered}`);
    return;
  }
  const env = { ...process.env, ...options.env };
  let command = executable;
  let commandArgs = args;
  if (process.platform === "win32" && /\.(?:cmd|bat)$/i.test(executable)) {
    command = process.env.ComSpec || "cmd.exe";
    commandArgs = ["/d", "/s", "/c", executable, ...args];
  }
  const result = spawnSync(command, commandArgs, { stdio: "inherit", env, windowsHide: false });
  if (result.error) throw new Error(`could not run ${executable}: ${result.error.message}`);
  if (result.status !== 0) throw new Error(`${basename(executable)} exited with code ${result.status}`);
}

function npmExecutable() {
  const npm = resolveCommand(process.platform === "win32" ? "npm.cmd" : "npm");
  if (!npm) throw new Error("npm is unavailable in the selected Node.js installation");
  return npm;
}

function profilePath(env = process.env) {
  const home = env.HOME || homedir();
  const shell = basename(env.SHELL || "");
  if (shell === "zsh") return join(home, ".zshrc");
  if (shell === "bash") return process.platform === "darwin" ? join(home, ".bash_profile") : join(home, ".bashrc");
  return join(home, ".profile");
}

function persistToolPath(bin, dryRun) {
  process.env.PATH = `${bin}${process.platform === "win32" ? ";" : ":"}${process.env.PATH ?? ""}`;
  if (dryRun) {
    console.log(`  would add to user PATH: ${bin}`);
    return;
  }
  if (process.platform === "win32") {
    const script = [
      "$bin = $args[0]",
      "$entries = @([Environment]::GetEnvironmentVariable('Path', 'User') -split ';' | Where-Object { $_ })",
      "if (-not ($entries | Where-Object { $_.TrimEnd('\\') -ieq $bin.TrimEnd('\\') })) {",
      "  [Environment]::SetEnvironmentVariable('Path', ((@($entries) + $bin) -join ';'), 'User')",
      "}",
    ].join("; ");
    run("powershell.exe", ["-NoProfile", "-NonInteractive", "-Command", script, bin]);
    return;
  }
  const profile = profilePath();
  if (existsSync(profile) && readFileSync(profile, "utf8").includes(PATH_MARKER_BEGIN)) return;
  mkdirSync(dirname(profile), { recursive: true });
  const quoted = `'${bin.replaceAll("'", "'\\''")}'`;
  appendFileSync(
    profile,
    `\n${PATH_MARKER_BEGIN}\nexport PATH=${quoted}:"$PATH"\n${PATH_MARKER_END}\n`,
    "utf8",
  );
}

function installSystemPackage(installer, dryRun) {
  if (process.platform === "darwin") {
    const brew = resolveCommand("brew");
    if (!brew) throw new Error("Homebrew is required for this tool; install it from https://brew.sh and retry");
    run(brew, ["install", installer.macos], { dryRun });
    return;
  }
  if (process.platform === "win32") {
    const winget = resolveCommand("winget");
    if (winget) {
      run(winget, [
        "install", "--id", installer.windows, "--exact", "--source", "winget",
        "--accept-package-agreements", "--accept-source-agreements",
      ], { dryRun });
      return;
    }
    const choco = resolveCommand("choco");
    if (choco) return run(choco, ["install", installer.windows, "-y"], { dryRun });
    const scoop = resolveCommand("scoop");
    if (scoop) return run(scoop, ["install", installer.windows], { dryRun });
    throw new Error("winget, Chocolatey, or Scoop is required to install this tool");
  }
  const sudo = typeof process.getuid === "function" && process.getuid() === 0 ? [] : ["sudo"];
  const managers = [
    ["apt-get", ["update"], ["install", "-y", installer.linux]],
    ["dnf", null, ["install", "-y", installer.linux]],
    ["yum", null, ["install", "-y", installer.linux]],
    ["apk", null, ["add", installer.linux]],
    ["pacman", null, ["-Sy", "--noconfirm", installer.linux]],
    ["zypper", null, ["--non-interactive", "install", installer.linux]],
  ];
  for (const [name, prepare, install] of managers) {
    const manager = resolveCommand(name);
    if (!manager) continue;
    if (prepare) run(sudo[0] || manager, sudo.length ? [manager, ...prepare] : prepare, { dryRun });
    run(sudo[0] || manager, sudo.length ? [manager, ...install] : install, { dryRun });
    return;
  }
  throw new Error("no supported Linux package manager was found");
}

function installTool(tool, dryRun) {
  const installer = tool.installer;
  if (!installer) throw new Error(`${tool.name} has no automated installer`);
  console.log(`\n==> ${tool.name}`);
  switch (installer.kind) {
    case "managed-node":
      console.log("Node.js is already available; no installation is needed.");
      return;
    case "npm-global": {
      const paths = npmPaths();
      if (!dryRun) {
        mkdirSync(paths.prefix, { recursive: true });
      }
      run(npmExecutable(), ["install", "--global", installer.package], {
        dryRun,
        env: { npm_config_prefix: paths.prefix },
      });
      persistToolPath(paths.bin, dryRun);
      return;
    }
    case "system-package":
      installSystemPackage(installer, dryRun);
      return;
    case "aider": {
      const python = resolveCommand(process.platform === "win32" ? "python" : "python3");
      if (!python) throw new Error("Python 3 is required to install Aider");
      run(python, ["-m", "pip", "install", "--user", "aider-install"], { dryRun });
      const aiderInstall = resolveCommand(process.platform === "win32" ? "aider-install.exe" : "aider-install");
      if (!aiderInstall && !dryRun) throw new Error("aider-install was installed but is not on PATH");
      run(aiderInstall || "aider-install", [], { dryRun });
      return;
    }
    case "git-filter-repo":
      if (process.platform === "darwin") {
        installSystemPackage({ macos: "git-filter-repo" }, dryRun);
      } else if (process.platform === "win32") {
        const python = resolveCommand("python");
        if (!python) throw new Error("Python 3 is required to install git-filter-repo");
        run(python, ["-m", "pip", "install", "--user", "git-filter-repo"], { dryRun });
      } else {
        installSystemPackage({ linux: "git-filter-repo" }, dryRun);
      }
      return;
    case "manual":
      console.log(installPreview(tool));
      return;
    default:
      throw new Error(`unsupported installer strategy: ${installer.kind}`);
  }
}

async function chooseTools(tools, yes) {
  if (yes) return tools;
  const selected = tools.filter((tool) => tool.required);
  const optional = tools.filter((tool) => !tool.required);
  if (!optional.length) return selected;
  if (!process.stdin.isTTY) {
    throw new Error("interactive setup requires a terminal; rerun from Terminal or use --yes");
  }
  const prompt = createInterface({ input: process.stdin, output: process.stdout });
  try {
    console.log("\nOptional tools");
    for (const tool of optional) {
      const answer = await prompt.question(`Install ${tool.name}? [y/N] `);
      if (/^y(?:es)?$/i.test(answer.trim())) selected.push(tool);
    }
  } finally {
    prompt.close();
  }
  return selected;
}

export async function main(argv = process.argv.slice(2)) {
  const args = parseArgs(argv);
  const catalogFile = resolve(args.catalogPath || fileURLToPath(new URL("./setup-tools.json", import.meta.url)));
  const catalog = validateCatalog(JSON.parse(readFileSync(catalogFile, "utf8")));
  const major = parseNodeMajor(process.version);
  if (major === null || major < catalog.minimumNodeMajor) {
    throw new Error(`Cairn setup requires Node.js ${catalog.minimumNodeMajor}+ (found ${process.version})`);
  }

  console.log(`Cairn Setup Wizard · Node.js ${process.version}`);
  const available = catalog.tools.filter((tool) => tool.installer && tool.special !== "git-identity");
  if (args.mode === "tool") {
    const tool = available.find((candidate) => candidate.id === args.toolId);
    if (!tool) throw new Error(`unknown or non-installable setup tool: ${args.toolId}`);
    const current = detectTool(tool);
    if (current.ok) {
      console.log(`${tool.name} is already installed${current.detail ? `: ${current.detail}` : "."}`);
      return;
    }
    installTool(tool, args.dryRun);
    return;
  }

  const missing = available.filter((tool) => tool.id !== "node" && !detectTool(tool).ok);
  if (!missing.length) {
    console.log("All setup tools are already available.");
    return;
  }
  const selected = args.dryRun ? missing : await chooseTools(missing, args.yes);
  if (!selected.length) {
    console.log("No tools selected.");
    return;
  }
  for (const tool of selected) installTool(tool, args.dryRun);
  console.log("\nSetup finished. Return to Cairn and choose Re-check.");
}

const entry = process.argv[1] ? realpathSync(process.argv[1]) : "";
if (entry === realpathSync(fileURLToPath(import.meta.url))) {
  main().catch((error) => {
    console.error(`\nSetup failed: ${error instanceof Error ? error.message : String(error)}`);
    process.exitCode = 1;
  });
}
