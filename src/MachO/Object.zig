const Object = @This();

const std = @import("std");
const build_options = @import("build_options");
const assert = std.debug.assert;
const dwarf = std.dwarf;
const fs = std.fs;
const io = std.io;
const log = std.log.scoped(.macho);
const macho = std.macho;
const math = std.math;
const mem = std.mem;
const sort = std.sort;
const trace = @import("../../tracy.zig").trace;

const Allocator = mem.Allocator;
const Atom = @import("Atom.zig");
const AtomIndex = MachO.AtomIndex;
const DwarfInfo = @import("DwarfInfo.zig");
const LoadCommandIterator = macho.LoadCommandIterator;
const MachO = @import("../MachO.zig");
const SymbolWithLoc = MachO.SymbolWithLoc;

name: []const u8,
mtime: u64,
contents: []align(@alignOf(u64)) const u8,

header: macho.mach_header_64 = undefined,

/// Symtab and strtab might not exist for empty object files so we use an optional
/// to signal this.
in_symtab: ?[]align(1) const macho.nlist_64 = null,
in_strtab: ?[]const u8 = null,

/// Output symtab is sorted so that we can easily reference symbols following each
/// other in address space.
symtab: std.ArrayListUnmanaged(macho.nlist_64) = .{},
/// Can be null as set together with in_symtab.
source_symtab_lookup: []u32 = undefined,
/// Can be null as set together with in_symtab.
strtab_lookup: []u32 = undefined,

sections_as_symbols: std.AutoHashMapUnmanaged(u16, u32) = .{},

atoms: std.ArrayListUnmanaged(AtomIndex) = .{},
atom_by_index_table: std.AutoHashMapUnmanaged(u32, AtomIndex) = .{},

pub fn deinit(self: *Object, gpa: Allocator) void {
    self.symtab.deinit(gpa);
    self.sections_as_symbols.deinit(gpa);
    self.atoms.deinit(gpa);
    self.atom_by_index_table.deinit(gpa);
    gpa.free(self.name);
    gpa.free(self.contents);
    if (self.in_symtab) |_| {
        gpa.free(self.source_symtab_lookup);
        gpa.free(self.strtab_lookup);
    }
}

pub fn parse(self: *Object, allocator: Allocator, cpu_arch: std.Target.Cpu.Arch) !void {
    var stream = std.io.fixedBufferStream(self.contents);
    const reader = stream.reader();

    self.header = try reader.readStruct(macho.mach_header_64);

    if (self.header.filetype != macho.MH_OBJECT) {
        log.debug("invalid filetype: expected 0x{x}, found 0x{x}", .{
            macho.MH_OBJECT,
            self.header.filetype,
        });
        return error.NotObject;
    }

    const this_arch: std.Target.Cpu.Arch = switch (self.header.cputype) {
        macho.CPU_TYPE_ARM64 => .aarch64,
        macho.CPU_TYPE_X86_64 => .x86_64,
        else => |value| {
            log.err("unsupported cpu architecture 0x{x}", .{value});
            return error.UnsupportedCpuArchitecture;
        },
    };
    if (this_arch != cpu_arch) {
        log.err("mismatched cpu architecture: expected {s}, found {s}", .{
            @tagName(cpu_arch),
            @tagName(this_arch),
        });
        return error.MismatchedCpuArchitecture;
    }

    var it = LoadCommandIterator{
        .ncmds = self.header.ncmds,
        .buffer = self.contents[@sizeOf(macho.mach_header_64)..][0..self.header.sizeofcmds],
    };
    while (it.next()) |cmd| {
        switch (cmd.cmd()) {
            .SYMTAB => {
                const symtab = cmd.cast(macho.symtab_command).?;
                self.in_symtab = @ptrCast(
                    [*]const macho.nlist_64,
                    @alignCast(@alignOf(macho.nlist_64), &self.contents[symtab.symoff]),
                )[0..symtab.nsyms];
                self.in_strtab = self.contents[symtab.stroff..][0..symtab.strsize];

                try self.symtab.ensureTotalCapacity(allocator, self.in_symtab.?.len);
                self.source_symtab_lookup = try allocator.alloc(u32, self.in_symtab.?.len);
                self.strtab_lookup = try allocator.alloc(u32, self.in_symtab.?.len);

                // You would expect that the symbol table is at least pre-sorted based on symbol's type:
                // local < extern defined < undefined. Unfortunately, this is not guaranteed! For instance,
                // the GO compiler does not necessarily respect that therefore we sort immediately by type
                // and address within.
                var sorted_all_syms = try std.ArrayList(SymbolAtIndex).initCapacity(allocator, self.in_symtab.?.len);
                defer sorted_all_syms.deinit();

                for (self.in_symtab.?) |_, index| {
                    sorted_all_syms.appendAssumeCapacity(.{ .index = @intCast(u32, index) });
                }

                // We sort by type: defined < undefined, and
                // afterwards by address in each group. Normally, dysymtab should
                // be enough to guarantee the sort, but turns out not every compiler
                // is kind enough to specify the symbols in the correct order.
                sort.sort(SymbolAtIndex, sorted_all_syms.items, self, SymbolAtIndex.lessThan);

                for (sorted_all_syms.items) |sym_id, i| {
                    const sym = sym_id.getSymbol(self);

                    self.symtab.appendAssumeCapacity(sym);
                    self.source_symtab_lookup[i] = sym_id.index;

                    const sym_name_len = mem.sliceTo(@ptrCast([*:0]const u8, self.in_strtab.?.ptr + sym.n_strx), 0).len + 1;
                    self.strtab_lookup[i] = @intCast(u32, sym_name_len);
                }
            },
            else => {},
        }
    }
}

const SymbolAtIndex = struct {
    index: u32,

    const Context = *const Object;

    fn getSymbol(self: SymbolAtIndex, ctx: Context) macho.nlist_64 {
        return ctx.in_symtab.?[self.index];
    }

    fn getSymbolName(self: SymbolAtIndex, ctx: Context) []const u8 {
        const off = self.getSymbol(ctx).n_strx;
        return mem.sliceTo(@ptrCast([*:0]const u8, ctx.in_strtab.?.ptr + off), 0);
    }

    /// Performs lexicographic-like check.
    /// * lhs and rhs defined
    ///   * if lhs == rhs
    ///     * if lhs.n_sect == rhs.n_sect
    ///       * ext < weak < local < temp
    ///     * lhs.n_sect < rhs.n_sect
    ///   * lhs < rhs
    /// * !rhs is undefined
    fn lessThan(ctx: Context, lhs_index: SymbolAtIndex, rhs_index: SymbolAtIndex) bool {
        const lhs = lhs_index.getSymbol(ctx);
        const rhs = rhs_index.getSymbol(ctx);
        if (lhs.sect() and rhs.sect()) {
            if (lhs.n_value == rhs.n_value) {
                if (lhs.n_sect == rhs.n_sect) {
                    if (lhs.ext() and rhs.ext()) {
                        if ((lhs.pext() or lhs.weakDef()) and (rhs.pext() or rhs.weakDef())) {
                            return false;
                        } else return rhs.pext() or rhs.weakDef();
                    } else {
                        const lhs_name = lhs_index.getSymbolName(ctx);
                        const lhs_temp = mem.startsWith(u8, lhs_name, "l") or mem.startsWith(u8, lhs_name, "L");
                        const rhs_name = rhs_index.getSymbolName(ctx);
                        const rhs_temp = mem.startsWith(u8, rhs_name, "l") or mem.startsWith(u8, rhs_name, "L");
                        if (lhs_temp and rhs_temp) {
                            return false;
                        } else return rhs_temp;
                    }
                } else return lhs.n_sect < rhs.n_sect;
            } else return lhs.n_value < rhs.n_value;
        } else if (lhs.undf() and rhs.undf()) {
            return false;
        } else return rhs.undf();
    }

    fn lessThanByNStrx(ctx: Context, lhs: SymbolAtIndex, rhs: SymbolAtIndex) bool {
        return lhs.getSymbol(ctx).n_strx < rhs.getSymbol(ctx).n_strx;
    }
};

fn filterSymbolsBySection(symbols: []macho.nlist_64, n_sect: u8) struct {
    index: u32,
    len: u32,
} {
    const FirstMatch = struct {
        n_sect: u8,

        pub fn predicate(pred: @This(), symbol: macho.nlist_64) bool {
            return symbol.n_sect == pred.n_sect;
        }
    };
    const FirstNonMatch = struct {
        n_sect: u8,

        pub fn predicate(pred: @This(), symbol: macho.nlist_64) bool {
            return symbol.n_sect != pred.n_sect;
        }
    };

    const index = MachO.lsearch(macho.nlist_64, symbols, FirstMatch{
        .n_sect = n_sect,
    });
    const len = MachO.lsearch(macho.nlist_64, symbols[index..], FirstNonMatch{
        .n_sect = n_sect,
    });

    return .{ .index = @intCast(u32, index), .len = @intCast(u32, len) };
}

fn filterSymbolsByAddress(symbols: []macho.nlist_64, n_sect: u8, start_addr: u64, end_addr: u64) struct {
    index: u32,
    len: u32,
} {
    const Predicate = struct {
        addr: u64,
        n_sect: u8,

        pub fn predicate(pred: @This(), symbol: macho.nlist_64) bool {
            return symbol.n_value >= pred.addr;
        }
    };

    const index = MachO.lsearch(macho.nlist_64, symbols, Predicate{
        .addr = start_addr,
        .n_sect = n_sect,
    });
    const len = MachO.lsearch(macho.nlist_64, symbols[index..], Predicate{
        .addr = end_addr,
        .n_sect = n_sect,
    });

    return .{ .index = @intCast(u32, index), .len = @intCast(u32, len) };
}

const SortedSection = struct {
    header: macho.section_64,
    id: u8,
};

fn sectionLessThanByAddress(ctx: void, lhs: SortedSection, rhs: SortedSection) bool {
    _ = ctx;
    if (lhs.header.addr == rhs.header.addr) {
        return lhs.id < rhs.id;
    }
    return lhs.header.addr < rhs.header.addr;
}

pub fn splitIntoAtoms(self: *Object, macho_file: *MachO, object_id: u32) !void {
    const gpa = macho_file.base.allocator;

    log.debug("splitting object({d}, {s}) into atoms", .{ object_id, self.name });

    const sections = self.getSourceSections();
    if (self.in_symtab == null) {
        for (sections) |sect, id| {
            if (sect.isDebug()) continue;
            const out_sect_id = (try macho_file.getOutputSection(sect)) orelse {
                log.debug("  unhandled section", .{});
                continue;
            };
            if (sect.size == 0) continue;

            const sect_id = @intCast(u8, id);
            const sym_index = self.sections_as_symbols.get(sect_id) orelse blk: {
                const sym_index = @intCast(u32, self.symtab.items.len);
                try self.symtab.append(gpa, .{
                    .n_strx = 0,
                    .n_type = macho.N_SECT,
                    .n_sect = out_sect_id + 1,
                    .n_desc = 0,
                    .n_value = sect.addr,
                });
                try self.sections_as_symbols.putNoClobber(gpa, sect_id, sym_index);
                break :blk sym_index;
            };
            const atom_index = try self.createAtomFromSubsection(
                macho_file,
                object_id,
                sym_index,
                0,
                sect.size,
                sect.@"align",
                out_sect_id,
            );
            macho_file.addAtomToSection(atom_index);
        }
        return;
    }

    // Well, shit, sometimes compilers skip the dysymtab load command altogether, meaning we
    // have to infer the start of undef section in the symtab ourselves.
    const iundefsym = blk: {
        const dysymtab = self.parseDysymtab() orelse {
            var iundefsym: usize = self.symtab.items.len;
            while (iundefsym > 0) : (iundefsym -= 1) {
                const sym = self.symtab.items[iundefsym - 1];
                if (sym.sect()) break;
            }
            break :blk iundefsym;
        };
        break :blk dysymtab.iundefsym;
    };

    // We only care about defined symbols, so filter every other out.
    const symtab = try gpa.dupe(macho.nlist_64, self.symtab.items[0..iundefsym]);
    defer gpa.free(symtab);

    const subsections_via_symbols = self.header.flags & macho.MH_SUBSECTIONS_VIA_SYMBOLS != 0;

    // Sort section headers by address.
    var sorted_sections = try gpa.alloc(SortedSection, sections.len);
    defer gpa.free(sorted_sections);

    for (sections) |sect, id| {
        sorted_sections[id] = .{ .header = sect, .id = @intCast(u8, id) };
    }

    std.sort.sort(SortedSection, sorted_sections, {}, sectionLessThanByAddress);

    var sect_sym_index: u32 = 0;
    for (sorted_sections) |section| {
        const sect = section.header;
        if (sect.isDebug()) continue;

        const sect_id = section.id;
        log.debug("splitting section '{s},{s}' into atoms", .{ sect.segName(), sect.sectName() });

        // Get output segment/section in the final artifact.
        const out_sect_id = (try macho_file.getOutputSection(sect)) orelse {
            log.debug("  unhandled section", .{});
            continue;
        };

        log.debug("  output sect({d}, '{s},{s}')", .{
            out_sect_id + 1,
            macho_file.sections.items(.header)[out_sect_id].segName(),
            macho_file.sections.items(.header)[out_sect_id].sectName(),
        });

        const cpu_arch = macho_file.options.target.cpu_arch.?;
        const sect_loc = filterSymbolsBySection(symtab[sect_sym_index..], sect_id + 1);
        const sect_start_index = sect_sym_index + sect_loc.index;

        sect_sym_index += sect_loc.len;

        if (sect.size == 0) continue;
        if (subsections_via_symbols and sect_loc.len > 0) {
            // If the first nlist does not match the start of the section,
            // then we need to encapsulate the memory range [section start, first symbol)
            // as a temporary symbol and insert the matching Atom.
            const first_sym = symtab[sect_start_index];
            if (first_sym.n_value > sect.addr) {
                const sym_index = self.sections_as_symbols.get(sect_id) orelse blk: {
                    const sym_index = @intCast(u32, self.symtab.items.len);
                    try self.symtab.append(gpa, .{
                        .n_strx = 0,
                        .n_type = macho.N_SECT,
                        .n_sect = out_sect_id + 1,
                        .n_desc = 0,
                        .n_value = sect.addr,
                    });
                    try self.sections_as_symbols.putNoClobber(gpa, sect_id, sym_index);
                    break :blk sym_index;
                };
                const atom_size = first_sym.n_value - sect.addr;
                const atom_index = try self.createAtomFromSubsection(
                    macho_file,
                    object_id,
                    sym_index,
                    0,
                    atom_size,
                    sect.@"align",
                    out_sect_id,
                );
                macho_file.addAtomToSection(atom_index);
            }

            var next_sym_index = sect_start_index;
            while (next_sym_index < sect_start_index + sect_loc.len) {
                const next_sym = symtab[next_sym_index];
                const addr = next_sym.n_value;
                const atom_loc = filterSymbolsByAddress(
                    symtab[next_sym_index..],
                    sect_id + 1,
                    addr,
                    addr + 1,
                );
                assert(atom_loc.len > 0);
                const atom_sym_index = atom_loc.index + next_sym_index;
                const nsyms_trailing = atom_loc.len - 1;
                next_sym_index += atom_loc.len;

                // TODO: We want to bubble up the first externally defined symbol here.
                const atom_size = if (next_sym_index < sect_start_index + sect_loc.len)
                    symtab[next_sym_index].n_value - addr
                else
                    sect.addr + sect.size - addr;

                const atom_align = if (addr > 0)
                    math.min(@ctz(addr), sect.@"align")
                else
                    sect.@"align";

                const atom_index = try self.createAtomFromSubsection(
                    macho_file,
                    object_id,
                    atom_sym_index,
                    nsyms_trailing,
                    atom_size,
                    atom_align,
                    out_sect_id,
                );

                // TODO rework this at the relocation level
                if (cpu_arch == .x86_64 and addr == sect.addr) {
                    // In x86_64 relocs, it can so happen that the compiler refers to the same
                    // atom by both the actual assigned symbol and the start of the section. In this
                    // case, we need to link the two together so add an alias.
                    const alias = self.sections_as_symbols.get(sect_id) orelse blk: {
                        const alias = @intCast(u32, self.symtab.items.len);
                        try self.symtab.append(gpa, .{
                            .n_strx = 0,
                            .n_type = macho.N_SECT,
                            .n_sect = out_sect_id + 1,
                            .n_desc = 0,
                            .n_value = addr,
                        });
                        try self.sections_as_symbols.putNoClobber(gpa, sect_id, alias);
                        break :blk alias;
                    };
                    try self.atom_by_index_table.put(gpa, alias, atom_index);
                }

                macho_file.addAtomToSection(atom_index);
            }
        } else {
            const sym_index = self.sections_as_symbols.get(sect_id) orelse blk: {
                const sym_index = @intCast(u32, self.symtab.items.len);
                try self.symtab.append(gpa, .{
                    .n_strx = 0,
                    .n_type = macho.N_SECT,
                    .n_sect = out_sect_id + 1,
                    .n_desc = 0,
                    .n_value = sect.addr,
                });
                try self.sections_as_symbols.putNoClobber(gpa, sect_id, sym_index);
                break :blk sym_index;
            };
            const atom_index = try self.createAtomFromSubsection(
                macho_file,
                object_id,
                sym_index,
                0,
                sect.size,
                sect.@"align",
                out_sect_id,
            );
            // If there is no symbol to refer to this atom, we create
            // a temp one, unless we already did that when working out the relocations
            // of other atoms.
            macho_file.addAtomToSection(atom_index);
        }
    }
}

fn createAtomFromSubsection(
    self: *Object,
    macho_file: *MachO,
    object_id: u32,
    sym_index: u32,
    nsyms_trailing: u32,
    size: u64,
    alignment: u32,
    out_sect_id: u8,
) !AtomIndex {
    const gpa = macho_file.base.allocator;
    const atom_index = try macho_file.createEmptyAtom(sym_index, size, alignment);
    const atom = macho_file.getAtomPtr(atom_index);
    atom.nsyms_trailing = nsyms_trailing;
    atom.file = object_id;
    self.symtab.items[sym_index].n_sect = out_sect_id + 1;

    log.debug("creating ATOM(%{d}, '{s}') in sect({d}, '{s},{s}') in object({d})", .{
        sym_index,
        self.getSymbolName(sym_index),
        out_sect_id + 1,
        macho_file.sections.items(.header)[out_sect_id].segName(),
        macho_file.sections.items(.header)[out_sect_id].sectName(),
        object_id,
    });

    try self.atoms.append(gpa, atom_index);
    try self.atom_by_index_table.putNoClobber(gpa, sym_index, atom_index);

    var it = Atom.getInnerSymbolsIterator(macho_file, atom_index);
    while (it.next()) |sym_loc| {
        const inner = macho_file.getSymbolPtr(sym_loc);
        inner.n_sect = out_sect_id + 1;
        try self.atom_by_index_table.putNoClobber(gpa, sym_loc.sym_index, atom_index);
    }

    return atom_index;
}

pub fn getSourceSymbol(self: Object, index: u32) ?macho.nlist_64 {
    const symtab = self.in_symtab.?;
    if (index >= symtab.len) return null;
    const mapped_index = self.source_symtab_lookup[index];
    return symtab[mapped_index];
}

/// Caller owns memory.
pub fn createReverseSymbolLookup(self: Object, gpa: Allocator) ![]u32 {
    const lookup = try gpa.alloc(u32, self.in_symtab.?.len);
    for (self.source_symtab_lookup) |source_id, id| {
        lookup[source_id] = @intCast(u32, id);
    }
    return lookup;
}

pub fn getSourceSection(self: Object, index: u16) macho.section_64 {
    const sections = self.getSourceSections();
    assert(index < sections.len);
    return sections[index];
}

pub fn getSourceSections(self: Object) []const macho.section_64 {
    var it = LoadCommandIterator{
        .ncmds = self.header.ncmds,
        .buffer = self.contents[@sizeOf(macho.mach_header_64)..][0..self.header.sizeofcmds],
    };
    while (it.next()) |cmd| switch (cmd.cmd()) {
        .SEGMENT_64 => {
            return cmd.getSections();
        },
        else => {},
    } else unreachable;
}

pub fn parseDataInCode(self: Object) ?[]const macho.data_in_code_entry {
    var it = LoadCommandIterator{
        .ncmds = self.header.ncmds,
        .buffer = self.contents[@sizeOf(macho.mach_header_64)..][0..self.header.sizeofcmds],
    };
    while (it.next()) |cmd| {
        switch (cmd.cmd()) {
            .DATA_IN_CODE => {
                const dice = cmd.cast(macho.linkedit_data_command).?;
                const ndice = @divExact(dice.datasize, @sizeOf(macho.data_in_code_entry));
                return @ptrCast(
                    [*]const macho.data_in_code_entry,
                    @alignCast(@alignOf(macho.data_in_code_entry), &self.contents[dice.dataoff]),
                )[0..ndice];
            },
            else => {},
        }
    } else return null;
}

fn parseDysymtab(self: Object) ?macho.dysymtab_command {
    var it = LoadCommandIterator{
        .ncmds = self.header.ncmds,
        .buffer = self.contents[@sizeOf(macho.mach_header_64)..][0..self.header.sizeofcmds],
    };
    while (it.next()) |cmd| {
        switch (cmd.cmd()) {
            .DYSYMTAB => {
                return cmd.cast(macho.dysymtab_command).?;
            },
            else => {},
        }
    } else return null;
}

pub fn parseDwarfInfo(self: Object) DwarfInfo {
    var di = DwarfInfo{
        .debug_info = &[0]u8{},
        .debug_abbrev = &[0]u8{},
        .debug_str = &[0]u8{},
    };
    for (self.getSourceSections()) |sect| {
        if (!sect.isDebug()) continue;
        const sectname = sect.sectName();
        if (mem.eql(u8, sectname, "__debug_info")) {
            di.debug_info = self.getSectionContents(sect);
        } else if (mem.eql(u8, sectname, "__debug_abbrev")) {
            di.debug_abbrev = self.getSectionContents(sect);
        } else if (mem.eql(u8, sectname, "__debug_str")) {
            di.debug_str = self.getSectionContents(sect);
        }
    }
    return di;
}

pub fn getSectionContents(self: Object, sect: macho.section_64) []const u8 {
    const size = @intCast(usize, sect.size);
    log.debug("getting {s},{s} data at 0x{x} - 0x{x}", .{
        sect.segName(),
        sect.sectName(),
        sect.offset,
        sect.offset + sect.size,
    });
    return self.contents[sect.offset..][0..size];
}

pub fn getRelocs(self: Object, sect: macho.section_64) []align(1) const macho.relocation_info {
    if (sect.nreloc == 0) return &[0]macho.relocation_info{};
    return @ptrCast([*]align(1) const macho.relocation_info, self.contents.ptr + sect.reloff)[0..sect.nreloc];
}

pub fn getSymbolName(self: Object, index: u32) []const u8 {
    const strtab = self.in_strtab.?;
    const sym = self.symtab.items[index];

    if (self.getSourceSymbol(index) == null) {
        assert(sym.n_strx == 0);
        return "";
    }

    const start = sym.n_strx;
    const len = self.strtab_lookup[index];

    return strtab[start..][0 .. len - 1 :0];
}

pub fn getAtomIndexForSymbol(self: Object, sym_index: u32) ?AtomIndex {
    return self.atom_by_index_table.get(sym_index);
}
