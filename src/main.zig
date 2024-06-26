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
    links: std.StringHashMap([]const u8),
    lock: std.Thread.Mutex = .{},

    pub fn init(allocator: mem.Allocator) Self {
        return Self{
            .allocator = allocator,
            .teams = ArrayList(Team).init(allocator),
            .links = std.StringHashMap([]const u8).init(allocator),
        };
    }

    fn deinit_teams(_: *Self, teams: *ArrayList(Team)) void {
        for (teams.items) |*t| {
            t.deinit();
        }
        teams.deinit();
    }

    fn deinit_links(self: *Self, links: *std.StringHashMap([]const u8)) void {
        var links_iter = links.iterator();
        while (links_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        links.deinit();
    }

    pub fn deinit(self: *Self) void {
        self.deinit_teams(&self.teams);
        self.deinit_links(&self.links);
    }

    pub fn fetchTeams(self: *Self) void {
        if (!self.lock.tryLock()) return;
        defer self.lock.unlock();

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
        self.deinit_teams(&old);

        var links = std.StringHashMap([]const u8).init(allocator);
        var properties = std.fs.cwd().openFile("teams.properties", .{}) catch {
            links.deinit();
            return;
        };
        defer properties.close();
        if (std.fs.File.readAll(properties, buf) catch null) |len| {
            var lines = mem.tokenize(u8, buf[0..len], "\n");
            while (lines.next()) |line| {
                if (mem.indexOfScalar(u8, line, '=')) |i| {
                    links.put(std.ascii.allocLowerString(allocator, line[0..i]) catch break, allocator.dupe(u8, line[i + 1 ..]) catch break) catch continue;
                }
            }
        }

        var old_links = self.links;
        self.links = links;
        self.deinit_links(&old_links);
    }

    pub fn onRefresh(self: *Self, r: zap.Request) void {
        self.fetchTeams();
        r.sendBody("Teams are refreshed!") catch return;
    }

    pub fn onRequest(self: *Self, r: zap.Request) void {
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
                var buf: [1024]u8 = undefined;
                while (iter.next()) |element| {
                    const package = getPackageName(element);
                    writer.print("{s} -- ", .{package}) catch return;
                    for (self.teams.items) |t| {
                        if (t.containsPackage(package)) {
                            const name = std.ascii.lowerString(&buf, t.name);
                            const link = self.links.get(name) orelse "";
                            writer.print("<a href='{s}' target='_blank'>{s}</a>&nbsp;", .{ link, t.name }) catch return;
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

fn notFound(req: zap.Request) void {
    std.debug.print("not found handler for {s}", .{req.path orelse ""});

    req.sendBody("Not found") catch return;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer std.debug.assert(gpa.deinit() == .ok);

    {
        var router = zap.Router.init(allocator, .{
            .not_found = notFound,
        });
        defer router.deinit();

        var handler = Handler.init(allocator);
        defer handler.deinit();
        handler.fetchTeams();
        try router.handle_func("/", &handler, &Handler.onRequest);
        try router.handle_func("/init", &handler, &Handler.onRefresh);

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
            .workers = 2,
        });
    }
}

fn getPackageName(trace: []const u8) []const u8 {
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
    try std.testing.expectEqualStrings("a.b.class.method", getPackageName("a.b.class.method"));
    try std.testing.expectEqualStrings("a.b", getPackageName("a.b.class.method(file:line)"));
}
