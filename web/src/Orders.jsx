import React, { useEffect, useMemo, useState } from "react";
import { Package, ChevronLeft, ChevronRight, Copy, ExternalLink, CalendarDays, Truck, Search, RefreshCw } from "lucide-react";
import { imageURL } from "./catalog.js";
import { fastReady } from "./fast-query";
import { Price } from "./fx";

// Orders on the website, from the account the app syncs (orderRecord.js).
import { fromAppleDate } from "./orderRecord.js";
import { updatesFor, stepOf, headline, arrivalLabel, carrierName, describe, safeLink, orderKey, STEP_NAMES } from "./orderUpdates.js";
export { webOrderRecord, recordWebOrder } from "./orderRecord.js";

/// The account page's short list: the latest orders and a way to all of them.
export function AccountOrders({ brandMap, money }) {
  const [orders, setOrders] = useState(null);
  useEffect(() => {
    fetch("/api/account/profile").then((r) => (r.ok ? r.json() : null)).then((d) => setOrders(d?.profile?.checkouts || [])).catch(() => setOrders([]));
  }, []);
  if (orders === null) return <p className="small">Loading your orders…</p>;
  return (
    <section className="account-orders" data-section="orders">
      <div className="account-orders-head">
        <h2>Your orders</h2>
        {orders.length > 0 && <a href="/orders">See all orders <ChevronRight size={16} /></a>}
      </div>
      {!orders.length && <p className="small">Orders you place in the app or here show up in both.</p>}
      {orders.slice(0, 3).map((o) => {
        const brand = brandMap.get(o.brandID);
        const number = orderNumberText(o);
        return (
          // Each order opens its details: status, shipments, items (owner, 2026-10-11).
          <a key={o.id} className="account-order" href={`/order?id=${encodeURIComponent(o.id)}`} data-order={o.id}>
            <Package size={20} />
            <div>
              <strong>{brand?.name || "Order"}</strong>
              <span className="small">
                {placedDate(o)}{number ? ` · Order #${number}` : ""}{` · ${o.itemCount} item${o.itemCount === 1 ? "" : "s"}`}
              </span>
              {o.items?.length ? <span className="small">{o.items.map((i) => `${i.title}${i.quantity > 1 ? ` × ${i.quantity}` : ""}`).join(", ")}</span> : null}
            </div>
            <span className="account-order-total">{money(o.total ?? o.subtotal, o.currency || o.subtotalCurrency || "USD")}</span>
            <ChevronRight size={18} className="account-order-chevron" aria-hidden="true" />
          </a>
        );
      })}
    </section>
  );
}

const placedDate = (o) => fromAppleDate(o.date).toLocaleDateString("en-US", { month: "long", day: "numeric", year: "numeric" });
const recordTotal = (o) => o.total ?? o.subtotal;
const recordCurrency = (o) => o.currency || o.subtotalCurrency || "USD";

/// What was in an order, with the catalog's product where it still has it.
function orderItems(record, productMap) {
  const ids = record.productIDs || [];
  const base = record.items?.length ? record.items : ids.map((id) => ({ title: productMap.get(id)?.title || "Item", quantity: 1 }));
  return base.map((it, i) => ({ ...it, product: productMap.get(ids[i]) || null }));
}

/// The products these orders hold, from the catalog when it's loaded, else
/// fetched one by one (at most 60): the page shouldn't wait for all 146k.
function useOrderProducts(orders, productMap) {
  const [fetched, setFetched] = useState(() => new Map());
  const wanted = [...new Set((orders || []).flatMap((o) => o.productIDs || []))].slice(0, 60);
  const missing = wanted.filter((id) => !productMap.has(id) && !fetched.has(id));
  const key = missing.join(",");
  useEffect(() => {
    if (!missing.length) return;
    let live = true;
    Promise.all(missing.map((id) => fetch("/api/products/" + encodeURIComponent(id) + "?v=3")
      .then((r) => (r.ok ? r.json() : null)).catch(() => null)))
      .then((list) => {
        if (!live) return;
        setFetched((m) => {
          const next = new Map(m);
          missing.forEach((id, i) => next.set(id, list[i] ? { id, ...list[i] } : null));
          return next;
        });
        fastReady();   // now the full catalog may load, behind the page
      });
    return () => { live = false; };
  }, [key]);
  return useMemo(() => ({ get: (id) => productMap.get(id) || fetched.get(id) || undefined, has: (id) => productMap.has(id) || !!fetched.get(id) }), [productMap, fetched]);
}

/// Loads the account's orders and their shipping updates once.
function useOrders() {
  const [data, setData] = useState(null);
  useEffect(() => {
    let live = true;
    Promise.all([
      fetch("/api/account/profile").then((r) => (r.ok ? r.json() : null)).catch(() => null),
      fetch("/api/account/orders/updates").then((r) => (r.ok ? r.json() : null)).catch(() => null),
    ]).then(([p, u]) => live && setData({ signedIn: !!p, orders: p?.profile?.checkouts || [], updates: u || { events: [], tracked: [] } }));
    return () => { live = false; };
  }, []);
  return data;
}

const RANGES = [
  { id: "30d", label: "last 30 days", since: () => Date.now() - 30 * 86400_000 },
  { id: "3m", label: "past 3 months", since: () => Date.now() - 92 * 86400_000 },
  { id: "year", label: String(new Date().getFullYear()), since: () => new Date(new Date().getFullYear(), 0, 1).getTime() },
  { id: "all", label: "all time", since: () => 0 },
];

/// "Your Orders" (owner, 2026-10-11: "lets have our orders page look like
/// this", Amazon's): search, Orders / Buy Again / Not Yet Shipped, a time
/// range, and a card per order with its status, items and actions.
export function OrdersPage({ tab = "orders", brandMap, productMap: catalogProducts, money, onBuyAgain, categories = [] }) {
  const data = useOrders();
  const productMap = useOrderProducts(data?.orders, catalogProducts);
  const [query, setQuery] = useState("");
  const [applied, setApplied] = useState("");
  const [range, setRange] = useState("3m");
  if (data === null) return <p className="small order-detail-loading">Loading your orders…</p>;
  if (!data.signedIn) return <section className="orders-page"><h1>Your Orders</h1><p>Sign in to see your orders.</p></section>;

  const enriched = [...data.orders]
    .sort((a, b) => b.date - a.date)
    .map((o) => {
      const brand = brandMap.get(o.brandID);
      const u = updatesFor(o, brand, data.orders, data.updates);
      return { o, brand, ...u, step: stepOf(u.events), items: orderItems(o, productMap) };
    });
  const q = applied.trim().toLowerCase();
  const matches = (e) => !q || [e.brand?.name, orderNumberText(e.o), ...e.items.map((i) => i.title)].some((t) => t && String(t).toLowerCase().includes(q));
  const since = RANGES.find((r) => r.id === range).since();
  const shown = enriched.filter((e) => matches(e) && (tab === "unshipped" ? e.step === 0 : fromAppleDate(e.o.date).getTime() >= since));

  const tabs = [["orders", "Orders", "/orders"], ["buy-again", "Buy Again", "/orders?tab=buy-again"], ["unshipped", "Not Yet Shipped", "/orders?tab=unshipped"]];
  return (
    <section className="orders-page" data-section="orders-page">
      <nav className="order-crumbs small"><a href="/account">Your Account</a> <ChevronRight size={14} /> <span>Your Orders</span></nav>
      <div className="orders-title-row">
        <h1>{tab === "buy-again" ? "Buy Again" : "Your Orders"}</h1>
        <form className="orders-search" role="search" onSubmit={(e) => { e.preventDefault(); setApplied(query); }}>
          <label className="orders-search-field"><Search size={18} aria-hidden="true" />
            <input value={query} onChange={(e) => { setQuery(e.target.value); if (!e.target.value) setApplied(""); }} placeholder="Search all orders" aria-label="Search all orders" />
          </label>
          <button type="submit" className="orders-search-button">Search Orders</button>
        </form>
      </div>
      <div className="orders-tabs" role="tablist">
        {tabs.map(([id, label, href]) => (
          <a key={id} role="tab" aria-selected={tab === id} className={tab === id ? "active" : ""} href={href}>{label}</a>
        ))}
      </div>
      {tab === "buy-again"
        ? <BuyAgain entries={enriched.filter(matches)} money={money} onBuyAgain={onBuyAgain} categories={categories} />
        : (
          <>
            <div className="orders-count">
              <span><strong>{shown.length} order{shown.length === 1 ? "" : "s"}</strong> {tab === "unshipped" ? "not yet shipped" : "placed in"}</span>
              {tab !== "unshipped" && (
                <select value={range} onChange={(e) => setRange(e.target.value)} aria-label="Time range">
                  {RANGES.map((r) => <option key={r.id} value={r.id}>{r.label}</option>)}
                </select>
              )}
            </div>
            {!shown.length && <p className="small orders-empty">{data.orders.length ? "No orders match." : "Orders you place in the app or here show up in both."}</p>}
            {shown.map((e) => <OrderCard key={e.o.id} entry={e} money={money} onBuyAgain={onBuyAgain} />)}
          </>
        )}
    </section>
  );
}

function OrderCard({ entry, money, onBuyAgain }) {
  const { o, brand, events, tracked, step, items } = entry;
  const placed = fromAppleDate(o.date).getTime();
  const number = orderNumberText(o);
  const details = `/order?id=${encodeURIComponent(o.id)}`;
  const arriving = step < 3 ? arrivalLabel(events.map((e) => e.estDelivery).filter(Boolean).pop()) : null;
  const trackHref = safeLink(tracked?.statusPage) || safeLink(tracked?.trackingURL);
  const note = step >= 3 ? "Your package was delivered." : step === 2 ? "Your package is on the delivery truck." : step === 1 ? "Your package is on its way." : `${brand?.name || "The brand"} is preparing your order.`;
  return (
    <article className="order-box" data-order={o.id}>
      <header className="order-box-head">
        <div><span>Order placed</span>{placedDate(o)}</div>
        <div><span>Total</span>{money(recordTotal(o), recordCurrency(o))}</div>
        <div><span>Brand</span>{brand ? <a href={`/b/${encodeURIComponent(brand.id)}`}>{brand.name}</a> : "—"}</div>
        <div className="order-box-ids">
          {number && <span>Order # {number}</span>}
          <a href={details}>View order details</a>
        </div>
      </header>
      <div className="order-box-body">
        <div className="order-box-main">
          <h2 data-order-status>{arriving && step < 3 ? arriving : headline(step, events, placed).replace(/ (Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday),/, "")}</h2>
          <p>{note}</p>
          {items.map((it, i) => (
            <div className="order-box-item" key={i}>
              <a href={it.product ? `/p/${encodeURIComponent(it.product.id)}` : details} className="order-box-thumb">
                {it.product?.images?.[0] ? <img src={imageURL(it.product.images[0], 240)} alt="" loading="lazy" /> : <Package size={28} />}
              </a>
              <div>
                <a href={it.product ? `/p/${encodeURIComponent(it.product.id)}` : details} className="order-box-title">{it.title}{it.quantity > 1 ? ` × ${it.quantity}` : ""}</a>
                {it.product?.available
                  ? <button type="button" className="buy-again-button" onClick={() => onBuyAgain?.(it.product)}><RefreshCw size={16} /> Buy it again</button>
                  : it.product ? <p className="small">No longer in stock</p> : null}
              </div>
            </div>
          ))}
        </div>
        <div className="order-box-actions">
          {trackHref
            ? <a className="order-action" href={trackHref} target="_blank" rel="noopener noreferrer">Track package</a>
            : step > 0 && <a className="order-action" href={details}>Track package</a>}
          <a className="order-action" href={details}>View order details</a>
          {brand && <a className="order-action" href={`/b/${encodeURIComponent(brand.id)}`}>Visit the {brand.name} store</a>}
        </div>
      </div>
    </article>
  );
}

const SORTS = [["recommended", "Recommended"], ["recent", "Most recent"], ["price-low", "Price: low to high"], ["price-high", "Price: high to low"]];

/// Everything bought before that the catalog still carries, once each.
function BuyAgain({ entries, money, onBuyAgain, categories }) {
  const [sort, setSort] = useState("recommended");
  const [picked, setPicked] = useState([]);
  const seen = new Map();
  for (const e of entries)
    for (const it of e.items)
      if (it.product && !seen.has(it.product.id)) seen.set(it.product.id, { p: it.product, when: e.o.date, times: 0 });
  for (const e of entries) for (const it of e.items) if (it.product) seen.get(it.product.id).times++;
  let list = [...seen.values()];
  const present = categories.filter((c) => list.some((x) => x.p.category === c.id));
  if (picked.length) list = list.filter((x) => picked.includes(x.p.category));
  const by = {
    recommended: (a, b) => (b.p.available - a.p.available) || (b.times - a.times) || (b.when - a.when),
    recent: (a, b) => b.when - a.when,
    "price-low": (a, b) => a.p.price - b.p.price,
    "price-high": (a, b) => b.p.price - a.p.price,
  }[sort];
  list.sort(by);
  return (
    <div className="buy-again">
      <aside className="buy-again-filters">
        <label className="buy-again-sort"><strong>Sort by</strong>
          <select value={sort} onChange={(e) => setSort(e.target.value)}>{SORTS.map(([id, l]) => <option key={id} value={id}>{l}</option>)}</select>
        </label>
        {present.length > 1 && (
          <fieldset><legend><strong>Department</strong></legend>
            {present.map((c) => (
              <label key={c.id}><input type="checkbox" checked={picked.includes(c.id)}
                onChange={() => setPicked((p) => (p.includes(c.id) ? p.filter((x) => x !== c.id) : [...p, c.id]))} /> {c.name}</label>
            ))}
          </fieldset>
        )}
      </aside>
      <div className="buy-again-grid">
        {!list.length && <p className="small">Products from your orders show here so you can get them again.</p>}
        {list.map(({ p }) => (
          <article key={p.id} className="buy-again-card" data-buy-again={p.id}>
            <a href={`/p/${encodeURIComponent(p.id)}`}><img src={imageURL(p.images?.[0], 400)} alt="" loading="lazy" /></a>
            <a className="buy-again-title" href={`/p/${encodeURIComponent(p.id)}`}>{p.title}</a>
            <span className="buy-again-price"><Price value={p.price} currency={p.currency} /></span>
            {p.compare_at > p.price && <span className="buy-again-deal">{Math.round((1 - p.price / p.compare_at) * 100)}% off</span>}
            {p.available
              ? <button type="button" className="buy-again-add" onClick={() => onBuyAgain?.(p)}>Add to cart</button>
              : <span className="small">Out of stock</span>}
          </article>
        ))}
      </div>
    </div>
  );
}

const orderNumberText = (o) => o.orderID?.match(/(\d+)\D*$/)?.[1];
const fmtTime = (ms) => new Date(ms).toLocaleString("en-US", { month: "short", day: "numeric", hour: "numeric", minute: "2-digit" });

/// One order: where it is, its shipments and what was in it, from the same
/// account and shipping updates the app reads (server/account-web.js).
export function OrderDetail({ id, brandMap, productMap: catalogProducts, money, toast }) {
  const data = useOrders();
  const productMap = useOrderProducts(data?.orders?.filter((o) => o.id === id), catalogProducts);
  if (data === null) return <p className="small order-detail-loading">Loading your order…</p>;
  const back = <a className="order-back" href="/orders"><ChevronLeft size={16} /> Your orders</a>;
  if (!data.signedIn) return <section className="order-detail">{back}<h1>Order details</h1><p>Sign in to see this order.</p></section>;
  const record = data.orders.find((o) => o.id === id);
  if (!record) return <section className="order-detail">{back}<h1>Order not found</h1><p className="small">It may belong to another account.</p></section>;

  const brand = brandMap.get(record.brandID);
  const brandName = brand?.name || "the brand";
  const placed = fromAppleDate(record.date).getTime();
  const { events, tracked } = updatesFor(record, brand, data.orders, data.updates);
  const step = stepOf(events);
  const arriving = step < 3 ? arrivalLabel(events.map((e) => e.estDelivery).filter(Boolean).pop()) : null;
  const tracking = [...events].reverse().find((e) => e.trackingNumber);
  const orderName = events.map((e) => e.orderName).find(Boolean);
  const number = orderName ? orderKey(orderName) : orderNumberText(record);
  const statusPage = safeLink(tracked?.statusPage);
  const carrierPage = safeLink(tracked?.trackingURL);
  const currency = record.currency || record.subtotalCurrency || "USD";
  const items = (record.items?.length ? record.items : (record.productIDs || []).map((pid) => ({ title: productMap.get(pid)?.title || "Item", quantity: 1 })))
    .map((it, i) => ({ ...it, product: productMap.get(record.productIDs?.[i]) }));
  const copy = (text, note) => navigator.clipboard?.writeText(text).then(() => toast?.(note)).catch(() => {});

  return (
    <section className="order-detail" data-section="order-detail">
      {back}
      <h1>Order details</h1>
      <div className="order-card">
        <div className="order-card-head">
          <div>
            <h2 data-order-status>{headline(step, events, placed)}</h2>
            <p className="small">
              {events.length ? `Updates from ${brandName} show here as they arrive.` : `${brandName} emails shipping updates to the address on the order.`}
            </p>
          </div>
          {items[0]?.product?.images?.[0] && <img className="order-thumb" src={imageURL(items[0].product.images[0], 240)} alt="" />}
        </div>
        <ol className="order-tracker" style={{ "--p": step / 3 }} aria-label={`Order progress: ${STEP_NAMES[step]}`}>
          {STEP_NAMES.map((name, i) => (
            <li key={name} className={i <= step ? "done" : ""} aria-current={i === step ? "step" : undefined}>{name}</li>
          ))}
        </ol>
        {arriving && <p className="order-arrival"><CalendarDays size={16} /> {arriving}</p>}
        {tracking && (
          <button type="button" className="order-tracking-number" onClick={() => copy(tracking.trackingNumber, "Tracking number copied")}>
            <Truck size={16} /> {carrierName(tracking.carrier)} tracking {tracking.trackingNumber} <Copy size={14} />
          </button>
        )}
        {(statusPage || carrierPage) && (
          <div className="order-links">
            {statusPage && <a className="outline-button" href={statusPage} target="_blank" rel="noopener noreferrer">Track package <ExternalLink size={14} /></a>}
            {carrierPage && carrierPage !== statusPage && <a className="outline-button" href={carrierPage} target="_blank" rel="noopener noreferrer">Carrier tracking <ExternalLink size={14} /></a>}
          </div>
        )}
      </div>

      <h2 className="order-section-title">Shipment history</h2>
      {events.length ? (
        <ol className="order-history" data-order-history>
          {[...events].reverse().map((e) => (
            <li key={e.id}>
              <strong>{describe(e)}</strong>
              <span className="small">{fmtTime(e.received)}{e.orderName ? ` · Order ${e.orderName}` : ""}</span>
            </li>
          ))}
          <li><strong>Ordered</strong><span className="small">{fmtTime(placed)}</span></li>
        </ol>
      ) : (
        <p className="small">No shipping updates yet. They show here once {brandName} ships.</p>
      )}

      <h2 className="order-section-title">Items</h2>
      <ul className="order-items">
        {items.map((it, i) => (
          <li key={i}>
            {it.product?.images?.[0] ? <img src={imageURL(it.product.images[0], 240)} alt="" /> : <span className="order-item-blank" />}
            <div>
              {it.product ? <a href={`/product?id=${encodeURIComponent(it.product.id)}`}>{it.title}</a> : <span>{it.title}</span>}
              {it.quantity > 1 && <span className="small"> × {it.quantity}</span>}
            </div>
          </li>
        ))}
      </ul>

      <h2 className="order-section-title">Summary</h2>
      <dl className="order-summary">
        <dt>Brand</dt><dd>{brand ? <a href={`/shop?brand=${encodeURIComponent(brand.id)}`}>{brandName}</a> : brandName}</dd>
        {number && <><dt>Order</dt><dd>#{number}</dd></>}
        <dt>Placed</dt><dd>{new Date(placed).toLocaleString("en-US", { dateStyle: "long", timeStyle: "short" })}</dd>
        <dt>Items</dt><dd>{record.itemCount}</dd>
        {record.subtotal != null && <><dt>Subtotal</dt><dd>{money(record.subtotal, record.subtotalCurrency || currency)}</dd></>}
        {record.total != null && <><dt>Total</dt><dd>{money(record.total, currency)}</dd></>}
      </dl>
    </section>
  );
}
