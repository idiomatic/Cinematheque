//! The app's state commands, a function per noun, and crawling.

const std = @import("std");
const Io = std.Io;
const core = @import("core");
const lib = core.library;
const review = core.review;
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
        .founder = try app.store.founder(app.arena),
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
        try app.out.print("library  {s}\nfounder  {s}\nmembers  {d}\ndigest   {s}\n", .{
            std.fmt.bytesToHex(r.library, .lower),
            hex(r.founder),
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
        try app.store.setFounder(app.arena, try app.person());
        var r = try app.open();
        defer r.close();
        try app.out.print("created library {s}\n", .{std.fmt.bytesToHex(r.library, .lower)});
    } else if (c.is("leave", 0, &.{"--to"})) {
        try leave(app, c.args.get("--to"));
    } else if (c.is("handover", 1, &.{"--leave"})) {
        var r = try app.open();
        defer r.close();
        try r.handOver(app.now(), try parseKey(c.rest[0]), !c.args.has("--leave"));
        try app.out.print("handed over to {s}\n", .{c.rest[0]});
    } else return error.Usage;
}

/// Leaves the library, as the apps' Leave This Library does: removes this
/// device (handing the library over first, to `to`, if this person founded
/// it and this is their only device) and syncs, so another device takes the
/// removal, then forgets the library and this device's identity, to pair
/// again as a new device. With no one else in it, or once the library has
/// removed this device, it only forgets.
fn leave(app: *App, to: ?[]const u8) !void {
    told: {
        var r = app.open() catch |err| switch (err) {
            error.NoLibrary => break :told,
            else => return err,
        };
        defer r.close();
        const me = try app.person();
        var others: usize = 0;
        for (try r.devicesOf(app.arena, me)) |d| {
            if (!std.mem.eql(u8, &d, &r.device()) and try r.revoked(d) == null) others += 1;
        }
        const members = try r.members(app.arena);
        if (members.len == 1 and others == 0) break :told;
        const founding = std.mem.eql(u8, &me, &r.founder) and others == 0 and members.len > 1;
        const successor: ?[32]u8 = if (to) |s| try parseKey(s) else null;
        if (founding and successor == null) return error.NeedsSuccessor;
        // Written once: leaving again, after no one could be reached, only
        // syncs.
        try r.removeSelf(app.now(), if (founding) successor else null);
        const found = try core.sync.everyDevice(app.io, app.arena, &r, try app.store.serviceName(app.arena));
        var client: std.http.Client = .{ .allocator = app.gpa, .io = app.io };
        defer client.deinit();
        for (found.urls) |u| {
            // A device that took the removal, or that had already removed
            // this one, is enough.
            if (core.sync.exchange(app.arena, &client, &r, u, app.now())) |_| {
                break :told;
            } else |err| switch (err) {
                error.Removed => break :told,
                else => try app.out.print("{s}: {s}\n", .{ u, @errorName(err) }),
            }
        }
        return error.NoOneReached;
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
            if (std.mem.eql(u8, &m, &r.founder)) try app.out.print("  founder", .{});
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

/// A source's quality setting, as listed: by its folders, a name, or the
/// files' names.
fn qualitySetting(arena: std.mem.Allocator, layout: lib.Layout) ![]const u8 {
    return switch (layout.quality) {
        .names => "by name",
        .folder => "by folder",
        .path => "by path",
        .named => |n| std.fmt.allocPrint(arena, "\"{s}\"", .{n}),
        .unknown => "set by a newer version",
    };
}

/// What `--quality-by` takes.
const QualityBy = enum { folder, name, path };

/// Where a source's quality comes from, as `--quality-by` and `--quality`
/// say, given what it was; null if they say nothing. By name keeps a name
/// already given.
fn qualityFrom(c: Command, by: ?QualityBy, was: lib.QualityFrom) ?lib.QualityFrom {
    if (by == .folder) return .folder;
    if (by == .path) return .path;
    if (c.args.get("--quality")) |n| return if (n.len > 0) .{ .named = n } else .path;
    if (by == .name) return if (was == .named) was else .names;
    return null;
}

pub fn source(app: *App, c: Command) !void {
    const settings = &.{ "--quality", "--skip", "--quality-by" };
    // `--quality-by path` reads each file's quality from the nearest of its
    // name and folders that says one; `folder`, from the first folder
    // within the source; `name`, from the source's name (`--quality`), or
    // else the file's.
    const by: ?QualityBy = if (c.args.get("--quality-by")) |v| std.meta.stringToEnum(QualityBy, v) orelse return error.Usage else null;
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
        if (qualityFrom(c, by, .path)) |q| layout.quality = q;
        if (c.args.get("--skip")) |v| layout.skip = v;
        try app.out.print("added source {s}\n", .{try lib.addSource(&r, app.now(), typed.items, layout)});
    } else if (c.is("set", 1, settings) and c.args.count() > 0) {
        var r = try app.open();
        defer r.close();
        var rp = try lib.findSource(&r, app.arena, c.rest[0]);
        if (qualityFrom(c, by, rp.layout.quality)) |q| rp = try lib.setQualityFrom(&r, app.arena, app.now(), c.rest[0], q);
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
            try out.print("]  {s}{s}{s}\n", .{ t.key, if (t.alias != null) " -> " else "", t.alias orelse "" });
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
        if (d.alias_of) |to| try out.print("  an alias of {s}\n", .{to});
        for (d.aliases.items) |from| try out.print("  {s} is an alias of it\n", .{from});
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
    } else if (c.is("review", 0, &.{})) {
        var r = try app.open();
        defer r.close();
        const all = try lib.titles(&r, app.arena);
        const matches = try review.closeMatches(app.arena, all);
        for (matches) |m| try out.print("{s}\t{s}\t{s}\n", .{ m.reason, m.a, m.b });
        const dups = try review.duplicates(&r, app.arena);
        for (dups) |m| try out.print("{s}\t{s}\t{s}\n", .{ m.reason, m.a, m.b });
        try out.print("{d} close matches among {d} titles; {d} duplicate files\n", .{ matches.len, all.len, dups.len });
    } else if (c.is("download", 1, &.{ "--quality", "--to" })) {
        try download(app, c);
    } else if (c.is("facets", 0, &.{})) {
        var r = try app.open();
        defer r.close();
        for (try lib.facets(app.arena, try lib.titles(&r, app.arena))) |f| try out.print("{s}\t{s}\t{d}\n", .{ f.facet, f.value, f.count });
    } else return error.Usage;
}

/// Fetches a title's, a season's, or an item's files into a directory, under
/// their sources' paths (see core's download.zig).
fn download(app: *App, c: Command) !void {
    const out = app.out;
    const files = blk: {
        var r = try app.open();
        defer r.close();
        break :blk core.download.plan(&r, app.arena, c.rest[0], c.args.get("--quality")) catch |err| switch (err) {
            error.NotFound => return error.NothingHeld,
            else => |e| return e,
        };
    };
    var dir = try Io.Dir.cwd().createDirPathOpen(app.io, c.args.get("--to") orelse ".", .{});
    defer dir.close(app.io);
    var client: std.http.Client = .{ .allocator = app.gpa, .io = app.io };
    defer client.deinit();
    var memory: core.race.Memory = .{};
    defer memory.deinit(app.gpa);
    var failed: usize = 0;
    for (files) |f| {
        try out.print("{s}  {d:.2} GB  {s}", .{ f.path, @as(f64, @floatFromInt(f.size)) / 1e9, f.quality });
        try out.flush();
        var shown = Shown{ .out = out };
        const fetched = core.download.fetch(app.io, app.gpa, app.arena, &client, &memory, dir, f, app.now(), .{ .context = &shown, .report = Shown.report }) catch |err| {
            try out.print("  failed: {t}\n", .{err});
            failed += 1;
            continue;
        };
        try out.print("{s}\n", .{if (fetched == .kept) "  already here" else "  done"});
    }
    if (failed > 0) return error.Incomplete;
}

/// A download's percentage, as it rises, in tens.
const Shown = struct {
    out: *Io.Writer,
    percent: u64 = 0,

    /// Shows it; and goes on, as nothing here stops wanting it.
    fn report(context: *anyopaque, done: u64, total: u64) core.download.Verdict {
        const s: *Shown = @ptrCast(@alignCast(context));
        // In tens, to keep to one line.
        const percent = if (total == 0) 100 else done * 10 / total * 10;
        if (percent == s.percent) return .go_on;
        s.percent = percent;
        s.out.print("  {d}%", .{percent}) catch {};
        s.out.flush() catch {};
        return .go_on;
    }
};

pub fn alias(app: *App, c: Command) !void {
    if (c.is("list", 0, &.{})) {
        var r = try app.open();
        defer r.close();
        for (try review.aliases(&r, app.arena)) |a| try app.out.print("{s} -> {s}\n", .{ a.from, a.to });
    } else if (c.is("add", 2, &.{})) {
        var r = try app.open();
        defer r.close();
        try review.addAlias(&r, app.now(), c.rest[0], c.rest[1]);
        try app.out.print("{s} -> {s}\n", .{ c.rest[0], c.rest[1] });
    } else if (c.is("remove", 1, &.{})) {
        var r = try app.open();
        defer r.close();
        try review.removeAlias(&r, app.now(), c.rest[0]);
        try app.out.print("removed alias of {s}\n", .{c.rest[0]});
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
    if (c.args.has("--full"))
        try crawlAndDescribe(app, &r, workers, sources, lib.crawlSourceAfresh)
    else
        try crawlAndDescribe(app, &r, workers, sources, lib.crawlSource);
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
    const every = try lib.crawlEvery(&r, app.arena);
    const window = if (every) |hours| lib.crawlWindow(app.io, hours) else 0;
    var due: std.ArrayList(lib.Source) = .empty;
    for (try lib.sources(&r, app.arena)) |rp| {
        if (rp.managed) {
            try due.append(app.arena, rp);
        } else if (every == null) {
            try app.out.print("{s}: crawled only when asked (crawl), not now\n", .{rp.url});
        } else if (rp.crawledLately(app.now(), window)) {
            try app.out.print("{s}: crawled within the last {d} hours, not again\n", .{ rp.url, every.? });
        } else try due.append(app.arena, rp);
    }
    try crawlAndDescribe(app, &r, 16, due.items, lib.crawlSource);
}

/// How a source is crawled: reusing the last crawl's listings, or afresh.
const Crawler = fn (*core.replica.Replica, Io, std.mem.Allocator, *std.http.Client, u64, lib.Source, usize) anyerror!lib.CrawlStats;

/// Crawls `sources`, but devices' downloads, then describes what's new:
/// covers and metadata, with concurrent workers.
fn crawlAndDescribe(app: *App, r: *core.replica.Replica, workers: usize, sources: []const lib.Source, comptime crawler: Crawler) !void {
    var client: std.http.Client = .{ .allocator = app.gpa, .io = app.io };
    defer client.deinit();
    var crawled: std.ArrayList(core.art.Crawled) = .empty;
    for (sources) |rp| {
        if (rp.managed) {
            try app.out.print("{s}: a device's downloads, not crawled\n", .{rp.url});
            continue;
        }
        if (rp.at() == null) {
            try app.out.print("{s}: its device hasn't said where it serves it, not crawled\n", .{rp.url});
            continue;
        }
        const s = try crawler(r, app.io, app.arena, &client, app.now(), rp, workers);
        const i = s.ingest;
        try app.out.print("{s}: {d} requests ({d} directories reused) in {d} ms; {d} files ({d} skipped, {d} extras, {d} unparsed); {d} titles added; copies {d} added, {d} changed, {d} removed; {d} duplicates; {d} directories unavailable; {d} ms in all\n", .{
            rp.url,         s.crawl.requests, s.crawl.skipped,  s.crawl_ms,       i.files,      i.skipped,     i.extras,   i.unparsed,
            i.titles_added, i.copies_added,   i.copies_changed, i.copies_removed, i.duplicates, i.unavailable, s.total_ms,
        });
        if (i.duplicate_example) |e| try app.out.print("  e.g., {s}\n", .{e});
        try app.out.flush();
        try crawled.append(app.arena, .{ .source = rp, .entries = s.entries });
    }
    const start = Io.Timestamp.now(app.io, .awake);
    const plan = try core.art.plan(r, app.arena, crawled.items);
    const a = try core.art.run(app.io, r, app.arena, &client, app.now(), plan.jobs, .{ .workers = workers });
    try app.out.print("described {d} movies and seasons ({d} unchanged) in {d} ms: {d} covers found, {d} placeholders made, {d} files read, {d} failed\n", .{
        plan.jobs.len, plan.unchanged, start.durationTo(Io.Timestamp.now(app.io, .awake)).toMilliseconds(), a.covers, a.thumbs, a.described, a.failed,
    });
}
