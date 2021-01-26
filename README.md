# zld

Zig's lld drop-in replacement, called ZigLD or `zld` for short

**Disclaimer**: this is a WIP so things naturally will not work as intended or at all.
However, with a bit of luck, and some spare time, I reckon `zld` can handle most common
cases (with a special focus on cross-compilation) relatively quickly.

## Why?

Excellent question! Lemme be perfectly frank with you. We're having immense problems with
the `lld` on macOS. Actually, it just doesn't work as it should and it's nowhere near its
other counterparts on other platforms (e.g., linking Elf with `lld` just works...). The purpose
of this project is to implement a drop-in replacement for `lld` in Zig. Mind you, I'm not trying
to replace the WIP of an incremental Mach-O linker! On the contrary, this linker being a traditional
linker will be used to augment the incremental linking in Zig, and if all goes well, we might
use it to perform optimised linking in the Release mode.

So that's that...

## Roadmap

Currently, the entire roadmap is organised around macOS/Mach-O support. This is mainly because
that's the binary format I'm most familiar with. Having said that, I'd welcome contributions
adding some support to other widely used formats such as Elf, Coff, PE, etc.

- [x] link `.o` generated from simple C program on macOS targeting `aarch64`
- [x] link the same `.o` but targeting `x86_64`
- [ ] unhack, or refactor, for basic single `.o` linking
- [ ] link simple `.zig` (this includes TLV so should be interesting!)
- [ ] link multiple `.o`
- [ ] converge with Zig's stage2
- [ ] handle multiple dynamic libraries
- [ ] handle frameworks
