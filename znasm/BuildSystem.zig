const std = @import("std");
const builtin = @import("builtin");
const Rom = @import("Rom.zig");
const MappingMode = Rom.Header.Mode.Map;
const Builder = @import("Builder.zig");
const Symbol = @import("symbol.zig").Symbol;
const resolved_symbol = @import("resolved_symbol.zig");

const BuildSystem = @This();

allocator: std.mem.Allocator,

mapping_mode: MappingMode,

/// Resolved function symbols
functions: std.AutoArrayHashMapUnmanaged(Symbol.Function, resolved_symbol.Function) = .{},
/// Resolved data symbols
data: std.AutoArrayHashMapUnmanaged(Symbol.Data, resolved_symbol.Data) = .{},

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
            .address => {},
            .function => |func_sym| _ = try sys.register_function(func_sym),
            .data => |data_sym| _ = try sys.register_data(data_sym),
        }
    } else if (@TypeOf(sym) == Symbol.Function or @TypeOf(sym) == fn (*Builder) void) {
        _ = try sys.register_function(sym);
    } else if (@TypeOf(sym) == Symbol.Data) {
        _ = try sys.register_data(sym);
    } else {
        @compileError(std.fmt.comptimePrint("Unsupported symbol type '{s}'", .{@typeName(@TypeOf(sym))}));
    }
}

/// Registers and generates the specified function symbol
pub fn register_function(sys: *BuildSystem, func_sym: Symbol.Function) !resolved_symbol.Function {
    const gop = try sys.functions.getOrPut(sys.allocator, func_sym);
    if (gop.found_existing) {
        return gop.value_ptr.*; // Already generated
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
        .call_conv = .{
            .start_a_size = builder.start_a_size,
            .start_xy_size = builder.start_xy_size,
            .end_a_size = builder.end_a_size,
            .end_xy_size = builder.end_xy_size,

            .inputs = try sys.allocator.dupe(Builder.CallValue, builder.inputs.keys()),
            .outputs = try sys.allocator.dupe(Builder.CallValue, builder.outputs.keys()),
            .clobbers = try sys.allocator.dupe(Builder.CallValue, builder.clobbers.keys()),
        },
        .symbol_name = builder.symbol_name,
        .source = builder.source_location,
    };

    std.log.debug("Generated function '{s}'", .{gop.value_ptr.symbol_name orelse "<unknown>"});
    return gop.value_ptr.*;
}

/// Includes the specified data symbol into the ROM
pub fn register_data(sys: *BuildSystem, data_sym: Symbol.Data) !resolved_symbol.Data {
    const gop = try sys.data.getOrPut(sys.allocator, data_sym);
    if (gop.found_existing) {
        return gop.value_ptr.*; // Already included
    }

    gop.value_ptr.* = .{
        .data = data_sym.data,
    };

    std.log.debug("Registered data '{s}'", .{data_sym.name});
    return gop.value_ptr.*;
}

/// Fixes target addresses of jump / branch instructions
pub fn resolve_relocations(sys: *BuildSystem, rom: []u8) void {
    for (sys.functions.values()) |func| {
        for (func.code_info) |info| {
            const reloc = info.reloc orelse continue;

            // Immediate relocations store the value inside target_offset
            if (reloc.type == .imm8) {
                const operand: *[1]u8 = rom[(func.offset + info.offset + 1)..][0..1];
                operand.* = @bitCast(@as(u8, @intCast(reloc.target_offset)));

                continue;
            } else if (reloc.type == .imm16) {
                const operand: *[2]u8 = rom[(func.offset + info.offset + 1)..][0..2];
                operand.* = @bitCast(reloc.target_offset);

                continue;
            }

            const target_addr = sys.symbol_location(reloc.target_sym) + reloc.target_offset;

            switch (reloc.type) {
                .imm8, .imm16 => unreachable,

                .rel8 => {
                    const current_addr = sys.offset_location(func.offset) + info.offset;
                    const rel_offset: i8 = @intCast(@as(i32, @intCast(target_addr)) - @as(i32, @intCast(current_addr)));
                    const operand: *[1]u8 = rom[(func.offset + info.offset + 1)..][0..1];
                    operand.* = @bitCast(rel_offset);
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

                .addr_l => {
                    const low_addr: u8 = @truncate(target_addr >> 0);
                    const operand: *[1]u8 = rom[(func.offset + info.offset + 1)..][0..1];
                    operand.* = @bitCast(low_addr);
                },
                .addr_h => {
                    const high_addr: u8 = @truncate(target_addr >> 8);
                    const operand: *[1]u8 = rom[(func.offset + info.offset + 1)..][0..1];
                    operand.* = @bitCast(high_addr);
                },
                .addr_bank => {
                    const bank_addr: u8 = @truncate(target_addr >> 16);
                    const operand: *[1]u8 = rom[(func.offset + info.offset + 1)..][0..1];
                    operand.* = @bitCast(bank_addr);
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

        // Write labels / comments
        for (func.code_info) |info| {
            const label = if (info.offset == 0)
                func.symbol_name orelse ""
            else
                "";

            try mlb_writer.print("SnesPrgRom:{x}:{s}", .{ func.offset + info.offset, label });

            for (info.comments, 0..) |comment, i| {
                if (i == 0) {
                    try mlb_writer.writeByte(':');
                } else {
                    try mlb_writer.writeAll("\\n");
                }

                try mlb_writer.writeAll(comment);
            }

            try mlb_writer.writeByte('\n');
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
        .address => |reg_sym| reg_sym,
        .function => |func_sym| if (sys.functions.get(func_sym)) |func|
            sys.offset_location(func.offset)
        else
            std.debug.panic("Tried to get offset of unknown function symbol", .{}),
        .data => |data_sym| if (sys.data.get(data_sym)) |data|
            sys.offset_location(data.offset)
        else
            std.debug.panic("Tried to get offset of unknown data symbol", .{}),
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
