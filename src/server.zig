const std = @import("std");
const tftp = @import("root.zig");

pub const Server = struct {
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    running: std.atomic.Value(bool),

    pub fn init(allocator: std.mem.Allocator, root_dir: []const u8) Server {
        return .{
            .allocator = allocator,
            .root_dir = root_dir,
            .running = std.atomic.Value(bool).init(true),
        };
    }

    pub fn stop(self: *Server) void {
        self.running.store(false, .release);
    }

    /// Starts the TFTP server on the specified port.
    /// This function blocks.
    pub fn start(self: *Server, port: u16) !void {
        const address = try std.net.Address.parseIp("0.0.0.0", port);

        // Create a UDP socket
        const sockfd = try std.posix.socket(address.any.family, std.posix.SOCK.DGRAM, std.posix.IPPROTO.UDP);
        defer std.posix.close(sockfd);

        // Set Receive Timeout to 100ms so we can check `running` flag frequently
        const timeo = std.posix.timeval{
            .sec = 0,
            .usec = 100 * 1000,
        };
        try std.posix.setsockopt(sockfd, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, &std.mem.toBytes(timeo));

        // Bind to the address
        try std.posix.bind(sockfd, &address.any, address.getOsSockLen());

        std.log.info("TFTP Server listening on 0.0.0.0:{d}\n", .{port});

        var buf: [1024]u8 = undefined;

        while (self.running.load(.acquire)) {
            var src_addr: std.net.Address = undefined;
            var src_addr_len: std.posix.socklen_t = @sizeOf(std.net.Address);

            // Receive data
            const len = std.posix.recvfrom(
                sockfd,
                &buf,
                0,
                &src_addr.any,
                &src_addr_len,
            ) catch |err| {
                if (err == error.WouldBlock) {
                    continue; // Timeout, check running flag
                }
                return err;
            };

            // Create a slice of the received data
            const received_data = buf[0..len];

            // Handle the packet (log errors but don't crash the server)
            self.handlePacket(received_data, src_addr) catch |err| {
                std.log.err("Error handling packet from {any}: {}", .{ src_addr, err });
            };
        }
    }

    fn handlePacket(self: *Server, data: []const u8, src: std.net.Address) !void {
        const packet = try tftp.Packet.parse(data);

        switch (packet) {
            .rrq => |req| {
                std.log.info("RRQ from {any}: file='{s}', mode={s}\n", .{ src, req.filename, req.mode.toString() });

                // Duplicate filename and resolve path
                const path = try std.fs.path.join(self.allocator, &.{ self.root_dir, req.filename });
                // We pass ownership of `path` to the thread

                const thread = try std.Thread.spawn(.{}, handleReadSession, .{ self.allocator, path, src });
                thread.detach();
            },
            .wrq => |req| {
                std.log.info("WRQ from {any}: file='{s}', mode={s}\n", .{ src, req.filename, req.mode.toString() });
                const path = try std.fs.path.join(self.allocator, &.{ self.root_dir, req.filename });
                const thread = try std.Thread.spawn(.{}, handleWriteSession, .{ self.allocator, path, src });
                thread.detach();
            },
            else => {
                std.log.info("Unexpected packet type from {any}: {}\n", .{ src, packet });
                try self.sendError(src, .illegal_operation, "Unexpected packet type\n");
            },
        }
    }

    fn sendError(self: *Server, dest: std.net.Address, code: tftp.ErrorCode, msg: []const u8) !void {
        _ = self;
        var buf: [516]u8 = undefined;
        const pkt = tftp.Packet{ .err = .{ .code = code, .msg = msg } };
        const len = try pkt.serialize(&buf);

        const sockfd = try std.posix.socket(dest.any.family, std.posix.SOCK.DGRAM, std.posix.IPPROTO.UDP);
        defer std.posix.close(sockfd);

        _ = try std.posix.sendto(sockfd, buf[0..len], 0, &dest.any, dest.getOsSockLen());
    }
};

fn handleReadSession(allocator: std.mem.Allocator, full_path: []const u8, client_addr: std.net.Address) !void {
    // ... existing implementation ...
    defer allocator.free(full_path);

    // 1. Open socket (Ephemeral)
    const sockfd = try std.posix.socket(client_addr.any.family, std.posix.SOCK.DGRAM, std.posix.IPPROTO.UDP);
    defer std.posix.close(sockfd);

    const bind_addr = if (client_addr.any.family == std.posix.AF.INET)
        try std.net.Address.parseIp("0.0.0.0", 0)
    else
        try std.net.Address.parseIp("::", 0);

    try std.posix.bind(sockfd, &bind_addr.any, bind_addr.getOsSockLen());

    // Set timeout
    const timeo = std.posix.timeval{ .sec = 2, .usec = 0 };
    try std.posix.setsockopt(sockfd, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, &std.mem.toBytes(timeo));

    // 2. Init Transfer
    var transfer = tftp.Transfer.ReadTransfer.init(std.fs.cwd(), full_path) catch |err| {
        std.log.err("Failed to open file '{s}': {}\n", .{ full_path, err });
        var err_buf: [512]u8 = undefined;
        const err_pkt = tftp.Packet{ .err = .{ .code = .file_not_found, .msg = "File not found" } };
        const len = try err_pkt.serialize(&err_buf);
        _ = std.posix.sendto(sockfd, err_buf[0..len], 0, &client_addr.any, client_addr.getOsSockLen()) catch {};
        return;
    };
    defer transfer.deinit();

    // 3. Loop
    var send_buf: [516]u8 = undefined;
    var recv_buf: [516]u8 = undefined;

    while (true) {
        // Get packet to send
        const pkt = try transfer.nextPacket();
        if (pkt == null) {
            std.log.info("Transfer finished for {any}\n", .{client_addr});
            break;
        }

        // Serialize
        const len = try pkt.?.serialize(&send_buf);

        // Send
        _ = try std.posix.sendto(sockfd, send_buf[0..len], 0, &client_addr.any, client_addr.getOsSockLen());

        // Wait for ACK
        var src: std.net.Address = undefined;
        var src_len: std.posix.socklen_t = @sizeOf(std.net.Address);

        const rlen = std.posix.recvfrom(sockfd, &recv_buf, 0, &src.any, &src_len) catch |err| {
            if (err == error.WouldBlock) {
                std.log.warn("Timeout waiting for ACK from {any}, retransmitting...\n", .{client_addr});
                continue;
            }
            return err;
        };

        const recv_pkt = tftp.Packet.parse(recv_buf[0..rlen]) catch continue;

        switch (recv_pkt) {
            .ack => |ack| {
                if (transfer.handleAck(ack.block_num)) {
                    // Advanced.
                }
            },
            .err => {
                std.log.err("Received ERROR from {any}: {s}\n", .{ client_addr, recv_pkt.err.msg });
                return;
            },
            else => {},
        }
    }
}

fn handleWriteSession(allocator: std.mem.Allocator, full_path: []const u8, client_addr: std.net.Address) !void {
    defer allocator.free(full_path);

    const sockfd = try std.posix.socket(client_addr.any.family, std.posix.SOCK.DGRAM, std.posix.IPPROTO.UDP);
    defer std.posix.close(sockfd);

    const bind_addr = if (client_addr.any.family == std.posix.AF.INET)
        try std.net.Address.parseIp("0.0.0.0", 0)
    else
        try std.net.Address.parseIp("::", 0);

    try std.posix.bind(sockfd, &bind_addr.any, bind_addr.getOsSockLen());

    const timeo = std.posix.timeval{ .sec = 2, .usec = 0 };
    try std.posix.setsockopt(sockfd, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, &std.mem.toBytes(timeo));

    var transfer = tftp.Transfer.WriteTransfer.init(std.fs.cwd(), full_path) catch |err| {
        std.log.err("Failed to create file '{s}': {}\n", .{ full_path, err });
        var err_buf: [512]u8 = undefined;
        const err_pkt = tftp.Packet{ .err = .{ .code = .access_violation, .msg = "Could not create file" } };
        const len = try err_pkt.serialize(&err_buf);
        _ = std.posix.sendto(sockfd, err_buf[0..len], 0, &client_addr.any, client_addr.getOsSockLen()) catch {};
        return;
    };
    defer transfer.deinit();

    // Ack 0 to start
    var send_buf: [516]u8 = undefined;
    var recv_buf: [516]u8 = undefined;

    const ack0 = tftp.Packet{ .ack = .{ .block_num = 0 } };
    var len = try ack0.serialize(&send_buf);
    _ = try std.posix.sendto(sockfd, send_buf[0..len], 0, &client_addr.any, client_addr.getOsSockLen());

    while (!transfer.finished) {
        var src: std.net.Address = undefined;
        var src_len: std.posix.socklen_t = @sizeOf(std.net.Address);

        const rlen = std.posix.recvfrom(sockfd, &recv_buf, 0, &src.any, &src_len) catch |err| {
            if (err == error.WouldBlock) {
                // Timeout, retransmit last ACK?
                // Yes, if we are waiting for DATA N, and we get timeout, we retransmit ACK N-1.
                // In this loop, `send_buf` contains the last ACK we sent.
                std.log.warn("Timeout waiting for DATA from {any}, retransmitting last ACK...\n", .{client_addr});
                _ = try std.posix.sendto(sockfd, send_buf[0..len], 0, &client_addr.any, client_addr.getOsSockLen());
                continue;
            }
            return err;
        };

        const recv_pkt = tftp.Packet.parse(recv_buf[0..rlen]) catch continue;

        switch (recv_pkt) {
            .data => |d| {
                if (try transfer.handleDataPacket(d)) |ack| {
                    len = try ack.serialize(&send_buf);
                    _ = try std.posix.sendto(sockfd, send_buf[0..len], 0, &client_addr.any, client_addr.getOsSockLen());
                }
            },
            .err => {
                std.log.err("Received ERROR from {any}: {s}\n   ", .{ client_addr, recv_pkt.err.msg });
                return;
            },
            else => {},
        }
    }
    std.log.info("Write Transfer finished for {any}\n", .{client_addr});
}

test "Server integration: WRQ full transfer" {
    const testing = std.testing;
    const Port = 9071;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(tmp_path);

    var server = Server.init(testing.allocator, tmp_path);
    const server_thread = try std.Thread.spawn(.{}, Server.start, .{ &server, Port });
    std.posix.nanosleep(0, 100 * 1000 * 1000);

    const client_socket = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.DGRAM, std.posix.IPPROTO.UDP);
    defer std.posix.close(client_socket);

    const timeo = std.posix.timeval{ .sec = 1, .usec = 0 };
    try std.posix.setsockopt(client_socket, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, &std.mem.toBytes(timeo));
    const dest_addr = try std.net.Address.parseIp("127.0.0.1", Port);

    // Send WRQ
    const wrq = tftp.Packet{ .wrq = .{ .filename = "uploaded.txt", .mode = .octet } };
    var send_buf: [512]u8 = undefined;
    var len = try wrq.serialize(&send_buf);
    _ = try std.posix.sendto(client_socket, send_buf[0..len], 0, &dest_addr.any, dest_addr.getOsSockLen());

    // Receive ACK 0
    var recv_buf: [516]u8 = undefined;
    var src_addr: std.net.Address = undefined;
    var src_len: std.posix.socklen_t = @sizeOf(std.net.Address);

    var rlen = try std.posix.recvfrom(client_socket, &recv_buf, 0, &src_addr.any, &src_len);
    var pkt = try tftp.Packet.parse(recv_buf[0..rlen]);

    try testing.expectEqual(tftp.Opcode.ack, std.meta.activeTag(pkt));
    try testing.expectEqual(@as(u16, 0), pkt.ack.block_num);

    // Send DATA 1
    const data1 = tftp.Packet{ .data = .{ .block_num = 1, .data = "Payload" } };
    len = try data1.serialize(&send_buf);
    // Send to NEW port
    _ = try std.posix.sendto(client_socket, send_buf[0..len], 0, &src_addr.any, src_len);

    // Receive ACK 1
    rlen = try std.posix.recvfrom(client_socket, &recv_buf, 0, &src_addr.any, &src_len);
    pkt = try tftp.Packet.parse(recv_buf[0..rlen]);

    try testing.expectEqual(tftp.Opcode.ack, std.meta.activeTag(pkt));
    try testing.expectEqual(@as(u16, 1), pkt.ack.block_num);

    // Cleanup
    server.stop();
    server_thread.join();

    // Check file exists
    const content = try tmp.dir.readFileAlloc(testing.allocator, "uploaded.txt", 1024);
    defer testing.allocator.free(content);
    try testing.expectEqualStrings("Payload", content);
}

test "Server integration: RRQ full transfer" {
    const testing = std.testing;
    const Port = 9070; // Use different port

    // Create dummy file
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "foo.txt", .data = "Hello TFTP World!" });

    // We need absolute path for the server because it uses std.fs.cwd() in handleReadSession
    // Actually, `tmp.dir` is a handle. `handleReadSession` uses `std.fs.cwd()`.
    // This is a bit disjointed. `Server` takes `root_dir` as string.
    // Ideally `handleReadSession` should use an `fs.Dir` handle, but we can't easily pass that across threads safely/easily without cloning.
    // Best way for test: Get absolute path of tmp dir.
    const tmp_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(tmp_path);

    var server = Server.init(testing.allocator, tmp_path);

    const server_thread = try std.Thread.spawn(.{}, Server.start, .{ &server, Port });

    // Give server a moment to start
    std.posix.nanosleep(0, 100 * 1000 * 1000);

    // Client Setup
    const client_socket = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.DGRAM, std.posix.IPPROTO.UDP);
    defer std.posix.close(client_socket);

    const timeo = std.posix.timeval{ .sec = 1, .usec = 0 };
    try std.posix.setsockopt(client_socket, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, &std.mem.toBytes(timeo));

    const dest_addr = try std.net.Address.parseIp("127.0.0.1", Port);

    // Send RRQ
    const rrq = tftp.Packet{ .rrq = .{ .filename = "foo.txt", .mode = .octet } };
    var send_buf: [512]u8 = undefined;
    const send_len = try rrq.serialize(&send_buf);
    _ = try std.posix.sendto(client_socket, send_buf[0..send_len], 0, &dest_addr.any, dest_addr.getOsSockLen());

    // Receive DATA Block 1
    var recv_buf: [516]u8 = undefined;
    var src_addr: std.net.Address = undefined;
    var src_len: std.posix.socklen_t = @sizeOf(std.net.Address);

    const len = try std.posix.recvfrom(client_socket, &recv_buf, 0, &src_addr.any, &src_len);
    const pkt = try tftp.Packet.parse(recv_buf[0..len]);

    try testing.expectEqual(tftp.Opcode.data, std.meta.activeTag(pkt));
    try testing.expectEqual(@as(u16, 1), pkt.data.block_num);
    try testing.expectEqualStrings("Hello TFTP World!", pkt.data.data);

    // Send ACK 1
    const ack = tftp.Packet{ .ack = .{ .block_num = 1 } };
    const ack_len = try ack.serialize(&send_buf);
    // Send ACK to the NEW port (src_addr), not Port 69!
    _ = try std.posix.sendto(client_socket, send_buf[0..ack_len], 0, &src_addr.any, src_len);

    // Cleanup
    server.stop();
    server_thread.join();
}
