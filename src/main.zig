const std = @import("std");
const zap = @import("zap");
const mem = std.mem;
const fmt = std.fmt;
const ArrayList = std.ArrayList;

const Team = struct {
    const Self = @This();

    allocator: mem.Allocator,
    name: []const u8,
    cache: std.ArrayList([]const u8),
    packages: std.ArrayList([]const u8),

    pub fn init(allocator: mem.Allocator, name: []const u8) Self {
        return .{
            .allocator = allocator,
            .name = allocator.dupe(u8, name) catch "",
            .cache = ArrayList([]const u8).init(allocator),
            .packages = ArrayList([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.packages.deinit();
        for (self.cache.items) |c| {
            self.allocator.free(c);
        }
        self.cache.deinit();
    }

    pub fn readFile(self: *Self, file: std.fs.File) []const u8 {
        const content = std.fs.File.readToEndAlloc(file, self.allocator, @as(usize, 1_000_000)) catch return "";
        self.cache.append(content) catch return content;
        return content;
    }

    pub fn containsPackage(self: *const Self, package: []const u8) bool {
        for (self.packages.items) |p| {
            if (mem.startsWith(u8, package, p)) {
                return true;
            }
        }
        return false;
    }
};
pub const Handler = struct {
    const Self = @This();

    allocator: mem.Allocator,
    teams: std.ArrayList(Team),

    pub fn init(allocator: mem.Allocator) Self {
        var self = Self{
            .allocator = allocator,
            .teams = ArrayList(Team).init(allocator),
        };
        self.refresh();
        return self;
    }

    fn deinit_teams(teams: *ArrayList(Team)) void {
        for (teams.items) |*t| {
            t.deinit();
        }
        teams.deinit();
    }

    pub fn deinit(self: *Self) void {
        deinit_teams(&self.teams);
    }

    pub fn refresh(self: *Self) void {
        var teams = std.ArrayList(Team).init(self.allocator);
        var dir = std.fs.cwd().openDir("packages", .{ .iterate = true }) catch return;
        var iter = dir.iterate();
        while (iter.next() catch return) |entry| {
            var file = dir.openFile(entry.name, .{}) catch continue;
            defer file.close();
            var team = Team.init(self.allocator, entry.name);
            const content = team.readFile(file);
            var lines = mem.tokenize(u8, content, "\n");
            while (lines.next()) |line| {
                team.packages.append(line) catch break;
            }
            teams.append(team) catch break;
        }
        var old = self.teams;
        self.teams = teams;
        deinit_teams(&old);
    }

    pub fn on_request(self: *Self, r: zap.Request) void {
        if (r.getParamSlice("q")) |the_query| {
            const allocator = self.allocator;

            var elements = std.ArrayList([]const u8).init(allocator);
            defer {
                for (elements.items) |e| {
                    allocator.free(e);
                }
                elements.deinit();
            }

            var iter = mem.splitScalar(u8, the_query, '\n');
            while (iter.next()) |element| {
                const package = get_package_name(element);
                var teams = std.ArrayList([]const u8).init(allocator);
                defer {
                    for (teams.items) |s| {
                        allocator.free(s);
                    }
                    teams.deinit();
                }

                for (self.teams.items) |t| {
                    if (t.containsPackage(package)) {
                        teams.append(fmt.allocPrint(allocator, "<a href=''>{s}</a>", .{t.name}) catch break) catch break;
                    }
                }
                elements.append(fmt.allocPrint(allocator, "{s} -- {s}", .{ package, mem.join(allocator, "", teams.items) catch "" }) catch break) catch break;
            }
            const output = mem.join(allocator, "\n", elements.items) catch "OOM";
            defer allocator.free(output);
            const body = fmt.allocPrint(allocator, "<html><body><h1>{s}</h1></body></html>", .{output}) catch return;
            defer allocator.free(body);
            r.sendBody(body) catch return;
        } else {
            r.sendBody("<html><body><h1>Hello!</h1></body></html>") catch return;
        }
    }
};

fn not_found(req: zap.Request) void {
    std.debug.print("not found handler", .{});

    req.sendBody("Not found") catch return;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer std.debug.assert(gpa.deinit() == .ok);

    {
        var router = zap.Router.init(allocator, .{
            .not_found = not_found,
        });
        defer router.deinit();

        var handler = Handler.init(allocator);
        defer handler.deinit();
        try router.handle_func("/", &handler, &Handler.on_request);
        try router.handle_func("/init", &handler, &Handler.refresh);

        var listener = zap.HttpListener.init(.{
            .port = 9000,
            .on_request = router.on_request_handler(),
            .log = true,
        });
        try listener.listen();

        std.debug.print("Listening on 0.0.0.0:9000\n", .{});

        // start worker threads
        zap.start(.{
            .threads = 2,
            .workers = 1,
        });
    }
}

fn get_package_name(trace: []const u8) []const u8 {
    var package = trace;
    if (mem.indexOfScalar(u8, trace, '(')) |i| {
        var j: usize = i;
        for (0..2) |_| {
            j = mem.lastIndexOfScalar(u8, trace[0..j], '.') orelse break;
        }
        package = trace[0..j];
    }
    return package;
}

test "test package name extraction" {
    try std.testing.expectEqualStrings("a.b.class.method", get_package_name("a.b.class.method"));
    try std.testing.expectEqualStrings("a.b", get_package_name("a.b.class.method(file:line)"));
}
