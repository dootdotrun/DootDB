//! The document plane (D88, D89, `05-architecture.md`).
//!
//! Static bytes served with no credential: the two HTML documents, the stylesheet, the
//! script, the icon and the crawl policy. A third plane rather than an exception inside
//! the control plane, because static bytes must not draw on the control plane's
//! per-address credential-guessing budget (D74) — a page load is four requests, and five
//! reloads would rate-limit the sign-in page itself.
//!
//! **Unauthenticated and unmetered.** A few kilobytes of `.rodata` served from RAM: no
//! store call, no lock, no allocation, no I/O worker. The same cost profile as
//! `/healthz`, which is already exempt from both.
//!
//! Content-addressing (D89): the digest is `SHA-256` over every embedded file, first 12
//! hex characters, computed at comptime — so `zig build` stays the whole pipeline and
//! no build step appears. A deploy changes the digest, so the URL changes, so nothing
//! stale is reachable. The two HTML documents are `no-store` and reference the
//! digest-bearing names; the assets are `immutable`. No `ETag`, no `304`: conditional
//! requests stay out of the transport entirely.

const std = @import("std");

/// Files an editor opens. `zig build` is the whole pipeline: no framework, no bundler,
/// no separate deployment (`05-architecture.md`).
pub const landing_html = @embedFile("../dashboard/landing.html");
pub const shell_html = @embedFile("../dashboard/shell.html");
pub const css = @embedFile("../dashboard/app.css");
pub const js = @embedFile("../dashboard/app.js");
pub const icon_svg = @embedFile("../dashboard/favicon.svg");
pub const robots_txt = @embedFile("../dashboard/robots.txt");

/// One digest for every asset: `SHA-256` over the concatenation of the embedded files,
/// first 12 hex characters (D89). One token rather than per-file digests, because the
/// assets change exactly when the binary does.
pub const digest: [12]u8 = blk: {
    @setEvalBranchQuota(2000000);
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    h.update(landing_html);
    h.update(shell_html);
    h.update(css);
    h.update(js);
    h.update(icon_svg);
    h.update(robots_txt);
    var full: [32]u8 = undefined;
    h.final(&full);
    var hex: [12]u8 = undefined;
    _ = std.fmt.bufPrint(&hex, "{s}", .{std.fmt.bytesToHex(full[0..6], .lower)}) catch unreachable;
    break :blk hex;
};

/// The token the HTML documents reference. `shell.html` and `landing.html` carry
/// `/app.@@DOOT_DIGEST@@.css`, and the served bytes substitute the real digest.
pub const token = "@@DOOT_DIGEST@@";

/// Paths the router classifies by shape. The concrete text depends on this binary's
/// digest, which only this module knows — so the router asks here.
pub fn cssPath() ["/app.".len + 12 + ".css".len]u8 {
    var out: ["/app.".len + 12 + ".css".len]u8 = undefined;
    @memcpy(out[0.."/app.".len], "/app.");
    @memcpy(out["/app.".len..][0..12], &digest);
    @memcpy(out["/app.".len + 12 ..], ".css");
    return out;
}

pub fn jsPath() ["/app.".len + 12 + ".js".len]u8 {
    var out: ["/app.".len + 12 + ".js".len]u8 = undefined;
    @memcpy(out[0.."/app.".len], "/app.");
    @memcpy(out["/app.".len..][0..12], &digest);
    @memcpy(out["/app.".len + 12 ..], ".js");
    return out;
}

pub const Doc = struct {
    body: []const u8,
    content_type: []const u8,
    /// `Cache-Control` value, or null when the document carries none (`/favicon.ico`).
    cache: ?[]const u8,
    /// True for the two HTML documents: CSP, `nosniff`, `Referrer-Policy` (D89).
    security: bool,
};

/// Content-Security-Policy for both HTML documents (D89).
///
/// `default-src 'none'` with every source named: it lists exactly what the dashboard
/// does and nothing else. No `'unsafe-inline'` anywhere — no inline script, no inline
/// style — which is a constraint on how the dashboard is written, recorded in the
/// decision so it is a rule rather than a violation discovered later.
pub const csp =
    "default-src 'none'; script-src 'self'; style-src 'self'; " ++
    "connect-src 'self'; img-src 'self'; base-uri 'none'; form-action 'self'; " ++
    "frame-ancestors 'none'";

/// Serves `path`, or null when it is not a document this binary knows.
///
/// Static HTML is served with the digest substituted, so the bytes reference the URLs
/// this binary actually serves — a stale reference is impossible by construction
/// rather than by a check remembering to compare. `/favicon.ico` answers `null` with
/// `favicon_ico` true: it is the one path a browser fetches unprompted, so it must
/// answer in the document plane's shape (a 404) rather than the data plane's 401 (D89).
pub const Served = struct {
    doc: ?Doc = null,
    favicon_ico: bool = false,
};

pub fn serve(path: []const u8) Served {
    if (std.mem.eql(u8, path, "/")) return .{ .doc = .{
        .body = landing_html,
        .content_type = "text/html; charset=utf-8",
        .cache = "no-store",
        .security = true,
    } };
    if (std.mem.eql(u8, path, "/app")) return .{ .doc = .{
        .body = shell_html,
        .content_type = "text/html; charset=utf-8",
        .cache = "no-store",
        .security = true,
    } };
    if (std.mem.eql(u8, path, "/favicon.svg")) return .{ .doc = .{
        .body = icon_svg,
        .content_type = "image/svg+xml",
        .cache = "public, max-age=31536000, immutable",
        .security = false,
    } };
    if (std.mem.eql(u8, path, "/robots.txt")) return .{ .doc = .{
        .body = robots_txt,
        .content_type = "text/plain; charset=utf-8",
        .cache = "public, max-age=31536000, immutable",
        .security = false,
    } };
    if (std.mem.eql(u8, path, "/favicon.ico")) return .{ .favicon_ico = true };

    const css_path = cssPath();
    if (std.mem.eql(u8, path, &css_path)) return .{ .doc = .{
        .body = css,
        .content_type = "text/css; charset=utf-8",
        .cache = "public, max-age=31536000, immutable",
        .security = false,
    } };
    const js_path = jsPath();
    if (std.mem.eql(u8, path, &js_path)) return .{ .doc = .{
        .body = js,
        .content_type = "text/javascript; charset=utf-8",
        .cache = "public, max-age=31536000, immutable",
        .security = false,
    } };
    return .{};
}

/// The HTML with the digest substituted, into a caller-supplied buffer.
///
/// Sized by the documents, not by the caller: two references, twelve hex characters
/// over an eight-character token, so four bytes of growth per document.
pub fn renderHtml(comptime src: []const u8) [src.len + 8]u8 {
    var out: [src.len + 8]u8 = undefined;
    var n: usize = 0;
    var rest: []const u8 = src;
    while (std.mem.indexOf(u8, rest, token)) |i| {
        @memcpy(out[n..][0..i], rest[0..i]);
        n += i;
        @memcpy(out[n..][0..12], &digest);
        n += 12;
        rest = rest[i + token.len ..];
    }
    @memcpy(out[n..][0..rest.len], rest);
    n += rest.len;
    return out;
}

const testing = std.testing;

test "the digest is twelve lowercase hex characters" {
    for (digest) |c| {
        try testing.expect((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'));
    }
}

test "the asset paths carry the digest the binary computed" {
    const css_path = cssPath();
    const js_path = jsPath();
    try testing.expect(std.mem.startsWith(u8, &css_path, "/app."));
    try testing.expect(std.mem.endsWith(u8, &css_path, ".css"));
    try testing.expect(std.mem.endsWith(u8, &js_path, ".js"));
    try testing.expectEqualStrings(&digest, css_path["/app.".len..][0..12]);
    try testing.expectEqualStrings(&digest, js_path["/app.".len..][0..12]);
}

test "every exact document-plane path serves, with its cache policy" {
    inline for (.{
        .{ "/", "text/html; charset=utf-8", "no-store", true },
        .{ "/app", "text/html; charset=utf-8", "no-store", true },
        .{ "/favicon.svg", "image/svg+xml", "public, max-age=31536000, immutable", false },
        .{ "/robots.txt", "text/plain; charset=utf-8", "public, max-age=31536000, immutable", false },
    }) |case| {
        const got = serve(case[0]);
        try testing.expect(got.doc != null);
        try testing.expectEqualStrings(case[1], got.doc.?.content_type);
        try testing.expectEqualStrings(case[2], got.doc.?.cache.?);
        try testing.expectEqual(case[3], got.doc.?.security);
        try testing.expect(!got.favicon_ico);
    }

    const css_doc = serve(&cssPath());
    try testing.expectEqualStrings("text/css; charset=utf-8", css_doc.doc.?.content_type);
    try testing.expectEqualStrings(
        "public, max-age=31536000, immutable",
        css_doc.doc.?.cache.?,
    );
    const js_doc = serve(&jsPath());
    try testing.expectEqualStrings("text/javascript; charset=utf-8", js_doc.doc.?.content_type);

    // The one path a browser fetches unprompted answers 404 in this plane's shape,
    // not the data plane's 401.
    const ico = serve("/favicon.ico");
    try testing.expect(ico.doc == null);
    try testing.expect(ico.favicon_ico);

    // A stale digest is not a document: after a deploy the old URL is unreachable,
    // which is what makes caching without revalidation safe.
    try testing.expect(serve("/app.000000000000.css").doc == null);
    try testing.expect(serve("/app.000000000000.js").doc == null);
}

test "the served HTML references the served asset URLs" {
    // A stale reference in the HTML would be a broken page with a 200 status. The
    // substitution is asserted rather than eyeballed.
    const landing = renderHtml(landing_html);
    const shell = renderHtml(shell_html);
    const css_path = cssPath();
    const js_path = jsPath();
    for ([_][]const u8{ &landing, &shell }) |html| {
        try testing.expect(std.mem.indexOf(u8, html, &css_path) != null);
        try testing.expect(std.mem.indexOf(u8, html, &js_path) != null);
        // No unsubstituted token survives.
        try testing.expect(std.mem.indexOf(u8, html, token) == null);
    }
}

test "no inline script or style survives into the served documents" {
    // D89's CSP forbids 'unsafe-inline', which is only affordable because there is
    // no inline script and no inline style. Asserted here so a later edit adding one
    // breaks the build rather than the page.
    for ([_][]const u8{ landing_html, shell_html }) |html| {
        try testing.expect(std.mem.indexOf(u8, html, "<script") == null or
            std.mem.indexOf(u8, html, "<script src=") != null);
        // Exactly one script tag, and it is the external one.
        var scripts: usize = 0;
        var rest: []const u8 = html;
        while (std.mem.indexOf(u8, rest, "<script")) |i| {
            scripts += 1;
            rest = rest[i + 1 ..];
        }
        try testing.expectEqual(@as(usize, 1), scripts);
        try testing.expect(std.mem.indexOf(u8, html, "style=") == null);
        try testing.expect(std.mem.indexOf(u8, html, "<style") == null);
    }
    // The script makes no excuse to need inline either: no document.write, no eval.
    try testing.expect(std.mem.indexOf(u8, js, "eval(") == null);
    try testing.expect(std.mem.indexOf(u8, js, "innerHTML") == null);
    try testing.expect(std.mem.indexOf(u8, js, "document.write") == null);
}

test "the security headers fit the response-head budget" {
    // D89's estimate: ~450 bytes of head against the 2 KiB ceiling. The transport
    // always writes Date, Content-Length and Connection; this is the rest.
    const config = @import("server").config;
    var head: [@import("server").config.max_response_head_bytes]u8 = undefined;
    var w = @import("server").response.Writer.init(&head);
    try w.status(200, "OK");
    try w.header("Date", "Mon, 31 Aug 2026 12:00:00 GMT");
    try w.header("Content-Type", "text/html; charset=utf-8");
    try w.headerInt("Content-Length", shell_html.len + 8);
    try w.header("Cache-Control", "no-store");
    try w.header("Content-Security-Policy", csp);
    try w.header("X-Content-Type-Options", "nosniff");
    try w.header("Referrer-Policy", "no-referrer");
    try w.header("Connection", "keep-alive");
    const done = try w.finish();
    try testing.expect(done.len < config.max_response_head_bytes - 512);
}
