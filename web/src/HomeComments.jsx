import React, { useEffect, useState } from "react";
import { MessageCircle } from "lucide-react";
import { imageURL } from "./catalog.js";

// "What people are saying" on the home page (owner, 2026-10-10): the newest
// product comments from /api/comments/recent (server/comment-feed.js, which
// leaves out anything hidden, reported, blocked or deleted). React escapes the
// text; nothing here renders HTML. With no comments the section isn't drawn.
export default function HomeComments() {
  const [comments, setComments] = useState([]);
  useEffect(() => {
    const controller = new AbortController();
    fetch("/api/comments/recent", { signal: controller.signal })
      .then((r) => (r.ok ? r.json() : null))
      .then((body) => Array.isArray(body?.comments) && setComments(body.comments))
      .catch(() => {});
    return () => controller.abort();
  }, []);
  if (!comments.length) return null;
  return (
    <section className="section home-comments" data-testid="home-comments">
      <div className="section-heading">
        <div>
          <h2>What people are saying</h2>
          <p>Notes from shoppers on the finds they love.</p>
        </div>
      </div>
      <div className="home-comments-grid">
        {comments.map((c) => (
          <a key={c.id} className="home-comment" href={"/p/" + encodeURIComponent(c.product.id)}>
            <div className="home-comment-product">
              {c.product.image && <img src={imageURL(c.product.image, 160)} alt="" loading="lazy" width="56" height="56" />}
              <div>
                <b>{c.product.title}</b>
                {c.product.brand && <span>{c.product.brand}</span>}
              </div>
            </div>
            <blockquote>
              <MessageCircle size={15} aria-hidden="true" />
              <span>{c.body}</span>
            </blockquote>
            <cite>{c.author.name} · @{c.author.handle}</cite>
          </a>
        ))}
      </div>
    </section>
  );
}
