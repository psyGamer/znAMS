const std = @import("std");
const znasm = @import("znasm");
const Builder = znasm.Builder;
const Addr = znasm.Address;

const mmio = @import("reg.zig");

/// Reads/Writes data to/from Work-RAM at WRAM_ADDR
/// Increments WRAM_ADDR by 1
pub const WRAM_DATA: Addr = mmio.WMDATA;

/// Work-RAM Address (Low) for WRAM_DATA
pub const WRAM_ADDR_LOW: Addr = mmio.WMADDL;
/// Work-RAM Address (Middle) for WRAM_DATA
pub const WRAM_ADDR_MID: Addr = mmio.WMADDM;
/// Work-RAM Address (High) for WRAM_DATA
pub const WRAM_ADDR_HIGH: Addr = mmio.WMADDH;

/// Controls how a Video-RAM DMA transfer operates
pub const VRAM_CONTROL: Addr = mmio.VMAIN;
/// Reads/Writes data to/from Videop-RAM at VRAM_ADDR
/// Increments VRAM_ADDR according to VRAM_CONTROL
pub const VRAM_DATA: Addr = mmio.VMDATAL;

/// Video-RAM Address (Low) for VRAM_DATA
pub const VRAM_ADDR_LOW: Addr = mmio.VMADDL;
/// Video-RAM Address (High) for VRAM_DATA
pub const VRAM_ADDR_HIGH: Addr = mmio.VMADDL;

/// Controls which DMA channel are currently enabled
pub const DMA_ENABLE: Addr = mmio.MDMAEN;

/// Parameters about the DMA operation
pub const DMA_PARAMETER: Addr = mmio.DMAPn;
/// Source A-Bus address for the transfer (Low)
pub const DMA_A_BUS_ADDR_LOW: Addr = mmio.A1TnL;
/// Source A-Bus address for the transfer (High)
pub const DMA_A_BUS_ADDR_HIGH: Addr = mmio.A1TnH;
/// Source A-Bus address for the transfer (Bank)
pub const DMA_A_BUS_ADDR_BANK: Addr = mmio.A1Bn;
/// Target B-Bus register for the transfer
pub const DMA_B_BUS_REGISTER: Addr = mmio.BBADn;
/// Byte-Counter for the transfer length (Low)
pub const DMA_BYTE_COUNT_L: Addr = mmio.DASnL;
/// Byte-Counter for the transfer length (High)
pub const DMA_BYTE_COUNT_H: Addr = mmio.DASnH;

pub const ChannelConfig = packed struct(u8) {
    pub const disable_all: ChannelConfig = .{};
    pub const enable_0: ChannelConfig = .{ .channel_0 = true };
    pub const enable_1: ChannelConfig = .{ .channel_1 = true };
    pub const enable_2: ChannelConfig = .{ .channel_2 = true };
    pub const enable_3: ChannelConfig = .{ .channel_3 = true };
    pub const enable_4: ChannelConfig = .{ .channel_4 = true };
    pub const enable_5: ChannelConfig = .{ .channel_5 = true };
    pub const enable_6: ChannelConfig = .{ .channel_6 = true };
    pub const enable_7: ChannelConfig = .{ .channel_7 = true };

    channel_0: bool = false,
    channel_1: bool = false,
    channel_2: bool = false,
    channel_3: bool = false,
    channel_4: bool = false,
    channel_5: bool = false,
    channel_6: bool = false,
    channel_7: bool = false,
};

/// Enalbes/Disables DMA for the specified channels
pub fn set_enabled(b: *Builder, register: Builder.Register, config: ChannelConfig) void {
    b.store_value(.@"8bit", register, DMA_ENABLE, @bitCast(config));
}

/// Enables DMA for the specified channel
pub fn enable_channel(b: *Builder, register: Builder.Register, channel: u3) void {
    b.store_value(.@"8bit", register, DMA_ENABLE, @as(u8, 1) << channel);
}

const DmaParameters = packed struct(u8) {
    transfer_pattern: enum(u3) {
        /// Reads 1 byte and writes it to B_ADDR
        read1_write0 = 0,
        /// Reads 2 bytes and writes them to B_ADDR and B_ADDR+1
        read2_write01 = 1,
        /// Reads 2 bytes and double-writes it to B_ADDR
        read2_write00 = 2,
        /// Reads 4 bytes and double-writes it to B_ADDR and B_ADDR+1
        read4_write0011 = 3,
        /// Reads 4 bytes and writes it to B_ADDR, B_ADDR+1, B_ADDR+2 and B_ADDR+3
        read4_write0123 = 4,
        /// Reads 4 bytes and writes it to B_ADDR, B_ADDR+1, B_ADDR and B_ADDR+1
        read4_write0101 = 5,
    },
    address_adjust: enum(u2) {
        /// Increments the read address after each copy
        increment = 0,
        /// Keeps the read address fixed
        fixed = 1,
        /// Decrements the read address after each copy
        decrement = 2,
    },
    _: u2 = 0,
    direction: enum(u1) {
        /// Copy from the A (CPU) to the B (PPU, etc.) bus
        a_to_b = 0,
        /// Copy from the B (PPU, etc.)to the A (CPU) bus
        b_to_a = 1,
    },
};

/// Configures parameters for a DMA operation on the specified channel
pub fn set_parameters(b: *Builder, register: Builder.Register, channel: u3, params: DmaParameters) void {
    b.store_value(.@"8bit", register, @as(Addr, DMA_PARAMETER + channel_offset(channel)), @bitCast(params));
}

const BBusRegister = enum(u8) {
    work_ram = @truncate(WRAM_DATA),
    video_ram = @truncate(VRAM_DATA),
};

/// Specifies the read/writer register, in the 0x2100 - 0x21ff range
pub fn set_b_bus_register(b: *Builder, register: Builder.Register, channel: u3, b_bus_reg: BBusRegister) void {
    b.store_value(.@"8bit", register, @as(Addr, DMA_B_BUS_REGISTER + channel_offset(channel)), @intFromEnum(b_bus_reg));
}

/// Specifies the amout of bytes to transfer
fn set_byte_count(b: *Builder, register: Builder.Register, channel: u3, count: u17) void {
    std.debug.assert(count <= 0x10000);

    // The count is decremented before being compared to 0, so there is an implicit +1
    const actual_count: u16 = @as(u16, @intCast(count % 0xFFFF)) -% 1;
    b.store_value(.@"16bit", register, @as(Addr, DMA_BYTE_COUNT_L + channel_offset(channel)), actual_count);
}

const VramControlConfig = packed struct(u8) {
    increment_amount: enum(u2) {
        @"1_word" = 0b00,
        @"32_words" = 0b01,
        @"128_words" = 0b10,
    },
    remapping: enum(u2) {
        none = 0b00,
        /// Remap rrrrrrrr YYYccccc -> rrrrrrrr cccccYYY
        @"2bpp" = 0b01,
        /// Remap rrrrrrrY YYcccccP -> rrrrrrrc ccccPYYY
        @"4bpp" = 0b10,
        /// Remap rrrrrrYY YcccccPP -> rrrrrrcc cccPPYYY
        @"8bpp" = 0b11,
    },
    _: u3 = 0,
    increment_mode: enum(u1) {
        after_low = 0b0,
        after_high = 0b1,
    },
};

pub fn set_vram_control(b: *Builder, register: Builder.Register, config: VramControlConfig) void {
    b.store_value(.@"8bit", register, VRAM_CONTROL, @bitCast(config));
}

/// DMA source data for memsets
const memset_sources: [0xFF]znasm.Data(u8) = b: {
    var sources: [0xFF]znasm.Data(u8) = undefined;
    for (0..sources.len) |i| {
        sources[i] = .init(i, std.fmt.comptimePrint("memset_source_0x{X:0>2}", .{i}), @This());
    }
    break :b sources;
};

pub fn wram_memset(b: *Builder, register: Builder.Register, channel: u3, start_addr: u24, count: u17, value: u8) void {
    const size_mode = switch (register) {
        .a => b.a_size,
        .x, .y => b.xy_size,
    };

    // Setup target address
    switch (size_mode) {
        // Default to 8-bit, since that's more common
        .none, .@"8bit" => {
            b.store_value(.@"8bit", register, WRAM_ADDR_LOW, @as(u8, @truncate(start_addr >> 0)));
            b.store_value(.@"8bit", register, WRAM_ADDR_MID, @as(u8, @truncate(start_addr >> 8)));
            b.store_value(.@"8bit", register, WRAM_ADDR_HIGH, @as(u8, @truncate(start_addr >> 16)));
        },
        .@"16bit" => {
            b.store_value(.@"16bit", register, WRAM_ADDR_LOW, @as(u16, @truncate(start_addr >> 0)));
            b.store_value(.@"16bit", register, WRAM_ADDR_MID, @as(u16, @truncate(start_addr >> 8)));
        },
    }

    // Setup DMA parametrs
    set_parameters(b, register, channel, .{
        .transfer_pattern = .read1_write0,
        .address_adjust = .fixed,
        .direction = .a_to_b,
    });
    // Write to WRAM
    set_b_bus_register(b, register, channel, .work_ram);

    // Set source byte
    const source = memset_sources[value];
    b.store_reloc(register, DMA_A_BUS_ADDR_LOW, source.reloc_addr16());
    b.store_reloc(register, DMA_A_BUS_ADDR_BANK, source.reloc_bank());

    // Set transfer size
    set_byte_count(b, register, channel, count);

    // Start transfer
    enable_channel(b, register, channel);
}

pub fn vram_memset(b: *Builder, register: Builder.Register, channel: u3, start_addr: u16, count: u17, value: u8) void {
    b.store_value(.@"16bit", register, VRAM_ADDR_LOW, start_addr);

    // Setup DMA parametrs
    set_parameters(b, register, channel, .{
        .transfer_pattern = .read2_write01,
        .address_adjust = .fixed,
        .direction = .a_to_b,
    });
    // Setup VRAM control
    set_vram_control(b, register, .{
        .increment_amount = .@"1_word",
        .remapping = .none,
        .increment_mode = .after_high,
    });
    // Write to VRAM
    set_b_bus_register(b, register, channel, .video_ram);

    // Set source byte
    const source = memset_sources[value];
    b.store_reloc(register, DMA_A_BUS_ADDR_LOW, source.reloc_addr16());
    b.store_reloc(register, DMA_A_BUS_ADDR_BANK, source.reloc_bank());

    // Set transfer size
    set_byte_count(b, register, channel, count);

    // Start transfer
    enable_channel(b, register, channel);
}

pub fn cgram_memset(b: *Builder, register: Builder.Register, channel: u3, start_addr: u9, count: u10, value: u8) void {
    // Setup target address
    switch (b.a_size) {
        // Default to 8-bit, since that's more common
        .none, .@"8bit" => {
            b.store_value(.@"8bit", register, WRAM_ADDR_LOW, @as(u8, @truncate(start_addr >> 0)));
            b.store_value(.@"8bit", register, WRAM_ADDR_MID, @as(u8, @truncate(start_addr >> 8)));
            b.store_value(.@"8bit", register, WRAM_ADDR_HIGH, @as(u8, @truncate(start_addr >> 16)));
        },
        .@"16bit" => {
            b.store_value(.@"16bit", register, WRAM_ADDR_LOW, @as(u16, @truncate(start_addr >> 0)));
            b.store_value(.@"16bit", register, WRAM_ADDR_MID, @as(u16, @truncate(start_addr >> 8)));
        },
    }

    // Setup DMA parametrs
    set_parameters(b, register, channel, .{
        .transfer_pattern = .read1_write0,
        .address_adjust = .fixed,
        .direction = .a_to_b,
    });
    // Write to WRAM
    set_b_bus_register(b, register, channel, .work_ram);

    // Set source byte
    const source = memset_sources[value];
    b.store_reloc(register, DMA_A_BUS_ADDR_LOW, source.reloc_addr16());
    b.store_reloc(register, DMA_A_BUS_ADDR_BANK, source.reloc_bank());

    // Set transfer size
    set_byte_count(b, register, channel, count);

    // Start transfer
    enable_channel(b, register, channel);
}

fn channel_offset(channel: u3) u8 {
    return 0x10 * @as(u8, channel);
}
