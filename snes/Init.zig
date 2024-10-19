const znasm = @import("znasm");

const reg = @import("reg.zig");

const MEMSEL: znasm.FixedAddress = .init(0x420D, null);

pub fn Reset(b: *znasm.Builder) void {
    b.setup_debug(@src(), @This(), null);

    // Jump to fast mirror in bank 0x80
    const fast = b.create_label();
    b.jump_long(fast);
    fast.define(b);

    // Enter native mode
    b.emit(.clc);
    b.emit(.xce);

    // Setup stauts flags
    b.change_status_flags(.{
        .carry = false,
        .zero = false,
        .irq_disable = true,
        .decimal = false,
        .xy_8bit = false,
        .a_8bit = true,
        .overflow = false,
        .negative = false,
    });

    // Initialize system
    b.call(CPU);

    // Main loop
    const loop = b.define_label();
    b.branch_always(loop);
}

pub fn CPU(b: *znasm.Builder) void {
    b.setup_debug(@src(), @This(), null);

    var a = b.reg_a8();
    a = .load_store(b, MEMSEL, 0x01);
    a = .a16(b);
    a = .load_store(b, MEMSEL, 0x0123);

    var x = b.reg_x16();
    x = .load_store(b, MEMSEL, 0x1234);
    var y = b.reg_y16();
    y = .load_store(b, MEMSEL, 0x5678);

    b.emit(.rts);
}