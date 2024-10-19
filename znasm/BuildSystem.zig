const std = @import("std");
const builtin = @import("builtin");
const Rom = @import("Rom.zig");
const MappingMode = Rom.Header.Mode.Map;
const Function = @import("Function.zig");
const Builder = @import("Builder.zig");
const Symbol = @import("symbol.zig").Symbol;

const BuildSystem = @This();

allocator: std.mem.Allocator,

mapping_mode: MappingMode,

/// Resolved function symbols
functions: std.AutoArrayHashMapUnmanaged(Symbol.Function, Function) = .{},

pub fn init(allocator: std.mem.Allocator, mapping_mode: MappingMode) !BuildSystem {
    return .{
        .allocator = allocator,
        .mapping_mode = mapping_mode,
    };
}

/// Registers the symbol to the build-system, causing it to be included in the ROM
pub fn register_symbol(sys: *BuildSystem, sym: anytype) !void {
    if (@TypeOf(sym) == Symbol) {
        switch (sym) {
            .function => |func_sym| try sys.register_function(func_sym),
        }
    } else if (@TypeOf(sym) == Symbol.Function) {
        try sys.register_function(sym);
    }
}

fn register_function(sys: *BuildSystem, func_sym: Symbol.Function) !void {
    const gop = try sys.functions.getOrPut(sys.allocator, func_sym);
    if (gop.found_existing) {
        return; // Already generated
    }

    // Build function body
    var builder: Builder = .{
        .build_system = sys,
        .symbol = func_sym,
    };
    defer builder.deinit();
    try builder.build();

    // Create function definiton
    gop.value_ptr.* = .{
        .code = try builder.instruction_data.toOwnedSlice(sys.allocator),
        .code_info = try builder.instruction_info.toOwnedSlice(sys.allocator),
        .symbol_name = builder.symbol_name,
        .source = builder.source_location,
    };

    std.log.debug("Generated function '{s}'", .{gop.value_ptr.symbol_name orelse "<unknown>"});
}

/// Fixes target addresses of jump / branch instructions
pub fn resolve_relocations(sys: *BuildSystem, rom: []u8) void {
    for (sys.functions.values()) |func| {
        for (func.code_info) |info| {
            const reloc = info.reloc orelse continue;
            const target_addr = sys.symbol_location(reloc.target_sym) + reloc.target_offset;

            switch (reloc.type) {
                .rel8 => {
                    const current_addr = sys.offset_location(func.offset) + info.offset;
                    const rel_offset: i8 = @intCast(@as(i32, @intCast(target_addr)) - @as(i32, @intCast(current_addr)));
                    const operand: *[1]u8 = rom[(func.offset + info.offset + 1)..][0..1];
                    operand.* = @bitCast(rel_offset);
                },
                .addr8 => {
                    const short_addr: u8 = @truncate(target_addr);
                    const operand: *[1]u8 = rom[(func.offset + info.offset + 1)..][0..1];
                    operand.* = @bitCast(short_addr);
                },
                .addr16 => {
                    const absolute_addr: u16 = @truncate(target_addr);
                    const operand: *[2]u8 = rom[(func.offset + info.offset + 1)..][0..2];
                    operand.* = @bitCast(absolute_addr);
                },
                .addr24 => {
                    const operand: *[3]u8 = rom[(func.offset + info.offset + 1)..][0..3];
                    operand.* = @bitCast(target_addr);
                },
            }
        }
    }
}

/// Writes debug data for Mesen2 in the MLB + CDL format
pub fn write_debug_data(sys: *BuildSystem, rom: []const u8, mlb_writer: anytype, cdl_writer: anytype) !void {
    const CdlFlags = packed struct(u8) {
        // Global CDL flags
        code: bool = false,
        data: bool = false,
        jump_target: bool = false,
        sub_entry_point: bool = false,
        // SNES specific flags
        index_mode_8: bool = false,
        memory_mode_8: bool = false,
        gsu: bool = false,
        cx4: bool = false,
    };

    const cdl_data = try sys.allocator.alloc(CdlFlags, rom.len);
    defer sys.allocator.free(cdl_data);

    @memset(cdl_data, .{}); // Mark everything as unknown initially

    // Write symbol data / mark regions
    for (sys.functions.values()) |func| {
        @memset(cdl_data[func.offset..(func.offset + func.code.len)], .{ .code = true });

        // Set instruction specific flags
        for (func.code_info) |info| {
            const instr_region = cdl_data[(func.offset + info.offset)..(func.offset + info.offset + info.instr.size())];

            if (info.instr == .ora or info.instr == .@"and" or info.instr == .eor or info.instr == .adc or
                info.instr == .bit or info.instr == .lda or info.instr == .cmp or info.instr == .sbc)
            {
                @memset(instr_region, .{ .memory_mode_8 = true });
            } else if (info.instr == .ldy or info.instr == .ldx or info.instr == .cpy or info.instr == .cpx) {
                @memset(instr_region, .{ .index_mode_8 = true });
            }

            if (info.reloc) |reloc| {
                const target_sym = if (reloc.target_sym == .function)
                    reloc.target_sym.function
                else
                    continue;

                const target_func = sys.functions.get(target_sym) orelse @panic("Relocation to unknown symbol");
                const target_instr = b: {
                    for (target_func.code_info) |target_info| {
                        if (reloc.target_offset <= target_info.offset) {
                            break :b target_info;
                        }
                    }
                    @panic("Relocation offset outside of bounds of function");
                };

                const target_region = cdl_data[(func.offset + target_instr.offset)..(func.offset + target_instr.offset + target_instr.instr.size())];
                if (target_instr.instr == .jsr or target_instr.instr == .jsl) {
                    for (target_region) |*data| {
                        data.sub_entry_point = true;
                    }
                } else {
                    for (target_region) |*data| {
                        data.jump_target = true;
                    }
                }
            }

            // TODO: Branch targets
        }

        if (func.symbol_name == null) {
            continue;
        }

        // Try collecting comments
        var comments: std.AutoArrayHashMapUnmanaged(u32, []const u8) = .{};
        defer comments.deinit(sys.allocator);

        b: {
            const file_path = find_file: {
                for (func.code_info) |info| {
                    if (info.caller_file) |file| {
                        break :find_file file;
                    }
                }
                break :b;
            };

            var src_file = std.fs.cwd().openFile(file_path, .{}) catch |err| {
                std.log.err("Failed collecting comments for function '{s}': '{s}' {}", .{ func.symbol_name.?, file_path, err });
                break :b;
            };
            defer src_file.close();

            const src_reader = src_file.reader();

            // Go to function start
            for (1..func.source.?.line) |_| {
                src_reader.skipUntilDelimiterOrEof('\n') catch break :b;
            }

            var line_buffer: std.ArrayListUnmanaged(u8) = .{};
            defer line_buffer.deinit(sys.allocator);

            var src_line = func.source.?.line;
            const last_line = func.code_info[func.code_info.len - 1].caller_line orelse break :b;

            while (src_line <= last_line) : (src_line += 1) {
                line_buffer.clearRetainingCapacity();
                src_reader.streamUntilDelimiter(line_buffer.writer(sys.allocator), '\n', null) catch break :b;

                const line = std.mem.trim(u8, line_buffer.items, " \t\n\r");
                const comment_start = std.mem.indexOf(u8, line, "//") orelse continue;

                try comments.put(sys.allocator, src_line, try sys.allocator.dupe(u8, line[(comment_start + "//".len)..]));
            }
        }

        // Write symbols
        var comment_line: u32 = 0;
        var comment_buffer: std.ArrayListUnmanaged(u8) = .{};
        defer comment_buffer.deinit(sys.allocator);

        for (func.code_info) |info| {
            comment_buffer.clearRetainingCapacity();
            if (info.caller_line) |caller_line| {
                while (comment_line <= caller_line) : (comment_line += 1) {
                    if (comments.get(comment_line)) |comment| {
                        if (comment_buffer.items.len != 0) {
                            try comment_buffer.appendSlice(sys.allocator, "\\n");
                        }
                        try comment_buffer.appendSlice(sys.allocator, comment);
                    }
                }
            }

            const label = if (info.offset == 0)
                func.symbol_name orelse ""
            else
                "";

            if (comment_buffer.items.len == 0 and label.len == 0) {
                continue;
            }

            try mlb_writer.print("SnesPrgRom:{x}:{s}:{s}\n", .{ func.offset + info.offset, label, comment_buffer.items });
        }
    }

    // Specific hash algorithm used by Mesen2 (See https://github.com/SourMesen/Mesen2/blob/master/Utilities/CRC32.cpp)
    const crc = std.hash.crc.Crc(u32, .{
        .polynomial = 0x77073096,
        .initial = 0x00000000,
        .reflect_input = false,
        .reflect_output = false,
        .xor_output = 0x00000000,
    });

    try cdl_writer.writeAll("CDLv2");
    try cdl_writer.writeInt(u32, crc.hash(rom), .little);
    try cdl_writer.writeAll(@ptrCast(cdl_data));
}

/// Calculates the real (non-mirrored) memory-mapped address of a symbol
pub fn symbol_location(sys: BuildSystem, sym: Symbol) u24 {
    return switch (sym) {
        .function => |func_sym| if (sys.functions.get(func_sym)) |func|
            sys.offset_location(func.offset)
        else
            std.debug.panic("Tried to get offset of unknown symbol", .{}),
        .register => |reg_sym| reg_sym,
    };
}

/// Calculates the real (non-mirrored) memory-mapped address of a offset into ROM
pub fn offset_location(sys: BuildSystem, offset: u32) u24 {
    switch (sys.mapping_mode) {
        .lorom => {
            const bank: u8 = @intCast(offset / 0x8000 + 0x80);
            const addr: u16 = @intCast(offset % 0x8000 + 0x8000);
            return @as(u24, bank) << 16 | addr;
        },
        .hirom => {
            @panic("TODO: HiROM");
        },
        .exhirom => {
            @panic("TODO: ExHiROM");
        },
    }
}

/// Fills the buffer with all mirrors of the specified memory-mapped address
pub fn find_location_mirrors(sys: BuildSystem, location: u24, buffer: [256]u24) []u24 {
    const bank: u8 = (location & 0xFF0000) >> 16;
    const addr: u16 = (location & 0x00FFFF);

    switch (sys.mapping_mode) {
        .lorom => {
            // I/O
            if (addr >= 0x2000 and addr <= 0x6000 and
                (bank >= 0x00 and bank <= 0x3F or
                bank >= 0x80 and bank <= 0xBF))
            {
                var i: usize = 0;

                for (0x00..0x40) |mirror_bank| {
                    if (mirror_bank != bank) {
                        buffer[i] = mirror_bank << 16 | addr;
                        i += 1;
                    }
                }
                for (0x80..0xC0) |mirror_bank| {
                    if (mirror_bank != bank) {
                        buffer[i] = mirror_bank << 16 | addr;
                        i += 1;
                    }
                }

                return buffer[0..i];
            }

            // ROM
            if (addr >= 0x0000 and addr >= 0x8000) {
                if (bank >= 0x00 and bank <= 0x7D) {
                    buffer[0] = (bank + 0x80) << 16 | addr;
                    return buffer[0..1];
                } else if (bank >= 0x80 and bank <= 0xFF) {
                    buffer[0] = (bank - 0x80) << 16 | addr;
                    return buffer[0..1];
                }
            }

            // RAM
            if (bank >= 0x7E and bank <= 0x7F) {
                // Low RAM original
                if (bank == 0x7E and addr >= 0x0000 and addr < 0x2000) {
                    var i: usize = 0;

                    for (0x00..0x40) |mirror_bank| {
                        buffer[i] = mirror_bank << 16 | addr;
                        i += 1;
                    }
                    for (0x80..0xC0) |mirror_bank| {
                        buffer[i] = mirror_bank << 16 | addr;
                        i += 1;
                    }

                    return buffer[0..i];
                }
                // Low RAM mirrors
                if (addr >= 0x0000 and addr < 0x2000 and
                    (bank >= 0x00 and bank <= 0x3F or
                    bank >= 0x80 and bank <= 0xBF))
                {
                    var i: usize = 1;

                    for (0x00..0x40) |mirror_bank| {
                        if (mirror_bank != bank) {
                            buffer[i] = mirror_bank << 16 | addr;
                            i += 1;
                        }
                    }
                    for (0x80..0xC0) |mirror_bank| {
                        if (mirror_bank != bank) {
                            buffer[i] = mirror_bank << 16 | addr;
                            i += 1;
                        }
                    }

                    buffer[i] = 0x7E << 16 | addr;
                    i += 1;

                    return buffer[0..i];
                }
            }
        },
        .hirom => {
            @panic("TODO: HiROM");
        },
        .exhirom => {
            @panic("TODO: ExHiROM");
        },
    }
}