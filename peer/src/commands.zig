//! The peer's state commands, a function per noun, and crawling.

const std = @import("std");
const Io = std.Io;
const core = @import("core");
const lib = core.library;
const main = @import("main.zig");
const network = @import("network.zig");
const agent_ = @import("agent.zig");
const Peer = main.Peer;
const Command = main.Command;
const parseKey = core.store.parseKey;

fn hex(key: [32]u8) [64]u8 {
    return std.fmt.bytesToHex(key, .lower);
}

pub fn user(peer: *Peer, c: Command) !void {
    if (c.is("show", 0, &.{})) {
        try peer.out.print("{s}\n", .{hex(try peer.user())});
    } else if (c.is("pair", 0, &.{})) {
        try network.offerPairing(peer, .link);
    } else if (c.is("pair", 1, &.{}) or c.is("pair", 2, &.{})) {
        _ = try pairWith(peer, c, .link);
    } else return error.Usage;
}

/// Pairs the new device showing the code `c.rest[0]` (found nearby, or at
/// `c.rest[1]`), offering for `kind`, and names it as it advertised itself;
/// returns its user's key.
fn pairWith(peer: *Peer, c: Command, kind: core.pair.Kind) ![32]u8 {
    const new: Offering = if (c.rest.len == 2) .{ .url = c.rest[1], .name = "" } else try offering(peer, kind);
    var client: std.http.Client = .{ .allocator = peer.gpa, .io = peer.io };
    defer client.deinit();
    const joined = try core.pair.send(peer.io, peer.arena, &client, new.url, kind, c.rest[0], .{
        .user = peer.store.identity.user,
        .founder = try peer.store.founder(peer.arena),
    });
    // A linked device acts as this user from now on, not as the one it had.
    const acting = if (kind == .link) try peer.user() else joined.user;
    if (new.name.len > 0) {
        var r = try peer.open();
        defer r.close();
        try lib.setName(&r, peer.arena, peer.now(), joined.device, new.name, acting);
    }
    try peer.out.print("paired {s}\n", .{new.url});
    return acting;
}

const Offering = struct { url: []const u8, name: []const u8 };

/// The one new device nearby offering to pair for `kind`.
fn offering(peer: *Peer, kind: core.pair.Kind) !Offering {
    var found: ?Offering = null;
    for (try core.discover.browse(peer.io, peer.arena, 2000)) |s| {
        if (s.host.len == 0 or !std.mem.eql(u8, s.get("pair") orelse "", @tagName(kind))) continue;
        if (found != null) return error.SeveralOffering;
        found = .{
            .url = try std.fmt.allocPrint(peer.arena, "http://{s}:{d}{s}", .{ s.host, s.port, s.get("path") orelse core.pair.path }),
            .name = s.get("name") orelse "",
        };
    }
    return found orelse error.NoneOffering;
}

pub fn library(peer: *Peer, c: Command) !void {
    if (c.is("show", 0, &.{})) {
        var r = try peer.open();
        defer r.close();
        try peer.out.print("library  {s}\nfounder  {s}\nmembers  {d}\ndigest   {s}\n", .{
            std.fmt.bytesToHex(r.library, .lower),
            hex(r.founder),
            (try r.members(peer.arena)).len,
            hex(try r.digest()),
        });
    } else if (c.is("join", 0, &.{})) {
        try network.offerPairing(peer, .join);
    } else if (c.is("create", 0, &.{})) {
        try peer.store.setFounder(peer.arena, try peer.user());
        var r = try peer.open();
        defer r.close();
        try peer.out.print("created library {s}\n", .{std.fmt.bytesToHex(r.library, .lower)});
    } else if (c.is("handover", 1, &.{"--leave"})) {
        var r = try peer.open();
        defer r.close();
        try r.handOver(peer.now(), try parseKey(c.rest[0]), !c.args.has("--leave"));
        try peer.out.print("handed over to {s}\n", .{c.rest[0]});
    } else return error.Usage;
}

pub fn member(peer: *Peer, c: Command) !void {
    if (c.is("list", 0, &.{})) {
        var r = try peer.open();
        defer r.close();
        const me = try peer.user();
        for (try r.members(peer.arena)) |m| {
            try peer.out.print("{s}", .{hex(m)});
            if (std.mem.eql(u8, &m, &r.founder)) try peer.out.print("  founder", .{});
            if (std.mem.eql(u8, &m, &me)) try peer.out.print("  you", .{});
            try peer.out.print("\n", .{});
        }
    } else if (c.is("pair", 1, &.{}) or c.is("pair", 2, &.{})) {
        const joining = try pairWith(peer, c, .join);
        var r = try peer.open();
        defer r.close();
        try r.addMember(peer.now(), joining);
        try peer.out.print("added {s}\n", .{std.fmt.bytesToHex(joining, .lower)});
    } else if (c.is("remove", 1, &.{})) {
        var r = try peer.open();
        defer r.close();
        try r.removeMember(peer.now(), try parseKey(c.rest[0]));
        try peer.out.print("removed {s}\n", .{c.rest[0]});
    } else return error.Usage;
}

pub fn repo(peer: *Peer, c: Command) !void {
    const settings = &.{ "--rendition", "--skip" };
    if (c.is("list", 0, &.{})) {
        var r = try peer.open();
        defer r.close();
        for (try lib.repositories(&r, peer.arena)) |rp|
            try peer.out.print("{s}  {s}  rendition: \"{s}\", skip: \"{s}\"\n", .{ rp.id, rp.url, rp.layout.rendition, rp.layout.skip });
    } else if (c.is("show", 1, &.{})) {
        var r = try peer.open();
        defer r.close();
        const rp = try lib.findRepository(&r, peer.arena, c.rest[0]);
        try peer.out.print("repo       {s}\nurl        {s}\nrendition  \"{s}\"\nskip       \"{s}\"\ncopies     {d}\n", .{
            rp.id, rp.url, rp.layout.rendition, rp.layout.skip, try lib.copies(&r, peer.arena, rp),
        });
    } else if (c.is("add", 1, settings)) {
        var r = try peer.open();
        defer r.close();
        var typed: std.ArrayList(u8) = .empty;
        try core.url.escape(peer.arena, &typed, c.rest[0]);
        if (!std.mem.endsWith(u8, typed.items, "/")) try typed.append(peer.arena, '/');
        var layout: lib.Layout = .{};
        if (c.args.get("--rendition")) |v| layout.rendition = v;
        if (c.args.get("--skip")) |v| layout.skip = v;
        try peer.out.print("added repo {s}\n", .{try lib.addRepository(&r, peer.now(), typed.items, layout)});
    } else if (c.is("set", 1, settings) and c.args.count() > 0) {
        var r = try peer.open();
        defer r.close();
        const rp = try lib.setRepository(&r, peer.arena, peer.now(), c.rest[0], c.args.get("--rendition"), c.args.get("--skip"));
        try peer.out.print("{s}  rendition: \"{s}\", skip: \"{s}\"; crawl to apply\n", .{ rp.id, rp.layout.rendition, rp.layout.skip });
    } else if (c.is("remove", 1, &.{})) {
        var r = try peer.open();
        defer r.close();
        const n = try lib.removeRepository(&r, peer.arena, peer.now(), c.rest[0]);
        try peer.out.print("removed {s} and its {d} copies\n", .{ c.rest[0], n });
    } else return error.Usage;
}

pub fn title(peer: *Peer, c: Command) !void {
    const out = peer.out;
    if (c.is("list", 0, &.{}) or c.is("list", 1, &.{})) {
        var r = try peer.open();
        defer r.close();
        const filter: []const u8 = if (c.rest.len > 0) c.rest[0] else "";
        var shown: usize = 0;
        var unheld: usize = 0;
        for (try lib.titles(&r, peer.arena)) |t| {
            if (filter.len > 0 and std.ascii.findIgnoreCase(t.name, filter) == null) continue;
            if (t.renditions == 0) {
                unheld += 1;
                continue;
            }
            shown += 1;
            try out.print("{s}", .{t.name});
            if (t.year) |y| try out.print(" ({d})", .{y});
            try out.print(" {s}: {d} {s}, {d} renditions [", .{ if (t.kind == 's') "series" else "movie", t.items, if (t.kind == 's') "episodes" else "versions", t.renditions });
            for (t.labels.items, 0..) |l, i| try out.print("{s}{s}", .{ if (i > 0) ", " else "", l });
            try out.print("]  {s}{s}{s}\n", .{ t.key, if (t.alias != null) " -> " else "", t.alias orelse "" });
        }
        try out.print("{d} titles", .{shown});
        if (unheld > 0) try out.print(" ({d} more held by no repo)", .{unheld});
        try out.print("\n", .{});
    } else if (c.is("show", 1, &.{})) {
        var r = try peer.open();
        defer r.close();
        const d = try lib.detail(&r, peer.arena, c.rest[0]) orelse {
            try out.print("no title {s}\n", .{c.rest[0]});
            return error.NotFound;
        };
        var urls: std.StringHashMapUnmanaged([]const u8) = .empty;
        for (try lib.repositories(&r, peer.arena)) |rp| try urls.put(peer.arena, try peer.arena.dupe(u8, &rp.id), rp.url);
        try out.print("{s}", .{d.name});
        if (d.year) |y| try out.print(" ({d})", .{y});
        try out.print("  {s}\n", .{d.key});
        for (d.fields.keys(), d.fields.values()) |k, v| try out.print("  {s}: {s}\n", .{ k, v });
        if (d.alias_of) |to| try out.print("  an alias of {s}\n", .{to});
        for (d.aliases.items) |from| try out.print("  {s} is an alias of it\n", .{from});
        for (d.items.items) |item| {
            try out.print("  {s}", .{item.key});
            try printPlayhead(out, item.playhead);
            try out.print("\n", .{});
            for (item.fields.keys(), item.fields.values()) |k, v| try out.print("    {s}: {s}\n", .{ k, v });
            for (item.renditions.items) |rendition| {
                try out.print("    {s}\n", .{rendition.label});
                for (rendition.holdings.items) |h| {
                    const base = core.url.decode(try peer.arena.dupe(u8, urls.get(h.repository) orelse h.repository)) catch h.repository;
                    try out.print("      {d:.2} GB  {s}  {s}{s}\n", .{ @as(f64, @floatFromInt(h.size)) / 1e9, h.mtime, base, h.path });
                }
            }
        }
    } else if (c.is("review", 0, &.{})) {
        var r = try peer.open();
        defer r.close();
        const all = try lib.titles(&r, peer.arena);
        const matches = try lib.closeMatches(peer.arena, all);
        for (matches) |m| try out.print("{s}\t{s}\t{s}\n", .{ m.reason, m.a, m.b });
        const dups = try lib.duplicates(&r, peer.arena);
        for (dups) |m| try out.print("{s}\t{s}\t{s}\n", .{ m.reason, m.a, m.b });
        try out.print("{d} close matches among {d} titles; {d} duplicate files\n", .{ matches.len, all.len, dups.len });
    } else if (c.is("facets", 0, &.{})) {
        var r = try peer.open();
        defer r.close();
        for (try lib.facets(peer.arena, try lib.titles(&r, peer.arena))) |f| try out.print("{s}\t{s}\t{d}\n", .{ f.facet, f.value, f.count });
    } else return error.Usage;
}

pub fn alias(peer: *Peer, c: Command) !void {
    if (c.is("list", 0, &.{})) {
        var r = try peer.open();
        defer r.close();
        for (try lib.aliases(&r, peer.arena)) |a| try peer.out.print("{s} -> {s}\n", .{ a.from, a.to });
    } else if (c.is("add", 2, &.{})) {
        var r = try peer.open();
        defer r.close();
        try lib.addAlias(&r, peer.now(), c.rest[0], c.rest[1]);
        try peer.out.print("{s} -> {s}\n", .{ c.rest[0], c.rest[1] });
    } else if (c.is("remove", 1, &.{})) {
        var r = try peer.open();
        defer r.close();
        try lib.removeAlias(&r, peer.now(), c.rest[0]);
        try peer.out.print("removed alias of {s}\n", .{c.rest[0]});
    } else return error.Usage;
}

pub fn playhead(peer: *Peer, c: Command) !void {
    const watched = c.args.has("--watched");
    if (c.is("list", 0, &.{}) or c.is("list", 1, &.{})) {
        var r = try peer.open();
        defer r.close();
        for (try lib.playheads(&r, peer.arena, if (c.rest.len > 0) c.rest[0] else null)) |e| {
            try peer.out.print("{s}", .{e.item});
            try printPlayhead(peer.out, e.playhead);
            try peer.out.print("\n", .{});
        }
    } else if (c.is("set", 3, &.{})) {
        var r = try peer.open();
        defer r.close();
        const position = try std.fmt.parseFloat(f64, c.rest[1]);
        const duration = try std.fmt.parseFloat(f64, c.rest[2]);
        try lib.setPlayhead(&r, peer.arena, peer.now(), c.rest[0], @intFromFloat(position * 1000), @intFromFloat(duration * 1000));
        try peer.out.print("set {s}\n", .{c.rest[0]});
    } else if (c.is("set", 1, &.{ "--watched", "--unwatched" }) and watched != c.args.has("--unwatched")) {
        var r = try peer.open();
        defer r.close();
        try lib.setWatched(&r, peer.arena, peer.now(), c.rest[0], watched);
        try peer.out.print("set {s}\n", .{c.rest[0]});
    } else if (c.is("remove", 1, &.{})) {
        var r = try peer.open();
        defer r.close();
        try lib.removePlayhead(&r, peer.arena, peer.now(), c.rest[0]);
        try peer.out.print("removed playhead of {s}\n", .{c.rest[0]});
    } else return error.Usage;
}

fn printPlayhead(out: *Io.Writer, head: lib.Playhead) !void {
    if (head.watched) try out.print("  watched", .{});
    if (head.position_ms > 0) try out.print("  at {d}:{d:0>2} of {d}:{d:0>2}", .{ head.position_ms / 60000, head.position_ms / 1000 % 60, head.duration_ms / 60000, head.duration_ms / 1000 % 60 });
}

pub fn agent(peer: *Peer, c: Command) !void {
    if (@import("builtin").os.tag != .macos) return error.MacOSOnly;
    const home = peer.environ.get("HOME") orelse return error.NoHome;
    const dir = peer.store.dir;
    const absolute = if (std.fs.path.isAbsolute(dir)) dir else try std.fs.path.resolve(peer.arena, &.{ peer.environ.get("PWD") orelse ".", dir });
    const list = try agent_.agents(peer.arena, try std.process.executablePathAlloc(peer.io, peer.arena), absolute, home, try c.args.port());
    if (c.is("show", 0, &.{"--port"})) {
        for (list) |a| try peer.out.print("{s}.plist:\n{s}\n", .{ a.label, a.plist });
    } else if (c.is("add", 0, &.{"--port"})) {
        _ = try peer.store.founder(peer.arena); // a library first
        try agent_.install(peer.io, peer.arena, home, list);
        try peer.out.print("added {s}.serve and {s}.refresh; logs in ~/Library/Logs/Cinematheque\n", .{ agent_.label_prefix, agent_.label_prefix });
    } else if (c.is("remove", 0, &.{})) {
        try agent_.uninstall(peer.io, peer.arena, home);
        try peer.out.print("removed the agents\n", .{});
    } else return error.Usage;
}

/// `crawl [REPO] [--workers WORKERS]`: crawls every repo, or one.
pub fn crawl(peer: *Peer, c: Command) !void {
    if (c.rest.len > 1) return error.Usage;
    try c.args.only(&.{"--workers"});
    try crawlRepositories(peer, try c.args.number("--workers", 16), if (c.rest.len == 1) c.rest[0] else null);
}

/// `refresh`: syncs, then crawls.
pub fn refresh(peer: *Peer, c: Command) !void {
    if (c.rest.len > 0) return error.Usage;
    try c.args.only(&.{});
    // Peers' catalog first, already described, so crawling then finds
    // little to do.
    try network.pullAll(peer, null);
    try crawlRepositories(peer, 16, null);
}

/// Crawls every repo, or the one given, then describes what's new: covers
/// and metadata, with concurrent workers.
fn crawlRepositories(peer: *Peer, workers: usize, only: ?[]const u8) !void {
    var r = try peer.open();
    defer r.close();
    var client: std.http.Client = .{ .allocator = peer.gpa, .io = peer.io };
    defer client.deinit();
    const repos = if (only) |which| &[_]lib.Repository{try lib.findRepository(&r, peer.arena, which)} else try lib.repositories(&r, peer.arena);
    var crawled: std.ArrayList(core.art.Crawled) = .empty;
    for (repos) |rp| {
        const s = try lib.crawlRepository(&r, peer.io, peer.arena, &client, peer.now(), rp, workers);
        const i = s.ingest;
        try peer.out.print("{s}: {d} requests ({d} directories reused) in {d} ms; {d} files ({d} skipped, {d} extras, {d} unparsed); {d} titles added; holdings {d} added, {d} changed, {d} removed; {d} duplicates; {d} ms in all\n", .{
            rp.url,         s.crawl.requests,  s.crawl.skipped,     s.crawl_ms,         i.files,      i.skipped, i.extras, i.unparsed,
            i.titles_added, i.holdings_added, i.holdings_changed, i.holdings_removed, i.duplicates, s.total_ms,
        });
        if (i.duplicate_example) |e| try peer.out.print("  e.g., {s}\n", .{e});
        try peer.out.flush();
        try crawled.append(peer.arena, .{ .repo = rp, .entries = s.entries });
    }
    const start = Io.Timestamp.now(peer.io, .awake);
    const plan = try core.art.plan(&r, peer.arena, crawled.items);
    const a = try core.art.run(peer.io, &r, peer.arena, &client, peer.now(), plan.jobs, .{ .workers = workers });
    try peer.out.print("described {d} movies and seasons ({d} unchanged) in {d} ms: {d} covers found, {d} placeholders made, {d} files read, {d} failed\n", .{
        plan.jobs.len, plan.unchanged, start.durationTo(Io.Timestamp.now(peer.io, .awake)).toMilliseconds(), a.covers, a.thumbs, a.described, a.failed,
    });
}
