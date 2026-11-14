import React, { useState, useEffect, useRef, useCallback } from "react";
import {
  Ellipsis, Flag, Ban, Trash2, Reply, Share2, Send, UserPlus, UserCheck, UserMinus,
  Lock, Link as LinkIcon, Search, X, ShieldAlert, Clock,
} from "lucide-react";
import { imageURL, money } from "../catalog.js";
import { track } from "../events.js";
import { open as openEnvelope, sealForFriends } from "../e2ee.js";
import { ensureDevice, replaceDevice, forgetDevice } from "../device-key.js";
import { refusal } from "../../server/content-filter.js";

// Comments, profiles, friends and end-to-end encrypted sharing for the
// storefront. Everything talks to /api/social (server/social.js).

export const SHARE_ORIGIN = "https://marracat.com";
export const shareURL = (id) => `${SHARE_ORIGIN}/p/${encodeURIComponent(id)}`;

export async function api(path, { method = "GET", body } = {}) {
  const response = await fetch("/api/social/" + path, {
    method,
    credentials: "same-origin",
    headers: body ? { "Content-Type": "application/json" } : {},
    body: body ? JSON.stringify(body) : undefined,
  });
  const data = response.status === 204 ? null : await response.json().catch(() => ({}));
  if (!response.ok)
    throw Object.assign(new Error(data?.error || "That didn’t work. Try again."), {
      status: response.status,
      code: data?.code,
    });
  return data;
}

export function ago(ms) {
  const s = Math.max(0, (Date.now() - ms) / 1000);
  if (s < 60) return "just now";
  const units = [["y", 31536e3], ["w", 604800], ["d", 86400], ["h", 3600], ["m", 60]];
  for (const [u, n] of units) if (s >= n) return `${Math.floor(s / n)}${u} ago`;
  return "just now";
}

// --- the signed-in person ---------------------------------------------------------

/** Profile, counts and this browser's encryption key, while signed in. */
export function useSocial(session) {
  const userID = session?.user?.id;
  const [me, setMe] = useState(null);
  const [device, setDevice] = useState(null);
  const refresh = useCallback(() => {
    if (!userID) return Promise.resolve(null);
    return api("me").then((m) => (setMe(m), m)).catch(() => null);
  }, [userID]);
  useEffect(() => {
    setMe(null);
    setDevice(null);
    if (!userID) return;
    refresh();
    ensureDevice(userID, api).then(setDevice).catch(() => setDevice(null));
  }, [userID, refresh]);
  const resetDevice = async () => {
    const d = await replaceDevice(userID, api);
    setDevice(d);
    return d;
  };
  const forget = () => (userID ? forgetDevice(userID, api) : Promise.resolve());
  return { me, refresh, device, resetDevice, forget, signedIn: !!userID };
}

// --- dialogs ----------------------------------------------------------------------

function Dialog({ label, onClose, children, className = "" }) {
  const ref = useRef(null);
  useEffect(() => {
    ref.current?.showModal?.();
    return () => ref.current?.close?.();
  }, []);
  return (
    <dialog
      ref={ref}
      className={"social-dialog " + className}
      aria-label={label}
      onCancel={(e) => {
        e.preventDefault();
        onClose();
      }}
      onClick={(e) => e.target === e.currentTarget && onClose()}
    >
      <button className="close-dialog icon-button" aria-label="Close" onClick={onClose}>
        <X />
      </button>
      {children}
    </dialog>
  );
}

/** Community guidelines, agreed once before posting anything (App Store 1.2). */
export function GuidelinesDialog({ onAgree, onClose }) {
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  return (
    <Dialog label="Community guidelines" onClose={onClose}>
      <ShieldAlert size={34} />
      <h2>Keep Marracat kind</h2>
      <p>Before you post or send anything, agree to these guidelines:</p>
      <ul className="guidelines">
        <li>No harassment, bullying or threats.</li>
        <li>No hate speech or slurs.</li>
        <li>No sexual content.</li>
        <li>No spam, scams or links.</li>
      </ul>
      <p>
        Anyone can report a comment, a message or a person. Objectionable content is removed,
        and people who break these rules are banned, within 24 hours.
      </p>
      {error && <p className="form-error" role="alert">{error}</p>}
      <button
        className="primary-button"
        disabled={busy}
        onClick={async () => {
          setBusy(true);
          try {
            await api("terms", { method: "POST", body: { agree: true } });
            await onAgree();
          } catch (e) {
            setError(e.message);
            setBusy(false);
          }
        }}
      >
        I agree
      </button>
    </Dialog>
  );
}

// --- comments ---------------------------------------------------------------------

function CommentMenu({ comment, onDelete, onReport, onBlock, owner }) {
  const [open, setOpen] = useState(false);
  const ref = useRef(null);
  useEffect(() => {
    if (!open) return;
    const close = (e) => !ref.current?.contains(e.target) && setOpen(false);
    document.addEventListener("click", close);
    return () => document.removeEventListener("click", close);
  }, [open]);
  const mine = comment.mine;
  return (
    <div className="comment-menu" ref={ref}>
      <button className="icon-button" aria-label="More actions" aria-expanded={open} onClick={() => setOpen((o) => !o)}>
        <Ellipsis size={18} />
      </button>
      {open && (
        <div className="menu-list" role="menu">
          {(mine || owner) && (
            <button role="menuitem" onClick={() => (setOpen(false), onDelete())}>
              <Trash2 size={15} /> Delete
            </button>
          )}
          {!mine && (
            <>
              <button role="menuitem" onClick={() => (setOpen(false), onReport())}>
                <Flag size={15} /> Report
              </button>
              {comment.author && (
                <button role="menuitem" onClick={() => (setOpen(false), onBlock())}>
                  <Ban size={15} /> Block {comment.author.name}
                </button>
              )}
            </>
          )}
        </div>
      )}
    </div>
  );
}

function CommentView({ comment, signedIn, owner, onReply, act }) {
  if (comment.deleted)
    return <p className="comment-removed">This comment was removed.</p>;
  return (
    <div className="comment" data-testid="comment">
      <div className="comment-head">
        {comment.author ? (
          <a href={`/u/${comment.author.handle}`} className="comment-author">
            <b>{comment.author.name}</b> <span>@{comment.author.handle}</span>
          </a>
        ) : (
          <b>Marracat shopper</b>
        )}
        <span className="comment-time">{ago(comment.created_at)}</span>
        {comment.under_review && <span className="review-tag">Under review</span>}
        {signedIn && (
          <CommentMenu
            comment={comment}
            owner={owner}
            onDelete={() => act("delete", comment)}
            onReport={() => act("report", comment)}
            onBlock={() => act("block", comment)}
          />
        )}
      </div>
      <p className="comment-body">{comment.body}</p>
      {signedIn && (
        <button className="text-link comment-reply" onClick={() => onReply(comment)}>
          <Reply size={14} /> Reply
        </button>
      )}
    </div>
  );
}

export function Comments({ productID, signedIn, onSignIn, toast }) {
  const [data, setData] = useState(null);
  const [body, setBody] = useState("");
  const [replyTo, setReplyTo] = useState(null);
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);
  const [terms, setTerms] = useState(false);
  const box = useRef(null);
  const path = `products/${encodeURIComponent(productID)}/comments`;
  const load = useCallback(
    () => api(path).then(setData).catch(() => setData({ comments: [], viewer: {} })),
    [path],
  );
  useEffect(() => {
    setData(null);
    setBody("");
    setReplyTo(null);
    setError("");
    load();
  }, [load, signedIn]);

  async function post() {
    const text = body.trim();
    if (!text) return;
    setBusy(true);
    setError("");
    try {
      const result = await api(path, { method: "POST", body: { body: text, parent_id: replyTo?.id ?? null } });
      setData((d) => ({ ...d, comments: result.comments, viewer: { ...d?.viewer, agreed_terms: true } }));
      track("comment_post", { product: productID });  // that a comment was posted, never its text
      setBody("");
      setReplyTo(null);
    } catch (e) {
      if (e.code === "terms_required") setTerms(true);
      else setError(e.message);
    } finally {
      setBusy(false);
    }
  }

  async function act(kind, comment) {
    try {
      if (kind === "delete") {
        if (!confirm("Delete this comment?")) return;
        const result = await api(`comments/${comment.id}`, { method: "DELETE" });
        setData((d) => ({ ...d, comments: result.comments }));
        toast("Comment deleted");
      } else if (kind === "report") {
        if (!confirm("Report this comment? It will be hidden while Marracat reviews it.")) return;
        await api(`comments/${comment.id}/report`, { method: "POST", body: {} });
        toast("Thanks. We’ll review it within 24 hours.");
        load();
      } else if (kind === "block") {
        if (!confirm(`Block ${comment.author.name}? You won’t see each other’s comments, and you can’t be friends.`)) return;
        await api(`comments/${comment.id}/block`, { method: "POST", body: {} });
        toast(`${comment.author.name} is blocked`);
        load();
      }
    } catch (e) {
      toast(e.message);
    }
  }

  const reply = (comment) => {
    setReplyTo({ id: comment.id, name: comment.author?.name || "this comment" });
    box.current?.focus();
    box.current?.scrollIntoView({ block: "center", behavior: "smooth" });
  };
  const comments = data?.comments || [];
  const owner = !!data?.viewer?.owner;
  const count = comments.reduce((n, c) => n + (c.deleted ? 0 : 1) + c.replies.length, 0);

  return (
    <section className="comments" aria-labelledby="comments-title" data-testid="comments">
      <h2 id="comments-title">
        Comments {count > 0 && <span className="count">{count}</span>}
      </h2>
      {signedIn ? (
        <div className="composer">
          {replyTo && (
            <div className="replying">
              Replying to {replyTo.name}
              <button className="icon-button" aria-label="Cancel reply" onClick={() => setReplyTo(null)}>
                <X size={15} />
              </button>
            </div>
          )}
          <textarea
            ref={box}
            aria-label={replyTo ? `Reply to ${replyTo.name}` : "Add a comment"}
            placeholder={replyTo ? "Write a reply" : "What do you think of it?"}
            maxLength={1000}
            value={body}
            onChange={(e) => setBody(e.target.value)}
          />
          <div className="composer-foot">
            <span className="counter">{body.length}/1000</span>
            <button className="primary-button" disabled={busy || !body.trim()} onClick={post}>
              {replyTo ? "Post reply" : "Post"}
            </button>
          </div>
          {error && <p className="form-error" role="alert">{error}</p>}
        </div>
      ) : (
        <button className="outline-button" onClick={onSignIn}>
          Sign in to comment
        </button>
      )}
      {!data ? (
        <p className="muted">Loading comments…</p>
      ) : comments.length === 0 ? (
        <p className="muted">No comments yet. Be the first to share what you think.</p>
      ) : (
        <ol className="threads">
          {comments.map((c) => (
            <li key={c.id} className="thread">
              <CommentView comment={c} signedIn={signedIn} owner={owner} onReply={reply} act={act} />
              {c.replies.length > 0 && (
                <ol className="replies">
                  {c.replies.map((r) => (
                    <li key={r.id}>
                      <CommentView comment={r} signedIn={signedIn} owner={owner} onReply={reply} act={act} />
                    </li>
                  ))}
                </ol>
              )}
            </li>
          ))}
        </ol>
      )}
      {terms && (
        <GuidelinesDialog
          onClose={() => setTerms(false)}
          onAgree={async () => {
            setTerms(false);
            await post();
          }}
        />
      )}
    </section>
  );
}

// --- sharing ----------------------------------------------------------------------

export function ShareButtons({ product, social, onSignIn, toast }) {
  const [sending, setSending] = useState(false);
  async function share() {
    const url = shareURL(product.id);
    track("share", { kind: "product", target: product.id });
    if (navigator.share) {
      try {
        await navigator.share({ title: product.title, url });
        return;
      } catch (e) {
        if (e?.name === "AbortError") return;
      }
    }
    try {
      await navigator.clipboard.writeText(url);
      toast("Link copied");
    } catch {
      toast(url);
    }
  }
  return (
    <>
      <div className="share-actions">
        <button className="outline-button" onClick={share} data-testid="share-button">
          <Share2 size={18} /> Share
        </button>
        <button
          className="outline-button"
          onClick={() => (social.signedIn ? setSending(true) : onSignIn())}
        >
          <Send size={18} /> Send to friends
        </button>
      </div>
      {sending && <SendDialog product={product} social={social} toast={toast} onClose={() => setSending(false)} />}
    </>
  );
}

function SendDialog({ product, social, toast, onClose }) {
  const [friends, setFriends] = useState(null);
  const [picked, setPicked] = useState([]);
  const [note, setNote] = useState("");
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);
  const [terms, setTerms] = useState(false);
  useEffect(() => {
    api("friends").then((f) => setFriends(f.friends)).catch((e) => setError(e.message));
  }, []);
  const toggle = (h) => setPicked((p) => (p.includes(h) ? p.filter((x) => x !== h) : [...p, h]));

  async function send() {
    setError("");
    // The server can't read notes, so the filter runs here, before sealing.
    const why = note.trim() && refusal(note);
    if (why) return setError(why);
    setBusy(true);
    try {
      const { keys } = await api(`keys?handles=${picked.map(encodeURIComponent).join(",")}`);
      const { messages, unreachable } = await sealForFriends(keys, picked, { product_id: product.id, note: note.trim() });
      const names = (hs) => hs.map((h) => friends.find((f) => f.handle === h)?.name || "@" + h).join(", ");
      if (!messages.length) {
        setError(`${names(unreachable)} needs to open Marracat once before they can receive shares.`);
        return;
      }
      await api("shares", { method: "POST", body: { messages } });
      toast(
        unreachable.length
          ? `Sent. ${names(unreachable)} needs to open Marracat once before they can receive shares.`
          : "Sent",
      );
      onClose();
    } catch (e) {
      if (e.code === "terms_required") setTerms(true);
      else setError(e.message);
    } finally {
      setBusy(false);
    }
  }

  return (
    <Dialog label="Send to friends" onClose={onClose} className="send-dialog">
      <h2>Send to friends</h2>
      <p className="encrypted-note">
        <Lock size={14} /> End-to-end encrypted. Only your friends can read it.
      </p>
      <div className="send-product">
        <img src={imageURL(product.images?.[0], 120)} alt="" />
        <span>{product.title}</span>
      </div>
      {!friends ? (
        <p className="muted">{error || "Loading your friends…"}</p>
      ) : friends.length === 0 ? (
        <p className="muted">
          Add friends from your <a href="/account" onClick={onClose}>account</a> to send them products.
        </p>
      ) : (
        <>
          <ul className="pick-friends">
            {friends.map((f) => (
              <li key={f.handle}>
                <label>
                  <input type="checkbox" checked={picked.includes(f.handle)} onChange={() => toggle(f.handle)} />
                  <b>{f.name}</b> <span>@{f.handle}</span>
                </label>
              </li>
            ))}
          </ul>
          <textarea
            aria-label="Add a note"
            placeholder="Add a note (optional)"
            maxLength={280}
            value={note}
            onChange={(e) => setNote(e.target.value)}
          />
          <span className="counter">{note.length}/280</span>
          {error && <p className="form-error" role="alert">{error}</p>}
          <button className="primary-button" disabled={busy || !picked.length} onClick={send}>
            <Send size={17} /> Send
          </button>
        </>
      )}
      {terms && (
        <GuidelinesDialog
          onClose={() => setTerms(false)}
          onAgree={async () => {
            setTerms(false);
            await send();
          }}
        />
      )}
    </Dialog>
  );
}

// --- people -----------------------------------------------------------------------

function RelationshipButtons({ person, relationship, onChange, toast }) {
  const [busy, setBusy] = useState(false);
  const run = async (fn, message) => {
    setBusy(true);
    try {
      const r = await fn();
      onChange(r.relationship);
      if (message) toast(message);
    } catch (e) {
      toast(e.message);
    } finally {
      setBusy(false);
    }
  };
  const h = encodeURIComponent(person.handle);
  const friend = (method) => () => api(`users/${h}/friend`, { method, body: method === "POST" ? {} : undefined });
  if (relationship === "self") return null;
  if (relationship === "blocked")
    return (
      <button className="outline-button" disabled={busy} onClick={() => run(() => api(`users/${h}/block`, { method: "DELETE" }), "Unblocked")}>
        Unblock
      </button>
    );
  return (
    <>
      {relationship === "none" && (
        <button className="primary-button" disabled={busy} onClick={() => run(friend("POST"), "Friend request sent")}>
          <UserPlus size={17} /> Add friend
        </button>
      )}
      {relationship === "incoming" && (
        <>
          <button className="primary-button" disabled={busy} onClick={() => run(friend("POST"), "You’re now friends")}>
            <UserCheck size={17} /> Accept
          </button>
          <button className="outline-button" disabled={busy} onClick={() => run(friend("DELETE"))}>
            Decline
          </button>
        </>
      )}
      {relationship === "requested" && (
        <button className="outline-button" disabled={busy} onClick={() => run(friend("DELETE"), "Request cancelled")}>
          <Clock size={17} /> Requested
        </button>
      )}
      {relationship === "friends" && (
        <button
          className="outline-button"
          disabled={busy}
          onClick={() => confirm(`Remove ${person.name} as a friend?`) && run(friend("DELETE"), "Removed")}
        >
          <UserMinus size={17} /> Friends
        </button>
      )}
    </>
  );
}

export function ProfilePage({ handle, social, onSignIn, toast }) {
  const [state, setState] = useState(null);
  const load = useCallback(
    () =>
      api(`users/${encodeURIComponent(handle)}`)
        .then(setState)
        .catch((e) => setState({ missing: e.status === 404, error: e.message })),
    [handle],
  );
  useEffect(() => {
    setState(null);
    load();
  }, [load, social.signedIn]);
  if (!state) return <p className="muted page-pad">Loading…</p>;
  if (state.missing || !state.profile)
    return (
      <div className="empty-state">
        <h1>No one by that name.</h1>
        <a href="/">Keep exploring</a>
      </div>
    );
  const person = state.profile;
  const h = encodeURIComponent(person.handle);
  return (
    <section className="profile-page" data-testid="profile-page">
      <div className="avatar" aria-hidden="true">{person.name.slice(0, 1).toUpperCase()}</div>
      <h1>{person.name}</h1>
      <p className="handle">@{person.handle}</p>
      {social.signedIn ? (
        <div className="profile-actions">
          <RelationshipButtons
            person={person}
            relationship={state.relationship}
            toast={toast}
            onChange={(r) => (setState((s) => ({ ...s, relationship: r })), social.refresh())}
          />
          {state.relationship !== "self" && state.relationship !== "blocked" && (
            <>
              <button
                className="text-link"
                onClick={async () => {
                  if (!confirm(`Block ${person.name}? You won’t see each other’s comments or messages, and any friendship ends.`)) return;
                  try {
                    await api(`users/${h}/block`, { method: "POST", body: {} });
                    setState((s) => ({ ...s, relationship: "blocked" }));
                    toast(`${person.name} is blocked`);
                  } catch (e) {
                    toast(e.message);
                  }
                }}
              >
                <Ban size={15} /> Block
              </button>
              <button
                className="text-link"
                onClick={async () => {
                  const reason = prompt(`Why are you reporting ${person.name}? (optional)`);
                  if (reason === null) return;
                  try {
                    await api(`users/${h}/report`, { method: "POST", body: { reason } });
                    toast("Thanks. We’ll review it within 24 hours.");
                  } catch (e) {
                    toast(e.message);
                  }
                }}
              >
                <Flag size={15} /> Report
              </button>
            </>
          )}
          {state.relationship === "self" && <a className="text-link" href="/account">Edit your profile</a>}
        </div>
      ) : (
        <button className="outline-button" onClick={onSignIn}>Sign in to add friends</button>
      )}
    </section>
  );
}

// --- account ----------------------------------------------------------------------

function ProfileEditor({ social, toast }) {
  const profile = social.me?.profile;
  const [name, setName] = useState("");
  const [handle, setHandle] = useState("");
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);
  useEffect(() => {
    if (profile) {
      setName(profile.name);
      setHandle(profile.handle);
    }
  }, [profile?.name, profile?.handle]);
  if (!profile) return <p className="muted">Loading your profile…</p>;
  return (
    <form
      className="profile-editor"
      onSubmit={async (e) => {
        e.preventDefault();
        setBusy(true);
        setError("");
        try {
          await api("me", { method: "PATCH", body: { name, handle } });
          await social.refresh();
          toast("Profile saved");
        } catch (err) {
          setError(err.message);
        } finally {
          setBusy(false);
        }
      }}
    >
      <label>
        Name
        <input value={name} maxLength={40} onChange={(e) => setName(e.target.value)} aria-label="Display name" />
      </label>
      <label>
        Handle
        <span className="handle-input">
          @<input value={handle} maxLength={20} onChange={(e) => setHandle(e.target.value.replace(/^@/, ""))} aria-label="Handle" />
        </span>
      </label>
      {error && <p className="form-error" role="alert">{error}</p>}
      <div className="row">
        <button className="primary-button" disabled={busy || (name === profile.name && handle === profile.handle)}>Save</button>
        <a className="text-link" href={`/u/${profile.handle}`}>View your profile</a>
      </div>
    </form>
  );
}

function PersonRow({ person, children }) {
  return (
    <li className="person-row">
      <a href={`/u/${person.handle}`}>
        <span className="avatar small" aria-hidden="true">{person.name.slice(0, 1).toUpperCase()}</span>
        <span><b>{person.name}</b> <span className="muted">@{person.handle}</span></span>
      </a>
      <span className="person-actions">{children}</span>
    </li>
  );
}

function Friends({ social, toast }) {
  const [data, setData] = useState(null);
  const [q, setQ] = useState("");
  const [found, setFound] = useState([]);
  const load = useCallback(() => api("friends").then(setData).catch(() => setData({ friends: [], incoming: [], outgoing: [] })), []);
  useEffect(() => {
    load();
  }, [load]);
  useEffect(() => {
    if (q.trim().length < 2) return setFound([]);
    const t = setTimeout(() => api(`search?q=${encodeURIComponent(q.trim())}`).then((r) => setFound(r.people)).catch(() => {}), 250);
    return () => clearTimeout(t);
  }, [q]);
  const act = async (handle, method, message) => {
    try {
      await api(`users/${encodeURIComponent(handle)}/friend`, { method, body: method === "POST" ? {} : undefined });
      if (message) toast(message);
      await load();
      social.refresh();
      if (q.trim().length >= 2) api(`search?q=${encodeURIComponent(q.trim())}`).then((r) => setFound(r.people)).catch(() => {});
    } catch (e) {
      toast(e.message);
    }
  };
  if (!data) return <p className="muted">Loading friends…</p>;
  return (
    <div className="friends" data-testid="friends">
      <label className="people-search">
        <Search size={16} />
        <input value={q} onChange={(e) => setQ(e.target.value)} placeholder="Find people by name or @handle" aria-label="Find people" />
      </label>
      {found.length > 0 && (
        <ul className="people">
          {found.map((p) => (
            <PersonRow key={p.handle} person={p}>
              {p.relationship === "none" && <button className="outline-button small" onClick={() => act(p.handle, "POST", "Friend request sent")}>Add friend</button>}
              {p.relationship === "incoming" && <button className="primary-button small" onClick={() => act(p.handle, "POST", "You’re now friends")}>Accept</button>}
              {p.relationship === "requested" && <span className="muted">Requested</span>}
              {p.relationship === "friends" && <span className="muted">Friends</span>}
            </PersonRow>
          ))}
        </ul>
      )}
      {data.incoming.length > 0 && (
        <>
          <h3>Friend requests</h3>
          <ul className="people">
            {data.incoming.map((p) => (
              <PersonRow key={p.handle} person={p}>
                <button className="primary-button small" onClick={() => act(p.handle, "POST", "You’re now friends")}>Accept</button>
                <button className="outline-button small" onClick={() => act(p.handle, "DELETE")}>Decline</button>
              </PersonRow>
            ))}
          </ul>
        </>
      )}
      <h3>Friends</h3>
      {data.friends.length === 0 ? (
        <p className="muted">No friends yet. Find people above to send them products.</p>
      ) : (
        <ul className="people">
          {data.friends.map((p) => (
            <PersonRow key={p.handle} person={p}>
              <button className="text-link" onClick={() => confirm(`Remove ${p.name} as a friend?`) && act(p.handle, "DELETE", "Removed")}>Remove</button>
            </PersonRow>
          ))}
        </ul>
      )}
      {data.outgoing.length > 0 && (
        <>
          <h3>Sent requests</h3>
          <ul className="people">
            {data.outgoing.map((p) => (
              <PersonRow key={p.handle} person={p}>
                <button className="text-link" onClick={() => act(p.handle, "DELETE", "Request cancelled")}>Cancel</button>
              </PersonRow>
            ))}
          </ul>
        </>
      )}
    </div>
  );
}

function Inbox({ social, productMap, brandMap, toast }) {
  const [items, setItems] = useState(null);
  const device = social.device;
  useEffect(() => {
    if (!device) return;
    let live = true;
    (async () => {
      try {
        const { shares, device_known } = await api(`shares?device=${encodeURIComponent(device.deviceId)}`);
        // The server forgot this browser's key: make a new one. Shares sent
        // from now on will open; earlier ones were sealed for the old key.
        if (device_known === false) {
          await social.resetDevice();
          return;
        }
        const opened = await Promise.all(
          shares.map(async (s) => {
            if (!s.envelope) return { ...s, message: null };
            try {
              return { ...s, message: await openEnvelope(device.privateKey, device.publicKey, s.envelope) };
            } catch {
              return { ...s, message: null, broken: true };
            }
          }),
        );
        if (!live) return;
        setItems(opened);
        if (shares.some((s) => !s.seen)) api("shares/seen", { method: "POST", body: {} }).then(() => social.refresh()).catch(() => {});
      } catch (e) {
        if (live) setItems([]);
      }
    })();
    return () => {
      live = false;
    };
  }, [device?.deviceId]);
  if (!device) return <p className="muted">Setting up encryption for this browser…</p>;
  if (!items) return <p className="muted">Opening your messages…</p>;
  if (!items.length) return <p className="muted">Nothing yet. When friends send you products, they’ll appear here.</p>;
  return (
    <ul className="inbox" data-testid="inbox">
      {items.map((s) => {
        const p = s.message && productMap.get(s.message.product_id);
        return (
          <li key={s.id} className={"share" + (s.seen ? "" : " unseen")}>
            <div className="share-head">
              <a href={`/u/${s.from.handle}`}><b>{s.from.name}</b></a>
              <span className="muted">{ago(s.created_at)}</span>
            </div>
            {!s.message ? (
              <p className="muted">
                <Lock size={13} /> {s.broken ? "This message couldn’t be opened." : "Sent before you used this browser, so it can’t be opened here."}
              </p>
            ) : (
              <>
                {p ? (
                  <a className="share-product" href={`/p/${encodeURIComponent(p.id)}`}>
                    <img src={imageURL(p.images?.[0], 160)} alt="" />
                    <span>
                      <b>{p.title}</b>
                      <span className="muted">{brandMap.get(p.brand)?.name} · {money(p.price, p.currency)}</span>
                    </span>
                  </a>
                ) : (
                  <a className="share-product" href={`/p/${encodeURIComponent(s.message.product_id)}`}>A product that’s no longer listed</a>
                )}
                {s.message.note && <p className="share-note">“{s.message.note}”</p>}
                <button
                  className="text-link small"
                  onClick={async () => {
                    if (!confirm("Report this message? The product and note will be shown to Marracat for review. Nothing else is shared.")) return;
                    try {
                      await api(`shares/${s.id}/report`, { method: "POST", body: { message: s.message } });
                      setItems((list) => list.filter((x) => x.id !== s.id));
                      toast("Thanks. We’ll review it within 24 hours.");
                    } catch (e) {
                      toast(e.message);
                    }
                  }}
                >
                  <Flag size={13} /> Report
                </button>
              </>
            )}
          </li>
        );
      })}
    </ul>
  );
}

function Blocked({ toast }) {
  const [list, setList] = useState(null);
  const load = () => api("blocks").then((r) => setList(r.blocked)).catch(() => setList([]));
  useEffect(() => {
    load();
  }, []);
  if (!list) return null;
  if (!list.length) return <p className="muted">You haven’t blocked anyone.</p>;
  return (
    <ul className="people">
      {list.map((p) => (
        <PersonRow key={p.handle} person={p}>
          <button
            className="text-link"
            onClick={async () => {
              await api(`users/${encodeURIComponent(p.handle)}/block`, { method: "DELETE" }).catch(() => {});
              toast(`${p.name} is unblocked`);
              load();
            }}
          >
            Unblock
          </button>
        </PersonRow>
      ))}
    </ul>
  );
}

export function AccountSocial({ social, productMap, brandMap, toast }) {
  const counts = social.me?.counts || {};
  const [tab, setTab] = useState("profile");
  const tabs = [
    ["profile", "Profile", 0],
    ["friends", "Friends", counts.incoming],
    ["inbox", "Shared with you", counts.unseen_shares],
    ["blocked", "Blocked", 0],
  ];
  return (
    <section className="account-social" data-testid="account-social">
      <div className="social-tabs" role="tablist">
        {tabs.map(([id, label, n]) => (
          <button key={id} role="tab" aria-selected={tab === id} className={tab === id ? "active" : ""} onClick={() => setTab(id)}>
            {label}
            {n > 0 && <span className="badge">{n}</span>}
          </button>
        ))}
        {social.me?.owner && <a className="text-link" href="/moderation">Moderation</a>}
      </div>
      <div className="social-panel">
        {tab === "profile" && <ProfileEditor social={social} toast={toast} />}
        {tab === "friends" && <Friends social={social} toast={toast} />}
        {tab === "inbox" && <Inbox social={social} productMap={productMap} brandMap={brandMap} toast={toast} />}
        {tab === "blocked" && <Blocked toast={toast} />}
      </div>
    </section>
  );
}

// --- moderation -------------------------------------------------------------------

export function Moderation({ social, toast }) {
  const [reports, setReports] = useState(null);
  const load = () => api("moderation").then((r) => setReports(r.reports)).catch(() => setReports(false));
  useEffect(() => {
    if (social.me?.owner) load();
  }, [social.me?.owner]);
  if (!social.me?.owner)
    return (
      <div className="empty-state">
        <h1>Nothing here.</h1>
        <a href="/">Keep exploring</a>
      </div>
    );
  const act = async (id, action) => {
    try {
      await api(`moderation/${id}`, { method: "POST", body: { action } });
      toast(action === "restore" ? "Restored" : action === "remove" ? "Removed" : "Removed and author suspended");
      load();
    } catch (e) {
      toast(e.message);
    }
  };
  return (
    <section className="moderation page-pad" data-testid="moderation">
      <h1>Moderation</h1>
      <p className="muted">Reported content is hidden until you decide. Act within 24 hours.</p>
      {reports === null ? (
        <p className="muted">Loading…</p>
      ) : !reports || !reports.length ? (
        <p className="muted">No open reports.</p>
      ) : (
        <ul className="reports">
          {reports.map((r) => (
            <li key={r.id} className="report">
              <div className="share-head">
                <b>{r.kind === "comment" ? "Comment" : r.kind === "share" ? "Shared message" : "Person"}</b>
                <span className="muted">{ago(r.created_at)}</span>
              </div>
              {r.subject?.author && (
                <p>
                  By <a href={`/u/${r.subject.author.handle}`}>{r.subject.author.name} @{r.subject.author.handle}</a>
                </p>
              )}
              {r.kind === "user" && r.subject && (
                <p><a href={`/u/${r.subject.handle}`}>{r.subject.name} @{r.subject.handle}</a></p>
              )}
              {r.subject?.body && <blockquote>{r.subject.body}</blockquote>}
              {r.subject?.note && <blockquote>{r.subject.note}</blockquote>}
              {r.subject?.product_id && (
                <p><a href={`/p/${encodeURIComponent(r.subject.product_id)}`}>Product</a></p>
              )}
              {r.reason && <p className="muted">Reason: {r.reason}</p>}
              <div className="row">
                <button className="outline-button small" onClick={() => act(r.id, "restore")}>
                  {r.kind === "user" ? "Dismiss" : "Restore"}
                </button>
                {r.kind !== "user" && <button className="outline-button small" onClick={() => act(r.id, "remove")}>Remove</button>}
                <button className="primary-button small" onClick={() => act(r.id, "suspend")}>
                  {r.kind === "user" ? "Suspend" : "Remove + suspend"}
                </button>
              </div>
            </li>
          ))}
        </ul>
      )}
    </section>
  );
}
