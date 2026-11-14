// Screens text people write for each other: comments, notes on shared
// products, display names and handles.
//
// The App Store requires apps with user-generated content to filter
// objectionable material (Guideline 1.2). This is the first line: hate slurs
// and sexual harassment are refused outright. Ordinary swearing is not; a
// product comment like "this oil is the shit" is fine. Reports and the owner's
// moderation queue catch what a word list can't.
//
// Links are refused too. Comments on a shopping app are where spam and
// phishing arrive first, and nothing here needs a link: a product is shared
// by sharing it.

// Matched as whole words after the normalisation below, so "Scunthorpe"
// passes and "n1gg3r" does not.
const TERMS = [
  // racial and ethnic slurs
  // ("spook" and "gypsy" are left out: they turn up in product names and
  // Halloween listings far more often than as slurs on a shopping app.)
  "nigger", "niggers", "nigga", "niggas", "negroid", "coon", "coons", "jigaboo", "porchmonkey",
  "sambo", "pickaninny", "chink", "chinks", "gook", "gooks", "spic", "spics", "wetback",
  "wetbacks", "beaner", "beaners", "kike", "kikes", "raghead", "towelhead", "sandnigger",
  "paki", "pakis", "redskin", "redskins", "squaw", "zipperhead",
  // homophobic and transphobic slurs
  "faggot", "faggots", "fag", "fags", "dyke", "dykes", "tranny", "trannies", "shemale",
  // disability slurs
  "retard", "retards", "retarded",
  // sexual harassment
  "rape", "raping", "rapist", "whore", "whores", "slut", "sluts", "cunt", "cunts",
  // violent threats
  "kys", "killyourself",
];

const LEET = { 0: "o", 1: "i", 3: "e", 4: "a", 5: "s", 7: "t", "@": "a", $: "s", "!": "i" };

function normalise(text) {
  return String(text)
    .toLowerCase()
    .normalize("NFKD")
    .replace(/[̀-ͯ]/g, "")
    .replace(/[01345@$!7]/g, (c) => LEET[c] ?? c)
    // "n.i.g" and "n i g g e r" spelled out to dodge a filter
    .replace(/\b(\w)(?:[\s._*-]+(?=\w\b))/g, "$1");
}

const WORDS = new RegExp(`\\b(?:${TERMS.join("|")})\\b`);
// "kill yourself" and friends, with any spacing
const PHRASES = /\bkill\s*your\s*self\b|\bgo\s+die\b/;
const LINK = /(?:https?:\/\/|www\.)\S|\b[a-z0-9-]+\.(?:com|net|org|io|co|shop|store|xyz|link|ly|me|app)\b/i;

/** Why `text` can't be posted, or null if it can. */
export function refusal(text, { allowLinks = false } = {}) {
  const plain = normalise(text);
  if (WORDS.test(plain) || PHRASES.test(plain)) return "That includes language Marracat doesn't allow. Please keep it respectful.";
  if (!allowLinks && LINK.test(text)) return "Links can't be posted. Share a product with the share button instead.";
  return null;
}
