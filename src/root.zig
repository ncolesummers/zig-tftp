const std = @import("std");
const mem = std.mem;
const testing = std.testing;

pub const Server = @import("server.zig").Server;
pub const Transfer = @import("transfer.zig");


/// TFTP Opcodes as defined in RFC 1350.
/// We use u16 because the opcode on the wire is 2 bytes.
pub const Opcode = enum(u16) {
    rrq = 1,
    wrq = 2,
    data = 3,
    ack = 4,
    err = 5,
};

/// TFTP Error Codes.
pub const ErrorCode = enum(u16) {
    not_defined = 0,
    file_not_found = 1,
    access_violation = 2,
    disk_full = 3,
    illegal_operation = 4,
    unknown_transfer_id = 5,
    file_already_exists = 6,
    no_such_user = 7,
};

/// Transfer modes.
pub const Mode = enum {
    netascii,
    octet,
    mail,

    pub fn fromString(s: []const u8) ?Mode {
        if (std.ascii.eqlIgnoreCase(s, "netascii")) return .netascii;
        if (std.ascii.eqlIgnoreCase(s, "octet")) return .octet;
        if (std.ascii.eqlIgnoreCase(s, "mail")) return .mail;
        return null;
    }

    pub fn toString(self: Mode) []const u8 {
        return switch (self) {
            .netascii => "netascii",
            .octet => "octet",
            .mail => "mail",
        };
    }
};

/// A tagged union representing a parsed TFTP packet.
pub const Packet = union(Opcode) {
    rrq: Request,
    wrq: Request,
    data: Data,
    ack: Ack,
    err: Error,

    pub const Request = struct {
        filename: []const u8,
        mode: Mode,
    };

    pub const Data = struct {
        block_num: u16,
        data: []const u8,
    };

    pub const Ack = struct {
        block_num: u16,
    };

    pub const Error = struct {
        code: ErrorCode,
        msg: []const u8,
    };

    /// Parses a raw byte buffer into a Packet structure.
    /// The returned Packet slices into the `buf`, so `buf` must remain valid.
    pub fn parse(buf: []const u8) !Packet {
        if (buf.len < 2) return error.InvalidPacket;

        // Opcode is always the first 2 bytes, network byte order (Big Endian)
        const opcode_int = std.mem.readInt(u16, buf[0..2], .big);
        const opcode = std.meta.intToEnum(Opcode, opcode_int) catch return error.InvalidOpcode;

        return switch (opcode) {
            .rrq, .wrq => |op| blk: {
                // Format: Opcode | Filename | 0 | Mode | 0
                // Skip opcode
                const rest = buf[2..];
                
                // Find filename terminator
                const null_pos1 = std.mem.indexOfScalar(u8, rest, 0) orelse return error.InvalidPacket;
                const filename = rest[0..null_pos1];
                
                // Find mode terminator
                const rest2 = rest[null_pos1 + 1 ..];
                const null_pos2 = std.mem.indexOfScalar(u8, rest2, 0) orelse return error.InvalidPacket;
                const mode_str = rest2[0..null_pos2];
                
                const mode = Mode.fromString(mode_str) orelse return error.InvalidMode;

                if (op == .rrq) {
                    break :blk Packet{ .rrq = .{ .filename = filename, .mode = mode } };
                } else {
                    break :blk Packet{ .wrq = .{ .filename = filename, .mode = mode } };
                }
            },
            .data => blk: {
                // Format: Opcode | Block # | Data
                if (buf.len < 4) return error.InvalidPacket;
                const block_num = std.mem.readInt(u16, buf[2..4], .big);
                const data_payload = buf[4..];
                break :blk Packet{ .data = .{ .block_num = block_num, .data = data_payload } };
            },
            .ack => blk: {
                // Format: Opcode | Block #
                if (buf.len < 4) return error.InvalidPacket;
                const block_num = std.mem.readInt(u16, buf[2..4], .big);
                break :blk Packet{ .ack = .{ .block_num = block_num } };
            },
            .err => blk: {
                // Format: Opcode | ErrorCode | ErrMsg | 0
                if (buf.len < 4) return error.InvalidPacket;
                const code_int = std.mem.readInt(u16, buf[2..4], .big);
                const code = std.meta.intToEnum(ErrorCode, code_int) catch .not_defined; // Default to undefined if unknown
                
                const rest = buf[4..];
                const null_pos = std.mem.indexOfScalar(u8, rest, 0) orelse return error.InvalidPacket;
                const msg = rest[0..null_pos];
                
                break :blk Packet{ .err = .{ .code = code, .msg = msg } };
            },
        };
    }

    /// Serializes the Packet into the provided buffer.
    /// Returns the number of bytes written.
    pub fn serialize(self: Packet, buf: []u8) !usize {
        if (buf.len < 2) return error.BufferTooSmall;

        // Write Opcode
        const opcode_int = @intFromEnum(self);
        std.mem.writeInt(u16, buf[0..2], opcode_int, .big);
        
        var pos: usize = 2;

        switch (self) {
            .rrq, .wrq => |req| {
                const filename = req.filename;
                const mode = req.mode.toString();
                // 2 (opcode) + filename + 1 (null) + mode + 1 (null)
                if (pos + filename.len + 1 + mode.len + 1 > buf.len) return error.BufferTooSmall;

                @memcpy(buf[pos .. pos + filename.len], filename);
                pos += filename.len;
                buf[pos] = 0;
                pos += 1;

                @memcpy(buf[pos .. pos + mode.len], mode);
                pos += mode.len;
                buf[pos] = 0;
                pos += 1;
            },
            .data => |d| {
                // 2 (opcode) + 2 (block) + data
                if (pos + 2 + d.data.len > buf.len) return error.BufferTooSmall;
                
                std.mem.writeInt(u16, buf[pos..][0..2], d.block_num, .big);
                pos += 2;
                
                @memcpy(buf[pos .. pos + d.data.len], d.data);
                pos += d.data.len;
            },
            .ack => |a| {
                // 2 (opcode) + 2 (block)
                if (pos + 2 > buf.len) return error.BufferTooSmall;
                
                std.mem.writeInt(u16, buf[pos..][0..2], a.block_num, .big);
                pos += 2;
            },
            .err => |e| {
                // 2 (opcode) + 2 (code) + msg + 1 (null)
                if (pos + 2 + e.msg.len + 1 > buf.len) return error.BufferTooSmall;
                
                const code_int = @intFromEnum(e.code);
                std.mem.writeInt(u16, buf[pos..][0..2], code_int, .big);
                pos += 2;

                @memcpy(buf[pos .. pos + e.msg.len], e.msg);
                pos += e.msg.len;
                buf[pos] = 0;
                pos += 1;
            },
        }

        return pos;
    }
};

// --- Tests ---

test "Packet.serialize/parse ACK" {
    var buf: [512]u8 = undefined;
    const pkt = Packet{ .ack = .{ .block_num = 10 } };
    
    // Test Serialize
    const len = try pkt.serialize(&buf);
    try testing.expectEqual(@as(usize, 4), len);
    
    // Wire format check (Big Endian):
    // Opcode 4 (0x00 0x04)
    // Block  10 (0x00 0x0A)
    try testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0x04, 0x00, 0x0A }, buf[0..len]);

    // Test Parse
    const parsed = try Packet.parse(buf[0..len]);
    try testing.expectEqual(Opcode.ack, std.meta.activeTag(parsed));
    try testing.expectEqual(@as(u16, 10), parsed.ack.block_num);
}

test "Packet.serialize/parse RRQ" {
    var buf: [512]u8 = undefined;
    const pkt = Packet{ .rrq = .{ .filename = "test.txt", .mode = .octet } };

    const len = try pkt.serialize(&buf);
    
    // Opcode (2) + "test.txt" (8) + 0 (1) + "octet" (5) + 0 (1) = 17 bytes
    try testing.expectEqual(@as(usize, 17), len);
    
    // Check Opcode
    try testing.expectEqualSlices(u8, &[_]u8{0x00, 0x01}, buf[0..2]);
    // Check null terminators
    try testing.expect(buf[2 + 8] == 0); // After filename
    try testing.expect(buf[len - 1] == 0); // End of packet

    const parsed = try Packet.parse(buf[0..len]);
    try testing.expectEqual(Opcode.rrq, std.meta.activeTag(parsed));
    try testing.expectEqualStrings("test.txt", parsed.rrq.filename);
    try testing.expectEqual(Mode.octet, parsed.rrq.mode);
}

test "Packet.serialize/parse DATA" {
    var buf: [516]u8 = undefined;
    const payload = "Hello World";
    const pkt = Packet{ .data = .{ .block_num = 1, .data = payload } };

    const len = try pkt.serialize(&buf);
    // Opcode (2) + Block (2) + Data (11) = 15
    try testing.expectEqual(@as(usize, 15), len);

    const parsed = try Packet.parse(buf[0..len]);
    try testing.expectEqual(Opcode.data, std.meta.activeTag(parsed));
    try testing.expectEqual(@as(u16, 1), parsed.data.block_num);
    try testing.expectEqualStrings(payload, parsed.data.data);
}

test "Packet.serialize/parse ERROR" {
    var buf: [512]u8 = undefined;
    const pkt = Packet{ .err = .{ .code = .file_not_found, .msg = "Not found" } };

    const len = try pkt.serialize(&buf);
    // Opcode (2) + ErrCode (2) + Msg (9) + 0 (1) = 14
    try testing.expectEqual(@as(usize, 14), len);

    const parsed = try Packet.parse(buf[0..len]);
    try testing.expectEqual(Opcode.err, std.meta.activeTag(parsed));
    try testing.expectEqual(ErrorCode.file_not_found, parsed.err.code);
    try testing.expectEqualStrings("Not found", parsed.err.msg);
}

test {
    std.testing.refAllDecls(@This());
}

