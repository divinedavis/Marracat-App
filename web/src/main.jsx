import { toPath as hrefFor, fromPath, currentRoute, navigate, interceptLinks } from "./router";
import { daily, rotateDaily, HERO_BRANDS, BEAUTY_BRANDS, HOME_BRANDS } from "./daily";
import PrivacyPolicy from "./PrivacyPolicy.jsx";
import ForBrands from "./ForBrands.jsx";
import { AlertButton } from "./Alerts.jsx";
import { AccountOrders, OrderDetail, OrdersPage, webOrderRecord, recordWebOrder } from "./Orders.jsx";
import BrandAds from "./BrandAds.jsx";
import { useSponsored, SponsoredRow } from "./Sponsored.jsx";
import { pullCart, pushCart, markDirty, forget as forgetCartSync } from "./cartSync.js";
import { BoostButton, BoostsPage, BoostedPicks } from "./Boosts.jsx";
import React, { useState, useEffect, useMemo, useRef, useCallback } from "react";
import { createRoot } from "react-dom/client";
import { flushSync } from "react-dom";
import {
  Search,
  Heart,
  ShoppingCart,
  UserRound,
  Grid2X2,
  ChevronDown,
  ChevronRight,
  ArrowRight,
  X,
  Plus,
  Minus,
  Check,
  Store,
  ShieldCheck,
  Gem,
  Droplet,
  Leaf,
  Carrot,
  Baby,
  Shirt,
  FlaskConical,
  PawPrint,
  Handbag,
  House,
  ExternalLink,
  Sparkles,
  Share2,
  SlidersHorizontal,
  ArrowUpDown,
  Coins,
  KeyRound,
} from "lucide-react";
import {
  money,
  imageURL,
  safeURL,
  filterProducts,
  countryChoices,
  relaxedSearch,
  searchWithGuesses,
  personalPicks,
  setSearchCategories,
  checkoutURL,
  usesMarracatCart,
  diversify,
  optionNoun,
  keptOffHome, unseenIn, brandFirst,
} from "./catalog";
import { saysOwnership, tokens } from "./search-words";
import { readRecent, rememberSearch, rememberView, forgetRecent } from "./recent";
import {
  useSocial,
  Comments,
  ShareButtons,
  AccountSocial,
  ProfilePage,
  Moderation,
} from "./social/Social.jsx";

// Real paths (/p/<id>, /b/<id>, /c/<category>) are the storefront's addresses
// now; old "#/…" links are upgraded in place (router.js, owner 2026-10-09: SEO).
interceptLinks();
preloadProductOnPress();
// The service worker (public/sw.js): the site opens offline and from the
// device on a repeat visit, and can show notifications. Registered once the
// page has loaded so it never competes with the first paint.
if ("serviceWorker" in navigator && import.meta.env.PROD)
  window.addEventListener("load", () => navigator.serviceWorker.register("/sw.js").catch(() => {}), { once: true });
// The kind of page showing when the visit ends, for the speed report.
let screenNow;
watchVitals({ screen: () => screenNow });
// Taps, page changes, API timings and errors for the owner's Monitor page (monitor-client.js).
startMonitor();
import "./style.css";
import OwnershipNotice from "./OwnershipNotice";

/// Keeps a CSS variable on <html> equal to an element's height, so the shop's
/// sticky filters sit just under the sticky header, whatever its height
/// (phone search row, wrapped nav). Returns a callback ref.
function useHeightVar(name) {
  const observer = useRef(null);
  return useCallback((el) => {
    observer.current?.disconnect();
    observer.current = null;
    if (!el || typeof ResizeObserver === "undefined") return;
    const set = () => document.documentElement.style.setProperty(name, `${el.offsetHeight}px`);
    set();
    observer.current = new ResizeObserver(set);
    observer.current.observe(el);
  }, [name]);
}
import SearchBox from "./SearchBox";
import AccountDevice from "./AccountDevice.jsx";
import AccountDelete from "./AccountDelete.jsx";
import { passkeysSupported, signInWithPasskey } from "./passkeys";
import BrandPicker from "./BrandPicker";
import { useServerQuery, FAST_READY, fastReady } from "./fast-query";
import { track, watchBuyClicks, screenFor, checkoutProps } from "./events";
import { startMonitor, monitorScreen } from "./monitor-client";
import { openCheckoutKit, preloadCheckoutKit } from "./checkoutKit";
import { productURL, preloadProductOnPress } from "./prefetch";
import { markCatalog, markIndexed, watchVitals } from "./vitals";
import { loadCatalogInWorker } from "./catalog-loader";
import AppPrompt from "./AppPrompt";
import { useComplements, useRowTracking, MIN_SHOWN } from "./GoesWellWith";
import HomeComments from "./HomeComments";
import { useTrending } from "./trending";
import { Price, Money, MixedTotal, totalsByCurrency, shipsFrom, useRates, useCurrency, setCurrency, currencyChoices } from "./fx";
import { rankBrands } from "./brand-match";
import { BuyerForm, CheckoutReview, buyerComplete } from "./Checkout";
import { PhotoGrid } from "./PhotoGrid";
import VariantPicker, { optionAxes } from "./VariantPicker";
import AttributeFilters, { attributeRows } from "./AttributeFilters";
import ColorFilter, { colorChoices } from "./ColorFilter";
import { colorCounts, colorOption } from "./colors";
import ColorDots from "./ColorDots";
import CardImages from "./CardImages";
import EmailSignIn from "./EmailSignIn";
import { attrOptions } from "./attrs";
import { collapseGroups, groupIndex } from "./colorways";
import { withLiveStock, fetchLiveStock } from "./live-stock";
const read = (key, fallback) => {
  try {
    return JSON.parse(localStorage.getItem(key)) ?? fallback;
  } catch {
    return fallback;
  }
};
const storedCart = read("marracat-cart", []),
  storedSaved = read("marracat-saved", []);
const startCart = Array.isArray(storedCart)
  ? storedCart.filter(
      (l) =>
        typeof l?.id === "string" &&
        Number.isInteger(l.quantity) &&
        l.quantity > 0 &&
        l.quantity <= 99,
    )
  : [];
// The shopper's details for the checkout across brands, kept in this browser.
const storedBuyer = (() => {
  try { return JSON.parse(localStorage.getItem("marracat-buyer")); } catch { return null; }
})();
const startBuyer = storedBuyer && typeof storedBuyer === "object" ? storedBuyer : null;
const startSaved = Array.isArray(storedSaved)
  ? storedSaved.filter((x) => typeof x === "string")
  : [];
/** The blue Marracat Clean mark. On a product page it links to the standard. */
function CleanBadge({ explain = false }) {
  const mark = (
    <span className="clean-badge">
      <ShieldCheck size={15} /> Marracat Clean
    </span>
  );
  return explain ? (
    <a className="clean-badge-link" href="/clean">
      {mark} <span className="clean-badge-why">What this means</span>
    </a>
  ) : (
    mark
  );
}

/** What the badge means. Mirrors the app's standard sheet and
 * catalog/clean_standard.md; keep the three in step. */
function CleanStandardPage() {
  const rules = [
    ["Ingredient list published", "The brand publishes an ingredient list on its product page, and the badge is checked against that list. We can’t confirm the list is complete. No list, no badge."],
    ["Banned nowhere", "No ingredient in it is banned in a major cosmetics market. Europe’s list is the longest anywhere, over 1,700 substances, and where another market bans something Europe still permits, that fails too: chlorphenesin is allowed in Europe and not in Japan, and sunscreen filters banned in Palau fail in any sunscreen."],
    ["Plus what the law only caps", "Where a country sets a concentration limit rather than a ban, the ingredient is usually barred instead, because an ingredient list can’t prove how much is in the bottle: no parabens, isothiazolinone preservatives, triclosan or retinyl palmitate. EDTA goes too, on the EU Ecolabel’s biodegradability rules, and so do SLS and SLES."],
    ["Fragrance is disclosed", "“Fragrance”, “parfum” or “scent” alone doesn’t pass. The brand names its fragrance allergens to the European standard that takes effect in July 2026, or uses no fragrance."],
    ["Candles follow the same idea", "Candles aren’t cosmetics, so their badge asks for the wax and wick to be named, no metal-core wick, and a scent from essential oils, stated phthalate-free, or none."],
    ["Some things are never badged", "Relaxers, keratin and straightening treatments, permanent colour, and skin bleaching, whatever the formula."],
  ];
  return (
    <section className="info-page clean-standard">
      <h1>
        <ShieldCheck size={26} /> Marracat Clean
      </h1>
      <p>
        Hair, skincare, makeup and candles marked with the blue shield hold nothing a major market has banned, and the bar
        is tightened again for textured hair and Black skin.
      </p>
      {rules.map(([title, body]) => (
        <div key={title}>
          <h2>{title}</h2>
          <p>{body}</p>
        </div>
      ))}
      <p className="fine-print">
        Read from the brand’s own published ingredient list. It is a check on the formula, not a safety certification,
        medical advice, or a claim that the product is registered to sell in any particular country. Petrolatum, mineral
        oil, linear silicones, the lye in traditional soap and paraffin candle wax are allowed.
      </p>
    </section>
  );
}

/** The quality-label marks beside Clean: Marracat Clear Scent on fragrance,
 * Marracat Safer Clean on household cleaners, Marracat Clean Food on groceries,
 * Marracat Baby Safe on baby products, Marracat Natural Fiber and Safe Fabric
 * on clothing, Marracat Lab Verified on wellness, Marracat Pet Safe on pet
 * products, Marracat True Material on bags and Marracat Natural Home on home
 * goods. On a product page each links to
 * its standard. Mirrors the app's QualityLabelBadge. */
const QUALITY_LABELS = {
  scent: {
    name: "Marracat Clear Scent",
    path: "/clear-scent",
    Icon: Droplet,
    className: "scent-badge",
    intro: "A fragrance marked with the violet drop shows exactly what’s in it, with nothing banned anywhere.",
    rules: [
      ["Ingredients published", "The brand publishes the fragrance’s ingredient list. No list, no badge."],
      ["Nothing banned anywhere", "No ingredient banned in any country: the EU, UK, California, Canada, Japan and more, plus IFRA’s prohibited materials (musk ambrette and tibetene, atranol, lilial, lyral and others)."],
      ["Phthalate-free", "No phthalate of any kind. That includes DEP, which no country bans but which the badge still rules out."],
      ["Scent disclosed", "“Fragrance” passes only with the EU fragrance allergens it contains named beside it, or a formula of named essential oils."],
    ],
  },
  safer: {
    name: "Marracat Safer Clean",
    path: "/safer-clean",
    Icon: Leaf,
    className: "safer-badge",
    intro: "A cleaner marked with the green leaf shows exactly what’s in it, with nothing banned anywhere.",
    rules: [
      ["Ingredients published", "The brand publishes an ingredient list, as California’s Cleaning Product Right to Know Act requires. No list, no badge."],
      ["Nothing banned anywhere", "No chlorine bleach, phosphates, nonylphenol ethoxylates, triclosan, PFAS, borates or 1,4-dioxane, and nothing on Marracat Clean’s list."],
      ["Fragrance disclosed", "“Fragrance” passes only with its allergens named, or a formula of named essential oils."],
      ["Noted, not failed", "Quats (benzalkonium chloride) and optical brighteners are legal everywhere, so they are noted rather than failed."],
    ],
  },
  food: {
    name: "Marracat Clean Food",
    path: "/clean-food",
    Icon: Carrot,
    className: "food-badge",
    intro: "A food marked with the orange carrot has a published ingredient list, with no additive on it banned in any country.",
    rules: [
      ["Ingredients published", "The brand publishes an ingredient list. No list, no badge."],
      ["Nothing banned anywhere", "No Red No. 3, no synthetic dyes banned somewhere (Red 40, Yellow 5 and 6, Blue 1 and 2, Green 3), no titanium dioxide, potassium bromate, brominated vegetable oil, azodicarbonamide, propylparaben, partially hydrogenated oil, cyclamate or olestra."],
      ["No high-fructose corn syrup", "Not banned anywhere, but left out by the Marracat standard."],
      ["Noted, not failed", "BHA/BHT, caramel colour and carrageenan are legal everywhere, so they are noted rather than failed."],
    ],
  },
  baby: {
    name: "Marracat Baby Safe",
    path: "/baby-safe",
    Icon: Baby,
    className: "baby-badge",
    intro: "A baby product marked in sky blue says exactly what it’s made of, with nothing banned for children anywhere.",
    rules: [
      ["What it’s made of, published", "Washes and creams publish an ingredient list; bottles, teethers, clothing and toys name their materials. Neither, no badge."],
      ["Nothing banned for children", "No BPA, phthalates, PVC, melamine, lead, cadmium, flame retardants or PFAS, and nothing the EU restricts for children under 3 (salicylic acid outside shampoo, talc, borates, methylisothiazolinone)."],
      ["No fragrance at all", "Baby washes and creams have no fragrance, no fragrance allergens and no essential oils."],
      ["Natural fibres", "Clothing and bedding are cotton, organic cotton, linen, wool, silk or hemp, or GOTS / OEKO-TEX certified. Polyester and bamboo viscose alone don’t qualify."],
    ],
  },
  fiber: {
    name: "Marracat Natural Fiber",
    path: "/natural-fiber",
    Icon: Shirt,
    className: "fiber-badge",
    intro: "A garment marked in flax tan states its fibres, and at least 90% of them are natural.",
    rules: [
      ["Composition stated", "The brand says exactly what the garment is made of: percentages, “100% linen”, or one named fibre. No composition, no badge."],
      ["At least 90% natural fibre", "Cotton, linen, hemp, ramie, wool, merino, alpaca, mohair, cashmere or silk. Up to 10% stretch (elastane) is allowed and noted."],
      ["Viscose isn’t natural", "Viscose, rayon, modal, lyocell (Tencel), cupro, acetate and “bamboo” fabric are plant pulp dissolved in chemicals and re-spun. EU and US textile rules class them as man-made, and so does this badge."],
      ["Organic tier", "“Marracat Natural Fiber · Organic” when the fibre is organic or GOTS certified."],
    ],
  },
  fiberOrganic: {
    name: "Marracat Natural Fiber · Organic",
    path: "/natural-fiber",
    Icon: Shirt,
    className: "fiber-badge",
    intro: "A garment marked in flax tan states its fibres, and at least 90% of them are natural.",
    rules: [
      ["Composition stated", "The brand says exactly what the garment is made of: percentages, “100% linen”, or one named fibre. No composition, no badge."],
      ["At least 90% natural fibre", "Cotton, linen, hemp, ramie, wool, merino, alpaca, mohair, cashmere or silk. Up to 10% stretch (elastane) is allowed and noted."],
      ["Viscose isn’t natural", "Viscose, rayon, modal, lyocell (Tencel), cupro, acetate and “bamboo” fabric are plant pulp dissolved in chemicals and re-spun. EU and US textile rules class them as man-made, and so does this badge."],
      ["Organic tier", "“Marracat Natural Fiber · Organic” when the fibre is organic or GOTS certified."],
    ],
  },
  fabric: {
    name: "Marracat Safe Fabric",
    path: "/safe-fabric",
    Icon: ShieldCheck,
    className: "fabric-badge",
    intro: "A garment marked in teal states its fibres, names no finish banned anywhere, and isn’t mostly synthetic.",
    rules: [
      ["Composition stated", "The brand says exactly what the garment is made of. No composition, no badge."],
      ["No finish banned anywhere", "No PFAS or fluorocarbon water-repellents (California AB 1817, New York, EU), no water-repellent finish not stated PFAS-free, no flame retardants, no antimicrobial biocides, no PVC not stated phthalate-free."],
      ["No harmful synthetics", "Less than half polyester, nylon, acrylic, elastane or polyurethane, unless the fabric is OEKO-TEX Standard 100, bluesign or GOTS certified."],
      ["What a label can’t show", "Banned azo dyes, NPEs and DMF are found by lab tests, not listings. The badge covers them through certification or a mostly natural composition, and doesn’t claim a lab test of every garment."],
    ],
  },
  lab: {
    name: "Marracat Lab Verified",
    path: "/lab-verified",
    Icon: FlaskConical,
    className: "lab-badge",
    intro: "A supplement marked in violet names a third-party programme or lab that tested it, and nothing in it is banned anywhere.",
    rules: [
      ["A named programme", "NSF Certified for Sport or NSF/ANSI 173, USP Verified, Informed Sport or Informed Choice, BSCG Certified, or Clean Label Project."],
      ["Or a published lab report", "A certificate of analysis the brand publishes, from a third-party, independent or ISO 17025 accredited lab."],
      ["A facility audit isn’t enough", "“GMP certified” or an NSF-registered facility audits the factory, not the product. “Third-party tested” with no programme or lab named can’t be checked."],
      ["Nothing banned anywhere", "No DMAA or DMHA, ephedra, sibutramine, tianeptine, phenibut, kratom, yohimbe, higenamine, DHEA, kava, comfrey, CBD, THC or delta-8 — each banned or restricted somewhere (FDA, EU, UK, Australia, Canada, WADA)."],
    ],
  },
  pet: {
    name: "Marracat Pet Safe",
    path: "/pet-safe",
    Icon: PawPrint,
    className: "pet-badge",
    intro: "A pet product marked in coral says what it is, with nothing toxic to pets or banned anywhere.",
    rules: [
      ["Food: complete or single-ingredient", "An AAFCO “complete and balanced” statement (or FEDIAF), or a single-ingredient treat with that ingredient named."],
      ["Nothing toxic to pets", "No xylitol, grapes or raisins, onion or garlic, chocolate, macadamia, caffeine or alcohol; no propylene glycol in cat food (FDA); no ethoxyquin (EU)."],
      ["Grooming: no toxic oils", "Ingredients published, nothing on Marracat Clean’s ban list, and no tea tree, pennyroyal, wintergreen, cinnamon, citrus, pine, ylang-ylang, peppermint, eucalyptus or clove oil (ASPCA)."],
      ["Goods: material named", "Toys, beds, collars and bowls name their material; chew toys and bowls in plastic or rubber are stated BPA- and phthalate-free; no PVC unless phthalate-free."],
    ],
  },
  material: {
    name: "Marracat True Material",
    path: "/true-material",
    Icon: Handbag,
    className: "material-badge",
    intro: "A bag marked in saddle brown names exactly what it’s made of.",
    rules: [
      ["Material named", "Real leather named as such (full-grain, top-grain, genuine, suede), a natural material (canvas, jute, raffia, straw, cork, wool), a named recycled or plant leather, or an honestly named synthetic like PU or nylon."],
      ["No unnamed “vegan leather”", "“Vegan leather”, “faux leather”, “leatherette” and “pleather” have to say what they are: PU, cactus, apple, mushroom."],
      ["No phthalate PVC", "PVC or vinyl must be stated phthalate-free (EU REACH Annex XVII entry 51)."],
      ["Vegetable Tanned tier", "“Marracat True Material · Vegetable Tanned” for leather tanned without chrome — chromium VI in leather is banned in the EU (REACH entry 47)."],
    ],
  },
  materialVeg: {
    name: "Marracat True Material · Vegetable Tanned",
    path: "/true-material",
    Icon: Handbag,
    className: "material-badge",
    intro: "A bag marked in saddle brown names exactly what it’s made of.",
    rules: [],
  },
  home: {
    name: "Marracat Natural Home",
    path: "/natural-home",
    Icon: House,
    className: "home-badge",
    intro: "A home product marked in sage names its main material, and that material is natural or certified.",
    rules: [
      ["Material named", "Solid wood, rattan, wicker, jute, seagrass, stone, marble, glass, ceramic, linen, cotton or wool — or a textile at least 90% natural fibre or OEKO-TEX / GOTS certified."],
      ["Lead-free ceramics", "Mugs, plates and bowls in ceramic, stoneware or porcelain are stated lead-free (FDA ceramicware lead levels; California Prop 65). Lead crystal doesn’t pass."],
      ["Nothing banned anywhere", "No MDF or particleboard without CARB Phase 2 / TSCA Title VI formaldehyde compliance, no PVC unless phthalate-free, no bamboo-fibre melamine (barred from EU food contact)."],
      ["Certified tier", "“Marracat Natural Home · Certified” for organic or GOTS textiles and FSC-certified wood."],
    ],
  },
  homeCertified: {
    name: "Marracat Natural Home · Certified",
    path: "/natural-home",
    Icon: House,
    className: "home-badge",
    intro: "A home product marked in sage names its main material, and that material is natural or certified.",
    rules: [],
  },
};
// The tiers explain the same standard as their badge.
QUALITY_LABELS.materialVeg.rules = QUALITY_LABELS.material.rules;
QUALITY_LABELS.homeCertified.rules = QUALITY_LABELS.home.rules;

function QualityLabelBadge({ kind, explain = false }) {
  const { name, path, Icon, className } = QUALITY_LABELS[kind];
  const mark = (
    <span className={className}>
      <Icon size={15} /> {name}
    </span>
  );
  return explain ? (
    <a className="clean-badge-link" href={path}>
      {mark} <span className="clean-badge-why">What this means</span>
    </a>
  ) : (
    mark
  );
}

function QualityLabelStandardPage({ kind }) {
  const { name, Icon, className, intro, rules } = QUALITY_LABELS[kind];
  return (
    <section className={`info-page clean-standard ${className}-standard`}>
      <h1>
        <Icon size={26} /> {name}
      </h1>
      <p>{intro}</p>
      {rules.map(([title, body]) => (
        <div key={title}>
          <h2>{title}</h2>
          <p>{body}</p>
        </div>
      ))}
      <p className="fine-print">
        Read from the ingredient list or materials the brand publishes. A product that doesn’t publish them isn’t
        badged. It is a check on what’s published, not a lab test.
      </p>
    </section>
  );
}

/** The gold Marracat True Metal mark on jewelry, with its Ethically Sourced
 * tier. On a product page it links to the standard. */
function TrueMetalBadge({ metal, explain = false }) {
  const mark = (
    <span className="metal-badge">
      <Gem size={15} /> Marracat True Metal{metal === "ethical" ? " · Ethically Sourced" : ""}
    </span>
  );
  return explain ? (
    <a className="clean-badge-link" href="/true-metal">
      {mark} <span className="clean-badge-why">What this means</span>
    </a>
  ) : (
    mark
  );
}

/** What the gold badge means. Mirrors the app's sheet and
 * catalog/metal_standard.md; keep the three in step. */
function TrueMetalStandardPage() {
  const rules = [
    ["Solid, real metal", "Every metal the listing names is 10 karat gold or more, sterling silver, platinum, 316L or surgical steel, titanium or niobium. Plain stainless steel needs to say it is nickel-free."],
    ["Nothing plated as solid", "No plating, gold-tone, PVD, dipped, gold-filled or vermeil over another metal. Rhodium over silver, white gold or platinum is allowed: it is those metals’ standard finish."],
    ["Skin-safe", "No nickel, lead or cadmium as a material. The qualifying metals sit inside the EU, US and California limits for jewelry."],
    ["Ethically Sourced tier", "The listing names recycled metal, Fairmined or Fairtrade gold, Responsible Jewellery Council certification, lab-grown stones, or Kimberley Process conflict-free stones. A bare “ethically sourced” isn’t enough."],
  ];
  return (
    <section className="info-page clean-standard metal-standard">
      <h1>
        <Gem size={26} /> Marracat True Metal
      </h1>
      <p>Jewelry marked with the gold gem names only real, solid, skin-safe metal.</p>
      {rules.map(([title, body]) => (
        <div key={title}>
          <h2>{title}</h2>
          <p>{body}</p>
        </div>
      ))}
      <p className="fine-print">
        Read from what the brand publishes about the piece. A listing that doesn’t name its metal isn’t badged. It is a
        check on the listing, not an assay or a certification.
      </p>
    </section>
  );
}

let fullRequested = false;
// Pages that draw before the full catalog lands and then fire FAST_READY.
const FAST_FIRST = new Set(["/shop", "/product", "/orders", "/order", "/account"]);
// Product types (or a department's other aisles) listed in the filter column
// before "Show all".
const TYPES_SHOWN = 7;

function ProductFeed({ products, renderProduct, total, onMore }) {
  const [limit, setLimit] = useState(36);
  const sentinel = useRef(null);
  // onMore: the page came from /api/query, which sends a page at a time.
  const hasMore = limit < products.length || (!!onMore && total > products.length);
  const grow = () => {
    if (onMore && limit + 36 > products.length) onMore();
    setLimit((current) => (onMore ? current + 36 : Math.min(current + 36, products.length)));
  };
  useEffect(() => {
    if (!hasMore || !sentinel.current || !("IntersectionObserver" in window))
      return;
    const observer = new IntersectionObserver(
      ([entry]) => {
        if (entry.isIntersecting) {
          observer.disconnect();
          grow();
        }
      },
      { rootMargin: "600px 0px" },
    );
    observer.observe(sentinel.current);
    return () => observer.disconnect();
  }, [hasMore, limit, products.length]);
  return (
    <>
      <div className="product-grid">
        {products.slice(0, limit).map(renderProduct)}
      </div>
      <div ref={sentinel} className="load-more" data-testid="scroll-sentinel">
        <p role="status">
          {hasMore || total > products.length
            ? `Showing ${Math.min(limit, products.length)} of ${(total || products.length).toLocaleString()} products`
            : `You’ve explored all ${products.length.toLocaleString()} products.`}
        </p>
        {hasMore && (
          <button
            className="outline-button"
            onClick={grow}
          >
            Show more finds
          </button>
        )}
      </div>
    </>
  );
}
/// The iPhone app's banner. It only appears once Apple confirms the listing is
/// live (/api/ios-app asks iTunes): the app was sitting approved but removed
/// from sale on 2026-09-23, and a button onto a 404 is worse than no button.
///
/// The button opens the App Store, which on an iPhone hands straight to the
/// App Store app. Everyone else gets the QR code to scan with their phone —
/// shown by default on a desktop, one tap away on a phone that isn't an iPhone.
function AppBanner({ hasApp = false, promptHere = false }) {
  const [app, setApp] = useState(null);
  const [dismissed, setDismissed] = useState(() => {
    try {
      return localStorage.getItem("marracat.appBanner") === "dismissed";
    } catch {
      return false;
    }
  });
  const [showCode, setShowCode] = useState(false);
  const isIOS =
    typeof navigator !== "undefined" &&
    (/iPhone|iPod/.test(navigator.userAgent) ||
      // iPadOS reports itself as a Mac; the touch points give it away.
      (/iPad|Macintosh/.test(navigator.userAgent) && navigator.maxTouchPoints > 1));

  useEffect(() => {
    if (dismissed) return;
    const controller = new AbortController();
    fetch("/api/ios-app", { signal: controller.signal })
      .then((r) => (r.ok ? r.json() : null))
      .then((body) => body?.live && setApp(body))
      .catch(() => {});
    return () => controller.abort();
  }, [dismissed]);

  // Safari on iPhone/iPad already draws Apple's own Smart App Banner (the
  // apple-itunes-app meta tag), so a second one there is a duplicate (owner,
  // 2026-09-30). Other iOS browsers and in-app browsers don't show Apple's.
  const appleBannerShown =
    isIOS &&
    /Safari\//.test(navigator.userAgent) &&
    !/CriOS|FxiOS|EdgiOS|OPiOS|GSA|DuckDuckGo|Instagram|FBAN|FBAV|TikTok|musical_ly|Snapchat|Twitter|LinkedInApp/.test(navigator.userAgent);
  // Product and brand pages carry their own "Shop … in the app" row
  // (AppPrompt) for iPhone/iPad; two app prompts on one page is clutter
  // (owner, 2026-10-10).
  if (hasApp || dismissed || !app || appleBannerShown || (isIOS && promptHere)) return null;
  const close = () => {
    setDismissed(true);
    try {
      localStorage.setItem("marracat.appBanner", "dismissed");
    } catch {
      /* private browsing: it comes back next visit, which is fine */
    }
  };
  return (
    <aside className="app-banner" data-testid="app-banner">
      <div className="app-banner-inner">
        <img className="app-banner-icon" src="/apple-touch-icon.png" alt="" width="44" height="44" />
        <div className="app-banner-copy">
          <strong>Marracat for iPhone and iPad</strong>
          <span>
            {isIOS
              ? "Shop every brand from the App Store app."
              : "Every brand on Marracat, in your pocket."}
          </span>
        </div>
        <div className="app-banner-actions">
          {/* Off iOS, the QR code is the way in (owner, 2026-09-30: nobody
              needs the App Store page on a desktop). */}
          {isIOS && (
            <a className="app-banner-get" href={app.url} target="_blank" rel="noopener noreferrer">
              Get the app
            </a>
          )}
          {!isIOS && (
            <button
              type="button"
              className="app-banner-qr-toggle"
              aria-expanded={showCode}
              onClick={() => setShowCode((on) => !on)}
            >
              {showCode ? "Hide QR code" : "Show QR code"}
            </button>
          )}
        </div>
        <button type="button" className="app-banner-close" onClick={close} aria-label="Dismiss">
          <X size={18} />
        </button>
        {!isIOS && (
          <figure className={`app-banner-qr${showCode ? " is-open" : ""}`}>
            {/* Encodes marracat.com/app: opens Marracat on the iPhone or iPad
                that scans it, or its App Store page when it isn't installed. */}
            <img src="/app-qr.svg?v=2" alt="QR code that opens Marracat on your iPhone or iPad" width="64" height="64" />
            <figcaption>Scan with your iPhone or iPad camera</figcaption>
          </figure>
        )}
      </div>
    </aside>
  );
}
// A department's three pills: All and its two biggest aisles, the open aisle
// taking the last spot if it's further down (owner, 2026-10-24: "only have 3
// filter pills"). The other aisles, skin concern, free of and colour are in
// the filter column beside the grid since 2026-11-03.
const AISLES_SHOWN = 2;
const SORT_LABELS = {
  featured: "Featured",
  low: "Price: low to high",
  high: "Price: high to low",
  new: "Newest arrivals",
};
// What the Sort pill shows on a phone, where three pills share the width.
const SORT_SHORT = { featured: "Featured", low: "Price ↑", high: "Price ↓", new: "Newest" };
const aisleLink = (params) => hrefFor("/shop?" + new URLSearchParams(params).toString());
function splitAisles(aisles, aisle) {
  const at = aisles.findIndex((a) => a.leaf === aisle);
  const shown = at < AISLES_SHOWN ? aisles.slice(0, AISLES_SHOWN) : [...aisles.slice(0, AISLES_SHOWN - 1), aisles[at]];
  return { shown, rest: aisles.filter((a) => !shown.includes(a)) };
}
function FilterPills({ aisles, category, aisle }) {
  if (!aisles.length) return null;
  const { shown } = splitAisles(aisles, aisle);
  return (
    <nav className="aisle-chips" aria-label="Aisles">
      <a href={aisleLink({ category })} className={aisle ? "" : "active"}>
        All
      </a>
      {shown.map((a) => (
        <a key={a.id} href={aisleLink({ category, aisle: a.leaf })} className={aisle === a.leaf ? "active" : ""}>
          {a.name} <small>{a.count.toLocaleString()}</small>
        </a>
      ))}
    </nav>
  );
}
function App() {
  const [catalog, setCatalog] = useState(null),
    [loadError, setLoadError] = useState(false),
    [route, setRoute] = useState(currentRoute),
    [query, setQuery] = useState(""),
    [menu, setMenu] = useState(false),
    [cart, setCart] = useState(startCart),
    [saved, setSaved] = useState(startSaved),
    [buyer, setBuyer] = useState(startBuyer),
    [buyerOpen, setBuyerOpen] = useState(false),
    [notice, setNotice] = useState(""),
    [authOpen, setAuthOpen] = useState(false),
    [providers, setProviders] = useState(null),
    [session, setSession] = useState(null),
    [authError, setAuthError] = useState(""),
    [authBusy, setAuthBusy] = useState(false),
    [authByEmail, setAuthByEmail] = useState(false),
    [sort, setSort] = useState("featured"),
    [brandFilter, setBrandFilter] = useState(""),
    [typeFilter, setTypeFilter] = useState(""),
    // The country brands are based in ("NG"), or "" (owner, 2026-11-26).
    [countryFilter, setCountryFilter] = useState(""),
    [allCountries, setAllCountries] = useState(false),
    [inStock, setInStock] = useState(false),
    [cleanOnly, setCleanOnly] = useState(false),
    [metalOnly, setMetalOnly] = useState(false),
    [scentOnly, setScentOnly] = useState(false),
    [saferOnly, setSaferOnly] = useState(false),
    [foodOnly, setFoodOnly] = useState(false),
    [babyOnly, setBabyOnly] = useState(false),
    [fiberOnly, setFiberOnly] = useState(false),
    [fabricOnly, setFabricOnly] = useState(false),
    [labOnly, setLabOnly] = useState(false),
    [petOnly, setPetOnly] = useState(false),
    [materialOnly, setMaterialOnly] = useState(false),
    [homeOnly, setHomeOnly] = useState(false),
    [filtersOpen, setFiltersOpen] = useState(false),
    [allTypes, setAllTypes] = useState(false),
    [variantID, setVariantID] = useState(""),
    [detailProduct, setDetailProduct] = useState(null),
    [liveStock, setLiveStock] = useState(null),
    [details, setDetails] = useState(() => new Map());
  // The full catalog is over a megabyte even compressed, and the page used to
  // show nothing until all of it arrived. The home screen's own products come
  // first in a small payload and draw straight away; the full list replaces
  // them when it lands, and every other page waits for that.
  const fetchCatalog = () => {
    setLoadError(false);
    const valid = (c) =>
      Array.isArray(c.brands) &&
      Array.isArray(c.products) &&
      Array.isArray(c.categories);
    let full = false;
    let mark = "";
    try {
      if (localStorage.getItem("marracat-owner") === "1") mark = "&o=1";
    } catch {}
    fetch("/api/home?v=5" + mark)
      .then((r) => (r.ok ? r.json() : null))
      .then((c) => {
        if (c && valid(c) && !full) {
          setSearchCategories(c.categories);
          setCatalog((current) => current || c);
        }
      })
      .catch(() => {});
    // A first load of a page that draws from /api/query or /api/products
    // first holds the full catalog back until that page fires FAST_READY (or
    // 4 s) so the two don't split a phone's bandwidth (2026-10-10). Every
    // other page (home, cart, saved, brands, ...) has nothing to wait for:
    // holding it back there only added a dead 4 s to a reload of the cart or
    // saved items before the download even began (2026-10-12).
    const gate = fullRequested || !FAST_FIRST.has(route.split("?")[0]) ? Promise.resolve()
      : new Promise((resolve) => { window.addEventListener(FAST_READY, resolve, { once: true }); setTimeout(resolve, 4000); });
    const landed = (c, from) => {
      if (!valid(c)) throw Error();
      full = true;
      markCatalog(from);
      // Search reads department names, as the server's does (src/catalog.js).
      setSearchCategories(c.categories);
      setCatalog(c);
    };
    const failed = () => {
      if (!full) setLoadError(true);
    };
    // As before the worker: the page downloads and reads the whole list itself.
    const onPage = () =>
      gate
        .then(() => { fullRequested = true; return fetch("/api/catalog?v=5" + mark, { priority: "low" }); })
        .then((r) => {
          if (!r.ok) throw Error();
          return r.json();
        })
        .then((c) => landed(c, "page"))
        .catch(failed);
    // A worker reads it, from the copy on this device or the network, and
    // hands it over a line at a time (src/catalog-loader.js); a browser
    // without module workers, or a worker that fails, loads it on the page.
    const started = loadCatalogInWorker({
      url: "/api/catalog?v=5&lines=1" + mark,
      gate: gate.then(() => { fullRequested = true; }),
      onCatalog: (c, from) => { try { landed(c, from); } catch { failed(); } },
      onIndex: markIndexed,
      onError: failed,
      onFallback: onPage,
    });
    if (!started) onPage();
  };
  useEffect(() => {
    fetchCatalog();
    const navigate = () => {
      setRoute(fromPath(location.pathname, location.search));
      setMenu(false);
      setFiltersOpen(false);
      setAllTypes(false);
      setBrandFilter("");
      setTypeFilter("");
      setCountryFilter("");
      setAllCountries(false);
      setCleanOnly(false);
      setMetalOnly(false);
      setScentOnly(false);
      setSaferOnly(false);
      setFoodOnly(false);
      setBabyOnly(false);
      setFiberOnly(false);
      setFabricOnly(false);
      setLabOnly(false);
      setPetOnly(false);
      setMaterialOnly(false);
      setHomeOnly(false);
      setSort("featured");
      setVariantID("");
      window.scrollTo(0, 0);
    };
    // Going to another page cross-fades (owner, 2026-11-10); a filter, a sort
    // or a search on the page you are on does not, and nor does anything for
    // someone who asked their device for less motion. The page is redrawn
    // inside the browser's snapshot, so React has to finish there and then.
    const onNavigate = (e) => {
      if (!e.detail?.page || !document.startViewTransition || matchMedia("(prefers-reduced-motion: reduce)").matches) return navigate();
      const t = document.startViewTransition(() => flushSync(navigate));
      // A second navigation mid-fade skips this one; that is not an error.
      for (const done of [t.ready, t.finished, t.updateCallbackDone]) done?.catch(() => {});
    };
    window.addEventListener("marracat:navigate", onNavigate);
    return () => window.removeEventListener("marracat:navigate", onNavigate);
  }, []);
  // One anonymous visit a load for the owner dashboard's returning visitors,
  // actives and sources (server/visits.js). The owner's browser never sends.
  useEffect(() => {
    try {
      if (localStorage.getItem("marracat-owner") === "1") return;
      let id = localStorage.getItem("marracat-visitor");
      if (!id) {
        id = crypto.randomUUID();
        localStorage.setItem("marracat-visitor", id);
      }
      const src = new URLSearchParams(location.search).get("src") ||
        new URLSearchParams(location.hash.split("?")[1] || "").get("src") || "";
      fetch("/api/visit", {
        method: "POST",
        keepalive: true,
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ id, ref: document.referrer, src }),
      }).catch(() => {});
    } catch {
      /* storage blocked: this visit just isn't counted */
    }
  }, []);
  useEffect(() => {
    fetch("/auth/session")
      .then((r) => r.json())
      .then((s) => {
        setSession(s);
        // A sign-in started here (signIn below) finished if we're back signed in.
        try {
          const provider = sessionStorage.getItem("marracat-signin");
          if (provider) {
            sessionStorage.removeItem("marracat-signin");
            if (s?.user && !s.user.owner) track("sign_in_complete", { provider });
          }
        } catch {}
        // The owner's own visits stay out of the dashboard from now on, in
        // this browser, even after signing out.
        if (s?.user?.owner)
          try {
            localStorage.setItem("marracat-owner", "1");
          } catch {}
      })
      .catch(() => {});
    fetch("/api/auth-status")
      .then((r) => r.json())
      .then(setProviders)
      .catch(() => setProviders({}));
    const error = new URLSearchParams(location.search).get("error");
    if (error) {
      setAuthOpen(true);
      setAuthError("Sign-in could not be completed. Please try again.");
      history.replaceState({}, "", location.pathname);
    }
  }, []);
  useEffect(() => {
    try {
      localStorage.setItem("marracat-cart", JSON.stringify(cart));
    } catch {
      setNotice("Your browser could not save this cart.");
    }
  }, [cart]);
  // The account's cart, shared with the app (cartSync.js). A cart that came
  // from the account isn't sent back; any other change is, a moment later.
  const cartFromAccount = useRef(false);
  const cartRef = useRef(cart);
  const signedInID = session?.user?.id || null;
  useEffect(() => {
    if (!signedInID) return;
    let live = true;
    const pull = () => pullCart(cartRef.current).then((next) => {
      if (live && next) { cartFromAccount.current = true; setCart(next); }
    });
    pull();
    const onFocus = () => document.visibilityState === "visible" && pull();
    document.addEventListener("visibilitychange", onFocus);
    window.addEventListener("focus", onFocus);
    return () => { live = false; document.removeEventListener("visibilitychange", onFocus); window.removeEventListener("focus", onFocus); };
  }, [signedInID]);
  const firstCart = useRef(true);
  useEffect(() => {
    cartRef.current = cart;
    if (firstCart.current) { firstCart.current = false; return; }
    if (cartFromAccount.current) { cartFromAccount.current = false; return; }
    markDirty();
    if (!signedInID) return;
    const t = setTimeout(() => pushCart(cart), 700);
    return () => clearTimeout(t);
  }, [cart]);
  useEffect(() => {
    try {
      localStorage.setItem("marracat-saved", JSON.stringify(saved));
    } catch {}
  }, [saved]);
  useEffect(() => {
    try {
      if (buyer) localStorage.setItem("marracat-buyer", JSON.stringify(buyer));
      else localStorage.removeItem("marracat-buyer");
    } catch {}
  }, [buyer]);
  useEffect(() => {
    if (notice) {
      const timer = setTimeout(() => setNotice(""), 3000);
      return () => clearTimeout(timer);
    }
  }, [notice]);
  useEffect(() => {
    if (authOpen) {
      setAuthByEmail(false); // each opening starts at Apple and Google
      const dialog = document.querySelector("#auth-dialog");
      dialog?.showModal();
      return () => dialog?.close();
    }
  }, [authOpen]);
  // The shop's filters follow the shopper down the page (owner, 2026-11-08).
  const headerHeight = useHeightVar("--header-h");
  const toolbarHeight = useHeightVar("--shop-toolbar-h");
  const brands = catalog?.brands || [],
    products = catalog?.products || [],
    categories = catalog?.categories || [],
    subcategories = catalog?.subcategories || [];
  const brandMap = useMemo(
    () => new Map(brands.map((b) => [b.id, b])),
    [brands],
  );
  const productMap = useMemo(
    () => new Map(products.map((p) => [p.id, p])),
    [products],
  );
  const available = useMemo(
    () => filterProducts(products, brands, { stock: true }),
    [products, brands],
  );
  // Colourways (src/colorways.js): each group's members, and the colour a
  // visitor picked on a card (group -> product id).
  const groupMembers = useMemo(() => groupIndex(products), [products]);
  const [colorPick, setColorPick] = useState({});
  const path = route.split("?")[0],
    params = new URLSearchParams(route.split("?")[1] || ""),
    category = params.get("category") || "",
    aisle = params.get("aisle") || "",
    selectedBrand = params.get("brand") || "",
    search = params.get("q") || "";
  // A /shop?sort=new link shows Newest until the visitor picks another sort.
  const sortValue = params.get("sort") === "new" && sort === "featured" ? "new" : sort;
  // Prices show in dollars unless the visitor picks another currency (fx.jsx).
  const fxRates = useRates();
  const shownCurrency = useCurrency();
  const currencyOptions = currencyChoices(fxRates);
  // The tab title and canonical address follow the screen, the way the server
  // writes them for /p/, /b/ and /c/ on first load (server/share-page.js).
  useEffect(() => {
    const id = params.get("id");
    const product = path === "/product" && id ? productMap.get(id) || detailProduct : null;
    const onlyBrand = path === "/shop" && selectedBrand && [...params.keys()].every((k) => k === "brand");
    const dept = path === "/shop" && category && !selectedBrand && !search
      ? (aisle ? subcategories.find((x) => x.id === `${category}:${aisle}`)?.name : categories.find((c) => c.id === category)?.name) : "";
    document.title = product
      ? `${product.title}${brandMap.get(product.brand)?.name ? ` · ${brandMap.get(product.brand).name}` : ""} | Marracat`
      : onlyBrand && brandMap.get(selectedBrand) ? `${brandMap.get(selectedBrand).name} | Marracat`
      : dept ? `${dept} from independent brands | Marracat`
      : "Marracat | Your next favorite. All in one place.";
    const canonical = document.querySelector('link[rel="canonical"]');
    if (canonical) canonical.href = "https://marracat.com" + hrefFor(route).split("?")[0];
  }, [route, productMap, brandMap, categories, subcategories, detailProduct]);
  const go = (to) => {
    navigate(to);
    setMenu(false);
  };
  const shop = (params = {}) =>
    "/shop?" + new URLSearchParams(params).toString();
  const toast = setNotice;
  const social = useSocial(session);
  const socialCount =
    (social.me?.counts?.incoming || 0) + (social.me?.counts?.unseen_shares || 0);
  function toggleSaved(id) {
    track(saved.includes(id) ? "unsave" : "save", { product: id, brand: productMap.get(id)?.brand });
    setSaved((s) => (s.includes(id) ? s.filter((x) => x !== id) : [...s, id]));
  }
  function add(p, v) {
    if (!v?.available || !p.available) return;
    const key = `${p.id}:${v.id}`;
    setCart((lines) => {
      const existing = lines.find((l) => l.key === key);
      return existing
        ? lines.map((l) =>
            l.key === key
              ? { ...l, quantity: Math.min(99, l.quantity + 1) }
              : l,
          )
        : [...lines, { key, id: p.id, variant: String(v.id), quantity: 1 }];
    });
    toast("Added to your cart");
    track("add_to_cart", { product: p.id, brand: p.brand });
  }
  // "Buy it again" from Your Orders: straight into the cart when the product
  // has one option in stock, else its page to pick a size or colour.
  async function buyAgain(p) {
    const d = await fetch(productURL(p.id)).then((r) => (r.ok ? r.json() : null)).catch(() => null);
    const options = (d?.variants || []).filter((v) => v.available);
    // Same rule as the product cards: one-tap add for Shopify brands only.
    if (d && options.length === 1 && (d.variants || []).length === 1 && usesMarracatCart(brandMap.get(p.brand)))
      add({ ...p, ...d, available: true }, options[0]);
    else go("/p/" + encodeURIComponent(p.id));
  }
  const cartIDs = cart.map((l) => l.id).join(",");
  useEffect(() => {
    const missing = [...new Set(cart.map((l) => l.id))].filter((id) => !details.has(id));
    if (!missing.length) return;
    const controller = new AbortController();
    Promise.all(
      missing.map((id) =>
        fetch(productURL(id), { signal: controller.signal })
          .then((r) => (r.ok ? r.json() : null))
          .catch(() => null),
      ),
    ).then((found) => {
      if (controller.signal.aborted) return;
      setDetails((current) => {
        const next = new Map(current);
        found.forEach((p) => p && next.set(p.id, p));
        return next;
      });
    });
    return () => controller.abort();
  }, [cartIDs]);
  // Sponsored products (Sponsored.jsx): the top of a search or an aisle, and
  // a row beside a product's own.
  const sponsoredSearch = useSponsored(search ? "search" : "category", { q: search, category }, path === "/shop" && (!!search || !!category));
  const sponsoredNear = useSponsored("product", { product: params.get("id") || "" }, path === "/product" && !!params.get("id"));
  // "Goes well with": the brand's own picks plus what shoppers cart together.
  const complementsFor = path === "/product" ? params.get("id") || "" : "";
  const complements = useComplements(complementsFor, productMap);
  // "Top picks in <aisle>": other brands' finds from this product's own aisle
  // (else its department), one per brand, the same picks on every visit.
  // Owner, 2026-11-08: swap out "Goes well with" (4 taps in 291 views on the
  // site, 30 days) for rows people tap — the app's "Top picks in" rows are
  // tapped about half the time. "Goes well with" moves to the bottom.
  const typePicks = useMemo(() => {
    const p = complementsFor && productMap.get(complementsFor);
    if (!p) return { title: "", items: [] };
    const sub = (p.subs || [])[0] || "";
    const name = (sub && subcategories.find((x) => x.id === `${p.category}:${sub}`)?.name) ||
      categories.find((c) => c.id === p.category)?.name || "";
    const seed = (id) => { let h = 2166136261; for (const ch of p.id + id) h = Math.imul(h ^ ch.charCodeAt(0), 16777619); return h >>> 0; };
    const pool = available
      .filter((x) => x.category === p.category && x.brand !== p.brand && (!sub || (x.subs || []).includes(sub)))
      .sort((a, c) => seed(a.id) - seed(c.id));
    const seen = new Set(), items = [];
    for (const x of pool) {
      if (seen.has(x.brand)) continue;
      seen.add(x.brand);
      items.push(x);
      if (items.length === 6) break;
    }
    return { title: name ? `Top picks in ${name}` : "", items };
  }, [complementsFor, productMap, available, subcategories, categories]);
  const tapTypePicks = useRowTracking("type_top", complementsFor, !!typePicks.title && typePicks.items.length >= MIN_SHOWN);
  const brandMore = useMemo(() => {
    const p = complementsFor && productMap.get(complementsFor);
    return p ? available.filter((x) => x.brand === p.brand && x.id !== p.id).slice(0, 6) : [];
  }, [complementsFor, productMap, available]);
  const tapBrandMore = useRowTracking("brand_more", complementsFor, brandMore.length > 0);
  // "Goes well with" skips what the rows above it already show (owner,
  // 2026-11-17: two rows shouldn't show the same products).
  const goesWell = useMemo(() => {
    const p = complementsFor && productMap.get(complementsFor);
    return brandFirst(unseenIn(complements, [typePicks.items, brandMore]), p?.brand).slice(0, 6);
  }, [complements, typePicks, brandMore, complementsFor, productMap]);
  const tapGoesWell = useRowTracking("complements", complementsFor, goesWell.length >= MIN_SHOWN);
  const cartLines = cart.map((l) => {
    const product = details.get(l.id) || productMap.get(l.id);
    return {
      ...l,
      product,
      variant: (product?.variants || []).find((v) => String(v.id) === l.variant),
    };
  });
  const cartTotalsBy = totalsByCurrency(
    cartLines.map((l) => [l.product?.currency, (l.variant?.price || 0) * l.quantity]),
  );

  const count = cart.reduce((n, l) => n + l.quantity, 0);
  const cartTitle = (
    <section className="page-title">
      <h1>
        Your cart <small>({count} items)</small>
      </h1>
      <p>Each brand has its own checkout. Your purchase goes directly to them.</p>
    </section>
  );
  // The cart by brand, for the checkout across brands; only brands whose
  // store builds a checkout from saved details, with every line buyable.
  const cartGroups = [...new Set(cartLines.map((l) => l.product?.brand).filter(Boolean))]
    .map((id) => ({ brand: brandMap.get(id), lines: cartLines.filter((l) => l.product?.brand === id) }))
    .filter((g) => g.brand);
  const checkoutTogether =
    cartGroups.length > 0 &&
    // One brand that can't take a filled-in checkout no longer hides the button
    // for the rest: the review page gives that brand its own checkout link.
    cartGroups.some((g) => g.brand.ucp) &&
    cartGroups.every((g) => g.lines.every((l) => l.product?.available && l.variant?.available)) &&
    cartLines.every((l) => l.product);
  const startCheckout = () => {
    track("checkout_start", checkoutProps(cartLines, "review", cartGroups.length === 1 ? cartGroups[0].brand.id : undefined));
    if (buyerComplete(buyer)) go("/checkout");
    else setBuyerOpen(true);
  };
  // A brand's order is placed: on the shopper's word ("Paid — remove from
  // cart", via "checkout"), or because Shopify's checkout window said so
  // (Checkout Kit, via "checkout_kit"). The order goes on the account, so the
  // app's Orders shows it too, and the brand's lines leave the cart.
  const markPaid = (id, via = "checkout") => {
    const g = cartGroups.find((x) => x.brand.id === id);
    if (g) track("checkout_complete", checkoutProps(g.lines, via, id));
    if (session?.user && g) recordWebOrder(webOrderRecord({
      brandID: id,
      lines: g.lines.map((l) => ({ id: l.id, quantity: l.quantity, title: l.product?.title })),
      subtotal: g.lines.reduce((n, l) => n + (l.variant?.price || 0) * l.quantity, 0),
      currency: g.brand.currency || "USD",
    }));
    setCart((c) =>
      c.filter((l) => (details.get(l.id) || productMap.get(l.id))?.brand !== id),
    );
    toast(via === "checkout_kit" ? "Order placed. Removed from your cart" : "Removed from your cart");
  };
  /// Shopify's checkout window over the page (src/checkoutKit.js) for a
  /// brand's checkout link; false when the link opens the usual way.
  const openKit = (brand, href) =>
    openCheckoutKit(brand, href, {
      onComplete: () => markPaid(brand.id, "checkout_kit"),
      onClose: (started) => {
        const g = cartGroups.find((x) => x.brand.id === brand.id);
        if (g) track("checkout_abandon", { ...checkoutProps(g.lines, "checkout_kit", brand.id), step: started ? "started" : "opened" });
      },
    });
  // Checkout Kit loads on the cart and checkout pages, before any click.
  useEffect(() => {
    if (path === "/cart" || path === "/checkout") preloadCheckoutKit();
  }, [path]);
  const listOptions = {
    q: search,
    category,
    aisle,
    brand: selectedBrand || brandFilter,
    country: selectedBrand ? "" : countryFilter,
    type: typeFilter,
    sale: params.get("sale") === "1",
    under: params.get("under") === "25",
    stock: inStock,
    clean: cleanOnly,
    metal: metalOnly,
    scent: scentOnly,
    safer: saferOnly,
    food: foodOnly,
    baby: babyOnly,
    fiber: fiberOnly,
    fabric: fabricOnly,
    lab: labOnly,
    pet: petOnly,
    material: materialOnly,
    home: homeOnly,
    ...attrOptions(params),
    color: colorOption(params.get("color")),
    sort,
  };
  const local = useMemo(() => {
    const options = listOptions;
    // Nothing for the whole phrase: show the closest shorter search, or the
    // best guess at what was meant, and offer the other guesses (owner,
    // 2026-11-03: suggestions, not "no matches"). As the app.
    const found = searchWithGuesses(products, brands, options, { relax: !!search });
    const relaxed = found.showing ? { q: found.showing, result: found.result } : null;
    const guessed = found.guessed;
    const without = (o) => (guessed ? filterProducts(products, brands, { ...o, q: relaxed.q })
      : relaxed ? relaxedSearch(products, brands, o)?.result : filterProducts(products, brands, o)) || [];
    const shown = collapseGroups(found.result);
    // The type filter's choices come from the page without it, so picking
    // "Sweatpants" still offers the brand's other types (owner, 2026-10-09).
    const typeBase = typeFilter ? without({ ...options, type: "" }) : shown;
    const counts = new Map();
    for (const p of typeBase)
      for (const leaf of p.subs || []) {
        const id = `${p.category}:${leaf}`;
        counts.set(id, (counts.get(id) || 0) + 1);
      }
    // The colour chips count the page without its own colour (server/query.js does the same).
    const colorBase = options.color ? without({ ...options, color: "" }) : found.result;
    return { result: shown, relaxedQuery: relaxed ? relaxed.q : null, guesses: found.guesses, typeCounts: counts, colors: colorCounts(colorBase) };
  }, [products, brands, route, brandFilter, countryFilter, typeFilter, inStock, cleanOnly, metalOnly, scentOnly, saferOnly, foodOnly, babyOnly, fiberOnly, fabricOnly, labOnly, petOnly, materialOnly, homeOnly, sort]);
  // Until the full catalog lands, a filtered page draws from the server
  // (src/fast-query.js), then from the full list exactly as before.
  const server = useServerQuery(!!catalog?.partial && path === "/shop", {
    ...listOptions,
    sort: params.get("sort") === "new" && sort === "featured" ? "new" : sort,
  });
  const result = server ? server.products : local.result,
    relaxedQuery = server ? server.relaxedQuery : local.relaxedQuery,
    guesses = (server ? server.guesses : local.guesses) || [],
    typeCounts = server ? server.typeCounts : local.typeCounts,
    resultCount = server ? server.total : result.length,
    colors = server ? server.colors : local.colors,
    resultHas = (badge) => (server ? server.badges.includes(badge) : result.some((p) => p[badge]));
  useEffect(() => {
    if (!filtersOpen) return;
    const esc = (e) => e.key === "Escape" && setFiltersOpen(false);
    document.addEventListener("keydown", esc);
    const overflow = document.body.style.overflow;
    document.body.style.overflow = "hidden";
    return () => {
      document.removeEventListener("keydown", esc);
      document.body.style.overflow = overflow;
    };
  }, [filtersOpen]);
  // "Picked for you": a product or two matching a short search and what this
  // browser has been looking at (personalPicks; history stays on the device).
  // Only on a plain search with the full catalog, as the app shows them.
  const catalogDone = !!catalog && !catalog.partial;
  const plainSearch = search && path === "/shop" && !category && !aisle && !selectedBrand && !typeFilter && sort === "featured" && !relaxedQuery;
  const forYou = useMemo(() => {
    if (!plainSearch || !catalogDone) return null;
    const names = new Map(subcategories.map((x) => [x.id, x.name]));
    const recent = readRecent();
    return personalPicks(products, brands, search, recent.searches, recent.viewed,
      (p) => (p.subs?.length ? names.get(`${p.category}:${p.subs[0]}`) : null), productMap);
  }, [plainSearch, catalogDone, search, products, brands, subcategories, productMap]); // eslint-disable-line react-hooks/exhaustive-deps
  const pickedIDs = new Set(forYou?.products.map((p) => p.id) || []);
  const listed = pickedIDs.size ? result.filter((p) => !pickedIDs.has(p.id)) : result;
  // What visitors do, counted on our own server (src/events.js; owner,
  // 2026-10-10). A search counts once, from whichever answered it first: the
  // server (before the full catalog lands) or the full catalog.
  const hostBrand = useRef(new Map());
  useEffect(() => {
    hostBrand.current = new Map(brands.map((b) => [String(b.domain || "").toLowerCase().replace(/^www\./, ""), b.id]));
  }, [brands]);
  useEffect(() => watchBuyClicks((host) => hostBrand.current.get(host.toLowerCase())), []);
  // Each page as the app's screen names (EVENTS.md), once per address.
  const screen = screenFor(path, params);
  screenNow = screen || undefined;
  useEffect(() => {
    monitorScreen(screen || path.replace(/^\//, "").split("/")[0] || "home");
    if (screen) track("screen_view", { screen, brand: screen === "brand" ? selectedBrand : undefined,
      product: screen === "product" ? params.get("id") || undefined : undefined });
  }, [route]);
  const openedID = path === "/product" ? params.get("id") || "" : "";
  useEffect(() => {
    if (openedID) track("product_open", { product: openedID, brand: productMap.get(openedID)?.brand });
    if (openedID) rememberView(openedID);
  }, [openedID]);
  useEffect(() => { if (search) rememberSearch(search); }, [search]);
  const searchCounted = useRef("");
  const catalogComplete = !!catalog && !catalog.partial;
  useEffect(() => {
    if (!search || !(catalogComplete || server) || searchCounted.current === search) return;
    searchCounted.current = search;
    // n=0 when nothing matched the whole phrase (the page fell back to a shorter search).
    track("search", { q: search, n: relaxedQuery ? 0 : resultCount });
  }, [search, catalogComplete, server, resultCount, relaxedQuery]);
  useEffect(() => {
    setDetailProduct(null);
    if (path !== "/product") return;
    const controller = new AbortController();
    fetch(
      productURL(params.get("id") || ""),
      {
        signal: controller.signal,
      },
    )
      .then((r) => {
        if (!r.ok) throw Error();
        return r.json();
      })
      .then((d) => {
        setDetailProduct(d);
        fastReady();
      })
      .catch(() => fastReady());
    return () => controller.abort();
  }, [route]);
  // The brand's store's own stock, since the catalog's can be up to a day old
  // (src/live-stock.js). The page draws from the catalog first and never waits.
  useEffect(() => {
    setLiveStock(null);
    const id = params.get("id");
    if (path !== "/product" || !id) return;
    const controller = new AbortController();
    fetchLiveStock(id, { signal: controller.signal }).then((s) => { if (!controller.signal.aborted) setLiveStock(s); });
    return () => controller.abort();
  }, [route]);
  // The home page's photos change once a day (owner, 2026-10-09): each tile
  // picks today's brand from a hand-picked pool with strong photography, then
  // one of that brand's best sellers. Same picks for every visitor all day.
  const brandPick = (id, salt = 0, category) => {
    const items = available
      .filter((p) => p.brand === id && p.images?.length && (!category || [].concat(category).includes(p.category)))
      .sort((a, b) => (a.best_rank ?? 999) - (b.best_rank ?? 999))
      .slice(0, 6);
    return items.length ? daily(items, salt) : undefined;
  };
  const firstPick = (pool, salt, category) => {
    for (const id of rotateDaily(pool, salt)) {
      const p = brandPick(id, salt, category);
      if (p) return p;
    }
  };
  // "Keep discovering": every in-stock product except the ones kept off Home.
  const homeFeed = useMemo(() => available.filter((p) => !keptOffHome(p)), [available]);
  const heroProduct = firstPick(HERO_BRANDS, 0, "bags");
  const beautyProduct = firstPick(BEAUTY_BRANDS, 1);
  const homeProduct = firstPick(HOME_BRANDS, 2, ["home", "household"]);
  const picks = rotateDaily([...HERO_BRANDS, ...BEAUTY_BRANDS, ...HOME_BRANDS], 3, undefined, 6)
    .map((id) => brandPick(id, 4))
    .filter(Boolean)
    .slice(0, 6);
  const categoryImage = (id) =>
    imageURL(
      available.find((p) => p.category === id && p.images?.length)?.images?.[0],
      300,
    );
  async function signIn(provider) {
    if (!providers?.[provider]) {
      setAuthError(
        `${provider === "apple" ? "Apple" : "Google"} sign-in is not available yet. You can still browse, save items, and shop as a guest.`,
      );
      return;
    }
    setAuthBusy(true);
    setAuthError("");
    track("sign_in_start", { provider });
    try {
      sessionStorage.setItem("marracat-signin", provider);
    } catch {}
    try {
      const csrf = await fetch("/auth/csrf").then((r) => r.json());
      const form = document.createElement("form");
      form.method = "POST";
      form.action = `/auth/signin/${provider}`;
      for (const [name, value] of Object.entries({
        csrfToken: csrf.csrfToken,
        callbackUrl: location.origin + "/account",
      })) {
        const input = document.createElement("input");
        input.type = "hidden";
        input.name = name;
        input.value = value;
        form.append(input);
      }
      document.body.append(form);
      form.submit();
    } catch {
      setAuthError("Unable to connect. Please try again.");
      setAuthBusy(false);
    }
  }
  // What this browser kept for the account. The next person here doesn't find
  // the last one's name, email, phone and address filled in at checkout, or
  // what they searched and opened (until 2026-11-12 both stayed in
  // localStorage after signing out). Saved items stay on a sign-out: they live
  // only in this browser, so removing them would lose them.
  function forgetHere() {
    setSession(null);
    // The cart belongs to the account, which keeps it for the next sign-in
    // (here or in the app); this browser starts empty.
    forgetCartSync();
    cartFromAccount.current = true;
    setCart([]);
    setBuyer(null);
    forgetRecent();
  }
  // The account is gone (AccountDelete): its session cookie names nobody now.
  async function accountDeleted() {
    // This browser's encryption key goes too (the server's copy went with the account).
    await Promise.resolve(social.forget()).catch(() => {});
    forgetHere();
    setSaved([]);
    try {
      const { csrfToken } = await fetch("/auth/csrf").then((r) => r.json());
      await fetch("/auth/signout", { method: "POST", headers: { "Content-Type": "application/x-www-form-urlencoded", "X-Auth-Return-Redirect": "1" },
        body: new URLSearchParams({ csrfToken, callbackUrl: location.origin }) });
    } catch {}
    go("/");
    toast("Your Marracat account has been deleted");
  }
  async function signOut() {
    try {
      // Unregister and forget this browser's encryption key while still signed in.
      await social.forget();
      const { csrfToken } = await fetch("/auth/csrf").then((r) => r.json());
      await fetch("/auth/signout", {
        method: "POST",
        headers: {
          "Content-Type": "application/x-www-form-urlencoded",
          "X-Auth-Return-Redirect": "1",
        },
        body: new URLSearchParams({ csrfToken, callbackUrl: location.origin }),
      });
      forgetHere();
      go("/");
      toast("You are signed out");
    } catch {
      toast("Could not sign out. Please try again.");
    }
  }
  function ProductCard({ p: face }) {
    // A colourway shows the picked member's photo, title, price and link.
    const members = face.group ? face.members || groupMembers.get(face.group) : null;
    const p = (members && colorPick[face.group] && members.find((m) => m.id === colorPick[face.group])) || face;
    return (
      <article className="product-card">
        <div className="product-art">
          <CardImages key={p.id} p={p} href={`/p/${encodeURIComponent(p.id)}`} imageURL={imageURL} />
          {p.compare_at > p.price && (
            <span className="sale-badge">Price drop</span>
          )}
          <button
            className={`save-button ${saved.includes(p.id) ? "is-saved" : ""}`}
            aria-label={`${saved.includes(p.id) ? "Unsave" : "Save"} ${p.title}`}
            onClick={() => toggleSaved(p.id)}
          >
            <Heart
              size={19}
              fill={saved.includes(p.id) ? "currentColor" : "none"}
            />
          </button>
        </div>
        <div className="card-text">
          {/* One even spacing under the photo (owner, 2026-11-09: "the text
              under the title, the price and the badges are sitting too
              separated ... we need uniformity"): the dots keep their row even
              when a product has none, the price sits right under the title,
              then who sells it, then the badges; the button keeps to the
              card's foot, so cards in a row line up. */}
          <div className="card-dots">
            <ColorDots
              members={members}
              active={p.id}
              onPick={(id) => setColorPick((picks) => ({ ...picks, [face.group]: id }))}
            />
          </div>
          <a
            className="product-brand"
            href={hrefFor(shop({ brand: p.brand }))}
          >
            {brandMap.get(p.brand)?.name}
          </a>
          <a
            className="product-title"
            href={`/p/${encodeURIComponent(p.id)}`}
          >
            {p.title}
          </a>
          <div className="price">
            <Price value={p.price} currency={p.currency} />{" "}
            {p.compare_at > p.price && <del><Money value={p.compare_at} currency={p.currency} /></del>}
          </div>
          <p className="stock-label">
            {p.available
              ? "Sold by " + brandMap.get(p.brand)?.name
              : "Currently unavailable"}
          </p>
          <div className="card-badges">
            {p.clean && <CleanBadge />}
            {p.metal && <TrueMetalBadge metal={p.metal} />}
            {p.scent && <QualityLabelBadge kind="scent" />}
            {p.safer && <QualityLabelBadge kind="safer" />}
            {p.food && <QualityLabelBadge kind="food" />}
            {p.baby && <QualityLabelBadge kind="baby" />}
            {p.fiber && <QualityLabelBadge kind={p.fiber === "organic" ? "fiberOrganic" : "fiber"} />}
            {p.fabric && <QualityLabelBadge kind="fabric" />}
            {p.lab && <QualityLabelBadge kind="lab" />}
            {p.pet && <QualityLabelBadge kind="pet" />}
            {p.material && <QualityLabelBadge kind={p.material === "veg" ? "materialVeg" : "material"} />}
            {p.home && <QualityLabelBadge kind={p.home === "certified" ? "homeCertified" : "home"} />}
          </div>
        </div>
        <button
          className="add-button"
          disabled={!p.available}
          onClick={() =>
            p.variants?.length === 1 && usesMarracatCart(brandMap.get(p.brand))
              ? add(p, p.variants[0])
              : go("/product?id=" + encodeURIComponent(p.id))
          }
        >
          <Plus size={17} />
          {p.variants?.length === 1 && usesMarracatCart(brandMap.get(p.brand))
            ? "Add"
            : "View options"}
        </button>
      </article>
    );
  }
  const trending = useTrending(path === "/");
  const ProductRow = ({ title, subtitle, items, link, testid, onTap }) => (
    <section className="section" data-testid={testid}>
      <div className="section-heading">
        <div>
          <h2>{title}</h2>
          {subtitle && <p>{subtitle}</p>}
        </div>
        {link && (
          <a className="text-link" href={hrefFor(link)}>
            View all <ArrowRight size={16} />
          </a>
        )}
      </div>
      <div className="product-row">
        {items.map((p, i) => (
          <div key={p.id} className="product-row-item" onClickCapture={onTap ? () => onTap(p.id, i) : undefined}>
            <ProductCard p={p} />
          </div>
        ))}
      </div>
    </section>
  );
  function BrandCard({ b }) {
    const n = brandProductCounts.get(b.id) || 0;
    return (
      <a href={hrefFor(shop({ brand: b.id }))} className="brand-card">
        <div className="brand-initial">
          {b.name
            .split(" ")
            .map((x) => x[0])
            .slice(0, 2)
            .join("")}
        </div>
        <div>
          <h3>{b.name}</h3>
          <p>
            {b.tagline ||
              categories.find((c) => c.id === b.category)?.name ||
              "Discover the brand"}
          </p>
          <span>
            {n ? n.toLocaleString() + " products" : "Explore brand store"}
          </span>
        </div>
        <ChevronRight size={18} />
      </a>
    );
  }
  // The aisles of the department on show, biggest first, as the app's Browse
  // lists them. An aisle id is "department:leaf"; products carry the leaf.
  const aisles = useMemo(() => {
    if (!category) return [];
    const counts = new Map(server ? Object.entries(server.aisleCounts || {}) : []);
    if (!server)
      for (const p of products)
        if (p.category === category) for (const leaf of p.subs || []) counts.set(leaf, (counts.get(leaf) || 0) + 1);
    return subcategories
      .filter((sub) => sub.category === category && counts.get(sub.id.split(":")[1]))
      .map((sub) => ({ ...sub, leaf: sub.id.split(":")[1], count: counts.get(sub.id.split(":")[1]) }))
      .sort((a, b) => b.count - a.count);
  }, [products, subcategories, category, server]);
  // Brand and search pages have no aisle chips, so a product-type menu narrows
  // them instead: every aisle the listed products sit in, biggest first, named
  // as in Browse (owner, 2026-10-09: "i want to filter on sweatpants").
  const typeOptions = useMemo(() => {
    if (aisle || !(selectedBrand || search)) return [];
    const names = new Map(subcategories.map((s) => [s.id, s.name]));
    return [...typeCounts]
      .filter(([id]) => names.has(id))
      .map(([id, count]) => ({ id, name: names.get(id), count }))
      .sort((a, b) => b.count - a.count || a.name.localeCompare(b.name));
  }, [typeCounts, subcategories, aisle, selectedBrand, search]);
  // The Marracat badge filters, each offered only where something listed has
  // the badge (owner, 2026-10-04: no Clean filter on earrings), and kept while
  // it's on so it can be turned off.
  const badgeFilters = [
    ["clean", cleanOnly, setCleanOnly, ShieldCheck, "Clean"],
    ["metal", metalOnly, setMetalOnly, Gem, "True Metal"],
    ["scent", scentOnly, setScentOnly, Droplet, "Clear Scent"],
    ["safer", saferOnly, setSaferOnly, Leaf, "Safer Clean"],
    ["food", foodOnly, setFoodOnly, Carrot, "Clean Food"],
    ["baby", babyOnly, setBabyOnly, Baby, "Baby Safe"],
    ["fiber", fiberOnly, setFiberOnly, Shirt, "Natural Fiber"],
    ["fabric", fabricOnly, setFabricOnly, ShieldCheck, "Safe Fabric"],
    ["lab", labOnly, setLabOnly, FlaskConical, "Lab Verified"],
    ["pet", petOnly, setPetOnly, PawPrint, "Pet Safe"],
    ["material", materialOnly, setMaterialOnly, Handbag, "True Material"],
    ["home", homeOnly, setHomeOnly, House, "Natural Home"],
  ];
  const offeredBadges = badgeFilters.filter(([key, on]) => on || resultHas(key));
  // What the brand says (hair type, free of, …) and colour live in the URL.
  const attrActive = attrOptions(params), colorActive = colorOption(params.get("color"));
  const setParam = (field, value) => {
    if (value) params.set(field, value);
    else params.delete(field);
    history.replaceState({}, "", hrefFor("/shop?" + params));
    setRoute("/shop?" + params);
  };
  const attrsHere = attributeRows({ category, products: result, active: attrActive }).length > 0;
  const colorsHere = colorChoices({ category, search, counts: colors, active: colorActive }).length > 0;
  // A department's three pills; its other aisles go in the filter column.
  const pillAisles = !selectedBrand && !search ? aisles || [] : [];
  const moreAisles = splitAisles(pillAisles, aisle).rest;
  const activeFilters =
    (brandFilter && !selectedBrand ? 1 : 0) + (countryFilter && !selectedBrand ? 1 : 0) + (typeFilter ? 1 : 0) + (inStock ? 1 : 0) +
    badgeFilters.filter(([, on]) => on).length +
    Object.values(attrActive).filter(Boolean).length + (colorActive ? 1 : 0);
  const clearFilters = () => {
    if (!selectedBrand) setBrandFilter("");
    setCountryFilter("");
    setTypeFilter("");
    setInStock(false);
    for (const [, , set] of badgeFilters) set(false);
    const fields = [...Object.keys(attrActive), "color"].filter((f) => params.has(f));
    if (fields.length) {
      for (const f of fields) params.delete(f);
      history.replaceState({}, "", hrefFor("/shop?" + params));
      setRoute("/shop?" + params);
    }
  };
  // The brand filter's choices: brands with products in this department (all
  // brands outside one), A to Z, each with its product count. One pass over
  // the catalog, not one per brand.
  const brandOptions = useMemo(() => {
    const counts = new Map(server ? Object.entries(server.brandCounts || {}) : []);
    if (!server)
      for (const p of products)
        if (!category || p.category === category) counts.set(p.brand, (counts.get(p.brand) || 0) + 1);
    return brands
      .filter((b) => counts.has(b.id))
      .map((b) => ({ id: b.id, name: b.name, count: counts.get(b.id) }))
      .sort((a, b) => a.name.localeCompare(b.name));
  }, [products, brands, category, server]);
  // The Country filter's choices: the countries those brands are based in,
  // most products first (owner, 2026-11-26: "Let's put a filter for the
  // country the company is founded").
  const countryOptions = useMemo(() => countryChoices(brands, brandOptions), [brands, brandOptions]);
  // The All brands page's search: forgiving about typos, spacing and accents,
  // closest names first, then brands whose tagline or department matches.
  // Products per brand, counted once per catalog. Each brand card used to
  // filter all 147k products itself: ~195M comparisons on every render of
  // All brands, ~3 s after the catalog had already arrived (2026-10-12).
  const brandProductCounts = useMemo(() => {
    const counts = new Map();
    for (const p of products) counts.set(p.brand, (counts.get(p.brand) || 0) + 1);
    return counts;
  }, [products]);
  const brandResults = useMemo(
    () =>
      rankBrands(
        [...brands].sort((a, b) => a.name.localeCompare(b.name)),
        query,
        (b) => b.name,
        (b) => `${b.tagline || ""} ${categories.find((c) => c.id === b.category)?.name || ""}`,
      ),
    [brands, categories, query],
  );
  const aisleName = aisle && aisles.find((a) => a.leaf === aisle)?.name;
  const title = selectedBrand
    ? brandMap.get(selectedBrand)?.name
    : search
      ? `Results for “${relaxedQuery || search}”`
      : aisleName
        ? aisleName
      : category
        ? categories.find((c) => c.id === category)?.name
        : params.get("sale")
          ? "Discover the price drops"
          : params.get("under")
            ? "Little finds under $25"
            : "Shop all products";
  return (
    <>
      <a className="skip-link" href="#main">
        Skip to content
      </a>
      {/* Signed in on the app already (owner, 2026-10-03): no "get the app". */}
      <AppBanner hasApp={!!session?.user?.hasApp} promptHere={path === "/product" || (path === "/shop" && !!selectedBrand)} />
      <header className="header" ref={headerHeight}>
        <div className="header-main">
          <a href="/" className="logo" aria-label="Marracat home">
            <img src="/logo.svg" alt="marracat" />
          </a>
          <div className="header-promise">
            <Store size={22} />
            <span>
              Your next favorite.<strong>All in one place.</strong>
            </span>
          </div>
          <SearchBox
            products={catalog?.partial ? [] : products}
            brands={brands}
            categories={categories}
            subcategories={subcategories}
            query={search}
            navigationKey={route}
            loading={!catalog || catalog.partial}
            onSearch={(value) => go(shop({ q: value }))}
            onNavigate={go}
          />

          <a href="/saved" className="header-action saved-action">
            <Heart />
            <span>
              Love it? <strong>Saved items</strong>
            </span>
          </a>
          <button
            className="header-action"
            onClick={() => (session?.user ? go("/account") : setAuthOpen(true))}
          >
            <UserRound />
            {socialCount > 0 && (
              <span className="header-badge" aria-label={`${socialCount} new`}>
                {socialCount}
              </span>
            )}
            <span>
              {session?.user ? "Welcome back" : "Sign in"}
              <strong>{session?.user?.name?.split(" ")[0] || "Account"}</strong>
            </span>
          </button>
          <a
            href="/cart"
            className="header-cart"
            aria-label={`Cart with ${count} items`}
          >
            <div>
              <ShoppingCart size={27} />
              <b>{count}</b>
            </div>
            <span><MixedTotal compact totals={cartTotalsBy} /></span>
          </a>
        </div>
        <nav className="nav">
          <button
            className="departments-button"
            onClick={() => setMenu(!menu)}
            aria-expanded={menu}
          >
            <Grid2X2 size={18} /> Departments <ChevronDown size={15} />
          </button>
          <a href="/brands">
            <Store size={17} /> All brands
          </a>
          <span className="nav-divider" />
          {[
            ["New discoveries", shop({ sort: "new" })],
            ["Beauty & skincare", shop({ category: "skincare" })],
            ["Fashion", shop({ category: "clothing" })],
            ["Bags", shop({ category: "bags" })],
            ["Home & living", shop({ category: "home" })],
            ["Price drops", shop({ sale: "1" })],
          ].map(([label, to]) => (
            <a href={hrefFor(to)} key={label}>
              {label}
            </a>
          ))}
          <span className="nav-end">Good finds. Greater impact.</span>
        </nav>
        {menu && (
          <div className="department-menu">
            <div className="section-heading">
              <h2>Shop by department</h2>
              <button
                className="icon-button"
                onClick={() => setMenu(false)}
                aria-label="Close departments"
              >
                <X />
              </button>
            </div>
            <div>
              {categories.map((c) => (
                <a key={c.id} href={hrefFor(shop({ category: c.id }))}>
                  {c.name}
                  <ChevronRight size={15} />
                </a>
              ))}
            </div>
          </div>
        )}
      </header>
      <main id="main" tabIndex="-1">
        {!catalog ||
        (catalog.partial && path !== "/" &&
          // Account and orders draw from the home catalog's brands and fetch
          // only the products ordered (Orders.jsx), not all 146k (2026-10-11).
          !["/account", "/orders", "/order"].includes(path) &&
          !(path === "/shop" && server) &&
          // The cart draws from its lines' own product records (details),
          // fetched one by one, so a reload shows it without the full catalog.
          !(path === "/cart" && cart.every((l) => details.has(l.id))) &&
          !(path === "/product" && detailProduct?.id === params.get("id"))) ? (
          <div className="loading-state">
            <img src="/mark.svg" alt="" />
            <h1>
              {loadError
                ? "Let’s try that again."
                : "Good things are on their way."}
            </h1>
            <p>
              {loadError
                ? "We couldn’t load the catalog. Please check your connection."
                : "Loading your next favorite brands…"}
            </p>
            {loadError && (
              <button className="primary-button" onClick={fetchCatalog}>
                Try again
              </button>
            )}
          </div>
        ) : (
          <>
            {path === "/" && (
              <>
                <div className="welcome-line">
                  <span>
                    <Sparkles size={15} /> A whole world to discover.
                  </span>
                  <span>
                    {brands.length} brands. One place to discover them.
                  </span>
                </div>
                <section className="hero-grid">
                  <div className="hero-main">
                    <div className="hero-copy">
                      <span className="eyebrow">THE EVERYDAY, REIMAGINED</span>
                      <h1>
                        Your next
                        <br />
                        favorite.
                        <br />
                        <em>Found here.</em>
                      </h1>
                      <p>
                        Brands with a story.
                        <br />
                        Finds you’ll make your own.
                      </p>
                      <a className="white-button" href={hrefFor(shop())}>
                        Discover your next favorite <ArrowRight size={18} />
                      </a>
                    </div>
                    <a
                      className="hero-image"
                      href={hrefFor(shop({ category: "bags" }))}
                    >
                      <img
                        src={imageURL(heroProduct?.hero || heroProduct?.images[0], 1000)}
                        alt={heroProduct?.title || "Today's featured bag"}
                      />
                      <span className="hero-brand-tag">
                        {(brandMap.get(heroProduct?.brand)?.name || "").toUpperCase()} <ArrowRight size={17} />
                      </span>
                    </a>
                    <span className="hero-bottom">
                      INDEPENDENT BRANDS. EVERYDAY POSSIBILITIES.
                    </span>
                  </div>
                  <div className="hero-side">
                    <a
                      className="promo-card beauty-promo"
                      href={hrefFor(shop({ category: "skincare" }))}
                    >
                      <div>
                        <span className="eyebrow">YOUR NEW ROUTINE</span>
                        <h2>
                          A little care.
                          <br />A lot of glow.
                        </h2>
                        <span className="underline-link">
                          Shop beauty <ArrowRight size={16} />
                        </span>
                      </div>
                      <img
                        src={imageURL(beautyProduct?.images?.[0], 600)}
                        alt={beautyProduct?.title || "Today's beauty pick"}
                      />
                    </a>
                    <a
                      className="promo-card home-promo"
                      href={hrefFor(shop({ category: "home" }))}
                    >
                      <div>
                        <span className="eyebrow">MAKE ROOM FOR JOY</span>
                        <h2>
                          Home, with
                          <br />
                          personality.
                        </h2>
                        <span className="underline-link">
                          Find your home favorites <ArrowRight size={16} />
                        </span>
                      </div>
                      <img
                        src={imageURL(homeProduct?.images?.[0], 600)}
                        alt={homeProduct?.title || "Today's home pick"}
                      />
                    </a>
                  </div>
                </section>
                {/* Boosts of $20 and up (server/boosts.js), labeled Sponsored. */}
                <BoostedPicks
                  productMap={productMap}
                  brandMap={brandMap}
                  productHref={(p) => "/p/" + encodeURIComponent(p.id)}
                  brandHref={(b) => hrefFor(shop({ brand: b.id }))}
                />
                <div className="value-strip">
                  <span>
                    <Store size={22} />
                    <b>{brands.length} brands</b>
                  </span>
                  <span>
                    <Heart size={22} />
                    <b>Find something that feels like you</b>
                  </span>
                  <span>
                    <ShieldCheck size={22} />
                    <b>Shop directly with each brand</b>
                  </span>
                </div>
                <section className="section categories-section">
                  <div className="section-heading">
                    <div>
                      <h2>What are you shopping for?</h2>
                      <p>Big plans or everyday little things. Start here.</p>
                    </div>
                    <button
                      className="text-link"
                      onClick={() => {
                        setMenu(true);
                        window.scrollTo(0, 0);
                      }}
                    >
                      All departments <ArrowRight size={16} />
                    </button>
                  </div>
                  <div className="category-row">
                    {[
                      "bags",
                      "skincare",
                      "clothing",
                      "fragrance",
                      "hair",
                      "home",
                      "jewelry",
                      "grocery",
                    ].map((id) => (
                      <a key={id} href={hrefFor(shop({ category: id }))}>
                        <span>
                          <img src={categoryImage(id)} alt="" loading="lazy" />
                        </span>
                        <b>{categories.find((c) => c.id === id)?.name}</b>
                      </a>
                    ))}
                  </div>
                </section>
                <ProductRow
                  title="Meet your new favorites"
                  subtitle="A few good finds to get you started."
                  items={picks}
                  link={shop()}
                />
                {trending && (
                  <div data-testid="trending-row">
                    <ProductRow
                      title={trending.title}
                      subtitle={trending.basis === "momentum" ? "What shoppers are opening and buying right now." : "What shoppers keep coming back to."}
                      items={trending.products}
                      link={shop()}
                    />
                  </div>
                )}
                <HomeComments />
                <section className="discovery-banner">
                  <div>
                    <span className="eyebrow">SMALL FINDS. BIG FEELING.</span>
                    <h2>
                      A little something,
                      <br />
                      for a little less.
                    </h2>
                    <p>Discover everyday favorites under $25.</p>
                    <a
                      className="primary-button"
                      href={hrefFor(shop({ under: "25" }))}
                    >
                      Shop under $25 <ArrowRight size={17} />
                    </a>
                  </div>
                  <div className="banner-products">
                    {diversify(
                      rotateDaily(available.filter(
                        (p) =>
                          (p.currency || "USD") === "USD" && p.price < 25 &&
                          ["skincare", "makeup", "grocery"].includes(
                            p.category,
                          ),
                      ), 5, undefined, 97),
                      3,
                    ).map((p) => (
                      <a href={"/p/" + encodeURIComponent(p.id)} key={p.id}>
                        <img
                          loading="lazy"
                          src={imageURL(p.images[0], 350)}
                          alt={p.title}
                        />
                        <span><Price value={p.price} currency={p.currency} /></span>
                      </a>
                    ))}
                  </div>
                </section>
                <ProductRow
                  title="Good finds. Even better prices."
                  subtitle="Real markdowns from the brands you’re discovering."
                  items={diversify(
                    available.filter((p) => p.compare_at > p.price),
                    6,
                  )}
                  link={shop({ sale: "1" })}
                />
                <section className="section">
                  <div className="section-heading">
                    <div>
                      <h2>Behind every find, a brand worth knowing.</h2>
                      <p>Explore the entire Marracat brand community.</p>
                    </div>
                    <a className="text-link" href="/brands">
                      All {brands.length} brands <ArrowRight size={16} />
                    </a>
                  </div>
                  <div className="brand-grid">
                    {[
                      "topicals",
                      "brown-girl-jane",
                      "kin",
                      "brandon-blackwood",
                      "pattern-beauty",
                    ]
                      .map((id) => brandMap.get(id))
                      .filter(Boolean)
                      .map((b) => (
                        <BrandCard key={b.id} b={b} />
                      ))}
                  </div>
                </section>
              </>
            )}
            {path === "/" && (
              <section className="section discovery-feed">
                <div className="section-heading">
                  <div>
                    <h2>Keep discovering</h2>
                    <p>
                      More finds, whenever you’re ready. Just keep scrolling.
                    </p>
                  </div>
                </div>
                <ProductFeed
                  products={homeFeed}
                  total={catalog.partial ? catalog.total_available : undefined}
                  renderProduct={(p) => <ProductCard key={p.id} p={p} />}
                />
              </section>
            )}
            {path === "/shop" && (
              <>
                <div className="breadcrumb">
                  <a href="/">Home</a>
                  <ChevronRight size={14} />
                  {aisleName ? (
                    <>
                      <a href={hrefFor(shop({ category }))}>
                        {categories.find((c) => c.id === category)?.name}
                      </a>
                      <ChevronRight size={14} />
                    </>
                  ) : null}
                  <span>
                    {title}
                    {!selectedBrand && !search && ` (${resultCount.toLocaleString()})`}
                  </span>
                </div>
                {/* A department or aisle is already named and counted in
                    the breadcrumb, "Socks & Hosiery (265)", so its heading
                    stays for screen readers only (owner, 2026-09-30).
                    Brands and searches keep theirs. */}
                {/* Only for a search saying "independent" (owner, 2026-11-03:
                    "a prompt that tells them all items on this site are
                    independent"); everywhere else the site says
                    "independent brands". As OwnershipNotice in the app. */}
                {search && saysOwnership(tokens(search)) && (
                  <OwnershipNotice brandCount={brands.length} />
                )}
                <section className={selectedBrand || search ? "shop-top" : "sr-only"}>
                  <div>
                    {/* A department's heading names it the way people search
                        for it (SEO, 2026-10-09); public copy says "independent
                        brands", never "independent" (owner rule). */}
                    <h1>{selectedBrand || search ? title : `${title} from independent brands`}</h1>
                    {(selectedBrand || search) && (
                    <p>
                      {selectedBrand
                        ? brandMap.get(selectedBrand)?.tagline
                        : relaxedQuery
                          ? `Showing ${resultCount.toLocaleString()} products for “${relaxedQuery}”.`
                          : `${resultCount.toLocaleString()} products to discover`}
                    </p>
                    )}
                  </div>
                  {/* One pill, Sale alerts in black (owner, 2026-11-03, picked
                      option 1 of five previews: "Action pill"). */}
                  {selectedBrand && brandMap.get(selectedBrand) && (
                  <div className="brand-actions" role="group" aria-label="Brand actions">
                    <a
                      className="brand-action"
                      href={safeURL(
                        "https://" + brandMap.get(selectedBrand)?.domain,
                      )}
                      target="_blank"
                      rel="noopener noreferrer"
                    >
                      <ExternalLink size={16} aria-hidden="true" /> Website
                    </a>
                    <button
                      className="brand-action"
                      type="button"
                      data-action="share-brand"
                      onClick={async () => {
                        const b = brandMap.get(selectedBrand);
                        const url = `https://marracat.com/b/${encodeURIComponent(b.id)}`;
                        track("share", { kind: "brand", target: b.id });
                        try {
                          if (navigator.share) await navigator.share({ title: `${b.name} on Marracat`, url });
                          else { await navigator.clipboard.writeText(url); toast("Link copied"); }
                        } catch {}
                      }}
                    >
                      <Share2 size={16} aria-hidden="true" /> Share
                    </button>
                    <AlertButton kind="brand" className="brand-action brand-action-main" id={selectedBrand} signedIn={!!session?.user} onSignIn={() => setAuthOpen(true)} toast={toast} />
                  </div>
                  )}
                  {selectedBrand && brandMap.get(selectedBrand) && (
                    <BoostButton type="brand" id={selectedBrand} name={brandMap.get(selectedBrand).name} autoOpen={params.get("boost") === "1"} />
                  )}
                </section>
                {search && guesses.length > 0 && (
                  <nav className="did-you-mean" aria-label="Did you mean" data-testid="did-you-mean">
                    <span>Did you mean</span>
                    {guesses.map((g) => (
                      <a key={g} className="chip" href={hrefFor(shop({ q: g }))}>{g}</a>
                    ))}
                  </nav>
                )}
                {selectedBrand && brandMap.get(selectedBrand) && (
                  <AppPrompt kind="brand" name={brandMap.get(selectedBrand).name} hasApp={!!session?.user?.hasApp} />
                )}
                <FilterPills key={category + "|" + search} aisles={pillAisles} category={category} aisle={aisle} />
                {/* Filters in a column beside the grid; on phones, Filters and
                    Sort buttons, the column opening as a sheet from the bottom
                    (owner, 2026-11-03, picked "5 · Sidebar" of five previews). */}
                <div className="shop-toolbar" ref={toolbarHeight}>
                  <button
                    type="button"
                    className="filters-toggle"
                    aria-expanded={filtersOpen}
                    aria-controls="shop-filters"
                    onClick={() => setFiltersOpen(true)}
                  >
                    <SlidersHorizontal size={16} aria-hidden="true" /> Filters
                    {activeFilters > 0 && <span className="filters-count">{activeFilters}</span>}
                  </button>
                  {/* Search and department headings already give the count. */}
                  {selectedBrand ? (
                    <span className="result-count">
                      {resultCount.toLocaleString()} {resultCount === 1 ? "product" : "products"}
                    </span>
                  ) : (
                    <span className="result-count" aria-hidden="true" />
                  )}
                  <label className="sort-control currency-control">
                    <Coins size={16} aria-hidden="true" />
                    <span className="sort-label" aria-hidden="true">Currency:</span>
                    <span className="sort-value" aria-hidden="true">
                      {shownCurrency === "ORIGINAL" ? "Brand's own" : shownCurrency}
                    </span>
                    <select
                      aria-label="Show prices in"
                      value={currencyOptions.some(([c]) => c === shownCurrency) ? shownCurrency : "USD"}
                      onChange={(e) => {
                        setCurrency(e.target.value);
                      }}
                    >
                      {currencyOptions.map(([value, label]) => (
                        <option key={value} value={value}>{label}</option>
                      ))}
                    </select>
                    <ChevronDown size={15} aria-hidden="true" />
                  </label>
                  {/* The select is stretched, invisible, over the whole pill so
                      a click anywhere on it opens the menu; the chosen option
                      is drawn as text underneath. */}
                  <label className="sort-control">
                    <ArrowUpDown size={16} aria-hidden="true" />
                    <span className="sort-label" aria-hidden="true">Sort:</span>
                    <span className="sort-value" aria-hidden="true">
                      <span className="sort-long">{SORT_LABELS[sortValue]}</span>
                      <span className="sort-short">{SORT_SHORT[sortValue]}</span>
                    </span>
                    <select
                      aria-label="Sort products"
                      value={sortValue}
                      onChange={(e) => {
                        setSort(e.target.value);
                        if (params.has("sort")) {
                          params.delete("sort");
                          history.replaceState({}, "", hrefFor("/shop?" + params));
                          setRoute("/shop?" + params);
                        }
                      }}
                    >
                      {Object.entries(SORT_LABELS).map(([value, label]) => (
                        <option key={value} value={value}>{label}</option>
                      ))}
                    </select>
                    <ChevronDown size={15} aria-hidden="true" />
                  </label>
                </div>
                <div className="shop-layout">
                  {filtersOpen && <div className="filter-scrim" onClick={() => setFiltersOpen(false)} />}
                  <aside
                    id="shop-filters"
                    className={filtersOpen ? "filter-side open" : "filter-side"}
                    aria-label="Filters"
                  >
                    <div className="filter-sheet-head">
                      <h2>Filters</h2>
                      <button type="button" className="filter-close" aria-label="Close filters" onClick={() => setFiltersOpen(false)}>
                        <X size={22} />
                      </button>
                    </div>
                    {activeFilters > 0 && (
                      <button type="button" className="filter-clear" onClick={clearFilters}>
                        Clear all
                      </button>
                    )}
                    {!selectedBrand && (
                      <div className="filter-group">
                        <h3>Brand</h3>
                        <BrandPicker brands={brandOptions} value={brandFilter} onChange={setBrandFilter} />
                      </div>
                    )}
                    {!selectedBrand && countryOptions.length > 1 && (
                      <fieldset className="filter-group" aria-label="Filter by the brand's country">
                        <legend>Country</legend>
                        {[
                          { id: "", name: "All" },
                          ...(allCountries
                            ? countryOptions
                            : countryOptions.filter((c, i) => i < TYPES_SHOWN || c.id === countryFilter)),
                        ].map((c) => (
                          <label key={c.id || "all"} className="filter-option">
                            <input
                              type="radio"
                              name="brand-country"
                              checked={countryFilter === c.id}
                              onChange={() => setCountryFilter(c.id)}
                            />
                            <span>{c.name}</span>
                            {c.count != null && <small>{c.count.toLocaleString()}</small>}
                          </label>
                        ))}
                        {countryOptions.length > TYPES_SHOWN && (
                          <button type="button" className="filter-more" aria-expanded={allCountries} onClick={() => setAllCountries(!allCountries)}>
                            {allCountries ? "Show fewer countries" : `Show all ${countryOptions.length} countries`}
                          </button>
                        )}
                      </fieldset>
                    )}
                    <div className="filter-group">
                      <h3>Availability</h3>
                      <label className="filter-option stock-filter">
                        <input type="checkbox" checked={inStock} onChange={(e) => setInStock(e.target.checked)} />
                        In stock only
                      </label>
                    </div>
                    {typeOptions.length > 1 && (
                      <fieldset className="filter-group" aria-label="Filter by product type">
                        <legend>Product type</legend>
                        {[
                          { id: "", name: "All" },
                          ...(allTypes
                            ? typeOptions
                            : typeOptions.filter((t, i) => i < TYPES_SHOWN || t.id === typeFilter)),
                        ].map((t) => (
                          <label key={t.id || "all"} className="filter-option">
                            <input
                              type="radio"
                              name="product-type"
                              checked={typeFilter === t.id}
                              onChange={() => setTypeFilter(t.id)}
                            />
                            <span>{t.name}</span>
                            {t.count != null && <small>{t.count.toLocaleString()}</small>}
                          </label>
                        ))}
                        {typeOptions.length > TYPES_SHOWN && (
                          <button type="button" className="filter-more" aria-expanded={allTypes} onClick={() => setAllTypes(!allTypes)}>
                            {allTypes ? "Show fewer types" : `Show all ${typeOptions.length} types`}
                          </button>
                        )}
                      </fieldset>
                    )}
                    {moreAisles.length > 0 && (
                      <div className="filter-group" role="group" aria-label="More aisles">
                        <h3>More aisles</h3>
                        {(allTypes ? moreAisles : moreAisles.slice(0, TYPES_SHOWN)).map((a) => (
                          <a key={a.id} className="filter-option filter-link" href={aisleLink({ category, aisle: a.leaf })}>
                            <span>{a.name}</span>
                            <small>{a.count.toLocaleString()}</small>
                          </a>
                        ))}
                        {moreAisles.length > TYPES_SHOWN && (
                          <button type="button" className="filter-more" aria-expanded={allTypes} onClick={() => setAllTypes(!allTypes)}>
                            {allTypes ? "Show fewer aisles" : `Show all ${moreAisles.length} aisles`}
                          </button>
                        )}
                      </div>
                    )}
                    {attrsHere && (
                      <div className="filter-group">
                        <AttributeFilters category={category} products={result} active={attrActive} onChange={setParam} />
                      </div>
                    )}
                    {colorsHere && (
                      <div className="filter-group">
                        <ColorFilter category={category} search={search} counts={colors} active={colorActive} onChange={(v) => setParam("color", v)} />
                      </div>
                    )}
                    {offeredBadges.length > 0 && (
                      <div className="filter-group">
                        <h3>Marracat badges</h3>
                        {offeredBadges.map(([key, on, set, Icon, name]) => (
                          <label key={key} className={`filter-option ${key}-filter`}>
                            <input type="checkbox" checked={on} onChange={(e) => set(e.target.checked)} />
                            <Icon size={15} aria-hidden="true" /> <span className="sr-only">Marracat </span>{name}
                          </label>
                        ))}
                      </div>
                    )}
                    <div className="filter-sheet-foot">
                      <button type="button" className="outline-button" onClick={clearFilters}>
                        Clear all
                      </button>
                      <button type="button" className="primary-button" onClick={() => setFiltersOpen(false)}>
                        Show {resultCount.toLocaleString()} {resultCount === 1 ? "product" : "products"}
                      </button>
                    </div>
                  </aside>
                  <div className="shop-results">
                {result.length ? (
                  <>
                    {forYou && (
                      <section className="personal-picks" data-testid="personal-picks">
                        <h2>Picked for you</h2>
                        <p>{forYou.searched ? `Because you searched “${forYou.phrase}”` : `Because you looked at ${forYou.phrase.toLowerCase()}`}</p>
                        <div className="product-grid">{forYou.products.map((p) => <ProductCard key={p.id} p={p} />)}</div>
                      </section>
                    )}
                    <SponsoredRow placement={search ? "search" : "category"} items={sponsoredSearch} productMap={productMap}
                      renderProduct={(p) => <ProductCard key={p.id} p={p} />} />
                    <ProductFeed
                      key={`${route}:${brandFilter}:${countryFilter}:${typeFilter}:${inStock}:${cleanOnly}:${metalOnly}:${scentOnly}:${saferOnly}:${foodOnly}:${babyOnly}:${fiberOnly}:${fabricOnly}:${labOnly}:${petOnly}:${materialOnly}:${homeOnly}:${sort}`}
                      products={
                        params.get("sort") === "new" && sort === "featured"
                          ? [...result].sort((a, b) =>
                              String(b.published_at || "").localeCompare(
                                String(a.published_at || ""),
                              ),
                            )
                          : listed
                      }
                      renderProduct={(p) => <ProductCard key={p.id} p={p} />}
                      total={server ? server.total : undefined}
                      onMore={server?.more}
                    />
                  </>
                ) : cleanOnly ? (
                  <div className="empty-state clean-empty">
                    <ShieldCheck size={42} />
                    <h2>No Marracat Clean products here yet</h2>
                    <p>
                      The badge covers hair care, skincare, makeup, face and
                      body washes, and candles whose brands publish what’s in
                      them. <a href="/clean">What Marracat Clean means</a>
                    </p>
                    <button
                      type="button"
                      className="primary-button"
                      onClick={() => setCleanOnly(false)}
                    >
                      Show everything <ArrowRight size={17} />
                    </button>
                  </div>
                ) : (
                  <div className="empty-state">
                    <Store size={42} />
                    <h2>
                      {selectedBrand
                        ? "More to discover at the brand’s store"
                        : "No finds just yet"}
                    </h2>
                    <p>
                      {selectedBrand
                        ? "This brand’s products aren’t in our catalog yet. Visit their store to explore the collection."
                        : "Try another search or change your filters."}
                    </p>
                    <a
                      className="primary-button"
                      href={
                        selectedBrand
                          ? safeURL(
                              "https://" + brandMap.get(selectedBrand)?.domain,
                            )
                          : hrefFor(shop())
                      }
                    >
                      {selectedBrand
                        ? "Explore " + brandMap.get(selectedBrand)?.name
                        : "Explore all products"}
                      <ArrowRight size={17} />
                    </a>
                  </div>
                )}
                  </div>
                </div>
              </>
            )}
            {path === "/brands" && (
              <>
                <section className="page-title">
                  <span className="eyebrow">THE MARRACAT COMMUNITY</span>
                  <h1>Good brands. Great discoveries.</h1>
                  <p>All {brands.length} brands, together in one place.</p>
                </section>
                <form
                  className="brand-search"
                  onSubmit={(e) => e.preventDefault()}
                >
                  <Search size={20} />
                  <input
                    aria-label="Find a brand"
                    placeholder="Find a brand by name or category"
                    value={query}
                    onChange={(e) => setQuery(e.target.value)}
                  />
                  {query && (
                    <button
                      onClick={() => setQuery("")}
                      aria-label="Clear brand search"
                    >
                      <X size={18} />
                    </button>
                  )}
                </form>
                <div className="brand-grid all-brands">
                  {brandResults.map((b) => (
                    <BrandCard key={b.id} b={b} />
                  ))}
                </div>
                {!brandResults.length && (
                  <div className="empty-state">
                    <h2>No brands found</h2>
                    <button
                      className="outline-button"
                      onClick={() => setQuery("")}
                    >
                      See all brands
                    </button>
                  </div>
                )}
              </>
            )}
            {path === "/product" &&
              (() => {
                const p = withLiveStock(
                  detailProduct?.id === params.get("id")
                    ? detailProduct
                    : productMap.get(params.get("id")),
                  liveStock,
                );
                if (!p)
                  return (
                    <div className="empty-state">
                      <h1>That find is no longer available.</h1>
                      <a href={hrefFor(shop())}>Keep exploring</a>
                    </div>
                  );
                const b = brandMap.get(p.brand);
                const variants = p.variants || [];
                const variant =
                  variants.find((v) => String(v.id) === variantID) ||
                  variants.find((v) => v.available) ||
                  variants[0];
                return (
                  <>
                    <div className="breadcrumb">
                      <a href="/">Home</a>
                      <ChevronRight size={14} />
                      <a href={hrefFor(shop({ brand: b.id }))}>{b.name}</a>
                    </div>
                    {/* Editorial grid (owner, 2026-11-09, picked "1 Editorial grid"):
                        every photo down the left, and the details beside them
                        stay in view while the page scrolls ("make sure the
                        right side section hovers as the user scrolls down"). */}
                    <div className="product-detail is-editorial">
                      <div className="detail-art">
                        <PhotoGrid key={p.id} images={p.images} title={p.title} />
                      </div>
                      <div className="detail-info">
                        <a className="detail-brand" href={hrefFor(shop({ brand: b.id }))}>
                          {b.name}
                        </a>
                        <h1>{p.title}</h1>
                        <div className="detail-price">
                          <Price value={variant?.price ?? p.price} currency={p.currency} />{" "}
                          {(variant?.compare_at ?? p.compare_at) >
                            (variant?.price ?? p.price) && (
                            <del>
                              <Money value={variant?.compare_at ?? p.compare_at} currency={p.currency} />
                            </del>
                          )}
                        </div>
                        <p className="stock-label">
                          {p.available
                            ? "Available from " + b.name +
                              (shipsFrom(p.currency) ? `, ships from ${shipsFrom(p.currency)}` : "")
                            : "Currently unavailable"}
                        </p>
                        {p.currency && p.currency !== "USD" && (
                          <p>Store prices in {p.currency}. Final currency and shipping are confirmed at checkout.</p>
                        )}
                        <div className="detail-badges">
                          {p.clean && <CleanBadge explain />}
                          {p.metal && <TrueMetalBadge metal={p.metal} explain />}
                          {p.scent && <QualityLabelBadge kind="scent" explain />}
                          {p.safer && <QualityLabelBadge kind="safer" explain />}
                          {p.food && <QualityLabelBadge kind="food" explain />}
                          {p.baby && <QualityLabelBadge kind="baby" explain />}
                          {p.fiber && <QualityLabelBadge kind={p.fiber === "organic" ? "fiberOrganic" : "fiber"} explain />}
                          {p.fabric && <QualityLabelBadge kind="fabric" explain />}
                          {p.lab && <QualityLabelBadge kind="lab" explain />}
                          {p.pet && <QualityLabelBadge kind="pet" explain />}
                          {p.material && <QualityLabelBadge kind={p.material === "veg" ? "materialVeg" : "material"} explain />}
                          {p.home && <QualityLabelBadge kind={p.home === "certified" ? "homeCertified" : "home"} explain />}
                        </div>
                        {variants.length > 1 &&
                          (optionAxes(p.option_names, variants) ? (
                            <VariantPicker
                              axes={optionAxes(p.option_names, variants)}
                              variants={variants}
                              variant={variant}
                              onPick={setVariantID}
                            />
                          ) : (
                              <label className="variant-label">
                                {/* What the store calls its options ("Color / Size"), else "an option". */}
                                Choose {optionNoun(p.option_names)}
                                <select
                                  aria-label={"Choose product " + optionNoun(p.option_names)}
                                  value={String(variant?.id)}
                                  onChange={(e) => setVariantID(e.target.value)}
                                >
                                  {variants.map((v) => (
                                    <option
                                      key={v.id}
                                      value={String(v.id)}
                                      disabled={!v.available}
                                    >
                                      {v.title}
                                      {!v.available ? " — Sold out" : ""}
                                    </option>
                                  ))}
                                </select>
                              </label>
                          ))}
                        <div className="detail-actions">
                          {usesMarracatCart(b) ? (
                            <button
                              className="primary-button"
                              disabled={!p.available || !variant?.available}
                              onClick={() => add(p, variant)}
                            >
                              <Plus size={19} /> Add to cart
                            </button>
                          ) : (
                            <a
                              className="primary-button"
                              href={safeURL(p.url)}
                              target="_blank"
                              rel="noopener noreferrer"
                              data-track-product={p.id}
                            >
                              Shop at {b.name} <ExternalLink size={17} />
                            </a>
                          )}
                          <button
                            className="outline-button detail-save"
                            aria-label={saved.includes(p.id) ? "Saved" : "Save"}
                            title={saved.includes(p.id) ? "Saved" : "Save"}
                            aria-pressed={saved.includes(p.id)}
                            onClick={() => toggleSaved(p.id)}
                          >
                            <Heart size={21} fill={saved.includes(p.id) ? "currentColor" : "none"} />
                          </button>
                        </div>
                        <div className="detail-acts">
                          <ShareButtons
                            product={p}
                            social={social}
                            onSignIn={() => setAuthOpen(true)}
                            toast={toast}
                          />
                          <div className="detail-extra-actions">
                            <AlertButton kind="price" id={p.id} signedIn={!!session?.user} onSignIn={() => setAuthOpen(true)} toast={toast} />
                            <BoostButton type="product" id={p.id} name={p.title} autoOpen={params.get("boost") === "1"} />
                          </div>
                        </div>
                        <AppPrompt kind="product" hasApp={!!session?.user?.hasApp} />
                        <details open>
                          <summary>About this find</summary>
                          <p className="description">
                            {p.description ||
                              "Explore the brand’s store for product details."}
                          </p>
                        </details>
                        <details>
                          <summary>From the brand, to you</summary>
                          <div className="fulfillment-note">
                            <Store size={22} />
                            <p>
                              {b.name} handles your payment, shipping, and
                              returns. Price and availability are confirmed at
                              their checkout.
                            </p>
                          </div>
                        </details>
                        <a
                          className="detail-row-link"
                          href={safeURL(p.url)}
                          target="_blank"
                          rel="noopener noreferrer"
                          data-track="no"
                        >
                          View original listing <ExternalLink size={15} />
                        </a>
                      </div>
                    </div>
                    <Comments
                      productID={p.id}
                      signedIn={social.signedIn}
                      onSignIn={() => setAuthOpen(true)}
                      toast={toast}
                    />
                    {typePicks.title && typePicks.items.length >= MIN_SHOWN && (
                      <ProductRow title={typePicks.title} subtitle="From other brands" items={typePicks.items}
                        testid="type-top-picks" onTap={tapTypePicks} />
                    )}
                    <SponsoredRow placement="product" items={sponsoredNear} productMap={productMap} title="Sponsored products"
                      renderProduct={(item) => <ProductCard key={item.id} p={item} />} />
                    <ProductRow
                      title={"More from " + b.name}
                      items={brandMore}
                      link={shop({ brand: b.id })}
                      onTap={tapBrandMore}
                    />
                    {goesWell.length >= MIN_SHOWN && (
                      <ProductRow title="Goes well with" items={goesWell} testid="goes-well-with" onTap={tapGoesWell} />
                    )}
                  </>
                );
              })()}
            {path.startsWith("/u/") && (
              <ProfilePage
                handle={decodeURIComponent(path.slice(3))}
                social={social}
                onSignIn={() => setAuthOpen(true)}
                toast={toast}
              />
            )}
            {path === "/moderation" && <Moderation social={social} toast={toast} />}
            {path === "/clean" && <CleanStandardPage />}
            {path === "/true-metal" && <TrueMetalStandardPage />}
            {path === "/clear-scent" && <QualityLabelStandardPage kind="scent" />}
            {path === "/safer-clean" && <QualityLabelStandardPage kind="safer" />}
            {path === "/clean-food" && <QualityLabelStandardPage kind="food" />}
            {path === "/baby-safe" && <QualityLabelStandardPage kind="baby" />}
            {path === "/natural-fiber" && <QualityLabelStandardPage kind="fiber" />}
            {path === "/safe-fabric" && <QualityLabelStandardPage kind="fabric" />}
            {path === "/lab-verified" && <QualityLabelStandardPage kind="lab" />}
            {path === "/pet-safe" && <QualityLabelStandardPage kind="pet" />}
            {path === "/true-material" && <QualityLabelStandardPage kind="material" />}
            {path === "/natural-home" && <QualityLabelStandardPage kind="home" />}
            {path === "/saved" && (
              <>
                <section className="page-title">
                  <span className="eyebrow">KEEP THE GOOD FINDS CLOSE</span>
                  <h1>Your saved items</h1>
                  <p>
                    Your favorites, saved on this browser for your next visit.
                  </p>
                </section>
                {saved.some((id) => productMap.has(id)) ? (
                  <div className="product-grid">
                    {saved
                      .map((id) => productMap.get(id))
                      .filter(Boolean)
                      .map((p) => (
                        <ProductCard key={p.id} p={p} />
                      ))}
                  </div>
                ) : (
                  <div className="empty-state">
                    <Heart size={44} />
                    <h2>Something will catch your eye.</h2>
                    <p>Tap the heart on any product to save it here.</p>
                    <a className="primary-button" href={hrefFor(shop())}>
                      Find your favorites <ArrowRight size={17} />
                    </a>
                  </div>
                )}
              </>
            )}
            {path === "/cart" && (
              <>
                {/* With items, the title sits in the left column so "Your
                    finds" lines up with "Your cart" (owner, 2026-09-30). */}
                {!cart.length && cartTitle}
                {cart.length ? (
                  <div className="cart-layout">
                    <div>
                      {cartTitle}
                      {[
                        ...new Set(
                          cartLines.map(
                            (l) => l.product?.brand || "unavailable",
                          ),
                        ),
                      ].map((id) => {
                        const b = brandMap.get(id),
                          lines = cartLines.filter(
                            (l) => (l.product?.brand || "unavailable") === id,
                          ),
                          url = checkoutURL(b, lines);
                        return (
                          <section className="cart-group" key={id}>
                            <h2>
                              <Store size={21} />
                              {b?.name || "Unavailable items"}
                            </h2>
                            {lines.map((l) => (
                              <div className="cart-line" key={l.key}>
                                <img
                                  src={imageURL(l.product?.images[0], 200)}
                                  alt={
                                    l.product?.title || "Unavailable product"
                                  }
                                />
                                <div>
                                  <a href={"/p/" + encodeURIComponent(l.id)}>
                                    {l.product?.title ||
                                      "Product no longer in catalog"}
                                  </a>
                                  <p>
                                    {l.variant?.title === "Default Title"
                                      ? ""
                                      : l.variant?.title}
                                  </p>
                                  {(!l.variant?.available ||
                                    !l.product?.available) && (
                                    <p className="error-message">
                                      Currently unavailable. Remove to continue.
                                    </p>
                                  )}
                                  <div className="quantity">
                                    <button
                                      aria-label={`Decrease quantity of ${l.product?.title}`}
                                      onClick={() =>
                                        setCart((c) =>
                                          l.quantity === 1
                                            ? c.filter((x) => x.key !== l.key)
                                            : c.map((x) =>
                                                x.key === l.key
                                                  ? {
                                                      ...x,
                                                      quantity: x.quantity - 1,
                                                    }
                                                  : x,
                                              ),
                                        )
                                      }
                                    >
                                      <Minus size={15} />
                                    </button>
                                    <span>{l.quantity}</span>
                                    <button
                                      aria-label={`Increase quantity of ${l.product?.title}`}
                                      disabled={l.quantity >= 99}
                                      onClick={() =>
                                        setCart((c) =>
                                          c.map((x) =>
                                            x.key === l.key
                                              ? {
                                                  ...x,
                                                  quantity: Math.min(
                                                    99,
                                                    x.quantity + 1,
                                                  ),
                                                }
                                              : x,
                                          ),
                                        )
                                      }
                                    >
                                      <Plus size={15} />
                                    </button>
                                  </div>
                                  <button
                                    className="remove-button"
                                    onClick={() => {
                                      track("remove_from_cart", { product: l.id, brand: l.product?.brand, qty: l.quantity });
                                      setCart((c) =>
                                        c.filter((x) => x.key !== l.key),
                                      );
                                    }}
                                  >
                                    Remove
                                  </button>
                                </div>
                                <b>
                                  <Price value={(l.variant?.price || 0) * l.quantity} currency={l.product?.currency} />
                                </b>
                              </div>
                            ))}
                            {/* One brand and the summary's "Check out" already: no
                                second button saying the same (owner, 2026-09-30). */}
                            {checkoutTogether && cartGroups.length === 1 ? null : b?.checkout === "ucp" && b.ucp && lines.every((l) => l.product?.available && l.variant?.available) ? (
                              <button className="primary-button" type="button" onClick={startCheckout} data-action="brand-review">
                                Check out at {b.name} <ArrowRight size={17} />
                              </button>
                            ) : url ? (
                              <a
                                className="primary-button"
                                href={url}
                                target="_blank"
                                rel="noopener noreferrer"
                                onClick={(e) => { if (openKit(b, url)) e.preventDefault(); }}
                              >
                                Check out at {b.name} <ExternalLink size={17} />
                              </a>
                            ) : (
                              <p>
                                Remove unavailable items to continue checkout.
                              </p>
                            )}
                          </section>
                        );
                      })}
                    </div>
                    <aside className="cart-summary">
                      <h2>Your finds</h2>
                      <div>
                        <span>Subtotal ({count} items)</span>
                        <b><MixedTotal totals={cartTotalsBy} /></b>
                      </div>
                      {checkoutTogether && (
                        <>
                          <button
                            className="primary-button checkout-all"
                            type="button"
                            onClick={startCheckout}
                            data-action="checkout-all"
                          >
                            {cartGroups.length > 1
                              // Not one payment: each brand is paid on its
                              // own checkout (Shopify hasn't granted
                              // Universal Cart; owner, 2026-10-03).
                              ? `Review all ${cartGroups.length} checkouts`
                              : "Check out"}{" "}
                            <ArrowRight size={17} />
                          </button>
                          <p>
                            {cartGroups.length > 1
                              ? "Enter your details once. Each brand's shipping and total come back on one screen, then it's one click per brand to pay."
                              : "Enter your details once; the brand's checkout opens filled in."}
                          </p>
                        </>
                      )}
                      <p>
                        Shipping, taxes, and final prices are calculated by each
                        brand at checkout.
                      </p>
                      <hr />
                      <p>
                        <ShieldCheck size={20} /> Secure checkout on each
                        brand’s own store.
                      </p>
                      <p className="small">
                        Your cart stays here until you remove items. Marracat
                        does not receive order confirmations from brand stores.
                      </p>
                    </aside>
                  </div>
                ) : (
                  <div className="empty-state">
                    <ShoppingCart size={44} />
                    <h2>Your next favorite is out there.</h2>
                    <p>Let’s find something to add to your cart.</p>
                    <a className="primary-button" href={hrefFor(shop())}>
                      Start exploring <ArrowRight size={17} />
                    </a>
                  </div>
                )}
              </>
            )}
            {path === "/checkout" && (
              <CheckoutReview
                groups={cartGroups}
                buyer={buyer}
                onEditBuyer={() => setBuyerOpen(true)}
                onPaid={markPaid}
                openKit={openKit}
                shopHref={hrefFor(shop())}
              />
            )}
            {path === "/orders" && (
              <OrdersPage tab={params.get("tab") || "orders"} brandMap={brandMap} productMap={productMap} money={money}
                onBuyAgain={buyAgain} categories={categories} />
            )}
            {path === "/order" && (
              <OrderDetail id={params.get("id") || ""} brandMap={brandMap} productMap={productMap} money={money} toast={toast} />
            )}
            {path === "/account" && (
              <section className="account-page">
                <UserRound size={44} />
                <h1>
                  {session?.user
                    ? `Welcome, ${session.user.name || "shopper"}.`
                    : "A place for your next favorites."}
                </h1>
                {session?.user ? (
                  <>
                    <p>{session.user.email}</p>
                    <div className="account-links">
                      <a href="/saved">
                        Saved items <Heart />
                      </a>
                      <a href="/cart">
                        Your cart <ShoppingCart />
                      </a>
                    </div>
                    <p>Your cart and orders are the same here and in the app.</p>
                    <AccountOrders brandMap={brandMap} money={money} />
                    <AccountSocial
                      social={social}
                      productMap={productMap}
                      brandMap={brandMap}
                      toast={toast}
                    />
                    <AccountDevice toast={toast} />
                    <button className="outline-button" onClick={signOut}>
                      Sign out
                    </button>
                    <AccountDelete toast={toast} onDeleted={accountDeleted} />
                  </>
                ) : (
                  <>
                    <p>
                      Sign in or create your Marracat account with Google,
                      Apple, an emailed code or a passkey.
                    </p>
                    <button
                      className="primary-button"
                      onClick={() => setAuthOpen(true)}
                    >
                      Sign in or create account
                    </button>
                  </>
                )}
              </section>
            )}
            {path === "/support" && (
              <section className="info-page">
                <h1>Marracat support</h1>
                <p>
                  For help with Marracat, email{" "}
                  <a href="mailto:support@marracat.com">support@marracat.com</a>.
                  Include your device model, operating system, app version and
                  a description of the problem. Please do not send passwords or
                  payment-card details.
                </p>
                <h2>Orders, shipping and returns</h2>
                <p>
                  Contact the brand using its order-confirmation email for shipping
                  updates, cancellations, refunds and returns. Each brand handles
                  its own checkout; orders from different brands can require
                  separate payments and shipments. The brand confirms final prices,
                  availability, shipping and taxes before you pay.
                </p>
                <h2>Your account and privacy</h2>
                <p>
                  In the iOS app, open You to manage personalization, clear history
                  or delete your signed-in Marracat account; on the website, open
                  Account, then Delete account. For help accessing your
                  account, email support@marracat.com; for a privacy request, email{" "}
                  <a href="mailto:privacy@marracat.com">privacy@marracat.com</a>.
                  See our <a href="/privacy">privacy policy</a> for details.
                </p>
              </section>
            )}
            {path === "/boosts" && (
              <BoostsPage signedIn={!!session?.user} onSignIn={() => setAuthOpen(true)} params={params} />
            )}
            {path === "/brand-ads" && (
              <BrandAds params={params} products={[...productMap.values()]} money={money}
                signedIn={!!session?.user} onSignIn={() => setAuthOpen(true)} toast={toast} />
            )}
            {path === "/for-brands" && (
              <ForBrands
                brands={[...brandMap.values()]}
                signedIn={!!session?.user}
                onSignIn={() => setAuthOpen(true)}
                claimState={params.get("claim")}
              />
            )}
            {["/privacy", "/how-it-works"].includes(path) && (
              <section className="info-page">
                <h1>
                  {path === "/privacy"
                    ? "Your privacy at Marracat"
                    : "Good finds. Direct from the brand."}
                </h1>
                {path === "/privacy" ? (
                  <PrivacyPolicy />
                ) : (
                  <>
                    <p>
                      Discover brands and browse their products together on
                      Marracat. Search for a favorite, explore a department, or
                      meet a new brand.
                    </p>
                    <p>
                      Save products with the heart button. Add supported
                      products to your cart, choose your options, and check out
                      separately with each brand. Some brands are available
                      through a direct link to their store.
                    </p>
                    <p>
                      Each brand processes your payment and handles shipping,
                      order support, and returns. Product information comes from
                      the brand’s catalog; the brand confirms current pricing
                      and availability at checkout.
                    </p>
                  </>
                )}
              </section>
            )}
            {![
              "/",
              "/shop",
              "/brands",
              "/product",
              "/cart",
              "/saved",
              "/account",
              "/orders",
              "/order",
              "/privacy",
              "/support",
              "/how-it-works",
            ].includes(path) && (
              <div className="empty-state">
                <h1>Let’s find your way back.</h1>
                <a className="primary-button" href="/">
                  Back to Marracat
                </a>
              </div>
            )}
          </>
        )}
      </main>
      <footer>
        <div className="footer-top">
          <a href="/">
            <img src="/logo.svg" alt="Marracat" />
          </a>
          <p>Your next favorite. All in one place.</p>
          <a href="/brands">Our brands</a>
          <a href="/how-it-works">How it works</a>
          <a href="/for-brands">For brands</a>
          <a href="/privacy">Privacy</a>
          <a href="/support">Support</a>
        </div>
        <div className="footer-bottom">
          <span>© {new Date().getFullYear()} Marracat</span>
          <span>Explore more. Shop with intention.</span>
        </div>
      </footer>
      {notice && (
        <div className="toast" role="status">
          <Check size={18} />
          {notice}
        </div>
      )}
      {buyerOpen && (
        <BuyerForm
          buyer={buyer}
          account={session?.user}
          onClose={() => setBuyerOpen(false)}
          onSave={(d) => {
            setBuyer(d);
            setBuyerOpen(false);
            if (path !== "/checkout") go("/checkout");
          }}
        />
      )}
      {authOpen && (
        <dialog
          id="auth-dialog"
          className="auth-dialog"
          onCancel={() => setAuthOpen(false)}
          onClick={(e) => {
            if (e.target === e.currentTarget) setAuthOpen(false);
          }}
        >
          <button
            className="close-dialog icon-button"
            aria-label="Close sign in"
            onClick={() => setAuthOpen(false)}
          >
            <X />
          </button>
          {/* Plain card, Apple and Google side by side (owner, 2026-11-09,
              picked "2 Plain card"), and a link to sign in with an emailed
              code instead ("give user a hypertext to use email"). */}
          <img src="/mark.svg" alt="" />
          <h2>Log in or sign up</h2>
          {authByEmail ? (
            <EmailSignIn
              onBack={() => setAuthByEmail(false)}
              onStart={() => {
                track("sign_in_start", { provider: "email" });
                try { sessionStorage.setItem("marracat-signin", "email"); } catch {}
              }}
            />
          ) : (
            <>
              <p className="auth-sub">One account for every brand on Marracat.</p>
              <div className="auth-pair">
                <button
                  className="auth-square is-apple"
                  disabled={authBusy}
                  aria-label="Continue with Apple"
                  onClick={() => signIn("apple")}
                >
                  <svg width="26" height="28" viewBox="0 0 24 24" aria-hidden="true">
              <path
                fill="currentColor"
                d="M17.1 12.3c0-2.2 1.8-3.3 1.9-3.4-1.1-1.6-2.8-1.8-3.4-1.8-1.4-.2-2.8.9-3.5.9-.8 0-1.9-.9-3.1-.9-1.6 0-3 .9-3.8 2.2-1.6 2.7-.4 6.8 1.1 9 .7 1.1 1.6 2.3 2.7 2.2 1.1 0 1.5-.7 2.9-.7 1.3 0 1.7.7 2.9.7s2-1.1 2.7-2.2c.9-1.2 1.2-2.5 1.2-2.6-.1 0-2.3-.9-2.3-3.4h.7zM14.8 5.7c.6-.8 1.1-1.9 1-3-.9 0-2 .6-2.7 1.4-.6.6-1.1 1.8-1 2.8 1 .1 2-.5 2.7-1.2z"
              />
            </svg>
                  <span>Apple</span>
                </button>
                <button
                  className="auth-square"
                  disabled={authBusy}
                  aria-label="Continue with Google"
                  onClick={() => signIn("google")}
                >
                  <svg width="26" height="26" viewBox="0 0 48 48" aria-hidden="true">
                    <path fill="#EA4335" d="M24 9.5c3.5 0 6.6 1.2 9.1 3.6l6.8-6.8C35.8 2.4 30.3 0 24 0 14.6 0 6.6 5.4 2.6 13.3l7.9 6.1C12.4 13.7 17.7 9.5 24 9.5z" />
                    <path fill="#4285F4" d="M46.5 24.5c0-1.6-.1-3.1-.4-4.5H24v9h12.7c-.6 3-2.3 5.5-4.8 7.2l7.7 6c4.5-4.2 6.9-10.3 6.9-17.7z" />
                    <path fill="#FBBC05" d="M10.5 28.6c-.5-1.4-.8-3-.8-4.6s.3-3.2.8-4.6l-7.9-6.1C.9 16.6 0 20.2 0 24s.9 7.4 2.6 10.7l7.9-6.1z" />
                    <path fill="#34A853" d="M24 48c6.5 0 11.9-2.1 15.9-5.8l-7.7-6c-2.2 1.5-5 2.3-8.2 2.3-6.3 0-11.6-4.2-13.5-9.9l-7.9 6.1C6.6 42.6 14.6 48 24 48z" />
                  </svg>
                  <span>Google</span>
                </button>
              </div>
              {providers?.email && (
                <button
                  className="auth-email-link"
                  onClick={() => {
                    setAuthError("");
                    setAuthByEmail(true);
                  }}
                >
                  Use email instead
                </button>
              )}
              {providers?.passkey && passkeysSupported() && (
                <button
                  className="auth-email-link auth-passkey"
                  disabled={authBusy}
                  onClick={async () => {
                    setAuthError("");
                    track("sign_in_start", { provider: "passkey" });
                    try { sessionStorage.setItem("marracat-signin", "passkey"); } catch {}
                    try {
                      const url = await signInWithPasskey();
                      if (url === "cancelled") track("sign_in_cancel", { provider: "passkey", step: "provider" });
                      else location.assign(url);
                    } catch (e) {
                      track("sign_in_fail", { provider: "passkey", step: "exchange", reason: "error" });
                      setAuthError(e.message);
                    }
                  }}
                >
                  <KeyRound size={15} /> Sign in with a passkey
                </button>
              )}
            </>
          )}
          {authError && (
            <p className="auth-error" role="alert">
              {authError}
            </p>
          )}
          <p className="auth-fine">
            New here? Your first sign-in creates your account.
            <br />
            <a href="/privacy" onClick={() => setAuthOpen(false)}>
              How we use your information
            </a>
          </p>
          <button className="text-link" onClick={() => setAuthOpen(false)}>
            Keep exploring as a guest <ArrowRight size={15} />
          </button>
        </dialog>
      )}
    </>
  );
}
createRoot(document.getElementById("root")).render(<App />);
