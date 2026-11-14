// One card per style, a dot per colour (catalog/colorways.py; owner,
// 2026-10-10). Every member of a colourway group carries the same `group`,
// its own `color` name and, when the name has a known colour word, a
// `swatch` ("#rrggbb").

/// The list with only the first product of each group: lists are sorted
/// in-stock first, so the face of a group is an in-stock member when there is
/// one, and a search for "black hoodie" shows the black one.
export function collapseGroups(list) {
  const seen = new Set();
  return list.filter((p) => {
    if (!p.group) return true;
    if (seen.has(p.group)) return false;
    seen.add(p.group);
    return true;
  });
}

/// group -> its members, in catalog order.
export function groupIndex(products) {
  const index = new Map();
  for (const p of products) {
    if (!p.group) continue;
    if (!index.has(p.group)) index.set(p.group, []);
    index.get(p.group).push(p);
  }
  return index;
}

const HEX = /^#[0-9a-f]{6}$/i;
/// A dot's CSS colour: the catalog's swatch, only when it is a plain hex.
export const dotColor = (member) => (HEX.test(member?.swatch || "") ? member.swatch : null);
