const std = @import("std");
const Ast = @import("../Ast.zig");
const NodeIndex = Ast.NodeIndex;
const Sema = @import("../Sema.zig");
const Ir = @import("../ir.zig").Ir;
const Symbol = @import("../symbol.zig").Symbol;
const SymbolLocation = @import("../symbol.zig").SymbolLocation;
const TypeSymbol = @import("../symbol.zig").TypeSymbol;
const Instruction = @import("../instruction.zig").Instruction;
const Opcode = @import("../instruction.zig").Opcode;
const Relocation = @import("../CodeGen.zig").Relocation;
const BuiltinFn = @import("BuiltinFn.zig");
const BuiltinVar = @import("BuiltinVar.zig");

const Analyzer = @This();
const Error = Sema.AnalyzeError;

ast: *const Ast,
sema: *Sema,

symbol: *Symbol.Function,
symbol_location: SymbolLocation,

ir: std.ArrayListUnmanaged(Ir) = .empty,

/// Size of the A-Register / Memory instructions
mem_size: Instruction.SizeMode = .none,
/// Size of the X/Y-Registers
idx_size: Instruction.SizeMode = .none,

// Used to generate unique labels for loops
while_loops: u16 = 0,

pub fn handleFnDef(ana: *Analyzer, node_idx: NodeIndex) Error!void {
    try ana.handleBlock(ana.ast.node_data[node_idx].fn_def.block);
}

pub fn handleBlock(ana: *Analyzer, node_idx: NodeIndex) Error!void {
    const range = ana.ast.node_data[node_idx].sub_range;
    for (range.extra_start..range.extra_end) |extra_idx| {
        const child_idx = ana.ast.extra_data[extra_idx];

        switch (ana.ast.node_tags[child_idx]) {
            .instruction => try ana.handleInstruction(child_idx),
            .label => try ana.handleLabel(child_idx),
            .assign_statement => try ana.handleAssign(child_idx),
            .call_statement => try ana.handleCall(child_idx),
            .while_statement => try ana.handleWhile(child_idx),
            else => unreachable,
        }
    }
}

pub fn handleInstruction(ana: *Analyzer, node_idx: NodeIndex) Error!void {
    const opcode_name = ana.ast.parseIdentifier(ana.ast.node_tokens[node_idx]);

    const opcode = get_opcode: {
        inline for (std.meta.fields(Instruction)) |field| {
            @setEvalBranchQuota(std.meta.fields(Opcode).len * 1000);
            const curr_opcode: Opcode = comptime get_tag: {
                for (std.meta.fields(Opcode)) |tag| {
                    if (std.mem.eql(u8, field.name, tag.name)) {
                        break :get_tag @enumFromInt(tag.value);
                    }
                }
                unreachable;
            };
            const mnemonic = field.name[0..3];

            if (std.mem.eql(u8, mnemonic, opcode_name)) {
                if (field.type == void and ana.ast.isToken(ana.ast.node_tokens[node_idx] + 1, .new_line)) {
                    break :get_opcode curr_opcode;
                }
                if (field.type == Instruction.Imm816) {
                    if (ana.ast.areTokens(ana.ast.node_tokens[node_idx] + 1, &.{ .int_literal, .new_line })) {
                        break :get_opcode curr_opcode;
                    }
                    if (ana.ast.areTokens(ana.ast.node_tokens[node_idx] + 1, &.{ .ident, .new_line })) {
                        break :get_opcode curr_opcode;
                    }
                }
                if (field.type == Instruction.Addr16) {
                    if (ana.ast.areTokens(ana.ast.node_tokens[node_idx] + 1, &.{ .ident, .new_line })) {
                        break :get_opcode curr_opcode;
                    }
                }

                if (curr_opcode == .bra or
                    curr_opcode == .jmp or curr_opcode == .jml or curr_opcode == .jsr or curr_opcode == .jsl)
                {
                    if (ana.ast.areTokens(ana.ast.node_tokens[node_idx] + 1, &.{ .ident, .new_line })) {
                        break :get_opcode curr_opcode;
                    }
                }
            }
        }

        try ana.sema.errors.append(ana.sema.allocator, .{
            .tag = .invalid_opcode,
            .ast = ana.ast,
            .token = ana.ast.node_tokens[node_idx],
        });
        return;
    };

    const instr: Instruction, const reloc: ?Relocation = get_instr: switch (opcode) {
        inline else => |t| {
            const field = comptime find_field: {
                for (std.meta.fields(Instruction)) |field| {
                    if (std.mem.eql(u8, field.name, @tagName(t))) {
                        break :find_field field;
                    }
                }
                unreachable;
            };

            const operand_token = ana.ast.node_tokens[node_idx] + 1;

            const size_type = opcode.sizeType();
            const curr_size = switch (size_type) {
                .mem => ana.mem_size,
                .idx => ana.idx_size,
                .none => .none,
            };

            if (size_type != .none and curr_size == .none) {
                try ana.sema.errors.append(ana.sema.allocator, .{
                    .tag = .undefined_size_mode,
                    .ast = ana.ast,
                    .token = operand_token,
                    .extra = .{ .size_type = size_type },
                });
                return error.AnalyzeFailed;
            }

            if (field.type == void) {
                break :get_instr .{ @unionInit(Instruction, field.name, {}), null };
            }

            if (field.type == Instruction.Imm816) {
                if (ana.ast.token_tags[operand_token] == .int_literal) {
                    if (curr_size == .@"8bit") {
                        const value = try ana.sema.parseInt(u8, ana.ast, operand_token);
                        break :get_instr .{ @unionInit(Instruction, field.name, .{ .imm8 = value }), null };
                    }
                    if (curr_size == .@"16bit") {
                        const value = try ana.sema.parseInt(u16, ana.ast, operand_token);
                        break :get_instr .{ @unionInit(Instruction, field.name, .{ .imm16 = value }), null };
                    }
                }

                if (ana.ast.token_tags[operand_token] == .ident and ana.ast.token_tags[operand_token + 1] == .new_line) {
                    const value_sym, _ = try ana.sema.resolveSymbol(ana.ast, operand_token, ana.symbol_location.module);
                    switch (value_sym.*) {
                        .constant => |const_sym| {
                            if (curr_size == .@"8bit") {
                                if (const_sym.type != .raw or const_sym.type.raw != .unsigned_int or const_sym.type.raw.unsigned_int > 8) {
                                    try ana.sema.errors.append(ana.sema.allocator, .{
                                        .tag = .expected_type,
                                        .ast = ana.ast,
                                        .token = operand_token,
                                        .extra = .{ .expected_type = .{
                                            .expected = .{ .raw = .{ .unsigned_int = 8 } },
                                            .actual = const_sym.type,
                                        } },
                                    });
                                    return error.AnalyzeFailed;
                                }

                                break :get_instr .{ @unionInit(Instruction, field.name, .{ .imm8 = const_sym.value.resolve(u8, ana.sema) }), null };
                            }
                            if (curr_size == .@"16bit") {
                                if (const_sym.type != .raw or const_sym.type.raw != .unsigned_int or const_sym.type.raw.unsigned_int > 16) {
                                    try ana.sema.errors.append(ana.sema.allocator, .{
                                        .tag = .expected_type,
                                        .ast = ana.ast,
                                        .token = operand_token,
                                        .extra = .{ .expected_type = .{
                                            .expected = .{ .raw = .{ .unsigned_int = 16 } },
                                            .actual = const_sym.type,
                                        } },
                                    });
                                    return error.AnalyzeFailed;
                                }

                                break :get_instr .{ @unionInit(Instruction, field.name, .{ .imm16 = const_sym.value.resolve(u16, ana.sema) }), null };
                            }

                            unreachable;
                        },
                        .variable => |var_sym| {
                            _ = var_sym; // autofix
                            @panic("TODO");
                        },
                        .register => |reg_sym| {
                            _ = reg_sym; // autofix
                            @panic("TODO");
                        },
                        else => {
                            try ana.sema.errors.append(ana.sema.allocator, .{
                                .tag = .expected_const_var_reg_symbol,
                                .ast = ana.ast,
                                .token = operand_token,
                                .extra = .{ .actual_symbol = value_sym.* },
                            });
                            return error.AnalyzeFailed;
                        },
                    }
                }
            }
            if (field.type == Instruction.Addr16) {
                if (ana.ast.token_tags[operand_token] == .ident and ana.ast.token_tags[operand_token + 1] == .new_line) {
                    const value_sym_loc: SymbolLocation = .{
                        .module = ana.symbol_location.module,
                        .name = ana.ast.parseIdentifier(operand_token),
                    };
                    const value_sym = ana.sema.lookupSymbol(value_sym_loc) orelse {
                        try ana.sema.errors.append(ana.sema.allocator, .{
                            .tag = .undefined_symbol,
                            .ast = ana.ast,
                            .token = operand_token,
                        });
                        return error.AnalyzeFailed;
                    };

                    switch (value_sym.*) {
                        .variable => |var_sym| {
                            if (curr_size == .@"8bit") {
                                if (var_sym.type != .raw or var_sym.type.raw != .unsigned_int or var_sym.type.raw.unsigned_int > 8) {
                                    try ana.sema.errors.append(ana.sema.allocator, .{
                                        .tag = .expected_type,
                                        .ast = ana.ast,
                                        .token = operand_token,
                                        .extra = .{ .expected_type = .{
                                            .expected = .{ .raw = .{ .unsigned_int = 8 } },
                                            .actual = var_sym.type,
                                        } },
                                    });
                                    return error.AnalyzeFailed;
                                }
                            } else if (curr_size == .@"16bit") {
                                if (var_sym.type != .raw or var_sym.type.raw != .unsigned_int or var_sym.type.raw.unsigned_int > 16) {
                                    try ana.sema.errors.append(ana.sema.allocator, .{
                                        .tag = .expected_type,
                                        .ast = ana.ast,
                                        .token = operand_token,
                                        .extra = .{ .expected_type = .{
                                            .expected = .{ .raw = .{ .unsigned_int = 8 } },
                                            .actual = var_sym.type,
                                        } },
                                    });
                                    return error.AnalyzeFailed;
                                }
                            }

                            break :get_instr .{ @unionInit(Instruction, field.name, undefined), .{
                                .type = .addr16,
                                .target_sym = value_sym_loc,
                            } };
                        },
                        else => {
                            try ana.sema.errors.append(ana.sema.allocator, .{
                                .tag = .expected_var_symbol,
                                .ast = ana.ast,
                                .token = operand_token,
                                .extra = .{ .actual_symbol = value_sym.* },
                            });
                            return error.AnalyzeFailed;
                        },
                    }
                }
            }

            if (opcode == .bra or
                opcode == .jmp or opcode == .jml or opcode == .jsr or opcode == .jsl)
            {
                break :get_instr .{ @unionInit(Instruction, field.name, undefined), .{
                    .type = switch (opcode) {
                        .bra => .rel8,
                        .jmp, .jsr => .addr16,
                        .jml, .jsl => .addr24,
                        else => unreachable,
                    },
                    .target_sym = .parse(ana.ast.parseIdentifier(operand_token), ana.symbol_location.module),
                } };
            }

            unreachable;
        },
    };

    try ana.ir.append(ana.sema.allocator, .{
        .tag = .{ .instruction = .{ .instr = instr, .reloc = reloc } },
        .node = node_idx,
    });
}

pub fn handleLabel(ana: *Analyzer, node_idx: NodeIndex) Error!void {
    const label_token = ana.ast.node_tokens[node_idx];
    const label = ana.ast.parseIdentifier(label_token);

    if (ana.sema.lookupSymbol(.{ .module = ana.symbol_location.module, .name = label })) |existing_sym| {
        try ana.sema.errors.append(ana.sema.allocator, .{
            .tag = .duplicate_label,
            .ast = ana.ast,
            .token = label_token,
        });
        try ana.sema.errors.append(ana.sema.allocator, .{
            .tag = .existing_symbol,
            .is_note = true,
            .ast = ana.ast,
            .token = ana.ast.node_tokens[existing_sym.common().node],
        });
        return error.AnalyzeFailed;
    }
    for (ana.ir.items) |ir| {
        if (ir.tag != .label) {
            continue;
        }

        const existing_label = ir.tag.label;
        if (std.mem.eql(u8, label, existing_label)) {
            try ana.sema.errors.append(ana.sema.allocator, .{
                .tag = .duplicate_label,
                .ast = ana.ast,
                .token = label_token,
            });
            try ana.sema.errors.append(ana.sema.allocator, .{
                .tag = .existing_label,
                .is_note = true,
                .ast = ana.ast,
                .token = ana.ast.node_tokens[ir.node],
            });
            return error.AnalyzeFailed;
        }
    }

    try ana.ir.append(ana.sema.allocator, .{
        .tag = .{ .label = try ana.sema.allocator.dupe(u8, label) },
        .node = node_idx,
    });
}

fn handleAssign(ana: *Analyzer, node_idx: NodeIndex) Error!void {
    const data = ana.ast.node_data[node_idx].assign_statement;

    const target_ident = ana.ast.node_tokens[node_idx];

    const target: union(enum) { builtin: BuiltinVar, symbol: SymbolLocation } = get_target: {
        if (ana.ast.token_tags[target_ident] == .builtin_ident) {
            // Built-in variable
            if (BuiltinVar.get(ana.ast.parseIdentifier(target_ident))) |builtin| {
                break :get_target .{ .builtin = builtin };
            } else {
                try ana.sema.errors.append(ana.sema.allocator, .{
                    .tag = .invalid_builtin,
                    .ast = ana.ast,
                    .token = ana.ast.node_tokens[node_idx],
                });
                return error.AnalyzeFailed;
            }
        } else {
            _, const target_symbol_loc = try ana.sema.resolveSymbol(ana.ast, target_ident, ana.symbol_location.module);
            break :get_target .{ .symbol = target_symbol_loc };
        }
    };
    const target_type = get_type: switch (target) {
        .builtin => |builtin| break :get_type builtin.type,
        .symbol => |sym_loc| {
            const target_symbol = ana.sema.lookupSymbol(sym_loc).?;
            break :get_type switch (target_symbol.*) {
                .constant => |const_sym| const_sym.type,
                .variable => |var_sym| var_sym.type,
                .register => |reg_sym| reg_sym.type,
                else => {
                    try ana.sema.errors.append(ana.sema.allocator, .{
                        .tag = .expected_const_var_reg_symbol,
                        .ast = ana.ast,
                        .token = target_ident,
                        .extra = .{ .actual_symbol = target_symbol.* },
                    });
                    return error.AnalyzeFailed;
                },
            };
        },
    };

    const value_expr = try ana.sema.resolveExprValue(ana.ast, data.value, target_type, ana.symbol_location.module);
    defer value_expr.deinit(ana.sema.allocator);

    const opt_register_type = get_register: {
        if (value_expr != .register) {
            if (data.intermediate_register == Ast.null_token) {
                break :get_register null;
            }

            const register_name = ana.ast.tokenSource(data.intermediate_register);
            break :get_register std.meta.stringToEnum(Sema.RegisterType, register_name) orelse {
                try ana.sema.errors.append(ana.sema.allocator, .{
                    .tag = .invalid_register,
                    .ast = ana.ast,
                    .token = data.intermediate_register,
                });
                return error.AnalyzeFailed;
            };
        } else {
            break :get_register value_expr.register;
        }
    };

    if (target == .builtin) {
        if (!std.mem.containsAtLeast(?Sema.RegisterType, target.builtin.allowed_registers, 1, &.{opt_register_type})) {
            if (opt_register_type) |register_type| {
                try ana.sema.errors.append(ana.sema.allocator, .{
                    .tag = .unsupported_register,
                    .ast = ana.ast,
                    .token = data.intermediate_register,
                    .extra = .{ .unsupported_register = .{
                        .register = register_type,
                        .message = target.builtin.name,
                    } },
                });
                try ana.sema.errors.append(ana.sema.allocator, .{
                    .tag = .supported_registers,
                    .ast = ana.ast,
                    .token = data.intermediate_register,
                    .is_note = true,
                    .extra = .{ .supported_registers = target.builtin.allowed_registers },
                });
                return error.AnalyzeFailed;
            } else {
                try ana.sema.errors.append(ana.sema.allocator, .{
                    .tag = .expected_intermediate_register,
                    .ast = ana.ast,
                    .token = data.intermediate_register,
                });
                return error.AnalyzeFailed;
            }
        }

        try target.builtin.write(ana, node_idx, value_expr, opt_register_type);
        return;
    }

    const register_size: u8 = if (opt_register_type) |register_type|
        switch (register_type) {
            .a8, .x8, .y8 => 1,
            .a16, .x16, .y16 => 2,
        }
    else switch (ana.mem_size) {
        .none => @panic("TODO"),
        .@"8bit" => 1,
        .@"16bit" => 2,
    };

    // Validate size
    const target_size = target_type.size();
    if (value_expr == .register) {
        if (target_size != register_size) {
            try ana.sema.errors.append(ana.sema.allocator, .{
                .tag = .expected_register_size,
                .ast = ana.ast,
                .token = data.intermediate_register,
                .extra = .{ .expected_register_size = .{
                    .expected = target_size * 8,
                    .actual = register_size * 8,
                } },
            });
            return error.AnalyzeFailed;
        }
    } else {
        if (target_size % register_size != 0) {
            try ana.sema.errors.append(ana.sema.allocator, .{
                .tag = .expected_mod_register_size,
                .ast = ana.ast,
                .token = data.intermediate_register,
                .extra = .{ .expected_register_size = .{
                    .expected = target_size * 8,
                    .actual = register_size * 8,
                } },
            });
            return error.AnalyzeFailed;
        }
    }

    switch (value_expr) {
        .value, .variable => {
            // Storing zero doesn't require an intermediate register
            if (value_expr == .value and value_expr.value == 0) {
                // If an intermediate register exists, use it for the size
                if (opt_register_type) |register_type| {
                    try ana.ir.append(ana.sema.allocator, .{
                        .tag = .{ .change_size = .{
                            .target = .mem,
                            .mode = switch (register_type) {
                                .a8, .x8, .y8 => .@"8bit",
                                .a16, .x16, .y16 => .@"16bit",
                            },
                        } },
                        .node = node_idx,
                    });
                }

                // n stores
                try ana.ir.ensureUnusedCapacity(ana.sema.allocator, @divExact(target_size, register_size));

                var offset: std.math.Log2Int(TypeSymbol.ComptimeIntValue) = 0;
                while (offset < target_size) : (offset += @intCast(register_size * 8)) {
                    ana.ir.appendAssumeCapacity(.{
                        .tag = .{ .zero_variable = .{
                            .symbol = target.symbol,
                            .offset = offset,
                        } },
                        .node = node_idx,
                    });
                }
            } else {
                const register_type = opt_register_type orelse {
                    try ana.sema.errors.append(ana.sema.allocator, .{
                        .tag = .expected_intermediate_register,
                        .ast = ana.ast,
                        .token = ana.ast.node_tokens[node_idx],
                    });
                    return error.AnalyzeFailed;
                };

                // 1 size change + 2n load/stores
                try ana.ir.ensureUnusedCapacity(ana.sema.allocator, 1 + @divExact(target_size, register_size) * 2);
                ana.ir.appendAssumeCapacity(.{
                    .tag = .{ .change_size = .{
                        .target = switch (register_type) {
                            .a8, .a16 => .mem,
                            .x8, .x16, .y8, .y16 => .idx,
                        },
                        .mode = switch (register_type) {
                            .a8, .x8, .y8 => .@"8bit",
                            .a16, .x16, .y16 => .@"16bit",
                        },
                    } },
                    .node = node_idx,
                });

                var offset: std.math.Log2Int(TypeSymbol.ComptimeIntValue) = 0;
                while (offset < target_size) : (offset += @intCast(register_size * 8)) {
                    switch (value_expr) {
                        .value => |value| {
                            ana.ir.appendAssumeCapacity(.{
                                .tag = .{
                                    .load_value = .{
                                        .register = register_type,
                                        .value = switch (register_type) {
                                            .a8, .x8, .y8 => .{ .imm8 = @truncate(@as(TypeSymbol.UnsignedComptimeIntValue, @bitCast(value)) >> offset) },
                                            .a16, .x16, .y16 => .{ .imm16 = @truncate(@as(TypeSymbol.UnsignedComptimeIntValue, @bitCast(value)) >> offset) },
                                        },
                                    },
                                },
                                .node = node_idx,
                            });
                        },
                        .variable => |sym_loc| {
                            ana.ir.appendAssumeCapacity(.{
                                .tag = .{
                                    .load_variable = .{
                                        .register = register_type,
                                        .symbol = sym_loc,
                                        .offset = offset,
                                    },
                                },
                                .node = node_idx,
                            });
                        },
                        else => unreachable,
                    }

                    ana.ir.appendAssumeCapacity(.{
                        .tag = .{ .store_variable = .{
                            .register = register_type,
                            .symbol = target.symbol,
                            .offset = offset,
                        } },
                        .node = node_idx,
                    });
                }
            }
        },
        .packed_fields => |fields| {
            // If an intermediate register exists, use it for the size
            if (opt_register_type) |register_type| {
                try ana.ir.append(ana.sema.allocator, .{
                    .tag = .{ .change_size = .{
                        .target = .mem,
                        .mode = switch (register_type) {
                            .a8, .x8, .y8 => .@"8bit",
                            .a16, .x16, .y16 => .@"16bit",
                        },
                    } },
                    .node = node_idx,
                });
            }

            inline for (&.{ u8, u16 }) |T| {
                if (register_size == @sizeOf(T)) {
                    var byte_offset: u8 = 0;
                    var bit_offset: u8 = 0;

                    var used_symbols: std.ArrayListUnmanaged(PackedSymbol) = .empty;
                    defer used_symbols.deinit(ana.sema.allocator);

                    while (byte_offset < target_size) : (byte_offset += @sizeOf(T)) {
                        var curr_value: T = 0;
                        used_symbols.clearRetainingCapacity();

                        try ana.resolvePackedFields(T, node_idx, fields, &curr_value, &used_symbols, byte_offset, &bit_offset, 0);

                        if (used_symbols.items.len == 0) {
                            // No variables involved
                            if (curr_value == 0) {
                                try ana.ir.append(ana.sema.allocator, .{
                                    .tag = .{ .zero_variable = .{
                                        .symbol = target.symbol,
                                        .offset = byte_offset,
                                    } },
                                    .node = node_idx,
                                });
                            } else {
                                const register_type = opt_register_type orelse {
                                    try ana.sema.errors.append(ana.sema.allocator, .{
                                        .tag = .expected_intermediate_register,
                                        .ast = ana.ast,
                                        .token = ana.ast.node_tokens[node_idx],
                                    });
                                    return error.AnalyzeFailed;
                                };

                                try ana.ir.append(ana.sema.allocator, .{
                                    .tag = .{ .load_value = .{
                                        .register = register_type,
                                        .value = if (T == u8)
                                            .{ .imm8 = curr_value }
                                        else
                                            .{ .imm16 = curr_value },
                                    } },
                                    .node = node_idx,
                                });
                                try ana.ir.append(ana.sema.allocator, .{
                                    .tag = .{ .store_variable = .{
                                        .register = register_type,
                                        .symbol = target.symbol,
                                        .offset = byte_offset,
                                    } },
                                    .node = node_idx,
                                });
                            }
                        } else {
                            // Some variables involved
                            const register_type = opt_register_type orelse {
                                try ana.sema.errors.append(ana.sema.allocator, .{
                                    .tag = .expected_intermediate_register,
                                    .ast = ana.ast,
                                    .token = ana.ast.node_tokens[node_idx],
                                });
                                return error.AnalyzeFailed;
                            };
                            if (register_type != .a8 and register_type != .a16) {
                                try ana.sema.errors.append(ana.sema.allocator, .{
                                    .tag = .unsupported_register,
                                    .ast = ana.ast,
                                    .token = data.intermediate_register,
                                    .extra = .{ .unsupported_register = .{
                                        .register = register_type,
                                        .message = "object-initializer including variables",
                                    } },
                                });
                                try ana.sema.errors.append(ana.sema.allocator, .{
                                    .tag = .supported_registers,
                                    .ast = ana.ast,
                                    .token = data.intermediate_register,
                                    .is_note = true,
                                    .extra = .{ .supported_registers = &.{ .a8, .a16 } },
                                });
                                return error.AnalyzeFailed;
                            }

                            // Shift in variables
                            var i: u8 = @intCast(used_symbols.items.len - 1);
                            while (true) : (i -= 1) {
                                const curr_symbol = used_symbols.items[i];

                                if (i == used_symbols.items.len - 1) {
                                    // First variable
                                    try ana.ir.append(ana.sema.allocator, .{
                                        .tag = .{ .load_variable = .{
                                            .register = register_type,
                                            .symbol = curr_symbol.symbol,
                                            .offset = curr_symbol.byte_offset,
                                        } },
                                        .node = node_idx,
                                    });
                                } else {
                                    // Other variable
                                    const prev_symbol = used_symbols.items[i + 1];

                                    try ana.ir.append(ana.sema.allocator, .{
                                        .tag = .{ .shift_accum_left = prev_symbol.shift_offset - curr_symbol.shift_offset },
                                        .node = node_idx,
                                    });
                                    try ana.ir.append(ana.sema.allocator, .{
                                        .tag = .{ .or_variable = .{
                                            .symbol = curr_symbol.symbol,
                                            .offset = curr_symbol.byte_offset,
                                        } },
                                        .node = node_idx,
                                    });
                                }

                                if (i == 0) break;
                            }

                            try ana.ir.append(ana.sema.allocator, .{
                                .tag = .{ .shift_accum_left = used_symbols.items[0].shift_offset },
                                .node = node_idx,
                            });

                            // OR-in constant value
                            if (curr_value != 0) {
                                try ana.ir.append(ana.sema.allocator, .{
                                    .tag = .{ .or_value = if (T == u8)
                                        .{ .imm8 = curr_value }
                                    else
                                        .{ .imm16 = curr_value } },
                                    .node = node_idx,
                                });
                            }

                            // Store final value
                            try ana.ir.append(ana.sema.allocator, .{
                                .tag = .{ .store_variable = .{
                                    .register = register_type,
                                    .symbol = target.symbol,
                                    .offset = byte_offset,
                                } },
                                .node = node_idx,
                            });
                        }
                    }
                    return;
                }
            }
            unreachable;
        },
        .register => |reg| {
            try ana.ir.append(ana.sema.allocator, .{
                .tag = .{ .store_variable = .{
                    .register = reg,
                    .symbol = target.symbol,
                } },
                .node = node_idx,
            });
        },
    }
}

const PackedSymbol = struct {
    symbol: SymbolLocation,
    byte_offset: u8,
    shift_offset: u8,
};
fn resolvePackedFields(ana: *Analyzer, comptime T: type, node_idx: NodeIndex, fields: []const Sema.ExpressionValue.PackedField, curr_value: *T, used_symbols: *std.ArrayListUnmanaged(PackedSymbol), byte_offset: u8, bit_offset: *u8, base_bit_offset: u8) Error!void {
    while (bit_offset.* < (byte_offset + @sizeOf(T)) * 8) {
        const field = find_field: {
            for (fields) |field| {
                const actual_bit_offset = base_bit_offset + field.bit_offset;
                if (actual_bit_offset <= bit_offset.* and bit_offset.* < actual_bit_offset + field.bit_size) {
                    break :find_field field;
                }
            }

            // No fields remaining
            break;
        };
        defer bit_offset.* = @min(bit_offset.* + field.bit_size, (byte_offset + @sizeOf(T)) * 8);
        const shift_offset: std.math.Log2Int(T) = @intCast(bit_offset.* % @bitSizeOf(T));

        switch (field.value) {
            .value => |value| {
                curr_value.* |= @as(T, @truncate(@as(TypeSymbol.UnsignedComptimeIntValue, @bitCast(value)) >> @intCast(bit_offset.* - field.bit_offset - base_bit_offset))) << shift_offset;
            },
            .variable => |sym_loc| {
                // If there isn't a shift yet, crossing boundries is fine
                if (shift_offset != 0 and shift_offset + field.bit_size > @bitSizeOf(T)) {
                    try ana.sema.errors.append(ana.sema.allocator, .{
                        .tag = .fields_cross_register_boundry,
                        .ast = ana.ast,
                        .token = ana.ast.node_tokens[field.node_idx],
                        .extra = .{ .bit_size = 8 },
                    });
                    return error.AnalyzeFailed;
                }

                const target_symbol = ana.sema.lookupSymbol(sym_loc).?;
                const target_type = switch (target_symbol.*) {
                    .variable => |var_sym| var_sym.type,
                    .register => |reg_sym| reg_sym.type,
                    else => unreachable,
                };

                if (target_type.size() % @sizeOf(T) != 0) {
                    try ana.sema.errors.append(ana.sema.allocator, .{
                        .tag = .expected_mod_register_size,
                        .ast = ana.ast,
                        .token = ana.ast.node_tokens[field.node_idx],
                        .extra = .{ .expected_register_size = .{
                            .expected = target_type.size() * 8,
                            .actual = @sizeOf(T) * 8,
                        } },
                    });
                    return error.AnalyzeFailed;
                }

                try used_symbols.append(ana.sema.allocator, .{
                    .symbol = sym_loc,
                    .byte_offset = @intCast(@divFloor(bit_offset.* - field.bit_offset - base_bit_offset, @bitSizeOf(T))),
                    .shift_offset = shift_offset,
                });
            },
            .register => |register| {
                _ = register; // autofix
                @panic("TODO");
            },
            .packed_fields => |nested_fields| {
                try ana.resolvePackedFields(T, node_idx, nested_fields, curr_value, used_symbols, byte_offset, bit_offset, field.bit_offset + base_bit_offset);
            },
        }
    }
}

fn handleCall(ana: *Analyzer, node_idx: NodeIndex) Error!void {
    const target_ident = ana.ast.node_tokens[node_idx];
    const target_name = ana.ast.tokenSource(target_ident);

    const param_range = ana.ast.node_data[node_idx].sub_range;
    const params = ana.ast.extra_data[param_range.extra_start..param_range.extra_end];

    if (target_name[0] == '@') {
        // Built-in call
        if (BuiltinFn.get(target_name)) |builtin| {
            if (builtin.param_count != params.len) {
                try ana.sema.errors.append(ana.sema.allocator, .{
                    .tag = .expected_arguments,
                    .ast = ana.ast,
                    .token = ana.ast.node_tokens[node_idx],
                    .extra = .{ .arguments = .{
                        .expected = builtin.param_count,
                        .actual = @intCast(params.len),
                    } },
                });
                return error.AnalyzeFailed;
            }

            try builtin.handler_fn(ana, node_idx, params);
        } else {
            try ana.sema.errors.append(ana.sema.allocator, .{
                .tag = .invalid_builtin,
                .ast = ana.ast,
                .token = ana.ast.node_tokens[node_idx],
            });
            return error.AnalyzeFailed;
        }
    } else {
        // Function / macro call
        const sym, const sym_loc = try ana.sema.resolveSymbol(ana.ast, target_ident, ana.symbol_location.module);

        switch (sym.*) {
            .function => {
                try ana.ir.append(ana.sema.allocator, .{
                    .tag = .{ .call = .{ .target = sym_loc } },
                    .node = node_idx,
                });
            },
            // TODO: Support macros
            else => {
                try ana.sema.errors.append(ana.sema.allocator, .{
                    .tag = .expected_fn_symbol,
                    .ast = ana.ast,
                    .token = ana.ast.node_tokens[node_idx],
                    .extra = .{ .actual_symbol = sym.* },
                });
                return error.AnalyzeFailed;
            },
        }
    }
}

fn handleWhile(ana: *Analyzer, node_idx: NodeIndex) Error!void {
    const while_statement = ana.ast.node_data[node_idx].while_statement;

    if (while_statement.condition == Ast.null_node) {
        // while (true)
        const loop_label = try std.fmt.allocPrint(ana.sema.allocator, "__while{}_loop", .{ana.while_loops});
        ana.while_loops += 1;

        try ana.ir.append(ana.sema.allocator, .{
            .tag = .{ .label = loop_label },
            .node = node_idx,
        });

        try ana.handleBlock(while_statement.block);

        try ana.ir.append(ana.sema.allocator, .{
            .tag = .{ .branch = .{
                .type = .always,
                .target = loop_label,
            } },
            .node = node_idx,
        });
    } else {
        // Runtime loop condition
        @panic("TODO");
    }
}
