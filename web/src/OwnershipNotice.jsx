import React from "react";
import { BadgeCheck } from "lucide-react";

/// Shown on a search saying "independent" anywhere in it, before or after
/// other words (owner, 2026-11-03; 2026-11-08 picked the headline card,
/// option 2 of five, for any words around "independent"). `compact` is the
/// one-line version over the typing suggestions. Everywhere else the site
/// says "independent brands", and since 2026-11-13 (owner) so does the notice:
/// "Every brand on Marracat is independent". As OwnershipNotice in the app.
export default function OwnershipNotice({ brandCount = 0, compact = false }) {
  const line = compact
    ? "Every brand on Marracat is independent."
    : brandCount >= 100
      ? `Every one of our ${brandCount.toLocaleString("en-US")} brands is independent, so here’s everything that matches.`
      : "Every brand on Marracat is independent, so here’s everything that matches.";
  return (
    <div className={`ownership-notice${compact ? " compact" : ""}`} data-testid="ownership-notice" role="note">
      <span className="ownership-icon" aria-hidden="true">
        <BadgeCheck size={compact ? 14 : 18} />
      </span>
      <span className="ownership-text">
        <b>You’re in the right place.</b>
        <span>{line}</span>
      </span>
    </div>
  );
}
