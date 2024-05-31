const std = @import("std");
const zap = @import("zap");
const mem = std.mem;
const fmt = std.fmt;
const ArrayList = std.ArrayList;

const Team = struct {
    const Self = @This();

    allocator: mem.Allocator,
    name: []const u8,
    packages: std.ArrayList([]const u8),

    pub fn init(allocator: mem.Allocator, name: []const u8) Self {
        return .{
            .allocator = allocator,
            .name = allocator.dupe(u8, name) catch "",
            .packages = ArrayList([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.name);
        for (self.packages.items) |p| {
            self.allocator.free(p);
        }
        self.packages.deinit();
    }

    pub fn addPackage(self: *Self, package: []const u8) !void {
        try self.packages.append(try self.allocator.dupe(u8, package));
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
        return Self{
            .allocator = allocator,
            .teams = ArrayList(Team).init(allocator),
        };
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
        const allocator = self.allocator;
        const buf = allocator.alloc(u8, 1_000_000) catch return;
        defer allocator.free(buf);

        var teams = std.ArrayList(Team).init(allocator);
        var dir = std.fs.cwd().openDir("packages", .{ .iterate = true }) catch {
            teams.deinit();
            return;
            };
        var iter = dir.iterate();
        while (iter.next() catch null) |entry| {
            var file = dir.openFile(entry.name, .{}) catch continue;
            defer file.close();
            var team = Team.init(allocator, entry.name);
            const len = std.fs.File.readAll(file, buf) catch continue;
            var lines = mem.tokenize(u8, buf[0..len], "\n");
            while (lines.next()) |line| {
                team.addPackage(line) catch break;
            }
            teams.append(team) catch break;
        }
        var old = self.teams;
        self.teams = teams;
        deinit_teams(&old);
    }

    pub fn on_request(self: *Self, r: zap.Request) void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        r.parseQuery();
        if (r.getParamStr(allocator, "q", false)) |maybe_str| {
            if (maybe_str) |*s| {
                const the_query = s.str;
                var output = ArrayList(u8).init(allocator);
                var writer = output.writer();
                writer.print("<html><body><h1>", .{}) catch return;
                var iter = mem.splitScalar(u8, the_query, '\n');
                while (iter.next()) |element| {
                    const package = get_package_name(element);
                    writer.print("{s} -- ", .{package}) catch return;
                    for (self.teams.items) |t| {
                        if (t.containsPackage(package)) {
                            writer.print("<a href=''>{s}</a>&nbsp;", .{t.name}) catch return;
                        }
                    }
                    writer.print("<br>", .{}) catch return;
                }
                writer.print("</h1></body></html>", .{}) catch return;
                r.sendBody(output.items) catch return;
            } else {
                r.sendBody("<html><body><h1>Hello!</h1></body></html>") catch return;
            }
        } else |err| {
            std.log.err("cannot check for `q` param: {any}\n", .{err});
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
        handler.refresh();
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
