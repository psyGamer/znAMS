const std = @import("std");
const BuildSystem = @import("BuildSystem.zig");
const Instruction = @import("instruction.zig").Instruction;
const InstructionType = @import("instruction.zig").InstructionType;
const Symbol = @import("symbol.zig").Symbol;
const CallConv = @import("resolved_symbol.zig").Function.CallingConvention;
const RegA = @import("register.zig").RegA;
const RegX = @import("register.zig").RegX;
const RegY = @import("register.zig").RegY;

const Builder = @This();

// NOTE: This intentionally doesn't expose OutOfMemory errors, to keep the API simpler (they would crash the assembler anyway)

/// Index to a target instruction
pub const Label = struct {
    index: ?u16,

    /// Defines the label to point to the next instruction
    pub fn define(label: *Label, b: *const Builder) void {
        label.index = @intCast(b.instruction_info.items.len);
    }
};

/// Metadata information about an instruction
pub const InstructionInfo = struct {
    /// A relocatoion indicates that this instruction has an operand to another symbol,
    /// which needs to be fixed after emitting the data into ROM
    pub const Relocation = struct {
        pub const Type = enum {
            // Immediate relocations are just for convenience. They use the target_offset as the value
            imm8,
            imm16,

            rel8,

            addr16,
            addr24,

            addr_l,
            addr_h,
            addr_bank,
        };

        type: Type,
        target_sym: Symbol,
        target_offset: u16,
    };
    /// Branches need to be relocated to point to their label and use the short / long form
    const BranchRelocation = struct {
        pub const Type = enum {
            always,
            jump_long,
        };

        type: Type,
        target: *Label,
    };

    instr: Instruction,
    offset: u16,

    reloc: ?Relocation,
    branch_reloc: ?BranchRelocation,

    a_size: Instruction.SizeMode,
    xy_size: Instruction.SizeMode,

    comments: []const []const u8,
};

/// A value which is either an input or output of this function
pub const CallValue = union(enum) {
    a: void,
    x: void,
    y: void,
};

const SourceLocation = struct {
    file: []const u8,
    function: []const u8,
};
const SourceLocationHashContext = struct {
    pub fn hash(_: SourceLocationHashContext, key: SourceLocation) u32 {
        var hasher = std.hash.Wyhash.init(0);
        std.hash.autoHashStrat(&hasher, key, .Deep);
        return @truncate(hasher.final());
    }
    pub fn eql(_: SourceLocationHashContext, a: SourceLocation, b: SourceLocation, _: usize) bool {
        return std.mem.eql(u8, a.file, b.file) and std.mem.eql(u8, a.function, b.function);
    }
};

build_system: *BuildSystem,

symbol: Symbol.Function,
instruction_data: std.ArrayListUnmanaged(u8) = .{},
instruction_info: std.ArrayListUnmanaged(InstructionInfo) = .{},

labels: std.ArrayListUnmanaged(*const Label) = .{},

// Register State
a_size: Instruction.SizeMode = .none,
xy_size: Instruction.SizeMode = .none,
a_reg_id: ?u64 = null,
x_reg_id: ?u64 = null,
y_reg_id: ?u64 = null,

// Calling convention
start_a_size: Instruction.SizeMode = .none,
start_xy_size: Instruction.SizeMode = .none,
end_a_size: Instruction.SizeMode = .none,
end_xy_size: Instruction.SizeMode = .none,

/// Input values for this function
inputs: std.AutoArrayHashMapUnmanaged(CallValue, void) = .{},
/// Output values from this function
outputs: std.AutoArrayHashMapUnmanaged(CallValue, void) = .{},
/// Values which are modified by this function, potentially leaving them in an invalid state
clobbers: std.AutoArrayHashMapUnmanaged(CallValue, void) = .{},

// Debug data
curr_caller_lines: std.ArrayHashMapUnmanaged(SourceLocation, u64, SourceLocationHashContext, true) = .{},
prev_caller_lines: std.ArrayHashMapUnmanaged(SourceLocation, u64, SourceLocationHashContext, true) = .{},

symbol_name: ?[]const u8 = null,
source_location: ?std.builtin.SourceLocation = null,

pub fn deinit(b: *Builder) void {
    b.inputs.deinit(b.build_system.allocator);
    b.outputs.deinit(b.build_system.allocator);
    b.clobbers.deinit(b.build_system.allocator);

    for (b.labels.items) |label| {
        b.build_system.allocator.destroy(label);
    }

    b.labels.deinit(b.build_system.allocator);
}

/// Provides debug information for proper labels
pub fn setup_debug(b: *Builder, src: std.builtin.SourceLocation, declaring_type: type, overwrite_symbol_name: ?[]const u8) void {
    b.symbol_name = overwrite_symbol_name orelse std.fmt.allocPrint(b.build_system.allocator, "{s}@{s}", .{ @typeName(declaring_type), src.fn_name }) catch @panic("Out of memory");
    b.source_location = src;

    // Start capturing comments
    const comments = b.resolve_comments(@returnAddress()) catch &.{};
    for (comments) |comment| {
        b.build_system.allocator.free(comment);
    }
    b.build_system.allocator.free(comments);
}

// Labels

/// Creates a new undefined label
pub fn create_label(b: *Builder) *Label {
    var label = b.build_system.allocator.create(Label) catch @panic("Out of memory");
    label.index = null;

    b.labels.append(b.build_system.allocator, label) catch @panic("Out of memory");
    return label;
}

/// Creates and defines and new label
pub fn define_label(b: *Builder) *Label {
    var label = b.create_label();
    label.define(b);
    return label;
}

// Registers

/// Sets up the A register in 8-bit mode
pub fn reg_a8(b: *Builder) RegA {
    b.change_status_flags(.{ .a_8bit = true });
    return .next(b);
}

/// Sets up the A register in 16-bit mode
pub fn reg_a16(b: *Builder) RegA {
    b.change_status_flags(.{ .a_8bit = false });
    return .next(b);
}

/// Sets up the X register in 8-bit mode
pub fn reg_x8(b: *Builder) RegX {
    b.change_status_flags(.{ .xy_8bit = true });
    return .next(b);
}

/// Sets up the X register in 16-bit mode
pub fn reg_x16(b: *Builder) RegX {
    b.change_status_flags(.{ .xy_8bit = false });
    return .next(b);
}

/// Sets up the Y register in 8-bit mode
pub fn reg_y8(b: *Builder) RegY {
    b.change_status_flags(.{ .xy_8bit = true });
    return .next(b);
}

/// Sets up the Y register in 16-bit mode
pub fn reg_y16(b: *Builder) RegY {
    b.change_status_flags(.{ .xy_8bit = false });
    return .next(b);
}

/// Sets up the X and Y registers in 8-bit mode
pub fn reg_xy8(b: *Builder) struct { RegX, RegY } {
    b.change_status_flags(.{ .xy_8bit = true });
    return .{ .next(b), .next(b) };
}

/// Sets up the X and Y registers in 8-bit mode
pub fn reg_xy16(b: *Builder) struct { RegX, RegY } {
    b.change_status_flags(.{ .xy_8bit = false });
    return .{ .next(b), .next(b) };
}

// Instrucion Emitting

pub fn emit(b: *Builder, instr: Instruction) void {
    b.emit_extra(instr, .{});
}
pub fn emit_reloc(b: *Builder, instr_type: InstructionType, reloc: InstructionInfo.Relocation) void {
    const instr = switch (instr_type) {
        inline else => |t| @unionInit(Instruction, @tagName(t), undefined),
    };
    b.emit_extra(instr, .{ .reloc = reloc });
}
pub fn emit_branch_reloc(b: *Builder, branch_reloc: InstructionInfo.BranchRelocation) void {
    b.emit_extra(.nop, .{ .branch_reloc = branch_reloc });
}

pub fn emit_extra(b: *Builder, instr: Instruction, extra: struct {
    reloc: ?InstructionInfo.Relocation = null,
    branch_reloc: ?InstructionInfo.BranchRelocation = null,
    comments: ?[]const []const u8 = null,
}) void {
    const comments = extra.comments orelse b.resolve_comments(@returnAddress()) catch @as([]const []const u8, &.{});

    b.instruction_info.append(b.build_system.allocator, .{
        .instr = instr,
        .offset = undefined,

        .reloc = extra.reloc,
        .branch_reloc = extra.branch_reloc,

        .a_size = b.a_size,
        .xy_size = b.xy_size,

        .comments = comments,
    }) catch @panic("Out of memory");

    // Ensure every return leaves with the same register sizes
    if (instr == .rts or instr == .rtl) {
        if (b.a_size != .none) {
            if (b.end_a_size == .none) {
                b.end_a_size = b.a_size;
            } else {
                std.debug.assert(b.end_a_size == b.a_size);
            }
        }
        if (b.xy_size != .none) {
            if (b.end_xy_size == .none) {
                b.end_xy_size = b.xy_size;
            } else {
                std.debug.assert(b.end_xy_size == b.xy_size);
            }
        }
    }
}

// Helpers

pub const AddrSize = enum { @"8bit", @"16bit" };
pub fn AddrSizeType(comptime size: AddrSize) type {
    return switch (size) {
        .@"8bit" => u8,
        .@"16bit" => u16,
    };
}

pub const Register = enum { a, x, y };
pub fn RegisterType(comptime register: Register) type {
    return switch (register) {
        .a => RegA,
        .x => RegX,
        .y => RegY,
    };
}

/// Stores zero into the target symbol
pub fn store_zero(b: *Builder, size: AddrSize, target: anytype) void {
    if (@TypeOf(target) == Symbol.Address) {
        // TODO: Handle symbols in other banks
        if (size == .@"8bit" and b.a_size == .@"8bit" or
            size == .@"16bit" and b.a_size == .@"16bit")
        {
            b.emit_reloc(.stz_addr16, .{
                .type = .addr16,
                .target_sym = .{ .address = target },
                .target_offset = 0,
            });
            return;
        }

        switch (size) {
            .@"8bit" => {
                // Temporarily change bitwidth
                const prev_a_size = b.a_size;
                b.change_status_flags(.{ .a_8bit = true });
                defer if (prev_a_size != .none) b.change_status_flags(.{ .a_8bit = prev_a_size == .@"8bit" });

                b.emit_reloc(.stz_addr16, .{
                    .type = .addr16,
                    .target_sym = .{ .address = target },
                    .target_offset = 0,
                });
            },
            .@"16bit" => {
                // Double write to avoid changing size
                b.emit_reloc(.stz_addr16, .{
                    .type = .addr16,
                    .target_sym = .{ .address = target },
                    .target_offset = 0,
                });
                b.emit_reloc(.stz_addr16, .{
                    .type = .addr16,
                    .target_sym = .{ .address = target },
                    .target_offset = 1,
                });
            },
        }
    } else {
        @compileError(std.fmt.comptimePrint("Unsupported target address'{s}'", .{@typeName(@TypeOf(target))}));
    }
}

/// Stores the specified value into the target symbol
/// For non-zero values, the A Register might be clobbered
pub fn store_value(b: *Builder, comptime size: AddrSize, register: Register, target: anytype, value: AddrSizeType(size)) void {
    b.store_reloc(register, target, .{
        .type = if (size == .@"8bit") .imm8 else .imm16,
        .target_sym = undefined,
        .target_offset = value,
    });
}

/// Stores the specified reloc into the target symbol
/// For non-zero values, the A Register might be clobbered
pub fn store_reloc(b: *Builder, register: Register, target: anytype, reloc: InstructionInfo.Relocation) void {
    if ((reloc.type == .imm8 or reloc.type == .imm16) and reloc.target_offset == 0) {
        b.store_zero(if (reloc.type == .imm8) .@"8bit" else .@"16bit", target);
        return;
    }

    if (reloc.type != .imm8 and reloc.type != .imm16) {
        b.build_system.register_symbol(reloc.target_sym) catch @panic("Out of memory");
    }

    const reloc_size: Builder.AddrSize = switch (reloc.type) {
        .imm8, .rel8, .addr_l, .addr_h, .addr_bank => .@"8bit",
        .imm16, .addr16 => .@"16bit",
        .addr24 => @panic("Cannot load 24-bit value into register"),
    };

    const curr_size = switch (register) {
        .a => b.a_size,
        .x, .y => b.xy_size,
    };

    if (reloc_size == .@"8bit" and curr_size == .@"8bit" or
        reloc_size == .@"16bit" and curr_size == .@"16bit")
    {
        switch (register) {
            inline else => |reg_type| {
                var reg: RegisterType(reg_type) = .next(b);
                reg = .load_reloc(b, reloc);
                reg.store(target);
            },
        }
        return;
    }

    // Only change bitwidth if required
    if (curr_size == .none or reloc_size == .@"8bit") {
        b.change_status_flags(switch (register) {
            .a => .{ .a_8bit = reloc_size == .@"8bit" },
            .x, .y => .{ .xy_8bit = reloc_size == .@"8bit" },
        });

        switch (register) {
            inline else => |reg_type| {
                var reg: RegisterType(reg_type) = .next(b);
                reg = .load_reloc(b, reloc);
                reg.store(target);
            },
        }
        return;
    }

    // Otherwise use a double-write
    const low_reloc: InstructionInfo.Relocation = .{
        .type = switch (reloc.type) {
            .imm8, .rel8, .addr24, .addr_l, .addr_h, .addr_bank => unreachable,
            .imm16 => .imm8,
            .addr16 => .addr_l,
        },
        .target_sym = reloc.target_sym,
        // The target_offset stores the value of immedate relocations
        .target_offset = if (reloc.type == .imm16)
            @as(u8, @truncate(reloc.target_offset >> 0))
        else
            reloc.target_offset,
    };
    const high_reloc: InstructionInfo.Relocation = .{
        .type = switch (reloc.type) {
            .imm8, .rel8, .addr24, .addr_l, .addr_h, .addr_bank => unreachable,
            .imm16 => .imm8,
            .addr16 => .addr_h,
        },
        .target_sym = reloc.target_sym,
        // The target_offset stores the value of immedate relocations
        .target_offset = if (reloc.type == .imm16)
            @as(u8, @truncate(reloc.target_offset >> 8))
        else
            reloc.target_offset,
    };

    switch (register) {
        inline else => |reg_type| {
            var reg: RegisterType(reg_type) = .next(b);
            reg = .load_reloc(b, low_reloc);
            reg.store_offset(target, 0);
            reg = .load_reloc(b, high_reloc);
            reg.store_offset(target, 1);
        },
    }
}

/// Calls the target method, respecting the target calling convention
pub fn call(b: *Builder, target: Symbol.Function) void {
    const target_func = b.build_system.register_function(target) catch @panic("Out of memory");
    if (target_func.code.len == 0) {
        @panic("Circular dependency detected: Target function isn't generated yet! Consider using call_with_convention() or jump_subroutine()");
    }

    b.call_with_convention(target, target_func.call_conv);
}

/// Calls the target method, respecting the specified calling convention
pub fn call_with_convention(b: *Builder, target: Symbol.Function, call_conv: CallConv) void {
    var change: ChangeStatusRegister = .{};
    if (call_conv.start_a_size != .none) {
        if (b.start_a_size == .none) {
            // Forward size
            b.start_a_size = call_conv.start_a_size;
        } else {
            change.a_8bit = call_conv.start_a_size == .@"8bit";
        }
    }
    if (call_conv.start_xy_size != .none) {
        if (b.start_xy_size == .none) {
            // Forward size
            b.start_xy_size = call_conv.start_xy_size;
        } else {
            change.xy_8bit = call_conv.start_xy_size == .@"8bit";
        }
    }

    if (call_conv.end_a_size != .none) {
        b.a_size = call_conv.end_a_size;
    }
    if (call_conv.end_xy_size != .none) {
        b.xy_size = call_conv.end_xy_size;
    }

    for (call_conv.clobbers) |clobber| {
        switch (clobber) {
            .a => _ = RegA.next(b),
            .x => _ = RegX.next(b),
            .y => _ = RegY.next(b),
        }
    }

    b.change_status_flags(change);
    b.emit_reloc(.jsr, .{
        .type = .addr16,
        .target_sym = .{ .function = target },
        .target_offset = 0,
    });
}

/// Always branch to the target label
pub fn branch_always(b: *Builder, target: *Label) void {
    b.emit_branch_reloc(.{
        .type = .always,
        .target = target,
    });
}

/// Jumps Long to the target symbol or label
pub fn jump_long(b: *Builder, target: anytype) void {
    if (@TypeOf(target) == *Label) {
        b.emit_branch_reloc(.{
            .type = .jump_long,
            .target = target,
        });
    } else if (@TypeOf(target) == Symbol) {
        std.debug.assert(target == .function);
        b.emit_reloc(.jml, .{
            .type = .addr24,
            .target_sym = target,
            .target_offset = 0,
        });
    } else if (@TypeOf(target) == Symbol.Function) {
        b.emit_reloc(.jml, .{
            .type = .addr24,
            .target_sym = .{ .function = target },
            .target_offset = 0,
        });
    } else {
        @compileError(std.fmt.comptimePrint("Unsupported target type '{s}'", .{@typeName(@TypeOf(target))}));
    }
}

/// Jumps to the target subroutine, without respecting the calling convention
pub fn jump_subroutine(b: *Builder, target: Symbol.Function) void {
    b.emit_reloc(.jsr, .{
        .type = .addr16,
        .target_sym = .{ .function = target },
        .target_offset = 0,
    });
}

const StackValue = union(enum) {
    a: void,
    x: void,
    y: void,
    data_bank: void,
    direct_page: void,
    program_bank: void,
    processor_status: void,

    /// Loads the immediate address value
    addr16: u16,
    /// Indirectly load the address at the specified offset into the Direct Page
    dpind_addr16: u8,
    /// Loads the address of the PC + the offset
    pcrel_addr16: i16,
};

/// Pushes the specified value onto the stack
pub fn push_stack(b: *Builder, value: StackValue) void {
    b.emit(switch (value) {
        .a => .pha,
        .x => .phx,
        .y => .phy,
        .data_bank => .phb,
        .direct_page => .phd,
        .program_bank => .phk,
        .processor_status => .php,
        .addr16 => |addr16| .{ .pea = addr16 },
        .dpind_addr16 => |addr8| .{ .pei = addr8 },
        .pcrel_addr16 => |offset| .{ .per = offset },
    });
}

/// Pulls the specified value from the stack
pub fn pull_stack(b: *Builder, value: StackValue) void {
    b.emit(switch (value) {
        .a => .pla,
        .x => .plx,
        .y => .ply,
        .data_bank => .plb,
        .direct_page => .pld,
        .processor_status => .plp,

        .program_bank, .addr16, .dpind_addr16, .pcrel_addr16 => std.debug.panic("Cannot pull value {} from stack", .{value}),
    });

    // Invalidate registers
    switch (value) {
        .a => _ = RegA.next(b),
        .x => _ = RegX.next(b),
        .y => _ = RegY.next(b),
        else => {},
    }
}

const ChangeStatusRegister = struct {
    carry: ?bool = null,
    zero: ?bool = null,
    irq_disable: ?bool = null,
    decimal: ?bool = null,
    xy_8bit: ?bool = null,
    a_8bit: ?bool = null,
    overflow: ?bool = null,
    negative: ?bool = null,
};

/// Changes non-null fields to the specfied value
pub fn change_status_flags(b: *Builder, change_status: ChangeStatusRegister) void {
    var change = change_status;

    if (change.a_8bit) |value| {
        const new_size: Instruction.SizeMode = if (value) .@"8bit" else .@"16bit";
        if (b.a_size != new_size) {
            b.a_size = new_size;
            if (b.start_a_size == .none) {
                b.start_a_size = b.a_size;
            }
            _ = RegA.next(b);
        } else {
            change.a_8bit = null;
        }
    }
    if (change.xy_8bit) |value| {
        const new_size: Instruction.SizeMode = if (value) .@"8bit" else .@"16bit";
        if (b.xy_size != new_size) {
            b.xy_size = if (value) .@"8bit" else .@"16bit";
            if (b.start_xy_size == .none) {
                b.start_xy_size = b.xy_size;
            }
            _ = RegX.next(b);
            _ = RegY.next(b);

            // Changing the index-register size from 16-bit to 8-bit clears the high-byte
            if (b.xy_size == .@"8bit") {
                b.clobbers.put(b.build_system.allocator, .x, {}) catch @panic("Out of memory");
                b.clobbers.put(b.build_system.allocator, .y, {}) catch @panic("Out of memory");
            }
        } else {
            change.a_8bit = null;
        }
    }

    var set: Instruction.StatusRegister = .{};
    var clear: Instruction.StatusRegister = .{};

    inline for (std.meta.fields(Instruction.StatusRegister)) |field| {
        if (@field(change, field.name)) |value| {
            if (value) {
                @field(set, field.name) = true;
            } else {
                @field(clear, field.name) = true;
            }
        }
    }

    if (set != @as(Instruction.StatusRegister, .{})) {
        b.emit(.{ .sep = set });
    }
    if (clear != @as(Instruction.StatusRegister, .{})) {
        b.emit(.{ .rep = clear });
    }
}

/// Set the Direct Page to the specified value
pub fn set_direct_page(b: *Builder, direct_page: u16) void {
    var a = b.reg_a16();
    a = .load(b, direct_page);
    a.transfer_to(.direct_page);
}

/// Invokes the generator function associated with this builder
pub fn build(b: *Builder) !void {
    b.symbol(b);

    try b.resolve_branch_relocs();
    try b.genereate_bytecode();
}

fn resolve_branch_relocs(b: *Builder) !void {
    // Relative offsets to the target instruction to determine short- / long-form
    var reloc_offsets: std.AutoArrayHashMapUnmanaged(usize, i32) = .{};
    defer reloc_offsets.deinit(b.build_system.allocator);

    for (b.instruction_info.items, 0..) |info, i| {
        if (info.branch_reloc != null) {
            // Default to long-form, lower to short-form later
            try reloc_offsets.put(b.build_system.allocator, i, std.math.maxInt(i32));
        }
    }

    const short_sizes: std.EnumArray(InstructionInfo.BranchRelocation.Type, u8) = .init(.{
        .always = comptime Instruction.bra.size(),
        .jump_long = comptime Instruction.jml.size(),
    });
    const long_sizes: std.EnumArray(InstructionInfo.BranchRelocation.Type, u8) = .init(.{
        .always = comptime Instruction.jmp.size(),
        .jump_long = comptime Instruction.jml.size(),
    });

    // Interativly lower to short-form
    var changed = true;
    while (changed) {
        changed = false;

        for (reloc_offsets.keys(), reloc_offsets.values()) |source_idx, *relative_offset| {
            // If its's already short, don't mark this as a change, but still recalculate the offset
            const already_short = relative_offset.* >= std.math.minInt(i8) and relative_offset.* <= std.math.maxInt(i8);

            const reloc = b.instruction_info.items[source_idx].branch_reloc.?;

            // Calculate offset to target
            const min = @min(source_idx + 1, reloc.target.index.?);
            const max = @max(source_idx + 1, reloc.target.index.?);

            relative_offset.* = 0;
            for (b.instruction_info.items[min..max], min..max) |info, i| {
                if (info.branch_reloc) |other_reloc| {
                    const other_offset = reloc_offsets.get(i).?;

                    if (other_offset >= std.math.minInt(i8) and other_offset <= std.math.maxInt(i8)) {
                        relative_offset.* += short_sizes.get(other_reloc.type);
                    } else {
                        relative_offset.* += long_sizes.get(other_reloc.type);
                    }
                } else {
                    relative_offset.* += info.instr.size();
                }
            }
            if (reloc.target.index.? <= source_idx) {
                relative_offset.* = -relative_offset.*;
            }

            if (!already_short and relative_offset.* >= std.math.minInt(i8) and relative_offset.* <= std.math.maxInt(i8)) {
                changed = true;
            }
        }
    }

    // Calculate target offsets (for jumps)
    var target_offsets: std.AutoArrayHashMapUnmanaged(usize, u16) = .{};
    defer target_offsets.deinit(b.build_system.allocator);

    for (reloc_offsets.keys()) |source_idx| {
        const reloc = b.instruction_info.items[source_idx].branch_reloc.?;

        var offset: usize = 0;
        for (b.instruction_info.items[0..reloc.target.index.?], 0..) |info, i| {
            if (info.branch_reloc) |other_reloc| {
                const other_offset = reloc_offsets.get(i).?;

                if (other_offset >= std.math.minInt(i8) and other_offset <= std.math.maxInt(i8)) {
                    offset += short_sizes.get(other_reloc.type);
                } else {
                    offset += long_sizes.get(other_reloc.type);
                }
            } else {
                offset += info.instr.size();
            }
        }

        try target_offsets.put(b.build_system.allocator, source_idx, @intCast(offset));
    }

    // Insert instructions (reversed to avoid shifting following indices)
    var it = std.mem.reverseIterator(reloc_offsets.keys());

    while (it.next()) |source_idx| {
        const info = &b.instruction_info.items[source_idx];
        const reloc = info.branch_reloc.?;

        const relative_offset = reloc_offsets.get(source_idx).?;
        const target_offset = target_offsets.get(source_idx).?;

        const use_short = relative_offset >= std.math.minInt(i8) and relative_offset <= std.math.maxInt(i8);

        switch (reloc.type) {
            .always => {
                if (use_short) {
                    info.instr = .{ .bra = @intCast(relative_offset) };
                } else {
                    info.instr = .{ .jmp = undefined };
                    info.reloc = .{
                        .type = .addr16,
                        .target_sym = .{ .function = b.symbol },
                        .target_offset = target_offset,
                    };
                }
            },
            .jump_long => {
                info.instr = .{ .jml = undefined };
                info.reloc = .{
                    .type = .addr24,
                    .target_sym = .{ .function = b.symbol },
                    .target_offset = target_offset,
                };
            },
        }
    }
}

/// Generates the raw assembly bytes for all instructions
fn genereate_bytecode(b: *Builder) !void {
    b.instruction_data.clearRetainingCapacity();
    for (b.instruction_info.items) |*info| {
        const target_register = info.instr.target_register();
        const register_size = switch (target_register) {
            .none => .none,
            .a => info.a_size,
            .x, .y => info.xy_size,
        };
        if (target_register != .none) {
            std.debug.assert(register_size != .none);
        }

        info.offset = @intCast(b.instruction_data.items.len);
        info.instr.write_data(b.instruction_data.writer(b.build_system.allocator), register_size) catch @panic("Out of memory");
    }
}

/// Unwinds the stack to find the calling code and retrieve code comments
fn resolve_comments(b: *Builder, start_addr: usize) ![]const []const u8 {
    if (b.source_location == null) {
        return &.{};
    }

    const debug_info = try std.debug.getSelfDebugInfo();

    var context: std.debug.ThreadContext = undefined;
    const has_context = std.debug.getContext(&context);

    var it = (if (has_context) blk: {
        break :blk std.debug.StackIterator.initWithContext(start_addr, debug_info, &context) catch null;
    } else null) orelse std.debug.StackIterator.init(start_addr, null);
    defer it.deinit();

    while (it.next()) |return_address| {
        const addr = return_address -| 1;
        const module = try debug_info.getModuleForAddress(addr);
        const symbol = try module.getSymbolAtAddress(b.build_system.allocator, addr);

        const srcloc = symbol.source_location orelse {
            if (symbol.source_location) |sl| debug_info.allocator.free(sl.file_name);
            continue;
        };

        try b.curr_caller_lines.put(b.build_system.allocator, .{ .file = srcloc.file_name, .function = symbol.name }, srcloc.line);
    }

    // Find first movement (we dont want a different path in a macro to cause comments)
    var comments: std.ArrayListUnmanaged([]const u8) = .{};
    errdefer {
        for (comments.items) |comment| {
            b.build_system.allocator.free(comment);
        }
        comments.deinit(b.build_system.allocator);
    }

    var i: usize = b.curr_caller_lines.count() - 1;
    while (true) {
        const srcloc = b.curr_caller_lines.keys()[i];
        const curr_line = b.curr_caller_lines.values()[i];
        if (b.prev_caller_lines.get(srcloc)) |prev_line| {
            if (curr_line > prev_line) {
                // Found important code location

                var src_file = try std.fs.cwd().openFile(srcloc.file, .{});
                defer src_file.close();

                var buf_reader = std.io.bufferedReader(src_file.reader());
                const src_reader = buf_reader.reader();

                // Go to previous line
                for (0..prev_line) |_| {
                    try src_reader.skipUntilDelimiterOrEof('\n');
                }

                // Read inbetween lines
                var line_buffer: std.ArrayListUnmanaged(u8) = .{};
                defer line_buffer.deinit(b.build_system.allocator);

                for ((prev_line + 1)..(curr_line + 1)) |_| {
                    line_buffer.clearRetainingCapacity();
                    try src_reader.streamUntilDelimiter(line_buffer.writer(b.build_system.allocator), '\n', null);

                    const line = std.mem.trim(u8, line_buffer.items, " \t\n\r");
                    const comment_start = std.mem.indexOf(u8, line, "//") orelse continue;

                    try comments.append(b.build_system.allocator, try b.build_system.allocator.dupe(u8, line[(comment_start + "//".len)..]));
                }

                break;
            }
        }

        if (i == 0) break;
        i -= 1;
    }

    const prev = b.prev_caller_lines;
    b.prev_caller_lines = b.curr_caller_lines;
    b.curr_caller_lines = prev;

    for (b.curr_caller_lines.keys()) |key| {
        b.build_system.allocator.free(key.file);
    }
    b.curr_caller_lines.clearRetainingCapacity();

    return comments.toOwnedSlice(b.build_system.allocator);
}
