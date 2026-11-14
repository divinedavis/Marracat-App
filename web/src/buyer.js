/// What a signed-in account already knows (name, email) fills the blanks, so
/// only the address and phone are left to type (owner, 2026-10-03).
export const buyerFromAccount = (user) => {
  const parts = String(user?.name || "").trim().split(/\s+/).filter(Boolean);
  const email = String(user?.email || "");
  return {
    firstName: parts[0] || "",
    lastName: parts.slice(1).join(" "),
    // An Apple private-relay address still reaches the buyer, so it's kept.
    email: /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email) ? email : "",
  };
};
