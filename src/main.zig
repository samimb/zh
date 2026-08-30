const std = @import("std");
const Io = std.Io;
const zhist = @import("zhist");

const usage =
    \\zhist - print the output of a previous command from terminal scrollback
    \\
    \\usage: zhist [options]
    \\
    \\options:
    \\  -n <num>       command <num> steps back (default 1 = previous command)
    \\  -l             list recent commands instead of printing output
    \\  -c             prepend the command line itself
    \\  -f <file>      read scrollback from <file> instead of tmux/screen
    \\  --from <src>   force capture source: tmux | screen (default: auto,
    \\                 tmux wins when nested)
    \\  --marker <m>   text zhist was invoked as, if aliased (default: zhist)
    \\  --color        keep ANSI colors (tmux only)
    \\  -h, --help     show this help
    \\
    \\capture sources, in order: -f file, tmux ($TMUX), GNU screen ($STY).
    \\ghostty (no scrollback CLI): bind a key to write_screen_file:copy, then
    \\run: zhist -f "$(wl-paste)"   (or pbpaste on macOS)
    \\
;

const Options = struct {
    n: usize = 1,
    list: bool = false,
    with_cmd: bool = false,
    file: ?[]const u8 = null,
    from: enum { auto, tmux, screen } = .auto,
    marker: []const u8 = "zhist",
    color: bool = false,
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const environ = init.environ_map;

    const args = try init.minimal.args.toSlice(arena);
    const opts = parseArgs(args);

    const capture = try captureScrollback(arena, io, environ, opts);

    if (environ.get("ZHIST_DEBUG_CAPTURE")) |dbg_path| {
        Io.Dir.cwd().writeFile(io, .{ .sub_path = dbg_path, .data = capture }) catch {};
    }

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const out = &stdout_file_writer.interface;

    if (opts.list) {
        const cmds = zhist.list(arena, capture, opts.marker, 20) catch |err|
            die("{s}", .{explain(err)});
        for (cmds, 1..) |cmd, i| {
            try out.print("{d: >3}  {s}\n", .{ i, cmd });
        }
    } else {
        // For --color, parse the plain capture but emit lines from a second,
        // ANSI-styled capture of the same scrollback.
        const styled: ?[]const u8 = if (opts.color and opts.file == null and
            (environ.get("TMUX") != null or environ.get("TMUX_PANE") != null))
            try captureTmux(arena, io, environ, true)
        else
            null;
        const entry = zhist.extractStyled(arena, capture, styled, opts.marker, opts.n) catch |err|
            die("{s}", .{explain(err)});
        if (opts.with_cmd) {
            try out.print("$ {s}\n", .{entry.command});
        }
        for (entry.output) |line| {
            try out.print("{s}\n", .{line});
        }
    }
    try out.flush();
}

fn explain(err: zhist.Error) []const u8 {
    return switch (err) {
        error.MarkerNotFound => "could not find the zhist invocation in the scrollback (aliased? try --marker)",
        error.NotEnoughHistory => "not that many commands in the scrollback",
        error.OutOfMemory => "out of memory",
    };
}

fn parseArgs(args: []const [:0]const u8) Options {
    var opts: Options = .{};
    if (args.len > 0) {
        const argv0 = args[0];
        const base = if (std.mem.lastIndexOfScalar(u8, argv0, '/')) |p| argv0[p + 1 ..] else argv0;
        if (base.len > 0) opts.marker = base;
    }
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-n")) {
            i += 1;
            if (i >= args.len) die("-n needs a number", .{});
            opts.n = std.fmt.parseInt(usize, args[i], 10) catch
                die("invalid -n value: {s}", .{args[i]});
            if (opts.n == 0) die("-n starts at 1", .{});
        } else if (std.mem.eql(u8, arg, "-l")) {
            opts.list = true;
        } else if (std.mem.eql(u8, arg, "-c")) {
            opts.with_cmd = true;
        } else if (std.mem.eql(u8, arg, "-f")) {
            i += 1;
            if (i >= args.len) die("-f needs a file path", .{});
            opts.file = args[i];
        } else if (std.mem.eql(u8, arg, "--from")) {
            i += 1;
            if (i >= args.len) die("--from needs tmux or screen", .{});
            if (std.mem.eql(u8, args[i], "tmux")) {
                opts.from = .tmux;
            } else if (std.mem.eql(u8, args[i], "screen")) {
                opts.from = .screen;
            } else {
                die("--from must be tmux or screen, got: {s}", .{args[i]});
            }
        } else if (std.mem.eql(u8, arg, "--marker")) {
            i += 1;
            if (i >= args.len) die("--marker needs a value", .{});
            opts.marker = args[i];
        } else if (std.mem.eql(u8, arg, "--color")) {
            opts.color = true;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            std.debug.print("{s}", .{usage});
            std.process.exit(0);
        } else {
            die("unknown option: {s}\n\n{s}", .{ arg, usage });
        }
    }
    return opts;
}

fn captureScrollback(
    arena: std.mem.Allocator,
    io: Io,
    environ: *std.process.Environ.Map,
    opts: Options,
) ![]const u8 {
    if (opts.file) |path| {
        return Io.Dir.cwd().readFileAlloc(io, path, arena, .unlimited) catch |err|
            die("cannot read {s}: {t}", .{ path, err });
    }
    const in_tmux = environ.get("TMUX") != null or environ.get("TMUX_PANE") != null;
    const in_screen = environ.get("STY") != null;
    switch (opts.from) {
        .tmux => {
            if (!in_tmux) die("--from tmux, but $TMUX is not set", .{});
            return captureTmux(arena, io, environ, false);
        },
        .screen => {
            if (!in_screen) die("--from screen, but $STY is not set", .{});
            return captureScreen(arena, io, environ);
        },
        .auto => {
            if (in_tmux) return captureTmux(arena, io, environ, false);
            if (in_screen) return captureScreen(arena, io, environ);
        },
    }
    die("no capture source found.\nrun inside tmux or GNU screen, or pass -f <scrollback-file>.\nsee zhist --help for the ghostty recipe.", .{});
}

fn captureTmux(
    arena: std.mem.Allocator,
    io: Io,
    environ: *std.process.Environ.Map,
    color: bool,
) ![]const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    // -p: to stdout, -J: rejoin wrapped lines, -S -: entire scrollback.
    try argv.appendSlice(arena, &.{ "tmux", "capture-pane", "-p", "-J", "-S", "-" });
    if (color) try argv.append(arena, "-e");
    if (environ.get("TMUX_PANE")) |pane| {
        try argv.appendSlice(arena, &.{ "-t", pane });
    }
    const result = std.process.run(arena, io, .{ .argv = argv.items }) catch |err|
        die("failed to run tmux: {t}", .{err});
    checkTerm(result, "tmux capture-pane");
    return result.stdout;
}

fn captureScreen(
    arena: std.mem.Allocator,
    io: Io,
    environ: *std.process.Environ.Map,
) ![]const u8 {
    const tmpdir = environ.get("TMPDIR") orelse "/tmp";
    const sty = environ.get("STY").?;
    const dump = try std.fmt.allocPrint(arena, "{s}/zhist-{s}.dump", .{ tmpdir, sty });
    defer Io.Dir.cwd().deleteFile(io, dump) catch {};

    // Target our own session and window explicitly: a bare `screen -X` picks
    // the "current" display, which may not be this one. $WINDOW is set by
    // screen in the child shell. -h includes scrollback history.
    const window = environ.get("WINDOW") orelse "0";
    const result = std.process.run(arena, io, .{
        .argv = &.{ "screen", "-S", sty, "-p", window, "-X", "hardcopy", "-h", dump },
    }) catch |err| die("failed to run screen: {t}", .{err});
    checkTerm(result, "screen -X hardcopy");

    // hardcopy is asynchronous: screen writes the file after the -X command
    // returns. Poll briefly.
    var tries: usize = 0;
    while (tries < 100) : (tries += 1) {
        if (Io.Dir.cwd().readFileAlloc(io, dump, arena, .unlimited)) |text| {
            if (text.len > 0) return text;
        } else |_| {}
        io.sleep(.fromMilliseconds(10), .awake) catch break;
    }
    die("screen hardcopy never appeared at {s}", .{dump});
}

fn checkTerm(result: std.process.RunResult, what: []const u8) void {
    switch (result.term) {
        .exited => |code| if (code != 0)
            die("{s} exited with {d}: {s}", .{ what, code, std.mem.trim(u8, result.stderr, "\n ") }),
        else => die("{s} terminated abnormally", .{what}),
    }
}

fn die(comptime fmt: []const u8, fmt_args: anytype) noreturn {
    std.debug.print("zhist: " ++ fmt ++ "\n", fmt_args);
    std.process.exit(1);
}
