// Reads a brand's order email: which order it is about, what happened to it,
// the link to the brand's order status page, and the carrier's tracking
// number. Written for Shopify's standard notification templates (order
// confirmation, shipping confirmation, shipping update, out for delivery,
// delivered). An email it can't read is still forwarded; it just doesn't move
// the order's tracker.

const CARRIER_LINKS = [
  // USPS: tools.usps.com/go/TrackConfirmAction?tLabels=9400…
  { carrier: "USPS", re: /usps\.com\/[^"'\s<>]*?(?:tLabels|tRef=fullpage&tLc=\d+&text28777=&tLabels|qtc_tLabels1)=([A-Z0-9]{10,35})/i },
  // UPS: www.ups.com/track?tracknum=1Z… or wwwapps.ups.com/WebTracking/track?trackNums=1Z…
  { carrier: "UPS", re: /ups\.com\/[^"'\s<>]*?(?:tracknum|trackNums|InquiryNumber1)=([A-Z0-9]{10,35})/i },
  // FedEx: www.fedex.com/fedextrack/?trknbr=… or /apps/fedextrack/?tracknumbers=…
  { carrier: "FedEx", re: /fedex\.com\/[^"'\s<>]*?(?:trknbr|tracknumbers|tracknumber_list)=([0-9]{12,22})/i },
  // DHL eCommerce / Express
  { carrier: "DHLExpress", re: /dhl\.com\/[^"'\s<>]*?(?:tracking-id|AWB|trackingNumber|tracking_id)=([A-Z0-9]{8,35})/i },
  // OnTrac (owner's Ripl Efek order, 2026-10-13): www.ontrac.com/tracking/?number=1LS…
  // or the older trackingresults.asp?tracking_number=C…
  { carrier: "OnTrac", re: /ontrac\.com\/[^"'\s<>]*?(?:number|tracking_?number|trackingnumber|tracking)=([A-Z0-9]{10,35})/i },
];

// Bare numbers, only when the email already says it's about tracking.
const BARE = [
  { carrier: "UPS", re: /\b(1Z[0-9A-Z]{16})\b/ },
  { carrier: "USPS", re: /\b(9[2345]\d{18,24})\b/ },
  { carrier: "OnTrac", re: /\b(1LS[0-9A-Z]{12,15}|C\d{14})\b/ },
];

// The carrier for a number on its own (one the shopper typed in), by the
// shapes the carriers publish; null leaves it to the tracker's auto-detection.
export function carrierFor(number = "") {
  const n = String(number).toUpperCase();
  if (/^1Z[0-9A-Z]{16}$/.test(n)) return "UPS";
  if (/^(?:1LS[0-9A-Z]{12,15}|C\d{14})$/.test(n)) return "OnTrac";
  if (/^9[2345]\d{18,24}$/.test(n) || /^[A-Z]{2}\d{9}US$/.test(n)) return "USPS";
  if (/^(?:\d{12}|\d{15}|\d{20}|\d{22})$/.test(n)) return "FedEx";
  return null;
}

// https only: a link from an email is never kept in cleartext (2026-11-12).
const STATUS_URL = /https:\/\/[^"'\s<>]+?\/\d{5,}\/orders\/[a-f0-9]{32}(?:\/authenticate\?key=[a-f0-9]{32})?/i;
const ORDER_NAME = /(?:order|pedido|commande)\s*(?:number|no\.?|#|:)?\s*#?\s*([A-Z]{0,6}-?#?\d{3,10}(?:-\d{1,3})?)\b/i;

const decodeEntities = (s) =>
  s.replace(/&amp;/g, "&").replace(/&#x3D;|&#61;/g, "=").replace(/&quot;/g, '"').replace(/&#39;/g, "'");

// What happened, from the subject first (Shopify's subjects are fixed
// phrases the merchant rarely edits), then the body.
export function eventKind(subject = "", text = "") {
  const s = subject.toLowerCase(), t = text.toLowerCase().slice(0, 4000);
  const has = (re) => re.test(s) || re.test(t);
  if (/\bdelivered\b/.test(s) || /has been delivered|was delivered/.test(t)) return "delivered";
  if (/out for delivery/.test(s) || /is out for delivery/.test(t)) return "out_for_delivery";
  if (/on (?:its|the) way|has shipped|shipped|shipping (?:confirmation|update)|shipment/.test(s)) return "shipped";
  if (/\bcancel+ed\b/.test(s)) return "cancelled";
  if (/\brefund/.test(s)) return "refunded";
  if (/order .*confirm|confirmed|thank you for your (?:order|purchase)|order received|we(?:'|’)ve received your order/.test(s)) return "confirmation";
  if (has(/tracking number|track your (?:order|shipment|package)/)) return "shipped";
  if (/thank you for your purchase|order confirmation/.test(t)) return "confirmation";
  return "other";
}

export function findTracking(html = "", text = "") {
  const hay = decodeEntities(`${html}\n${text}`);
  for (const { carrier, re } of CARRIER_LINKS) {
    const m = hay.match(re);
    if (m) return { carrier, trackingNumber: m[1].toUpperCase() };
  }
  if (/tracking/i.test(hay))
    for (const { carrier, re } of BARE) {
      const m = hay.match(re);
      if (m) return { carrier, trackingNumber: m[1].toUpperCase() };
    }
  const labelled = hay.replace(/<[^>]+>/g, " ").match(/tracking (?:number|#|no\.?)\s*:?\s*([A-Z0-9]{10,35})\b/i);
  if (labelled) return { carrier: null, trackingNumber: labelled[1].toUpperCase() };
  return null;
}

// The items in a Shopify notification: its standard templates title each line
// <span class="order-list__item-title">Name × 2</span>. Returns the first
// item's name and how many lines there are, or null.
export function findItems(html = "") {
  const titles = [...decodeEntities(html).matchAll(/class="[^"]*\border-list__item-title\b[^"]*"[^>]*>([\s\S]{1,400}?)<\/span>/gi)]
    .map((m) => m[1].replace(/<[^>]+>/g, " ").replace(/&nbsp;|\u00a0/g, " ").replace(/\s*[×x]\s*\d+\s*$/i, "").replace(/\s+/g, " ").trim())
    .filter(Boolean);
  return titles.length ? { title: titles[0].slice(0, 120), count: titles.length } : null;
}

export function parseOrderEmail({ subject = "", html = "", text = "", fromName = "", fromAddress = "" } = {}) {
  const body = decodeEntities(`${html}\n${text}`);
  const plain = text || html.replace(/<[^>]+>/g, " ");
  const statusMatch = body.match(STATUS_URL);
  const statusURL = statusMatch ? statusMatch[0] : null;
  let brandDomain = null;
  if (statusURL) {
    try { brandDomain = new URL(statusURL).hostname.replace(/^www\./, "").toLowerCase(); } catch {}
  }
  if (!brandDomain && fromAddress.includes("@")) {
    const d = fromAddress.split("@")[1].toLowerCase();
    if (!/shopify|myshopify|gmail|outlook|yahoo|icloud/.test(d)) brandDomain = d.replace(/^(?:mail|email|orders|shop|store|hello|info|support)\./, "");
  }
  const orderName = (subject.match(ORDER_NAME) || plain.match(ORDER_NAME) || [])[1] || null;
  let kind = eventKind(subject, plain);
  const items = findItems(html);
  const tracking = kind === "confirmation" ? null : findTracking(html, text);
  // A carrier tracking link in an otherwise unreadable email means it shipped.
  if (kind === "other" && tracking && CARRIER_LINKS.some(({ re }) => re.test(body))) kind = "shipped";
  return {
    kind,
    orderName: orderName ? (orderName.startsWith("#") ? orderName : `#${orderName}`) : null,
    statusURL,
    brandDomain,
    brandName: fromName ? fromName.replace(/\s+via\s+.*$/i, "").slice(0, 120) : null,
    carrier: tracking?.carrier || null,
    trackingNumber: tracking?.trackingNumber || null,
    itemTitle: items?.title || null,
    itemCount: items?.count || null,
  };
}
