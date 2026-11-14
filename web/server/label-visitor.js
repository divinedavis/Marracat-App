#!/usr/bin/env node
// Name a visitor we know (visitors.js visitor_labels).
//
//   DATA_DIR=/var/lib/marracat node server/label-visitor.js <hash or prefix> <owner|creator> [name]
//   DATA_DIR=/var/lib/marracat node server/label-visitor.js --list
//
// The id is the stored hash from visits / site_events (a prefix of 6+
// characters is enough if it matches exactly one visitor). An owner label also
// deletes that visitor's rows: back the database up first.
import path from "node:path";
import { fileURLToPath } from "node:url";
import Database from "better-sqlite3";
import { installLabelSchema, labelVisitor, LABEL_KINDS } from "./visits.js";

const here = path.dirname(fileURLToPath(import.meta.url));
const file = path.join(process.env.DATA_DIR || path.join(here, "../data"), "marracat.sqlite");
const db = new Database(file, { fileMustExist: true });
installLabelSchema(db);
const [id, kind, ...name] = process.argv.slice(2);
if (id === "--list") {
  for (const r of db.prepare("SELECT visitor, kind, name, added FROM visitor_labels ORDER BY added").all())
    console.log(`${r.visitor.slice(0, 12)}  ${r.kind.padEnd(7)}  ${r.added}  ${r.name}`);
  process.exit(0);
}
if (!/^[a-f0-9]{6,64}$/.test(id || "") || !LABEL_KINDS.includes(kind)) {
  console.error("usage: label-visitor.js <hash or 6+ char prefix> <owner|creator> [name]  |  --list");
  process.exit(2);
}
const matches = db.prepare(`SELECT visitor FROM visits WHERE visitor LIKE ? || '%'
    UNION SELECT visitor FROM site_events WHERE visitor LIKE ? || '%'`).all(id, id).map((r) => r.visitor);
if (matches.length !== 1) {
  console.error(`${matches.length} visitors match ${id}; give more of the hash`);
  process.exit(1);
}
const removed = labelVisitor(db, matches[0], kind, name.join(" "));
console.log(`${matches[0].slice(0, 12)} is now ${kind}${name.length ? ` (${name.join(" ")})` : ""}` +
  (kind === "owner" ? `; removed ${removed.visits} visit rows and ${removed.site_events} events` : ""));
