// Networks that host servers, not shoppers (web/metrics/datacenter.json, the
// list the dashboard's log count already used). The visitor tile counts
// /api/visit beacons, and until 2026-11-12 those had no such check: a
// headless crawler that ran the storefront's JavaScript from eight Tencent
// Cloud and Huawei Cloud addresses, one brand page each in four minutes,
// read as the day's 8 web visitors.
import { readFileSync } from "node:fs";
import { BlockList, isIPv4 } from "node:net";

const list = JSON.parse(readFileSync(new URL("../metrics/datacenter.json", import.meta.url), "utf8"));
const entries = list.groups.flatMap((g) => g.prefixes);
const prefixes = entries.filter((e) => !e.includes("/"));
const nets = new BlockList();
for (const e of entries.filter((e) => e.includes("/"))) {
  const [addr, bits] = e.split("/");
  nets.addSubnet(addr, Number(bits), isIPv4(addr) ? "ipv4" : "ipv6");
}

export function isDatacenter(ip) {
  // Express reports an IPv4 client on a dual-stack socket as ::ffff:a.b.c.d.
  const a = String(ip || "").replace(/^::ffff:/i, "");
  if (!a) return false;
  if (prefixes.some((p) => a.startsWith(p))) return true;
  try {
    return nets.check(a, isIPv4(a) ? "ipv4" : "ipv6");
  } catch {
    return false;
  }
}
