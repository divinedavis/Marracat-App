// Forgiving brand-name matching for the brand picker and the All brands page.
// "brown girl", "browngirl", "Brwon Girl", "bgj", "cafe" for "Café" and
// "&" for "and" all find the brand. Scores rank the closest names first.

export const fold = (value) =>
  String(value || "")
    .normalize("NFKD")
    .replace(/[̀-ͯ]/g, "")
    .toLowerCase()
    .replace(/&/g, " and ")
    .replace(/['’`]/g, "")
    .replace(/[^a-z0-9]+/g, " ")
    .trim();

const words = (value) => fold(value).split(" ").filter(Boolean);
const LEADING = new Set(["the", "a", "an"]);

// Damerau-Levenshtein distance, stopped early once it passes `max`.
function distance(a, b, max) {
  if (Math.abs(a.length - b.length) > max) return max + 1;
  let prev2 = null,
    prev = Array.from({ length: b.length + 1 }, (_, j) => j);
  for (let i = 1; i <= a.length; i++) {
    const row = [i];
    let best = i;
    for (let j = 1; j <= b.length; j++) {
      let d = Math.min(
        prev[j] + 1,
        row[j - 1] + 1,
        prev[j - 1] + (a[i - 1] === b[j - 1] ? 0 : 1),
      );
      if (prev2 && i > 1 && j > 1 && a[i - 1] === b[j - 2] && a[i - 2] === b[j - 1])
        d = Math.min(d, prev2[j - 2] + 1);
      row.push(d);
      best = Math.min(best, d);
    }
    if (best > max) return max + 1;
    prev2 = prev;
    prev = row;
  }
  return prev[b.length];
}
const typos = (length) => (length >= 8 ? 2 : length >= 4 ? 1 : 0);

// One typed word against a name's words: exact, prefix, or a near miss.
function wordScore(typed, nameWords, last) {
  let best = 0;
  for (const w of nameWords) {
    if (w === typed) return 3;
    if (w.startsWith(typed) && (last || typed.length >= 3)) best = Math.max(best, 2.5);
    const allowed = typos(typed.length);
    if (allowed) {
      // A slip on the whole word beats one on the start of a longer word:
      // "telfr" is Telfar, one letter out, before Kemi Telford, whose
      // "telfo" is too (2026-10-31, the day Kemi Telford went live).
      if (distance(typed, w, allowed) <= allowed) best = Math.max(best, 2);
      // Still typing: compare against the start of the name word as well.
      else if (last && w.length > typed.length && distance(typed, w.slice(0, typed.length), allowed) <= allowed)
        best = Math.max(best, 1.5);
    }
  }
  return best;
}

export function brandScore(name, query, extra = "") {
  const q = fold(query);
  if (!q) return 1;
  const n = fold(name);
  const qCompact = q.replace(/ /g, ""),
    nCompact = n.replace(/ /g, "");
  if (n === q || nCompact === qCompact) return 100;
  const nWords = n.split(" ").filter((w, i) => !(i === 0 && LEADING.has(w) && n.includes(" ")));
  const bare = nWords.join(" ");
  if (bare.startsWith(q) || n.startsWith(q)) return 90;
  if (nCompact.startsWith(qCompact)) return 85;
  if (nWords.some((w) => w.startsWith(q)) || (" " + n).includes(" " + q)) return 80;
  if (qCompact.length >= 3 && nCompact.includes(qCompact)) return 70;
  const qWords = q.split(" ");
  if (qCompact.length >= 2 && qWords.length === 1 && nWords.length > 1 &&
      nWords.map((w) => w[0]).join("").startsWith(qCompact)) return 65;
  const scores = qWords.map((t, i) => wordScore(t, nWords, i === qWords.length - 1));
  if (scores.every((s) => s > 0)) return 40 + scores.reduce((a, b) => a + b, 0) / qWords.length * 5;
  // The whole name typed as one run with a slip: "browngirljne".
  const allowed = typos(qCompact.length);
  if (allowed && distance(qCompact, nCompact.slice(0, qCompact.length), allowed) <= allowed) return 35;
  if (extra) {
    const e = fold(extra);
    if (qWords.every((t) => t.length >= 3 && e.includes(t))) return 20;
  }
  return 0;
}

// Brands matching `query`, best first; ties keep the given order.
export function rankBrands(list, query, name = (b) => b.name, extra = () => "") {
  if (!fold(query)) return list;
  return list
    .map((b, at) => ({ b, at, score: brandScore(name(b), query, extra(b)) }))
    .filter((x) => x.score > 0)
    .sort((x, y) => y.score - x.score || x.at - y.at)
    .map((x) => x.b);
}
