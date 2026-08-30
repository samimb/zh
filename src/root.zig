//! zhist core: given a dump of terminal scrollback, find the boundaries of
//! previously executed commands and extract their output.
//!
//! Terminals don't record where one command's output ends and the next
//! prompt begins (unless they support OSC 133 zones, which we can't access
//! from a capture). So this works by prompt-shape heuristics:
//!
//! 1. Locate the line where zhist itself was invoked (bottom-most line
//!    containing the marker, e.g. "zhist"). Everything before the marker on
//!    that line is the current prompt's text — the "prefix".
//! 2. Scan upward for earlier prompt lines, matching in order of confidence:
//!    exact prefix match, then the prefix's last token, then a trailing
//!    prompt character ($ % # > ❯ »). This tolerates prompts that embed a
//!    changing cwd or git branch.
//! 3. The output of command N is everything between its prompt line and the
//!    next prompt line below it.
const std = @import("std");
const Allocator = std.mem.Allocator;

const prompt_chars = [_][]const u8{ "❯", "»", "$", "%", "#", ">" };

fn endsWithPromptChar(text: []const u8) bool {
    for (prompt_chars) |pc| {
        if (std.mem.endsWith(u8, text, pc)) return true;
    }
    return false;
}

pub const Error = error{
    /// The zhist invocation line was not found in the capture.
    MarkerNotFound,
    /// Fewer commands present in the scrollback than requested.
    NotEnoughHistory,
} || Allocator.Error;

pub const Entry = struct {
    /// The command as typed (slice into the capture text).
    command: []const u8,
    /// Output lines (slices into the capture text). Caller owns the array;
    /// the line slices themselves point into the capture.
    output: []const []const u8,
};

/// Extract the command `n` steps back (n=1 is the command right before the
/// zhist invocation) and its output.
pub fn extract(gpa: Allocator, capture: []const u8, marker: []const u8, n: usize) Error!Entry {
    return extractStyled(gpa, capture, null, marker, n);
}

/// Like `extract`, but returns output lines taken from `render` — a second
/// capture of the same scrollback with ANSI styling intact (tmux -e). All
/// prompt matching happens on the plain `capture`; `render` must have the
/// same line structure or it is ignored.
pub fn extractStyled(
    gpa: Allocator,
    capture: []const u8,
    render: ?[]const u8,
    marker: []const u8,
    n: usize,
) Error!Entry {
    std.debug.assert(n >= 1);
    var scan = try Scan.init(gpa, capture, marker);
    defer scan.deinit(gpa);

    var prompts: std.ArrayList(Boundary) = .empty;
    defer prompts.deinit(gpa);
    try scan.collectPrompts(gpa, &prompts, n);

    // Position (in the newest-first prompt list) of the n-th command-bearing
    // prompt line.
    const target_pos: usize = blk: {
        var seen: usize = 0;
        for (prompts.items, 0..) |b, pos| {
            if (!b.has_cmd) continue;
            seen += 1;
            if (seen == n) break :blk pos;
        }
        return Error.NotEnoughHistory;
    };
    const target = prompts.items[target_pos];
    // Output ends at the nearest prompt line below the target (which may be
    // an empty prompt), or at the zhist invocation itself.
    const end = if (target_pos == 0) scan.invocation else prompts.items[target_pos - 1].line;

    var lo = target.line + 1;
    var hi = end;
    while (lo < hi and isBlank(scan.lines[lo])) lo += 1;
    while (hi > lo and isBlank(scan.lines[hi - 1])) hi -= 1;

    const command = commandText(scan.lines[target.line], target.cmd_start);

    if (render) |styled| {
        const styled_lines = try splitCaptureLines(gpa, styled);
        defer gpa.free(styled_lines);
        // Same scrollback rendered twice differs only within lines, never in
        // line structure; if that doesn't hold, fall back to plain lines.
        if (hi <= styled_lines.len) {
            return .{
                .command = command,
                .output = try gpa.dupe([]const u8, styled_lines[lo..hi]),
            };
        }
    }

    return .{
        .command = command,
        .output = try gpa.dupe([]const u8, scan.lines[lo..hi]),
    };
}

/// List the most recent commands, newest first (index 0 is n=1). Caller owns
/// the array; the command slices point into the capture.
pub fn list(gpa: Allocator, capture: []const u8, marker: []const u8, limit: usize) Error![]const []const u8 {
    var scan = try Scan.init(gpa, capture, marker);
    defer scan.deinit(gpa);

    var prompts: std.ArrayList(Boundary) = .empty;
    defer prompts.deinit(gpa);
    try scan.collectPrompts(gpa, &prompts, limit);

    var cmds: std.ArrayList([]const u8) = .empty;
    defer cmds.deinit(gpa);
    for (prompts.items) |b| {
        if (!b.has_cmd) continue;
        try cmds.append(gpa, commandText(scan.lines[b.line], b.cmd_start));
    }
    return try cmds.toOwnedSlice(gpa);
}

const Boundary = struct {
    line: usize,
    cmd_start: usize,
    has_cmd: bool,
};

const Scan = struct {
    lines: [][]const u8,
    /// Index of the line where zhist was invoked.
    invocation: usize,
    /// The current prompt's rendered text (may embed cwd etc.).
    prefix: []const u8,
    /// Last whitespace-separated token of the prefix.
    token: []const u8,
    /// Space-delimited prompt character found in the prefix ("$", "❯", ...).
    prompt_char: []const u8,
    /// Prompt character glued to the end of the prefix (bash's "~$ " style).
    suffix_char: []const u8,

    fn init(gpa: Allocator, capture: []const u8, marker: []const u8) Error!Scan {
        var lines: std.ArrayList([]const u8) = .empty;
        errdefer lines.deinit(gpa);

        var it = std.mem.splitScalar(u8, capture, '\n');
        while (it.next()) |raw| {
            try lines.append(gpa, std.mem.trimEnd(u8, raw, "\r"));
        }
        while (lines.items.len > 0 and isBlank(lines.items[lines.items.len - 1])) {
            _ = lines.pop();
        }

        // The current invocation is the bottom-most line where the marker
        // sits right after a prompt character. A long command line wraps
        // across several capture lines (the shell's line editor defeats
        // tmux's -J rejoining), so continuation segments can also contain
        // the marker — those aren't prompted and only serve as a fallback.
        const LinePos = struct { line: usize, pos: usize };
        const found: LinePos = blk: {
            var fallback: ?LinePos = null;
            var i = lines.items.len;
            while (i > 0) {
                i -= 1;
                if (findMarker(lines.items[i], marker)) |m| {
                    if (m.prompted) break :blk .{ .line = i, .pos = m.pos };
                    if (fallback == null) fallback = .{ .line = i, .pos = m.pos };
                }
            }
            break :blk fallback orelse return Error.MarkerNotFound;
        };

        const prefix = lines.items[found.line][0..found.pos];
        const trimmed = std.mem.trimEnd(u8, prefix, " \t");
        const token = if (std.mem.lastIndexOfScalar(u8, trimmed, ' ')) |sp|
            trimmed[sp + 1 ..]
        else
            trimmed;

        // Right-most prompt char that stands alone in the prefix ("~ $ ").
        var prompt_char: []const u8 = "";
        var best_pos: usize = 0;
        for (prompt_chars) |pc| {
            var i: usize = 0;
            while (std.mem.indexOfPos(u8, prefix, i, pc)) |p| : (i = p + 1) {
                const after = p + pc.len;
                const before_ok = p == 0 or prefix[p - 1] == ' ';
                const after_ok = after == prefix.len or prefix[after] == ' ';
                if (before_ok and after_ok and (prompt_char.len == 0 or p > best_pos)) {
                    prompt_char = pc;
                    best_pos = p;
                }
            }
        }

        // Prompt char glued to the text before it ("user@box:~$ ").
        const suffix_char: []const u8 = for (prompt_chars) |pc| {
            if (std.mem.endsWith(u8, trimmed, pc)) break pc;
        } else "";

        return .{
            .lines = try lines.toOwnedSlice(gpa),
            .invocation = found.line,
            .prefix = prefix,
            .token = token,
            .prompt_char = prompt_char,
            .suffix_char = suffix_char,
        };
    }

    fn deinit(scan: *Scan, gpa: Allocator) void {
        gpa.free(scan.lines);
    }

    /// Walk upward from the invocation collecting prompt lines (newest
    /// first), stopping once `want` of them carry a non-empty command.
    fn collectPrompts(
        scan: *const Scan,
        gpa: Allocator,
        prompts: *std.ArrayList(Boundary),
        want: usize,
    ) Allocator.Error!void {
        var with_cmd: usize = 0;
        var i = scan.invocation;
        while (i > 0 and with_cmd < want) {
            i -= 1;
            const line = scan.lines[i];
            const cs = scan.commandStart(line) orelse continue;
            const has_cmd = commandText(line, cs).len != 0;
            if (has_cmd) with_cmd += 1;
            try prompts.append(gpa, .{ .line = i, .cmd_start = cs, .has_cmd = has_cmd });
        }
    }

    /// If `line` looks like a prompt line, return the offset where the
    /// command begins (== line.len for a prompt with no command).
    fn commandStart(scan: *const Scan, line: []const u8) ?usize {
        if (scan.prefix.len > 0 and std.mem.startsWith(u8, line, scan.prefix)) {
            return scan.prefix.len;
        }
        // An empty prompt renders without the trailing space(s).
        if (std.mem.eql(u8, line, std.mem.trimEnd(u8, scan.prefix, " \t"))) {
            return line.len;
        }
        if (scan.token.len > 0) {
            if (findDelimited(line, scan.token)) |pos| return pos;
        }
        if (scan.prompt_char.len > 0 and !std.mem.eql(u8, scan.prompt_char, scan.token)) {
            if (findDelimited(line, scan.prompt_char)) |pos| return pos;
        }
        // Last resort: prompt char glued to changing text ("user@box:~/b$ ").
        if (scan.suffix_char.len > 0) {
            const sc = scan.suffix_char;
            var i: usize = 0;
            while (std.mem.indexOfPos(u8, line, i, sc)) |p| : (i = p + 1) {
                const after = p + sc.len;
                if (after < line.len and line[after] == ' ') return after + 1;
            }
        }
        return null;
    }
};

fn splitCaptureLines(gpa: Allocator, text: []const u8) Allocator.Error![][]const u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    errdefer lines.deinit(gpa);
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        try lines.append(gpa, std.mem.trimEnd(u8, raw, "\r"));
    }
    return lines.toOwnedSlice(gpa);
}

fn commandText(line: []const u8, cmd_start: usize) []const u8 {
    return std.mem.trim(u8, line[cmd_start..], " \t");
}

fn isBlank(line: []const u8) bool {
    return std.mem.trim(u8, line, " \t").len == 0;
}

const Marker = struct { pos: usize, prompted: bool };

/// Find the occurrence of `marker` in `line` that reads as the start of the
/// invoked command: preceded by start-of-line or a space (or, failing that,
/// a '/' for ./zhist-style invocations) and followed by a space or
/// end-of-line. The first occurrence sitting right after a prompt character
/// wins ("… ❯ zhist"); this keeps the prefix correct when the command line
/// mentions the marker again ("zhist | grep zhist") or chains several
/// invocations. Otherwise fall back to the last plausible occurrence, which
/// handles a cwd whose basename equals the marker ("zhist ❯ zhist").
fn findMarker(line: []const u8, marker: []const u8) ?Marker {
    if (marker.len == 0) return null;
    var best_prompted: ?usize = null;
    var best_word: ?usize = null;
    var best_path: ?usize = null;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, line, i, marker)) |p| : (i = p + 1) {
        const after = p + marker.len;
        if (after != line.len and line[after] != ' ') continue;
        const pre = std.mem.trimEnd(u8, line[0..p], " \t");
        if (p == 0 or line[p - 1] == ' ') {
            if (best_prompted == null and endsWithPromptChar(pre)) best_prompted = p;
            best_word = p;
        } else if (line[p - 1] == '/') {
            if (best_prompted == null and endsWithPromptChar(pre)) best_prompted = p;
            best_path = p;
        }
    }
    if (best_prompted) |p| return .{ .pos = p, .prompted = true };
    const p = best_word orelse best_path orelse return null;
    return .{ .pos = p, .prompted = false };
}

/// Find `needle` preceded by start-of-line or a space and followed by a
/// space (or end-of-line, for an empty prompt); returns the offset where a
/// command would start. Matches the first such occurrence.
fn findDelimited(line: []const u8, needle: []const u8) ?usize {
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, line, i, needle)) |p| : (i = p + 1) {
        const after = p + needle.len;
        const before_ok = p == 0 or line[p - 1] == ' ';
        if (!before_ok) continue;
        if (after == line.len) return line.len;
        if (line[after] == ' ') return after + 1;
    }
    return null;
}

// ---------------------------------------------------------------------------

const t = std.testing;

fn expectExtract(capture: []const u8, n: usize, want_cmd: []const u8, want_out: []const []const u8) !void {
    const e = try extract(t.allocator, capture, "zhist", n);
    defer t.allocator.free(e.output);
    try t.expectEqualStrings(want_cmd, e.command);
    try t.expectEqual(want_out.len, e.output.len);
    for (want_out, e.output) |w, g| try t.expectEqualStrings(w, g);
}

test "simple zsh-style prompt" {
    const cap =
        "~/Code ❯ echo hello\n" ++
        "hello\n" ++
        "~/Code ❯ zhist\n";
    try expectExtract(cap, 1, "echo hello", &.{"hello"});
}

test "multi-line output and n=2" {
    const cap =
        "~ ❯ printf 'a\\nb\\n'\n" ++
        "a\n" ++
        "b\n" ++
        "~ ❯ echo done\n" ++
        "done\n" ++
        "~ ❯ zhist -n 2\n";
    try expectExtract(cap, 2, "printf 'a\\nb\\n'", &.{ "a", "b" });
    try expectExtract(cap, 1, "echo done", &.{"done"});
}

test "invocation piped elsewhere" {
    const cap =
        "~ ❯ ls\n" ++
        "main.zig\n" ++
        "~ ❯ zhist | wl-copy\n";
    try expectExtract(cap, 1, "ls", &.{"main.zig"});
}

test "prompt embeds changing cwd (token fallback)" {
    const cap =
        "user@box ~/a $ echo one\n" ++
        "one\n" ++
        "user@box ~/b $ zhist -n 1\n";
    // Exact prefix "user@box ~/b $ " doesn't match the earlier line;
    // the "$"-token fallback must find it.
    try expectExtract(cap, 1, "echo one", &.{"one"});
}

test "bash default prompt, glued $ and changing cwd" {
    const cap =
        "user@box:~/a$ echo one\n" ++
        "one\n" ++
        "user@box:~/b$ zhist\n";
    try expectExtract(cap, 1, "echo one", &.{"one"});
}

test "cwd basename equals marker" {
    const cap =
        "zhist ❯ ls\n" ++
        "build.zig\n" ++
        "zhist ❯ zhist\n";
    try expectExtract(cap, 1, "ls", &.{"build.zig"});
}

test "./ invocation" {
    const cap =
        "~ $ echo hi\n" ++
        "hi\n" ++
        "~ $ ./zig-out/bin/zhist\n";
    try expectExtract(cap, 1, "echo hi", &.{"hi"});
}

test "blank lines around output are trimmed" {
    const cap =
        "~ ❯ echo hi\n" ++
        "\n" ++
        "hi\n" ++
        "\n" ++
        "~ ❯ zhist\n" ++
        "\n\n";
    try expectExtract(cap, 1, "echo hi", &.{"hi"});
}

test "empty prompts are skipped" {
    const cap =
        "~ ❯ echo hi\n" ++
        "hi\n" ++
        "~ ❯\n" ++
        "~ ❯ \n" ++
        "~ ❯ zhist\n";
    try expectExtract(cap, 1, "echo hi", &.{"hi"});
}

test "several zhist invocations chained on one line" {
    const cap =
        "~ ❯ ls\n" ++
        "main.zig\n" ++
        "~ ❯ zhist -c > /tmp/a.txt; zhist -n 1 > /tmp/b.txt; zhist | tr a-z A-Z\n";
    try expectExtract(cap, 1, "ls", &.{"main.zig"});
}

test "invocation wraps across capture lines, marker on continuation" {
    // The shell's line editor defeats tmux -J joining, so a long invocation
    // appears as several capture lines; later segments may contain the
    // marker but are not prompted.
    const cap =
        "~ ❯ ls\n" ++
        "main.zig\n" ++
        "~ ❯ zhist -c > /tmp/some/long/path/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n" ++
        "b/out2.txt; zhist -n 1 > /tmp/b.txt; zhist | tr a-z A-Z\n";
    try expectExtract(cap, 1, "ls", &.{"main.zig"});
}

test "marker repeated in arguments" {
    const cap =
        "~ ❯ ls\n" ++
        "main.zig\n" ++
        "~ ❯ zhist | grep zhist\n";
    try expectExtract(cap, 1, "ls", &.{"main.zig"});
}

test "marker not found" {
    try t.expectError(Error.MarkerNotFound, extract(t.allocator, "no such thing\n", "zhist", 1));
}

test "not enough history" {
    const cap = "~ ❯ zhist -n 5\n";
    try t.expectError(Error.NotEnoughHistory, extract(t.allocator, cap, "zhist", 5));
}

test "list commands" {
    const cap =
        "~ ❯ echo one\n" ++
        "one\n" ++
        "~ ❯ echo two\n" ++
        "two\n" ++
        "~ ❯ zhist -l\n";
    const cmds = try list(t.allocator, cap, "zhist", 10);
    defer t.allocator.free(cmds);
    try t.expectEqual(@as(usize, 2), cmds.len);
    try t.expectEqualStrings("echo two", cmds[0]);
    try t.expectEqualStrings("echo one", cmds[1]);
}
