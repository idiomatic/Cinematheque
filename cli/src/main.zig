//! The command-line app; see usage.txt for its commands.

const std = @import("std");
const Io = std.Io;
const core = @import("core");
const commands = @import("commands.zig");
const network = @import("network.zig");

/// Which app this is, as `/version` says (see the core's version.zig).
pub const app_name = "command-line app";

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
    /// Whether the words began as `ls` or `show`, which stand for `title
    /// list` and `title show`.
    shortcut: bool = false,

    const flags = [_][]const u8{ "--leave", "--watched", "--unwatched", "--help", "--no-web", "--permissive", "--version", "--full" };

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
            a.shortcut = true;
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
        return if (a.get("--port")) |v| std.fmt.parseInt(u16, v, 10) catch error.Usage else null;
    }

    /// An option's positive whole number, or `default`; anything else isn't
    /// a command line.
    pub fn number(a: *const Args, name: []const u8, default: usize) !usize {
        const n = if (a.get(name)) |v| std.fmt.parseInt(usize, v, 10) catch return error.Usage else default;
        return if (n == 0) error.Usage else n;
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
};

/// Actions on the whole app: single words, with arguments but no verb.
const actions = [_]Noun{
    .{ .name = "crawl", .run = commands.crawl },
    .{ .name = "sync", .run = network.sync },
    .{ .name = "serve", .run = network.serve },
    .{ .name = "refresh", .run = commands.refresh },
};

/// Runs the command line; a failure is said in words, on stderr, with no
/// trace (an expected error isn't a crash), and exits with status 1.
pub fn main(init: std.process.Init) void {
    run(init) catch |err| {
        var buffer: [512]u8 = undefined;
        var stderr = Io.File.stderr().writer(init.io, &buffer);
        stderr.interface.print("error: {s}\n", .{explain(err)}) catch {};
        stderr.interface.flush() catch {};
        std.process.exit(1);
    };
}

/// What went wrong, as a person would put it, naming what to do where
/// there's something to do; else the error's name.
fn explain(err: anyerror) []const u8 {
    return switch (err) {
        error.NoLibrary => "this device has no library: create one (library create), or join one (library join)",
        error.LibraryExists => "this device already has a library (library leave forgets it)",
        error.NoHome => "HOME isn't set, so give a data directory with --data",
        error.NoSuchTitle => "there's no such title (title list shows them)",
        error.NoSuchSource => "there's no such source (source list shows them)",
        error.NothingHeld => "no source holds it (in that quality, if one was given)",
        error.BadKey => "that isn't a key (64 hex digits)",
        error.WrongCode => "that isn't the code the new device shows",
        error.Closed, error.TooManyWrongCodes => "pairing stopped after too many wrong codes: offer again, for a new code",
        error.NoneOffering => "no new device nearby is offering a code: give its URL after the code",
        error.SeveralOffering => "several new devices nearby are offering codes: give the one's URL after the code",
        error.NotAMember => "that device's library doesn't have this person as a member",
        error.WrongLibrary => "that device is in another library",
        error.Removed => "this device was removed from the library: library leave, then join again as a new device",
        error.NotFounder => "only the library's founder can do that",
        error.FounderIsPermanent => "the founder can't be removed: hand the library over first (library handover)",
        error.FoundersDevice => "only the founder can remove the founder's devices",
        error.ThisDevice => "that's this device",
        error.NeedsSuccessor => "this person founded the library and this is their only device: hand it over as it leaves (library leave --to PERSON, a member's key, as member list prints them)",
        error.NoOneReached => "none of the library's other devices could be reached, so they wouldn't hear this one left: try again while one is on (nothing's been forgotten)",
        error.NotYourDevice => "that isn't one of this person's devices (device list shows them)",
        error.Busy => "another long operation is using the library: try again once it's done",
        error.AddressInUse => "that port is taken: choose another with --port",
        error.ConnectionRefused => "nothing answered there (is it running?)",
        error.ConnectionTimedOut, error.Timeout => "it didn't answer in time",
        error.UnknownHostName, error.NameServerFailure, error.TemporaryNameServerFailure => "no device or server by that name was found",
        error.NetworkUnreachable => "it can't be reached from this network",
        error.HostUnreachable => "it can't be reached (on macOS, Terminal may need Local Network access, in System Settings > Privacy & Security)",
        error.AccessDenied => "permission denied",
        error.NotFound => "the server has nothing at that address",
        error.Stale => "its clock and this one's are more than ten minutes apart",
        error.WrongRecipient => "another device answered at its address",
        error.Refused => "that device refused (is it up to date? devices sync only with others as new)",
        error.PathTaken => "another file is already where it would go, so it's left alone",
        error.BadAddress => "that isn't a web address (http:// or https://, with a host)",
        error.TooMany => "the server lists far more than any library holds",
        error.TooDeep => "the server's folders nest too deeply",
        error.DownloadsElsewhere => "this device keeps its downloads in another directory (as the Mac app does, sharing its data directory): give that one with --downloads, or serve from another data directory (--data)",
        else => @errorName(err),
    };
}

/// Standard output, its control characters (but newlines and tabs) as `?`:
/// names come from files and other devices, and one with an escape
/// sequence could otherwise act on the terminal.
const Filtered = struct {
    inner: *Io.Writer,
    interface: Io.Writer,

    fn init(inner: *Io.Writer, buffer: []u8) Filtered {
        return .{ .inner = inner, .interface = .{ .vtable = &.{ .drain = drain, .flush = flush }, .buffer = buffer } };
    }

    fn put(f: *Filtered, bytes: []const u8) Io.Writer.Error!void {
        for (bytes) |c| try f.inner.writeByte(if ((c < 0x20 and c != '\n' and c != '\t') or c == 0x7f) '?' else c);
    }

    fn drain(w: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
        const f: *Filtered = @alignCast(@fieldParentPtr("interface", w));
        try f.put(w.buffered());
        w.end = 0;
        var n: usize = 0;
        for (data[0 .. data.len - 1]) |d| {
            try f.put(d);
            n += d.len;
        }
        const last = data[data.len - 1];
        for (0..splat) |_| try f.put(last);
        return n + last.len * splat;
    }

    fn flush(w: *Io.Writer) Io.Writer.Error!void {
        const f: *Filtered = @alignCast(@fieldParentPtr("interface", w));
        try f.put(w.buffered());
        w.end = 0;
        try f.inner.flush();
    }
};

test "control characters are shown as ?" {
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var buffer: [4]u8 = undefined;
    var f: Filtered = .init(&out.writer, &buffer);
    try f.interface.print("Alien\x1b[2J (1979)\t1080p\n", .{});
    try f.interface.flush();
    try std.testing.expectEqualStrings("Alien?[2J (1979)\t1080p\n", out.written());
}

fn run(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(arena);
    var buffer: [8192]u8 = undefined;
    var stdout = Io.File.stdout().writer(io, &buffer);
    var filtered_buffer: [1024]u8 = undefined;
    var filtered: Filtered = .init(&stdout.interface, &filtered_buffer);
    const out = &filtered.interface;
    defer out.flush() catch {};

    const args = Args.parse(arena, argv[1..]) catch usage(out, null);
    const w = args.words;
    // Help: `-h` or `--help`, on its own or for a noun or action, or a
    // noun alone.
    if (args.has("--help")) {
        // A shortcut's help is its command's alone.
        const topic = if (w.len == 0) null else if (args.shortcut) try std.fmt.allocPrint(arena, "{s} {s}", .{ w[0], w[1] }) else w[0];
        return help(out, topic);
    }
    if (args.has("--version")) {
        const v = core.version.info;
        return out.print("cinematheque {s} ({s}, {s}, Zig {s})\n", .{ v.version, v.revision, v.mode, v.zig });
    }
    if (w.len == 0) usage(out, null);
    const action = find(&actions, w[0]);
    const found = if (action) |a| a else find(&nouns, w[0]) orelse usage(out, null);
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
    found.run(&app, command) catch |err| switch (err) {
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
