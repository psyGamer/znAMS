//! Intermediate representation for program logic
const std = @import("std");
const Instruction = @import("instruction.zig").Instruction;
const SymbolIndex = @import("Sema.zig").SymbolIndex;
const Relocation = @import("CodeGen.zig").Relocation;
const BranchRelocation = @import("CodeGen.zig").BranchRelocation;
const NodeIndex = @import("Ast.zig").NodeIndex;

pub const Ir = struct {
    pub const RegisterType = enum {
        none,
        a8,
        a16,
        x8,
        x16,
        y8,
        y16,

        pub fn byteSize(reg: RegisterType) u16 {
            return switch (reg) {
                .none => unreachable,
                .a8, .x8, .y8 => 1,
                .a16, .x16, .y16 => 2,
            };
        }
        pub fn bitSize(reg: RegisterType) u16 {
            return switch (reg) {
                .none => unreachable,
                .a8, .x8, .y8 => 8,
                .a16, .x16, .y16 => 16,
            };
        }
    };
    pub const ChangeStatusFlags = struct {
        carry: ?bool = null,
        zero: ?bool = null,
        irq_disable: ?bool = null,
        decimal: ?bool = null,
        idx_8bit: ?bool = null,
        mem_8bit: ?bool = null,
        overflow: ?bool = null,
        negative: ?bool = null,
    };

    /// Micro-Operation which compose `store_...` instructions
    pub const StoreOperation = struct {
        value: union(enum) {
            immediate: std.math.big.int.Const,
            global: struct {
                symbol: SymbolIndex,
                bit_offset: u16,
            },
        },

        bit_offset: u16,
        bit_size: u16,

        /// Byte-offset for the register write for this operation
        write_offset: u16 = undefined,
    };

    const Tag = union(enum) {
        instruction: struct {
            instr: Instruction,
            reloc: ?Relocation,
        },
        change_status_flags: ChangeStatusFlags,

        /// Stores the value of the following `store_operation`s using the intermediate-register into the target
        store: struct {
            intermediate_register: RegisterType,
            symbol: SymbolIndex,
            operations: u16,
        },
        /// Immediatly followed `store.operations`-times after a `store` instruction
        store_operation: StoreOperation,

        /// Loads the immedate value into the register
        load_value: struct {
            register: RegisterType,
            value: Instruction.Imm816,
        },
        /// Loads the variable at the offset into the register
        load_variable: struct {
            register: RegisterType,
            symbol: SymbolIndex,
            offset: u16 = 0,
        },

        /// Stores the value of the register into the variable
        store_variable: struct {
            register: RegisterType,
            symbol: SymbolIndex,
            offset: u16 = 0,
        },
        /// Stores zero into the variable
        zero_variable: struct {
            symbol: SymbolIndex,
            offset: u16 = 0,
        },

        /// ANDs the accumulator with the value
        and_value: Instruction.Imm816,
        /// ANDs the accumulator with the variable
        and_variable: struct {
            symbol: SymbolIndex,
            offset: u16 = 0,
        },

        /// ORs the accumulator with the value
        or_value: Instruction.Imm816,
        /// ORs the accumulator with the variable
        or_variable: struct {
            symbol: SymbolIndex,
            offset: u16 = 0,
        },

        /// Bit-Shift the value in the accumulator to the left
        shift_accum_left: u16,
        /// Bit-Shift the value in the accumulator to the right
        shift_accum_right: u16,

        /// Bit-Rotate the value in the accumulator to the left
        rotate_accum_left: u16,
        /// Bit-Rotate the value in the accumulator to the right
        rotate_accum_right: u16,

        /// Sets all bits in the target to 0 where the mask is 1
        clear_bits: struct {
            symbol: SymbolIndex,
            offset: u16 = 0,
            mask: Instruction.Imm816,
        },

        /// Invokes the target method as a subroutine
        call: struct {
            target: SymbolIndex,
            target_offset: u16 = 0,
        },

        branch: BranchRelocation,

        label: []const u8,
    };

    tag: Tag,
    node: NodeIndex,

    pub fn deinit(ir: Ir, allocator: std.mem.Allocator) void {
        switch (ir.tag) {
            .label => |name| allocator.free(name),
            else => {},
        }
    }
};
