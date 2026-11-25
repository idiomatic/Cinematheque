//! The app's state commands, a function per noun, and crawling.

const std = @import("std");
const Io = std.Io;
const core = @import("core");
const lib = core.library;
const main = @import("main.zig");
const network = @import("network.zig");
const App = main.App;
const Command = main.Command;
const parseKey = core.store.parseKey;

fn hex(key: [32]u8) [64]u8 {
    return std.fmt.bytesToHex(key, .lower);
}

pub fn person(app: *App, c: Command) !void {
    if (c.is("show", 0, &.{})) {
        try app.out.print("{s}\n", .{hex(try app.person())});
    } else if (c.is("pair", 0, &.{})) {
        try network.offerPairing(app);
    } else if (c.is("pair", 1, &.{}) or c.is("pair", 2, &.{})) {
        _ = try pairWith(app, c, .pair);
    } else if (c.is("set", 0, &.{"--name"}) and c.args.get("--name") != null) {
        // The name everyone in the library sees this person by.
        var r = try app.open();
        defer r.close();
        try lib.setName(&r, app.arena, app.now(), try app.person(), c.args.get("--name").?, null);
        try app.out.print("named this person {s}\n", .{c.args.get("--name").?});
    } else return error.Usage;
}

/// Pairs the new device showing the code `c.rest[0]` (found nearby, or at
/// `c.rest[1]`), as `kind` makes it, and names it as it advertised itself;
/// returns its person's key.
fn pairWith(app: *App, c: Command, kind: core.pair.Kind) ![32]u8 {
    const new: Offering = if (c.rest.len == 2) .{ .url = c.rest[1], .name = "" } else try offering(app);
    var client: std.http.Client = .{ .allocator = app.gpa, .io = app.io };
    defer client.deinit();
    const joined = try core.pair.send(app.io, app.arena, &client, new.url, kind, c.rest[0], .{
        .person = app.store.identity.person,
        .creator = try app.store.creator(app.arena),
    });
    // A paired device acts as this person from now on, not as the one it had.
    const acting = if (kind == .pair) try app.person() else joined.person;
    if (new.name.len > 0) {
        var r = try app.open();
        defer r.close();
        try lib.setName(&r, app.arena, app.now(), joined.device, new.name, acting);
    }
    try app.out.print("paired {s}\n", .{new.url});
    return acting;
}

const Offering = struct { url: []const u8, name: []const u8 };

/// The one new device nearby offering to pair.
fn offering(app: *App) !Offering {
    var found: ?Offering = null;
    for (try core.discover.browse(app.io, app.arena, 2000)) |s| {
        if (s.host.len == 0 or s.get("pair") == null) continue;
        if (found != null) return error.SeveralOffering;
        found = .{
            .url = try std.fmt.allocPrint(app.arena, "http://{s}:{d}{s}", .{ s.host, s.port, s.get("path") orelse core.pair.path }),
            .name = try s.shownName(app.arena) orelse "",
        };
    }
    return found orelse error.NoneOffering;
}

pub fn library(app: *App, c: Command) !void {
    if (c.is("show", 0, &.{})) {
        var r = try app.open();
        defer r.close();
        try app.out.print("library  {s}\ncreator  {s}\nmembers  {d}\ndigest   {s}\n", .{
            std.fmt.bytesToHex(r.library, .lower),
            hex(r.genesis),
            (try r.members(app.arena)).len,
            hex(try r.digest()),
        });
        if (try lib.crawlEvery(&r, app.arena)) |hours|
            try app.out.print("crawl    every {d} hours\n", .{hours})
        else
            try app.out.print("crawl    manually\n", .{});
    } else if (c.is("set", 0, &.{"--crawl"}) and c.args.get("--crawl") != null) {
        // How often refreshes not asked for look in the sources: hours, or
        // only when asked.
        const every = c.args.get("--crawl").?;
        const hours: u64 = if (std.mem.eql(u8, every, "manually")) 0 else std.fmt.parseInt(u64, every, 10) catch return error.Usage;
        if (hours != 0 and hours != 1 and hours != 3 and hours != 24 and hours != 168) return error.Usage;
        var r = try app.open();
        defer r.close();
        try lib.setCrawlEvery(&r, app.now(), hours);
        if (hours == 0) try app.out.print("sources are crawled only when asked\n", .{}) else try app.out.print("sources are crawled every {d} hours\n", .{hours});
    } else if (c.is("join", 0, &.{})) {
        try network.offerPairing(app);
    } else if (c.is("create", 0, &.{})) {
        try app.store.setCreator(app.arena, try app.person());
        var r = try app.open();
        defer r.close();
        try app.out.print("created library {s}\n", .{std.fmt.bytesToHex(r.library, .lower)});
    } else if (c.is("leave", 0, &.{})) {
        try leave(app);
    } else return error.Usage;
}

/// Leaves the library, as the apps' Leave This Library does: removes this
/// device and syncs, so another device takes the
/// removal, then forgets the library and this device's identity, to pair
/// again as a new device. With no one else in it, or once the library has
/// removed this device, it only forgets.
fn leave(app: *App) !void {
    told: {
        var r = app.open() catch |err| switch (err) {
            error.NoLibrary => break :told,
            else => return err,
        };
        defer r.close();
        try core.sync.leave(app.io, app.gpa, app.arena, &r, try app.store.serviceName(app.arena));
    }
    try app.store.forget(app.arena);
    try app.out.print("left the library; this device will pair again as a new one\n", .{});
}

pub fn member(app: *App, c: Command) !void {
    if (c.is("list", 0, &.{})) {
        var r = try app.open();
        defer r.close();
        const me = try app.person();
        for (try r.members(app.arena)) |m| {
            try app.out.print("{s}", .{hex(m)});
            if (std.mem.eql(u8, &m, &me)) try app.out.print("  you", .{});
            try app.out.print("\n", .{});
        }
    } else if (c.is("pair", 1, &.{}) or c.is("pair", 2, &.{})) {
        const joining = try pairWith(app, c, .join);
        var r = try app.open();
        defer r.close();
        try r.addMember(app.now(), joining);
        try app.out.print("added {s}\n", .{std.fmt.bytesToHex(joining, .lower)});
    } else if (c.is("remove", 1, &.{})) {
        var r = try app.open();
        defer r.close();
        try r.removeMember(app.now(), try parseKey(c.rest[0]));
        try app.out.print("removed {s}\n", .{c.rest[0]});
    } else return error.Usage;
}

/// This person's devices, by name; removing one cuts it off (see
/// `Replica.revokeDevice`).
pub fn device(app: *App, c: Command) !void {
    if (c.is("list", 0, &.{})) {
        var r = try app.open();
        defer r.close();
        const this = try app.store.device();
        const named = try lib.names(&r, app.arena);
        // Every device certified for this person, named or not.
        for (try r.devicesOf(app.arena, try app.person())) |d| {
            if (try r.revoked(d) != null) continue;
            const key = hex(d);
            try app.out.print("{s}  {s}{s}\n", .{ key, lib.nameOf(named, &key) orelse "(unnamed)", if (std.mem.eql(u8, &d, &this)) "  this device" else "" });
        }
        try network.listNearby(app);
    } else if (c.is("add", 1, &.{})) {
        try network.addAddress(app, c.rest[0]);
    } else if (c.is("forget", 1, &.{})) {
        try network.forgetAddress(app, c.rest[0]);
    } else if (c.is("remove", 1, &.{})) {
        var r = try app.open();
        defer r.close();
        try r.revokeDevice(app.now(), try parseKey(c.rest[0]));
        try app.out.print("removed {s}\n", .{c.rest[0]});
    } else if ((c.is("set", 0, &.{"--name"}) or c.is("set", 1, &.{"--name"})) and c.args.get("--name") != null) {
        // The name everyone in the library sees one of this person's
        // devices by: this one, unless another is given.
        var r = try app.open();
        defer r.close();
        const me = try app.person();
        const which = if (c.rest.len == 1) try parseKey(c.rest[0]) else try app.store.device();
        const mine = for (try r.devicesOf(app.arena, me)) |d| {
            if (std.mem.eql(u8, &d, &which)) break try r.revoked(d) == null;
        } else std.mem.eql(u8, &which, &(try app.store.device()));
        if (!mine) return error.NotYourDevice;
        try lib.setName(&r, app.arena, app.now(), which, c.args.get("--name").?, me);
        try app.out.print("named {s} {s}\n", .{ hex(which), c.args.get("--name").? });
    } else return error.Usage;
}

/// A source's quality setting, as listed: by path, or a name.
fn qualitySetting(arena: std.mem.Allocator, layout: lib.Layout) ![]const u8 {
    return switch (layout.quality) {
        .path => "by path",
        .named => |n| std.fmt.allocPrint(arena, "\"{s}\"", .{n}),
        .unknown => "set by a newer version",
    };
}

/// Where a source's quality comes from, as `--quality` says: a name, or by
/// path if empty; null if it says nothing.
fn qualityFrom(c: Command) ?lib.QualityFrom {
    const n = c.args.get("--quality") orelse return null;
    return if (n.len > 0) .{ .named = n } else .path;
}

pub fn source(app: *App, c: Command) !void {
    const settings = &.{ "--quality", "--skip" };
    if (c.is("list", 0, &.{})) {
        var r = try app.open();
        defer r.close();
        for (try lib.sources(&r, app.arena)) |rp|
            try app.out.print("{s}  {s}  quality: {s}, skip: \"{s}\"\n", .{ rp.id, rp.url, try qualitySetting(app.arena, rp.layout), rp.layout.skip });
    } else if (c.is("show", 1, &.{})) {
        var r = try app.open();
        defer r.close();
        const rp = try lib.findSource(&r, app.arena, c.rest[0]);
        try app.out.print("source     {s}\nurl        {s}\nquality    {s}\nskip       \"{s}\"\ncopies     {d}\n", .{
            rp.id, rp.url, try qualitySetting(app.arena, rp.layout), rp.layout.skip, try lib.countCopies(&r, app.arena, rp),
        });
        for (try lib.unavailableDirs(&r, app.arena, &rp.id)) |a|
            try app.out.print("unavailable     /{s}, since {d} days ago\n", .{ a.dir, (app.now() -| a.since_ms) / (24 * 60 * 60 * 1000) });
    } else if (c.is("add", 1, settings)) {
        var r = try app.open();
        defer r.close();
        var typed: std.ArrayList(u8) = .empty;
        try core.url.escape(app.arena, &typed, c.rest[0]);
        if (!std.mem.endsWith(u8, typed.items, "/")) try typed.append(app.arena, '/');
        var layout: lib.Layout = .{};
        if (qualityFrom(c)) |q| layout.quality = q;
        if (c.args.get("--skip")) |v| layout.skip = v;
        try app.out.print("added source {s}\n", .{try lib.addSource(&r, app.now(), typed.items, layout)});
    } else if (c.is("set", 1, settings) and c.args.count() > 0) {
        var r = try app.open();
        defer r.close();
        var rp = try lib.findSource(&r, app.arena, c.rest[0]);
        if (qualityFrom(c)) |q| rp = try lib.setQualityFrom(&r, app.arena, app.now(), c.rest[0], q);
        if (c.args.get("--skip")) |v| rp = try lib.setSkip(&r, app.arena, app.now(), c.rest[0], v);
        try app.out.print("{s}  quality: {s}, skip: \"{s}\"; crawl to apply\n", .{ rp.id, try qualitySetting(app.arena, rp.layout), rp.layout.skip });
    } else if (c.is("remove", 1, &.{"--unavailable"}) and c.args.get("--unavailable") != null) {
        var r = try app.open();
        defer r.close();
        const rp = try lib.findSource(&r, app.arena, c.rest[0]);
        const dir = c.args.get("--unavailable").?;
        const n = try lib.removeUnavailable(&r, app.arena, app.now(), rp, dir);
        try app.out.print("removed /{s}'s {d} copies\n", .{ std.mem.trim(u8, dir, "/"), n });
    } else if (c.is("remove", 1, &.{})) {
        var r = try app.open();
        defer r.close();
        const n = try lib.removeSource(&r, app.arena, app.now(), c.rest[0]);
        try app.out.print("removed {s} and its {d} copies\n", .{ c.rest[0], n });
    } else return error.Usage;
}

pub fn title(app: *App, c: Command) !void {
    const out = app.out;
    if (c.is("list", 0, &.{}) or c.is("list", 1, &.{})) {
        var r = try app.open();
        defer r.close();
        const filter: []const u8 = if (c.rest.len > 0) c.rest[0] else "";
        var shown: usize = 0;
        var unheld: usize = 0;
        for (try lib.titles(&r, app.arena)) |t| {
            if (filter.len > 0 and std.ascii.findIgnoreCase(t.name, filter) == null) continue;
            if (t.qualities == 0) {
                unheld += 1;
                continue;
            }
            shown += 1;
            try out.print("{s}", .{t.name});
            if (t.year) |y| try out.print(" ({d})", .{y});
            try out.print(" {s}: {d} {s}, {d} {s} [", .{ @tagName(t.kind), t.items, switch (t.kind) {
                .movie => "versions",
                .series => "episodes",
            }, t.qualities, if (t.qualities == 1) "quality" else "qualities" });
            for (t.labels.items, 0..) |l, i| try out.print("{s}{s}", .{ if (i > 0) ", " else "", l });
            try out.print("]  {s}\n", .{t.key});
        }
        try out.print("{d} titles", .{shown});
        if (unheld > 0) try out.print(" ({d} more held by no source)", .{unheld});
        try out.print("\n", .{});
    } else if (c.is("show", 1, &.{})) {
        var r = try app.open();
        defer r.close();
        const d = try lib.detail(&r, app.arena, c.rest[0]) orelse return error.NoSuchTitle;
        var urls: std.StringHashMapUnmanaged([]const u8) = .empty;
        for (try lib.sources(&r, app.arena)) |rp| try urls.put(app.arena, try app.arena.dupe(u8, &rp.id), rp.at() orelse continue);
        try out.print("{s}", .{d.name});
        if (d.year) |y| try out.print(" ({d})", .{y});
        try out.print("  {s}\n", .{d.key});
        for (d.fields.keys(), d.fields.values()) |k, v| try out.print("  {s}: {s}\n", .{ k, v });
        for (d.items.items) |item| {
            try out.print("  {s}", .{item.key});
            try printProgress(out, item.progress);
            try out.print("\n", .{});
            for (item.fields.keys(), item.fields.values()) |k, v| try out.print("    {s}: {s}\n", .{ k, v });
            for (item.qualities.items) |quality| {
                try out.print("    {s}\n", .{quality.label});
                for (quality.copies.items) |h| {
                    const base = core.url.decode(try app.arena.dupe(u8, urls.get(h.source) orelse h.source)) catch h.source;
                    try out.print("      {d:.2} GB  {s}  {s}{s}\n", .{ @as(f64, @floatFromInt(h.size)) / 1e9, h.mtime, base, h.path });
                }
            }
        }
    } else return error.Usage;
}

pub fn progress(app: *App, c: Command) !void {
    const watched = c.args.has("--watched");
    if (c.is("list", 0, &.{}) or c.is("list", 1, &.{})) {
        var r = try app.open();
        defer r.close();
        for (try lib.progressOf(&r, app.arena, if (c.rest.len > 0) c.rest[0] else null)) |e| {
            try app.out.print("{s}", .{e.item});
            try printProgress(app.out, e.progress);
            try app.out.print("\n", .{});
        }
    } else if (c.is("set", 3, &.{})) {
        var r = try app.open();
        defer r.close();
        const position = try std.fmt.parseFloat(f64, c.rest[1]);
        const duration = try std.fmt.parseFloat(f64, c.rest[2]);
        try lib.setProgress(&r, app.arena, app.now(), c.rest[0], @intFromFloat(position * 1000), @intFromFloat(duration * 1000));
        try app.out.print("set {s}\n", .{c.rest[0]});
    } else if (c.is("set", 1, &.{ "--watched", "--unwatched" }) and watched != c.args.has("--unwatched")) {
        var r = try app.open();
        defer r.close();
        if (watched) try lib.markWatched(&r, app.arena, app.now(), c.rest[0]) else try lib.markUnwatched(&r, app.arena, app.now(), c.rest[0]);
        try app.out.print("set {s}\n", .{c.rest[0]});
    } else if (c.is("remove", 1, &.{})) {
        var r = try app.open();
        defer r.close();
        try lib.removeProgress(&r, app.arena, app.now(), c.rest[0]);
        try app.out.print("removed progress of {s}\n", .{c.rest[0]});
    } else return error.Usage;
}

/// Placeholders, titles not in the library yet, on this person's lists
/// (see core's lists.zig): listed, added (a movie, or with `--season` a
/// series' season), and removed, by their keys as `want list` prints them.
pub fn want(app: *App, c: Command) !void {
    if (c.is("list", 0, &.{})) {
        var r = try app.open();
        defer r.close();
        for (try core.lists.lists(&r, app.arena)) |l| {
            if (!l.mine) continue;
            for (l.wanted) |w| try app.out.print("{s}\t{s}\t{s}\t{s}\n", .{ l.name, w.key, w.name, w.note });
        }
    } else if (c.is("add", 2, &.{ "--year", "--season", "--note" })) {
        var r = try app.open();
        defer r.close();
        const list = try ownList(&r, app.arena, c.rest[0]);
        const year: ?u16 = if (c.args.get("--year")) |y| std.fmt.parseInt(u16, y, 10) catch return error.Usage else null;
        const season: ?u16 = if (c.args.get("--season")) |s| std.fmt.parseInt(u16, s, 10) catch return error.Usage else null;
        const key = core.lists.want(&r, app.arena, app.now(), list.id, .{
            .kind = if (season != null) .series else .movie,
            .name = c.rest[1],
            .year = year,
            .season = season,
            .note = c.args.get("--note") orelse "",
        }) catch |err| return if (err == error.InvalidArgument) error.BadPlaceholder else err;
        try app.out.print("{s}: {s}\n", .{ list.name, key });
    } else if (c.is("remove", 2, &.{})) {
        var r = try app.open();
        defer r.close();
        const list = try ownList(&r, app.arena, c.rest[0]);
        for (list.wanted) |w| {
            if (!std.mem.eql(u8, w.key, c.rest[1])) continue;
            try core.lists.setListed(&r, app.arena, app.now(), list.id, w.key, false);
            return app.out.print("{s}: removed {s}\n", .{ list.name, w.key });
        }
        return error.NoSuchPlaceholder;
    } else return error.Usage;
}

/// One of this person's lists, by its ID or its name (ignoring case).
fn ownList(r: *core.replica.Replica, arena: std.mem.Allocator, which: []const u8) !core.lists.List {
    for (try core.lists.lists(r, arena)) |l| {
        if (l.mine and (std.mem.eql(u8, l.id, which) or std.ascii.eqlIgnoreCase(l.name, which))) return l;
    }
    return error.NoSuchList;
}

fn printProgress(out: *Io.Writer, head: lib.Progress) !void {
    if (head.watched) try out.print("  watched", .{});
    if (head.position_ms > 0) try out.print("  at {d}:{d:0>2} of {d}:{d:0>2}", .{ head.position_ms / 60000, head.position_ms / 1000 % 60, head.duration_ms / 60000, head.duration_ms / 1000 % 60 });
}

/// `crawl [SOURCE] [--workers WORKERS] [--full]`: crawls every source, or
/// one; with `--full`, listing every directory afresh.
pub fn crawl(app: *App, c: Command) !void {
    if (c.rest.len > 1) return error.Usage;
    try c.args.only(&.{ "--workers", "--full" });
    const workers = try c.args.number("--workers", 16);
    var r = try app.open();
    defer r.close();
    const sources = if (c.rest.len == 1) &[_]lib.Source{try lib.findSource(&r, app.arena, c.rest[0])} else try lib.sources(&r, app.arena);
    try crawlAndDescribe(app, &r, sources, .{ .workers = workers, .listing = if (c.args.has("--full")) .afresh else .reuse });
}

/// `refresh [--jitter SECONDS]`: waits a random time up to the jitter (so
/// devices on timers don't refresh together), syncs, then crawls the
/// sources no device crawled within the library's interval (`library set
/// --crawl`), or none if it's manually.
pub fn refresh(app: *App, c: Command) !void {
    if (c.rest.len > 0) return error.Usage;
    try c.args.only(&.{"--jitter"});
    const jitter = if (c.args.get("--jitter") != null) try c.args.number("--jitter", 1) else 0;
    if (jitter > 0) {
        var n: u64 = undefined;
        app.io.random(std.mem.asBytes(&n));
        try app.io.sleep(.fromMilliseconds(@intCast(n % (@as(u64, jitter) * 1000))), .awake);
    }
    // Devices' catalog first, already described, so crawling then finds
    // little to do, and sources others crawled lately are skipped.
    try network.syncEvery(app);
    var r = try app.open();
    defer r.close();
    try crawlAndDescribe(app, &r, try lib.sources(&r, app.arena), .{ .due = try lib.due(&r, app.io, app.arena, app.now()) });
}

/// Crawls `sources`, then describes what's new, saying how each went; fails
/// as the first source that failed did.
fn crawlAndDescribe(app: *App, r: *core.replica.Replica, sources: []const lib.Source, options: core.art.Options) !void {
    const done = try core.art.crawlAndDescribe(app.io, app.gpa, r, app.arena, sources, options);
    var failed: ?anyerror = null;
    for (done.sources) |result| {
        const url = result.source.url;
        switch (result.outcome) {
            .skipped => |why| try app.out.print("{s}: {s}\n", .{ url, switch (why) {
                .downloads => "a device's downloads, not crawled",
                .away => "its device hasn't said where it serves it, not crawled",
                .manual => "crawled only when asked (crawl), not now",
                .lately => try std.fmt.allocPrint(app.arena, "crawled within the last {d} hours, not again", .{options.due.?.every.?}),
            } }),
            .failed => |err| failed = failed orelse err,
            .crawled => |s| {
                const i = s.ingest;
                try app.out.print("{s}: {d} requests ({d} directories reused) in {d} ms; {d} files ({d} skipped, {d} extras, {d} unparsed); {d} titles added; copies {d} added, {d} changed, {d} removed; {d} duplicates; {d} directories unavailable; {d} ms in all\n", .{
                    url,            s.crawl.requests, s.crawl.skipped,  s.crawl_ms,       i.files,      i.skipped,     i.extras,   i.unparsed,
                    i.titles_added, i.copies_added,   i.copies_changed, i.copies_removed, i.duplicates, i.unavailable, s.total_ms,
                });
                if (i.duplicate_example) |e| try app.out.print("  e.g., {s}\n", .{e});
            },
        }
    }
    const a = done.described;
    try app.out.print("described {d} movies and seasons ({d} unchanged) in {d} ms: {d} covers found, {d} files read, {d} failed\n", .{
        done.plan.jobs.len, done.plan.unchanged, done.describe_ms, a.covers, a.described, a.failed,
    });
    if (failed) |err| return err;
}
