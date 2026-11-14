// The website's answers for the same queries, beside the app's (search_parity.sh).
import { readFileSync } from "node:fs";
const [, , web, dir, here] = process.argv;
const { filterProducts, relaxedSearch, searchAlternatives, setSearchCategories } = await import(web + "/src/catalog.js");
const { interests } = await import(web + "/src/search-words.js");
const { COLOR_WORD } = await import(web + "/src/colors.js");
COLOR_WORD.clear(); // the harness leaves out the colour fallback
const c = JSON.parse(readFileSync(dir + "/catalog.json"));
const app = JSON.parse(readFileSync(dir + "/app.json"));
const queries = JSON.parse(readFileSync(here + "/queries.json"));
const relaxQueries = JSON.parse(readFileSync(here + "/relax_queries.json"));
setSearchCategories(c.categories);
const same = (a, b) => a.length === b.length && a.every((x, i) => x === b[i]);
let bad = 0;
for (const q of queries) {
  const ids = filterProducts(c.products, c.brands, { q, synonyms: {} }).map((p) => p.id);
  if (!same(ids, app.searches[q])) { bad++; console.log(`  differs: "${q}" web ${ids.length}, app ${app.searches[q].length}`); }
}
for (const q of relaxQueries) {
  const r = relaxedSearch(c.products, c.brands, { q, synonyms: {} });
  const want = app.relaxed[q];
  if ((r ? r.q : null) !== want.q || !same(r ? r.result.map((p) => p.id) : [], want.ids)) {
    bad++;
    console.log(`  differs: no-match "${q}" web ${r ? r.q : null}, app ${want.q}`);
  }
}
for (const q of relaxQueries) {
  const r = relaxedSearch(c.products, c.brands, { q, synonyms: {} });
  const got = searchAlternatives(c.products, c.brands, { q, synonyms: {} }, r ? r.q : null);
  if (!same(got, app.guesses[q])) { bad++; console.log(`  differs: guesses for "${q}" web ${JSON.stringify(got)}, app ${JSON.stringify(app.guesses[q])}`); }
}
const histories = [["fruit", ["fruit", "bag charm", "Independent"], ["Keychains & Charms", "Tote Bags", "Keychains & Charms"]],
  ["pink", ["pink top", "perfume", "the co"], []], ["bag", [], ["Tote Bags", "Crossbody Bags", "Crossbody Bags"]]];
for (const [q, searched, aisles] of histories) {
  const got = interests(q, searched, aisles).map((i) => `${i.phrase}|${i.searched}`);
  if (!same(got, app.interests[q])) { bad++; console.log(`  differs: interests for "${q}" web ${JSON.stringify(got)}, app ${JSON.stringify(app.interests[q])}`); }
}
const total = queries.length + 2 * relaxQueries.length + histories.length;
console.log(`${total - bad}/${total} searches, guesses and interests identical to the app's, in the same order`);
process.exit(bad ? 1 : 0);
