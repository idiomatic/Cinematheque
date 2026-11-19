//! The command-line app; see usage.txt for its commands.

const std = @import("std");
const Io = std.Io;
const core = @import("core");
const commands = @import("commands.zig");
const network = @import("network.zig");

/// What every command acts with: this device's data directory, and where
/// to print.
pub const App = struct {
    io: Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    store: core.store.Store,
    out: *Io.Writer,
    environ: *const std.process.Environ.Map,

    pub fn person(p: *const App) ![32]u8 {
        return p.store.person();
    }

    pub fn open(p: *const App) !core.replica.Replica {
        return p.store.openReplica(p.arena);
    }

    pub fn now(p: *const App) u64 {
        return @intCast(Io.Timestamp.now(p.io, .real).toMilliseconds());
    }
};

/// A command line: its words, and its options (`--name value`, or flags,
/// `--name`, with an empty value).
pub const Args = struct {
    words: []const []const u8,
    options: std.StringArrayHashMapUnmanaged([]const u8) = .empty,

    const flags = [_][]const u8{ "--leave", "--watched", "--unwatched", "--help" };

    fn parse(arena: std.mem.Allocator, argv: []const []const u8) !Args {
        var words: std.ArrayList([]const u8) = .empty;
        var a: Args = .{ .words = &.{} };
        var i: usize = 0;
        while (i < argv.len) : (i += 1) {
            const arg = argv[i];
            if (std.mem.eql(u8, arg, "-h")) {
                try a.options.put(arena, "--help", "");
            } else if (!std.mem.startsWith(u8, arg, "--")) {
                try words.append(arena, arg);
            } else if (for (flags) |f| {
                if (std.mem.eql(u8, f, arg)) break true;
            } else false) {
                try a.options.put(arena, arg, "");
            } else {
                i += 1;
                if (i == argv.len) return error.Usage;
                try a.options.put(arena, arg, argv[i]);
            }
        }
        // Shortcuts.
        if (words.items.len > 0 and (std.mem.eql(u8, words.items[0], "ls") or std.mem.eql(u8, words.items[0], "show"))) {
            const verb = if (words.items[0][0] == 'l') "list" else "show";
            words.items[0] = "title";
            try words.insert(arena, 1, verb);
        }
        a.words = words.items;
        return a;
    }

    pub fn get(a: *const Args, name: []const u8) ?[]const u8 {
        return a.options.get(name);
    }

    pub fn has(a: *const Args, name: []const u8) bool {
        return a.options.contains(name);
    }

    /// Fails unless every option given is among `allowed` (or `--data`).
    pub fn only(a: *const Args, allowed: []const []const u8) !void {
        for (a.options.keys()) |k| {
            if (std.mem.eql(u8, k, "--data")) continue;
            for (allowed) |o| {
                if (std.mem.eql(u8, o, k)) break;
            } else return error.Usage;
        }
    }

    /// How many options the command was given, besides `--data`.
    pub fn count(a: *const Args) usize {
        return a.options.count() - @intFromBool(a.has("--data"));
    }

    pub fn port(a: *const Args) !?u16 {
        return if (a.get("--port")) |v| try std.fmt.parseInt(u16, v, 10) else null;
    }

    pub fn number(a: *const Args, name: []const u8, default: usize) !usize {
        return if (a.get(name)) |v| try std.fmt.parseInt(usize, v, 10) else default;
    }
};

/// A command's words after its noun and verb, and its options; each noun's
/// function returns `error.Usage` for a command line that isn't one.
pub const Command = struct {
    verb: []const u8,
    rest: []const []const u8,
    args: *const Args,

    /// Whether this is `verb` with `arity` words after it, and options only
    /// among `options`.
    pub fn is(c: Command, verb: []const u8, arity: usize, options: []const []const u8) bool {
        return std.mem.eql(u8, c.verb, verb) and c.rest.len == arity and if (c.args.only(options)) |_| true else |_| false;
    }
};

const Noun = struct {
    name: []const u8,
    run: *const fn (*App, Command) anyerror!void,
};

const nouns = [_]Noun{
    .{ .name = "person", .run = commands.person },
    .{ .name = "library", .run = commands.library },
    .{ .name = "member", .run = commands.member },
    .{ .name = "source", .run = commands.source },
    .{ .name = "title", .run = commands.title },
    .{ .name = "alias", .run = commands.alias },
    .{ .name = "progress", .run = commands.progress },
    .{ .name = "device", .run = commands.device },
    .{ .name = "agent", .run = commands.agent },
};

/// Actions on the whole app: single words, with arguments but no verb.
const actions = [_]Noun{
    .{ .name = "crawl", .run = commands.crawl },
    .{ .name = "sync", .run = network.sync },
    .{ .name = "serve", .run = network.serve },
    .{ .name = "refresh", .run = commands.refresh },
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(arena);
    var buffer: [8192]u8 = undefined;
    var stdout = Io.File.stdout().writer(io, &buffer);
    const out = &stdout.interface;
    defer out.flush() catch {};

    const args = Args.parse(arena, argv[1..]) catch usage(out, null);
    const w = args.words;
    // Help: `-h` or `--help`, on its own or for a noun or action, or a
    // noun alone.
    if (args.has("--help")) return help(out, if (w.len > 0) w[0] else null);
    if (w.len == 0) usage(out, null);
    const action = find(&actions, w[0]);
    const run = if (action) |found| found else find(&nouns, w[0]) orelse usage(out, null);
    if (action == null and w.len == 1) usage(out, w[0]);

    const dir = args.get("--data") orelse init.environ_map.get("CINEMATHEQUE_DATA") orelse
        try core.store.defaultDataDir(arena, init.environ_map.get("HOME") orelse return error.NoHome, init.environ_map.get("XDG_DATA_HOME"));
    var app: App = .{
        .io = io,
        .gpa = init.gpa,
        .arena = arena,
        .store = try core.store.Store.open(io, init.gpa, arena, dir),
        .out = out,
        .environ = init.environ_map,
    };
    const command: Command = if (action != null)
        .{ .verb = "", .rest = w[1..], .args = &args }
    else
        .{ .verb = w[1], .rest = w[2..], .args = &args };
    run.run(&app, command) catch |err| switch (err) {
        error.Usage => usage(out, w[0]),
        else => return err,
    };
}

fn find(list: []const Noun, name: []const u8) ?Noun {
    for (list) |n| {
        if (std.mem.eql(u8, n.name, name)) return n;
    }
    return null;
}

const usage_text = @embedFile("usage.txt");

/// Prints the usage of `topic`'s commands (a noun's, or an action's), or
/// all of it if there are none.
fn help(out: *Io.Writer, topic: ?[]const u8) !void {
    defer out.flush() catch {};
    const t = topic orelse return out.print("{s}\n", .{usage_text});
    var showing = false;
    var shown = false;
    var lines = std.mem.splitScalar(u8, usage_text, '\n');
    while (lines.next()) |line| {
        // A command's first line is indented two spaces, and its
        // description's continuation lines more.
        if (std.mem.startsWith(u8, line, "  ") and line.len > 2 and line[2] != ' ') {
            const command = line[2..];
            showing = std.mem.startsWith(u8, command, t) and (command.len == t.len or command[t.len] == ' ');
        } else if (!std.mem.startsWith(u8, line, "   ")) showing = false;
        if (!showing) continue;
        try out.print("{s}\n", .{line});
        shown = true;
    }
    if (!shown) return out.print("{s}\n", .{usage_text});
    try out.print("\nRun cinematheque -h for every command.\n", .{});
}

/// Shows help for a command line that isn't one, and exits with status 2.
fn usage(out: *Io.Writer, topic: ?[]const u8) noreturn {
    help(out, topic) catch {};
    std.process.exit(2);
}
