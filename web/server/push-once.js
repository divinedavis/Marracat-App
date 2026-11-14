// Each delivery step reaches a person once (owner, 2026-10-09: "i shouldnt get
// the same notification multiple times"). KOBA's out-for-delivery email made a
// second relay record for the same package, so "Delivered" went out per
// record; a webhook and the 10-minute poll can also both see one change.
// Every delivery push now claims a row here first; a claimed key is never
// sent again.
export function installPushLog(db) {
  db.exec(`CREATE TABLE IF NOT EXISTS push_log (
    who TEXT NOT NULL, key TEXT NOT NULL, sent INTEGER NOT NULL,
    PRIMARY KEY (who, key))`);
}

// True the first time `who` (an account or a device) claims `key`.
export function claimPush(db, who, key, now = Date.now()) {
  installPushLog(db);
  return db.prepare("INSERT OR IGNORE INTO push_log(who, key, sent) VALUES(?,?,?)").run(String(who), String(key), now).changes === 1;
}

// A claim to give back when nothing was delivered, so a later try can send.
export function releasePush(db, who, key) {
  db.prepare("DELETE FROM push_log WHERE who=? AND key=?").run(String(who), String(key));
}
