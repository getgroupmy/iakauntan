// Which origins a browser may call these functions from.

/// Whether `origin` is admitted by one of `patterns`.
///
/// In a file of its own, and that is the point of the file: `cors.ts`
/// reads `ALLOWED_ORIGINS` at module scope, so importing it costs
/// `--allow-env`, and a test that needs a permission is a test that
/// stops being run the day somebody tightens the runner. This has no
/// imports and touches nothing — `origin_test.ts` runs with no flags at
/// all, like the other assertions in this directory.
///
/// ## What `*` is allowed to mean
///
/// One label, and only where it was written. `https://*.iakauntan.com`
/// admits `https://sinar.iakauntan.com` and nothing else — which is
/// what a company that has been given a subdomain has, and what the
/// wildcard certificate on either deployment path covers.
///
/// `[^.]+` rather than `.*` is the entire security of this. `.*` would
/// admit `https://anything.evil.com.iakauntan.com`, and — worse,
/// because it is the shape attackers actually try — an unanchored match
/// would admit `https://evil-iakauntan.com` and
/// `https://iakauntan.com.evil.test`.
///
/// So the pattern is escaped whole, `*` is put back as the one thing
/// that is not a literal, and the result is anchored at both ends. A
/// pattern with no `*` in it is an exact comparison, which is what
/// every entry was before subdomains existed.
export function originAllowed(origin: string, patterns: string[]): boolean {
  // An empty Origin is not a browser asking; it is a caller that sent
  // no header. Never admitted, because admitting it would echo an empty
  // allow-origin and mean nothing.
  if (!origin) return false;

  return patterns.some((pattern) => {
    if (!pattern.includes("*")) return pattern === origin;

    // Every regex metacharacter in the pattern is a literal — the dots
    // in a host name most of all.
    const escaped = pattern
      .replace(/[.*+?^${}()|[\]\\]/g, "\\$&")
      .replaceAll("\\*", "[^.]+");

    return new RegExp(`^${escaped}$`).test(origin);
  });
}
