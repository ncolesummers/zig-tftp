const std = @import("std");
const tftp = @import("root.zig");

/// Manages the state of a Read Request (RRQ) transfer (Server sending to Client).
pub const ReadTransfer = struct {
    file: std.fs.File,
    block_num: u16,
    buffer: [512]u8,
    last_read_size: usize,
    buffer_valid: bool,
    eof_reached: bool,
    finished: bool,

    pub fn init(dir: std.fs.Dir, filename: []const u8) !ReadTransfer {
        const file = try dir.openFile(filename, .{});
        return ReadTransfer{
            .file = file,
            .block_num = 1,
            .buffer = undefined,
            .last_read_size = 0,
            .buffer_valid = false,
            .eof_reached = false,
            .finished = false,
        };
    }

    pub fn deinit(self: *ReadTransfer) void {
        self.file.close();
    }

    /// Generates the next DATA packet to send.
    /// Returns the Packet union, or null if transfer is done (and acknowledged).
    /// Note: The returned Packet contains a slice to `self.buffer`, so it's only valid until next call.
    pub fn nextPacket(self: *ReadTransfer) !?tftp.Packet {
        if (self.finished) return null;

        if (!self.buffer_valid) {
            const bytes_read = try self.file.read(&self.buffer);
            self.last_read_size = bytes_read;
            self.buffer_valid = true;
            if (bytes_read < 512) {
                self.eof_reached = true;
            }
        }

        return tftp.Packet{
            .data = .{
                .block_num = self.block_num,
                .data = self.buffer[0..self.last_read_size],
            },
        };
    }

    /// Handles an ACK from the client.
    /// Returns true if the ACK was valid and advanced the state, false otherwise.
    pub fn handleAck(self: *ReadTransfer, block_num: u16) bool {
        if (block_num == self.block_num) {
            if (self.eof_reached) {
                self.finished = true;
            } else {
                self.block_num += 1;
                self.buffer_valid = false;
            }
            return true;
        }
        return false;
    }
};

/// Manages the state of a Write Request (WRQ) transfer (Client sending to Server).
pub const WriteTransfer = struct {
    file: std.fs.File,
    expected_block: u16,
    finished: bool,

    pub fn init(dir: std.fs.Dir, filename: []const u8) !WriteTransfer {
        // Create new file.
        const file = try dir.createFile(filename, .{});
        return WriteTransfer{
            .file = file,
            .expected_block = 1,
            .finished = false,
        };
    }

    pub fn deinit(self: *WriteTransfer) void {
        self.file.close();
    }

    /// Handles a received DATA packet.
    /// Returns the ACK packet to send back, or null if the packet should be ignored (e.g. out of order).
    /// Returns error if write fails.
    pub fn handleDataPacket(self: *WriteTransfer, packet: tftp.Packet.Data) !?tftp.Packet {
        if (packet.block_num == self.expected_block) {
            try self.file.writeAll(packet.data);
            if (packet.data.len < 512) {
                self.finished = true;
            }
            self.expected_block += 1;
            return tftp.Packet{ .ack = .{ .block_num = packet.block_num } };
        } else if (packet.block_num < self.expected_block) {
            // Duplicate packet, re-send ACK
            return tftp.Packet{ .ack = .{ .block_num = packet.block_num } };
        }
        // Future block, ignore
        return null;
    }
};

test "ReadTransfer: simple flow" {
    const testing = std.testing;
    
    // Setup: Create a dummy file
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    
    const payload = "Hello TFTP World";
    try tmp.dir.writeFile(.{ .sub_path = "test_read.txt", .data = payload });

    // Initialize Transfer
    var transfer = try ReadTransfer.init(tmp.dir, "test_read.txt");
    defer transfer.deinit();

    // Step 1: Get first DATA packet
    const pkt1 = (try transfer.nextPacket()) orelse return error.UnexpectedEnd;
    
    try testing.expectEqual(tftp.Opcode.data, std.meta.activeTag(pkt1));
    try testing.expectEqual(@as(u16, 1), pkt1.data.block_num);
    try testing.expectEqualStrings(payload, pkt1.data.data);

    // Step 2: Receive ACK for Block 1
    const accepted = transfer.handleAck(1);
    try testing.expect(accepted);

    // Step 3: Get next packet (should be done)
    const pkt2 = try transfer.nextPacket();
    try testing.expect(pkt2 == null);
}

test "WriteTransfer: simple flow" {
    const testing = std.testing;
    
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var transfer = try WriteTransfer.init(tmp.dir, "upload.txt");
    // defer transfer.deinit(); // Removed to avoid double close, we call it explicitly below

    // receive Block 1 (Full 512 bytes)
    const big_data = try testing.allocator.alloc(u8, 512);
    defer testing.allocator.free(big_data);
    @memset(big_data, 'A');
    
    const data1 = tftp.Packet.Data{ .block_num = 1, .data = big_data };
    const ack1 = (try transfer.handleDataPacket(data1)) orelse return error.NoAck;
    
    try testing.expectEqual(tftp.Opcode.ack, std.meta.activeTag(ack1));
    try testing.expectEqual(@as(u16, 1), ack1.ack.block_num);
    try testing.expectEqual(false, transfer.finished);

    // receive Block 2 (Final)
    const data2 = tftp.Packet.Data{ .block_num = 2, .data = "End" };
    const ack2 = (try transfer.handleDataPacket(data2)) orelse return error.NoAck;
    
    try testing.expectEqual(@as(u16, 2), ack2.ack.block_num);
    try testing.expectEqual(true, transfer.finished);
    
    // Verify file content
    transfer.deinit(); // Flush/Close explicitly to ensure write to disk
    // Note: deinit closes the file handle.
    
    const content = try tmp.dir.readFileAlloc(testing.allocator, "upload.txt", 1024);
    defer testing.allocator.free(content);
    
    try testing.expect(content.len == 512 + 3);
    try testing.expectEqualSlices(u8, big_data, content[0..512]);
    try testing.expectEqualStrings("End", content[512..]);
}
