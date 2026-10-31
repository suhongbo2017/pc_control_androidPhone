/**
 * android.ts — a pi extension that drives a real Android phone over adb.
 *
 * Design notes (learned the hard way, see docs/troubleshooting.md):
 *  - Never go through a shell: execFile(adb, argv) avoids quoting/path-mangling
 *    bugs entirely (adb joins argv itself).
 *  - Token budget: `screen` returns a compact text tree, never a bitmap.
 *    Screenshots are opt-in via action=shot.
 *  - A dozing screen makes `uiautomator dump` return a single com.android.systemui
 *    node. We pre-check `mWakefulness` (~0.3s) and wake once instead of dumping
 *    twice (~3s saved per observation).
 *  - With more than one device attached every action requires `device`.
 *
 * adb discovery order: PI_ANDROID_ADB → ANDROID_HOME/platform-tools/adb →
 * common install paths → `adb` from PATH.
 */
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { StringEnum } from "@earendil-works/pi-ai";
import { Type } from "typebox";
import { execFile } from "node:child_process";
import { existsSync } from "node:fs";
import { homedir } from "node:os";
import path from "node:path";

function candidateAdbPaths(): string[] {
  const list: string[] = [];
  if (process.env.PI_ANDROID_ADB) list.push(process.env.PI_ANDROID_ADB);
  if (process.env.ADB) list.push(process.env.ADB);
  for (const home of [process.env.ANDROID_HOME, process.env.ANDROID_SDK_ROOT]) {
    if (home) list.push(path.join(home, "platform-tools", process.platform === "win32" ? "adb.exe" : "adb"));
  }
  const exe = process.platform === "win32" ? "adb.exe" : "adb";
  if (process.platform === "win32") {
    list.push("C:/Program Files/scrcpy/adb.exe", "C:/scrcpy/adb.exe");
    const local = process.env.LOCALAPPDATA;
    if (local) list.push(path.join(local, "Android", "Sdk", "platform-tools", "adb.exe"));
  } else if (process.platform === "darwin") {
    list.push("/opt/homebrew/bin/adb", "/usr/local/bin/adb",
      path.join(homedir(), "Library/Android/sdk/platform-tools/adb"));
  } else {
    list.push("/usr/bin/adb", "/usr/local/bin/adb",
      path.join(homedir(), "Android/Sdk/platform-tools/adb"));
  }
  list.push(exe); // last resort: PATH
  return list;
}

let cachedAdb: string | null = null;
function adbPath(): string {
  if (cachedAdb) return cachedAdb;
  const candidates = candidateAdbPaths();
  for (const c of candidates) {
    if (!c.includes(path.sep) && !c.includes("/")) return (cachedAdb = c);
    if (existsSync(c)) return (cachedAdb = c);
  }
  return (cachedAdb = process.platform === "win32" ? "adb.exe" : "adb");
}

type RunResult = { ok: boolean; out: string; err: string };

function run(serial: string | null, args: string[], timeout = 60_000): Promise<RunResult> {
  const full = serial ? ["-s", serial, ...args] : args;
  return new Promise((resolve) => {
    execFile(
      adbPath(),
      full,
      { timeout, maxBuffer: 32 * 1024 * 1024, windowsHide: true, encoding: "buffer" },
      (error: Error | null, stdout: unknown, stderr: unknown) => {
        const errText = Buffer.isBuffer(stderr) ? stderr.toString("utf8") : String(stderr ?? "");
        resolve({
          ok: !error,
          out: Buffer.isBuffer(stdout) ? stdout.toString("utf8") : String(stdout ?? ""),
          err: errText + (error && (error as { killed?: boolean }).killed ? "\n(adb timed out)" : ""),
        });
      },
    );
  });
}

type Device = { serial: string; model: string; device: string; transport: string };

async function listDevices(): Promise<Device[]> {
  const r = await run(null, ["devices", "-l"], 20_000);
  const devs: Device[] = [];
  for (const line of r.out.split(/\r?\n/).slice(1)) {
    // NOTE: `.` does not match `\r`, so trim before matching.
    const m = line.trim().match(/^(\S+)\s+(\S+)(.*)$/);
    if (!m || m[2] !== "device") continue;
    const meta = m[3];
    const get = (k: string) => (meta.match(new RegExp(`${k}:(\\S+)`)) ?? [])[1] ?? "";
    devs.push({ serial: m[1], model: get("model"), device: get("device"), transport: get("transport_id") });
  }
  return devs;
}

class NeedDevice extends Error {}

async function resolveSerial(wanted?: string): Promise<string> {
  const devs = await listDevices();
  if (!devs.length) {
    throw new Error("no adb device attached. Run `adb connect <ip:port>` (wireless debugging) or plug in USB, then `adb devices`.");
  }
  if (wanted) {
    const hit =
      devs.find((d) => d.serial === wanted) ??
      devs.find((d) => d.serial.includes(wanted)) ??
      devs.find((d) => d.model === wanted || d.device === wanted);
    if (!hit) throw new Error(`device not found: ${wanted}; attached: ${devs.map((d) => d.serial).join(", ")}`);
    return hit.serial;
  }
  if (process.env.PI_ANDROID_DEVICE) return process.env.PI_ANDROID_DEVICE;
  if (devs.length === 1) return devs[0].serial;
  throw new NeedDevice(
    `${devs.length} devices attached — pass the device parameter (serial or a substring / model / codename):\n` +
      devs.map((d) => `- ${d.serial}  model=${d.model} device=${d.device}`).join("\n"),
  );
}

// ---------------------------------------------------------------- UI tree

type UiNode = {
  text: string;
  desc: string;
  id: string;
  cls: string;
  clickable: boolean;
  checked: boolean;
  scrollable: boolean;
  enabled: boolean;
  password: boolean;
  bounds: [number, number, number, number];
  center: [number, number];
  area: number;
};

function parseNodes(xml: string): UiNode[] {
  const nodes: UiNode[] = [];
  const re = /<node\s([^>]*?)\/?>/g;
  let m: RegExpExecArray | null;
  while ((m = re.exec(xml))) {
    const src = m[1];
    const attr = (k: string) => {
      const v = src.match(new RegExp(`(?:^|\\s)${k.replace(/-/g, "\\-")}="([^"]*)"`));
      return v ? v[1] : "";
    };
    const b = attr("bounds").match(/\[(-?\d+),(-?\d+)\]\[(-?\d+),(-?\d+)\]/);
    if (!b) continue;
    const x1 = +b[1];
    const y1 = +b[2];
    const x2 = +b[3];
    const y2 = +b[4];
    nodes.push({
      text: attr("text"),
      desc: attr("content-desc"),
      id: attr("resource-id"),
      cls: attr("class").replace(/^android\.widget\./, "").replace(/^androidx\./, "ax."),
      clickable: attr("clickable") === "true",
      checked: attr("checked") === "true",
      scrollable: attr("scrollable") === "true",
      enabled: attr("enabled") !== "false",
      password: attr("password") === "true",
      bounds: [x1, y1, x2, y2],
      center: [Math.round((x1 + x2) / 2), Math.round((y1 + y2) / 2)],
      area: Math.max(1, (x2 - x1) * (y2 - y1)),
    });
  }
  return nodes;
}

const DUMP_ARGS = ["exec-out", "uiautomator", "dump", "--compressed", "/dev/tty"];

function extractNodes(out: string): UiNode[] | null {
  const start = out.indexOf("<?xml");
  const end = out.lastIndexOf("</hierarchy>");
  if (start < 0 || end < 0) return null;
  return parseNodes(out.slice(start, end + 10));
}

async function rawDump(serial: string): Promise<UiNode[] | null> {
  const r = await run(serial, DUMP_ARGS, 60_000);
  return extractNodes(r.out);
}

async function wake(serial: string): Promise<void> {
  await run(serial, ["shell", "input", "keyevent", "224"], 15_000); // KEYCODE_WAKEUP
  await run(serial, ["shell", "wm", "dismiss-keyguard"], 15_000);
  await new Promise((r) => setTimeout(r, 700));
}

async function wakefulness(serial: string): Promise<string> {
  const r = await run(serial, ["shell", "dumpsys", "power"], 25_000);
  return (r.out.match(/mWakefulness=(\w+)/) ?? [])[1] ?? "Unknown";
}

/** Cheap pre-check (~0.3s) so a dozing screen costs one dump instead of two (~3s saved). */
async function ensureAwake(serial: string): Promise<boolean> {
  if ((await wakefulness(serial)) === "Awake") return false;
  await wake(serial);
  return true;
}

async function uiDump(serial: string): Promise<UiNode[]> {
  await ensureAwake(serial);
  const first = await rawDump(serial);
  if (first === null) throw new Error("uiautomator dump could not be parsed (screen locked or adb dropped)");
  if (first.length > 1) return first;
  await wake(serial);
  const second = await rawDump(serial);
  return second ?? first;
}

async function focusOf(serial: string): Promise<string> {
  const r = await run(serial, ["shell", "dumpsys", "activity", "activities"], 25_000);
  const m = r.out.match(/topResumedActivity.*?([\w.]+)\/([\w.$]+)/) ?? r.out.match(/ResumedActivity.*?([\w.]+)\/([\w.$]+)/);
  if (m) return `${m[1]}/${m[2]}`;
  const w = await run(serial, ["shell", "dumpsys", "window"], 25_000);
  const m2 = w.out.match(/mCurrentFocus=Window\{\S+ \S+ ([^\s}]+)/);
  return m2 ? m2[1] : "(unknown)";
}

function formatNodes(nodes: UiNode[], opts: { query?: string; limit?: number } = {}) {
  const wanted = (opts.query ?? "").toLowerCase();
  const limit = opts.limit ?? 80;
  const seen = new Set<string>();
  const lines: string[] = [];
  for (const n of nodes) {
    const label = n.text || n.desc;
    if (!label && !n.id) continue;
    if (wanted && !`${label} ${n.desc} ${n.id}`.toLowerCase().includes(wanted)) continue;
    const key = `${label}|${n.id}|${n.center.join(",")}`;
    if (seen.has(key)) continue;
    seen.add(key);
    const flags = [
      n.clickable ? "click" : "",
      n.checked ? "checked" : "",
      n.scrollable ? "scroll" : "",
      n.password ? "password" : "",
      n.enabled ? "" : "disabled",
    ].filter(Boolean);
    lines.push(
      `${n.center.join(",").padEnd(10)} ${n.cls.padEnd(18)}` +
        ` text=${JSON.stringify(label)}` +
        (n.id ? ` id=${n.id}` : "") +
        (flags.length ? ` [${flags.join(",")}]` : ""),
    );
  }
  const shown = lines.slice(0, limit);
  return { text: shown.join("\n"), total: lines.length, hidden: lines.length - shown.length };
}

function findNode(nodes: UiNode[], target: string, contains: boolean): UiNode | undefined {
  const t = target.toLowerCase();
  const label = (n: UiNode) => (n.text || n.desc || "").toLowerCase();
  const exact = nodes.filter((n) => label(n) === t);
  // Exact label wins; otherwise fall back to substring (contains=false refuses that).
  const pool = exact.length ? exact : contains ? nodes.filter((n) => label(n).includes(t)) : [];
  return pool.sort(
    (a, b) =>
      Number(b.clickable) - Number(a.clickable) ||
      (a.text || a.desc).length - (b.text || b.desc).length ||
      a.area - b.area,
  )[0];
}

const KEYCODES: Record<string, number> = {
  back: 4, home: 3, recent: 187, app_switch: 187, menu: 82,
  enter: 66, tab: 61, esc: 111, escape: 111, space: 62,
  del: 67, backspace: 67, forward_del: 112,
  power: 26, wakeup: 224, sleep: 223,
  volume_up: 24, volume_down: 25, mute: 164, play_pause: 85,
  dpad_up: 19, dpad_down: 20, dpad_left: 21, dpad_right: 22, dpad_center: 23,
  page_up: 92, page_down: 93, search: 84, camera: 27,
};

// `input text` is ASCII-only; %s means space.
function escapeInputText(s: string): string {
  return s.replace(/([\\'"&|<>;()$`*?[\]{}!#~])/g, "\\$1").replace(/ /g, "%s");
}

function text(r: RunResult): { content: { type: "text"; text: string }[]; details: Record<string, unknown> } {
  const body = [r.out.trim(), r.err.trim()].filter(Boolean).join("\n");
  return { content: [{ type: "text", text: body || "(no output)" }], details: { ok: r.ok } };
}

// ---------------------------------------------------------------- tool

export default function android(pi: ExtensionAPI) {
  pi.registerTool({
    name: "android",
    label: "Android (adb)",
    description:
      "Control a USB/Wi-Fi connected Android phone through adb: read the UI tree, tap by text, type, press keys, " +
      "launch/stop apps, swipe, screenshot, run shell commands. Use action=screen before acting and again to verify.",
    promptSnippet: "Drive a connected Android phone over adb (screen/tap/type/key/launch/shell/shot)",
    promptGuidelines: [
      "Use android action=screen first to see the current UI tree, then act by text (target=) rather than guessed coordinates, then call action=screen again to verify the result.",
      "Use android action=shell for state changes that have a direct command (e.g. `cmd uimode night yes`, `settings put system screen_off_timeout 600000`, `am start -a android.settings.DISPLAY_SETTINGS`) — it is far faster and more reliable than tapping through menus.",
      "Avoid android action=shot unless the UI tree has no usable text; screenshots cost many tokens.",
      "On HyperOS/MIUI `pm list packages` may return nothing — use `cmd package list packages`; `pm disable-user` on system packages is rejected, use `cmd appops set <pkg> RUN_IN_BACKGROUND ignore` or the UI toggle instead.",
    ],
    parameters: Type.Object({
      action: StringEnum([
        "devices", "screen", "tap", "type", "key", "swipe",
        "launch", "stop", "shell", "shot", "wake", "wait",
      ] as const),
      device: Type.Optional(
        Type.String({ description: "adb serial (or a substring / model / codename). Required when several devices are attached." }),
      ),
      query: Type.Optional(Type.String({ description: "action=screen: only show nodes matching this substring" })),
      limit: Type.Optional(Type.Number({ description: "action=screen: max lines (default 80)" })),
      target: Type.Optional(Type.String({ description: "action=tap/wait: node text or content-desc to look for" })),
      contains: Type.Optional(
        Type.Boolean({ description: "action=tap/wait: allow substring match when no exact label exists (default true)" }),
      ),
      text: Type.Optional(Type.String({ description: "action=type: ASCII text to type into the focused input" })),
      key: Type.Optional(Type.String({ description: "action=key: e.g. back, home, enter, tab, esc, power, volume_up" })),
      xy: Type.Optional(
        Type.String({ description: "action=tap/swipe: explicit coords 'x,y' (tap) or 'x1,y1,x2,y2' (swipe)" }),
      ),
      duration: Type.Optional(Type.Number({ description: "action=swipe: duration in ms (default 300)" })),
      pkg: Type.Optional(Type.String({ description: "action=launch/stop: package name, optionally 'pkg/.Activity'" })),
      command: Type.Optional(Type.String({ description: "action=shell: raw device shell command" })),
      timeout: Type.Optional(Type.Number({ description: "action=wait: max seconds to wait (default 10)" })),
      long: Type.Optional(Type.Boolean({ description: "action=tap: long press instead of tap" })),
    }),

    async execute(_toolCallId: string, params: Record<string, unknown>) {
      const action = String(params.action ?? "");
      const contains = params.contains !== false;

      if (action === "devices") {
        const devs = await listDevices();
        if (!devs.length) return { content: [{ type: "text" as const, text: "no adb device attached" }], details: {} };
        const lines = devs.map((d) => `${d.serial}  model=${d.model} device=${d.device} transport=${d.transport}`);
        return {
          content: [{ type: "text" as const, text: `${lines.length} device(s):\n${lines.join("\n")}` }],
          details: { devices: devs },
        };
      }

      const serial = await resolveSerial(params.device as string | undefined);

      switch (action) {
        case "wake": {
          await wake(serial);
          return text({ ok: true, out: `woke ${serial} (focus=${await focusOf(serial)})`, err: "" });
        }

        case "screen": {
          const nodes = await uiDump(serial);
          const f = formatNodes(nodes, {
            query: params.query as string | undefined,
            limit: params.limit as number | undefined,
          });
          const focus = await focusOf(serial);
          const head = `device=${serial}\nfocus=${focus}\nnodes=${nodes.length} shown=${f.total - f.hidden}/${f.total}`;
          return {
            content: [
              {
                type: "text" as const,
                text: `${head}\n${f.text}${f.hidden ? `\n…(+${f.hidden} more, use query/limit)` : ""}`,
              },
            ],
            details: { focus, nodes: nodes.length },
          };
        }

        case "tap": {
          let x: number;
          let y: number;
          let label = "";
          if (params.xy) {
            const [a, b] = String(params.xy).split(",").map((v) => Number(v.trim()));
            if (!Number.isFinite(a) || !Number.isFinite(b)) throw new Error("xy must be 'x,y'");
            x = a;
            y = b;
          } else if (params.target) {
            const nodes = await uiDump(serial);
            const hit = findNode(nodes, String(params.target), contains);
            if (!hit) {
              const f = formatNodes(nodes, { limit: 40 });
              return {
                content: [{ type: "text" as const, text: `not found: "${params.target}". Visible now:\n${f.text}` }],
                details: { ok: false },
              };
            }
            [x, y] = hit.center;
            label = hit.text || hit.desc;
          } else {
            throw new Error("tap needs target or xy");
          }
          const args = params.long
            ? ["shell", "input", "swipe", `${x}`, `${y}`, `${x}`, `${y}`, "700"]
            : ["shell", "input", "tap", `${x}`, `${y}`];
          const r = await run(serial, args, 30_000);
          return text({ ...r, out: `tap ${x},${y}${label ? ` ("${label}")` : ""} → ${r.ok ? "ok" : "failed"}` });
        }

        case "type": {
          const s = String(params.text ?? "");
          if (!s) throw new Error("type needs text (ASCII only)");
          const r = await run(serial, ["shell", "input", "text", escapeInputText(s)], 30_000);
          return text({ ...r, out: `typed ${JSON.stringify(s)} → ${r.ok ? "ok" : "failed"}` });
        }

        case "key": {
          const name = String(params.key ?? "").toLowerCase();
          const code = KEYCODES[name];
          if (!code) throw new Error(`unknown key ${name}; available: ${Object.keys(KEYCODES).join(", ")}`);
          const r = await run(serial, ["shell", "input", "keyevent", `${code}`], 30_000);
          return text({ ...r, out: `key ${name}(${code}) → ${r.ok ? "ok" : "failed"}` });
        }

        case "swipe": {
          const parts = String(params.xy ?? "").split(",").map((v) => Number(v.trim()));
          if (parts.length !== 4 || parts.some((v) => !Number.isFinite(v))) throw new Error("swipe needs xy='x1,y1,x2,y2'");
          const dur = Number(params.duration ?? 300);
          const r = await run(serial, ["shell", "input", "swipe", ...parts.map(String), String(dur)], 30_000);
          return text({ ...r, out: `swipe ${parts.join(",")} ${dur}ms → ${r.ok ? "ok" : "failed"}` });
        }

        case "launch": {
          const pkg = String(params.pkg ?? "");
          if (!pkg) throw new Error("launch needs pkg");
          const r = pkg.includes("/")
            ? await run(serial, ["shell", "am", "start", "-n", pkg], 40_000)
            : await run(serial, ["shell", "monkey", "-p", pkg, "-c", "android.intent.category.LAUNCHER", "1"], 40_000);
          // monkey is chatty; keep only the meaningful lines.
          const keep = r.out.split(/\r?\n/).filter((l) => /Events injected|No activities found|Error|Exception|monkey aborted/.test(l));
          return text({ ok: r.ok, out: keep.length ? keep.join("\n") : r.ok ? `launched ${pkg}` : r.err.slice(0, 400), err: "" });
        }

        case "stop": {
          const pkg = String(params.pkg ?? "");
          if (!pkg) throw new Error("stop needs pkg");
          const r = await run(serial, ["shell", "am", "force-stop", pkg], 30_000);
          return text({ ...r, out: `force-stop ${pkg} → ${r.ok ? "ok" : "failed"}` });
        }

        case "shell": {
          const cmd = String(params.command ?? "");
          if (!cmd) throw new Error("shell needs command");
          return text(await run(serial, ["shell", cmd], 60_000));
        }

        case "shot": {
          const r = await run(serial, ["exec-out", "screencap", "-p"], 60_000);
          const data = Buffer.from(r.out, "utf8");
          if (data.length < 1000) throw new Error(`screenshot failed: ${r.err || r.out.slice(0, 200)}`);
          return {
            content: [
              {
                type: "image" as const,
                source: { type: "base64" as const, mediaType: "image/png", data: data.toString("base64") },
              },
            ],
            details: { bytes: data.length },
          };
        }

        case "wait": {
          const target = String(params.target ?? "");
          if (!target) throw new Error("wait needs target");
          const budget = Number(params.timeout ?? 10);
          const deadline = Date.now() + budget * 1000;
          while (Date.now() < deadline) {
            const nodes = await uiDump(serial);
            const seen = findNode(nodes, target, contains);
            if (seen) return text({ ok: true, out: `found "${target}" @ ${seen.center.join(",")}`, err: "" });
            await new Promise((r) => setTimeout(r, 700));
          }
          return text({ ok: false, out: `timeout after ${budget}s waiting for "${target}"`, err: "" });
        }

        default:
          throw new Error(`unknown action: ${action}`);
      }
    },
  });
}
