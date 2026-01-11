const std = @import("std");
const tftp = @import("root.zig");

pub fn main() !void {
    // 1. Setup Allocator
    // Zig requires explicit memory management. We use the GeneralPurposeAllocator
    // which is great for catching memory leaks during development.
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 2. Configuration
    // We default to port 6969 to avoid needing 'sudo' (privileged ports < 1024).
    const port = 6969;
    const root_dir = ".";

    std.debug.print("Starting TFTP Server...\n", .{});
    std.debug.print("  > Port: {d}\n", .{port});
    std.debug.print("  > Root: {s}\n", .{root_dir});
    std.debug.print("  > Mode: Octet & NetASCII\n\n", .{});
    std.debug.print("Use a TFTP client to connect:\n", .{});
    std.debug.print("  $ tftp 127.0.0.1 {d}\n", .{port});
    std.debug.print("  tftp> binary\n", .{});
    std.debug.print("  tftp> get filename.txt\n\n", .{});

    // 3. Initialize Server
    // We pass the allocator so the server can manage its own memory for
    // request threads and buffers.
    var server = tftp.Server.init(allocator, root_dir);

    // 4. Start Server
    // This blocks the main thread forever (until stopped).
    try server.start(port);
}