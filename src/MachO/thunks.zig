pub fn createThunks(sect_id: u8, macho_file: *MachO) !void {
    const gpa = macho_file.base.allocator;
    const slice = macho_file.sections.slice();
    const header = &slice.items(.header)[sect_id];
    const atoms = slice.items(.atoms)[sect_id].items;
    assert(atoms.len > 0);

    for (atoms) |atom_index| {
        macho_file.getAtom(atom_index).?.value = @bitCast(@as(i64, -1));
    }
    macho_file.getAtom(atoms[0]).?.value = 0;

    var i: usize = 0;
    while (i < atoms.len) {
        const start = i;

        while (i < atoms.len and
            header.size - macho_file.getAtom(atoms[start]).?.value < max_allowed_distance) : (i += 1)
        {
            const atom_index = atoms[i];
            const atom = macho_file.getAtom(atom_index).?;
            assert(atom.flags.alive);
            const atom_alignment = try math.powi(u32, 2, atom.alignment);
            const offset = mem.alignForward(u64, header.size, atom_alignment);
            const padding = offset - header.size;
            atom.value = offset;
            header.size += padding + atom.size;
            header.@"align" = @max(header.@"align", atom.alignment);
        }

        // Insert a thunk at the group end
        const thunk_index = try macho_file.addThunk();
        const thunk = macho_file.getThunk(thunk_index);

        // Scan relocs in the group and create trampolines for any unreachable callsite
        for (atoms[start..i]) |atom_index| {
            const atom = macho_file.getAtom(atom_index).?;
            for (atom.getRelocs(macho_file)) |rel| {
                if (rel.type != .branch) continue;
                if (isReachable(atom, rel, macho_file)) continue;

                log.debug("atom({d}) -> %{d} unreachable", .{ atom_index, rel.target });
                log.debug("  {x} => {x}", .{ atom.value, rel.getTargetAddress(macho_file) });
                log.debug("  is stubs ?? {}", .{rel.getTargetSymbol(macho_file).flags.stubs});
                log.debug("  is objc_stubs ?? {}", .{rel.getTargetSymbol(macho_file).flags.objc_stubs});
                log.debug("  sect({d}) => sect({d})", .{
                    atom.out_n_sect,
                    rel.getTargetSymbol(macho_file).out_n_sect,
                });

                try thunk.symbols.put(gpa, rel.target, {});
            }
            atom.thunk_index = thunk_index;
        }

        const offset = mem.alignForward(u64, header.size, @alignOf(u32));
        const padding = offset - header.size;
        thunk.value = offset;
        header.size += padding + thunk.size();
        header.@"align" = @max(header.@"align", 2);
    }
}

fn isReachable(atom: *const Atom, rel: Relocation, macho_file: *MachO) bool {
    const target = rel.getTargetSymbol(macho_file);
    if (target.flags.stubs or target.flags.objc_stubs) return false;
    if (atom.out_n_sect != target.out_n_sect) return false;
    const target_atom = target.getAtom(macho_file).?;
    if (target_atom.value == @as(u64, @bitCast(@as(i64, -1)))) return false;
    const saddr = @as(i64, @intCast(atom.value)) + @as(i64, @intCast(rel.offset - atom.off));
    const taddr: i64 = @intCast(rel.getTargetAddress(macho_file));
    _ = math.cast(i28, taddr + rel.addend - saddr) orelse return false;
    return true;
}

// pub fn writeThunkCode(macho_file: *MachO, atom_index: AtomIndex, writer: anytype) !void {
//     const atom = macho_file.getAtom(atom_index);
//     const sym = macho_file.getSymbol(atom.getSymbolWithLoc());
//     const source_addr = sym.n_value;
//     const thunk = macho_file.thunks.items[getThunkIndex(macho_file, atom_index).?];
//     const target_addr = for (thunk.lookup.keys()) |target| {
//         const target_atom_index = thunk.lookup.get(target).?;
//         if (atom_index == target_atom_index) break macho_file.getSymbol(target).n_value;
//     } else unreachable;

//     const pages = Atom.calcNumberOfPages(source_addr, target_addr);
//     try writer.writeInt(u32, aarch64.Instruction.adrp(.x16, pages).toU32(), .little);
//     const off = try Atom.calcPageOffset(target_addr, .arithmetic);
//     try writer.writeInt(u32, aarch64.Instruction.add(.x16, .x16, off, false).toU32(), .little);
//     try writer.writeInt(u32, aarch64.Instruction.br(.x16).toU32(), .little);
// }

pub const Thunk = struct {
    value: u64 = 0,
    symbols: std.AutoArrayHashMapUnmanaged(Symbol.Index, void) = .{},

    pub fn deinit(thunk: *Thunk, allocator: Allocator) void {
        thunk.symbols.deinit(allocator);
    }

    pub fn size(thunk: Thunk) usize {
        return thunk.symbols.keys().len * trampoline_size;
    }

    pub fn getAddress(thunk: Thunk, sym_index: Symbol.Index) u64 {
        return thunk.value + thunk.symbols.getIndex(sym_index).? * trampoline_size;
    }

    pub fn format(
        thunk: Thunk,
        comptime unused_fmt_string: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = thunk;
        _ = unused_fmt_string;
        _ = options;
        _ = writer;
        @compileError("do not format Thunk directly");
    }

    pub fn fmt(thunk: Thunk, macho_file: *MachO) std.fmt.Formatter(format2) {
        return .{ .data = .{
            .thunk = thunk,
            .macho_file = macho_file,
        } };
    }

    const FormatContext = struct {
        thunk: Thunk,
        macho_file: *MachO,
    };

    fn format2(
        ctx: FormatContext,
        comptime unused_fmt_string: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = options;
        _ = unused_fmt_string;
        const thunk = ctx.thunk;
        const macho_file = ctx.macho_file;
        try writer.print("@{x} : size({x})\n", .{ thunk.value, thunk.size() });
        for (thunk.symbols.keys()) |index| {
            const sym = macho_file.getSymbol(index);
            try writer.print("  %{d} : {s} : @{x}\n", .{ index, sym.getName(macho_file), sym.value });
        }
    }

    const trampoline_size = 3 * @sizeOf(u32);

    pub const Index = u32;
};

/// Branch instruction has 26 bits immediate but is 4 byte aligned.
const jump_bits = @bitSizeOf(i28);
const max_distance = (1 << (jump_bits - 1));

/// A branch will need an extender if its target is larger than
/// `2^(jump_bits - 1) - margin` where margin is some arbitrary number.
/// mold uses 5MiB margin, while ld64 uses 4MiB margin. We will follow mold
/// and assume margin to be 5MiB.
const max_allowed_distance = max_distance - 0x500_000;

const assert = std.debug.assert;
const log = std.log.scoped(.link);
const math = std.math;
const mem = std.mem;
const std = @import("std");

const Allocator = mem.Allocator;
const Atom = @import("Atom.zig");
const MachO = @import("../MachO.zig");
const Relocation = @import("Relocation.zig");
const Symbol = @import("Symbol.zig");
