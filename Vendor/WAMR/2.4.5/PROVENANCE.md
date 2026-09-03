# WAMR provenance

- Upstream: Bytecode Alliance WebAssembly Micro Runtime (WAMR) `WAMR-2.4.5`
- Official source: `https://github.com/bytecodealliance/wasm-micro-runtime/archive/refs/tags/WAMR-2.4.5.tar.gz`
- Archive SHA-256: `1ab09d51099f276ca4a1d6629f6b589aab2bd0caa01445e05031a4bed22c199b`
- License: `LICENSE` (Apache License 2.0 with LLVM Exceptions)
- Included subset: Core interpreter loader/runtime, common runtime, allocator,
  utilities, and Darwin/POSIX memory/thread primitives plus public headers.
  AOT declaration headers required by common headers are present, but no AOT
  implementation source is compiled.
- Excluded at source selection and build time: AOT, LLVM/Fast JIT, WASI,
  built-in libc, sockets, filesystem/clock WASI shims, pthread/multi-module,
  debugger, samples, tools, tests, and release binaries.
- Duckpad build: interpreter-only; no native module imports are registered.
  Bulk-memory/reference-types decoding required by the pinned sample adds no
  host capability. Modules must still declare zero imports and bounded memory.
- Text normalization: trailing horizontal whitespace and extra blank lines at
  EOF are removed so regenerated sources pass the repository review gate.
- Duckpad sandbox patch: interpreter-only builds do not request Apple's
  `MAP_JIT`; that flag remains enabled when WAMR JIT, Fast JIT, or AOT is
  compiled. Normalized upstream `posix_memmap.c` SHA-256 is
  `5fc9ddbca5737c77748ebed4f65a0d7d4610ee1ae26c568102aa190f1f508a33`;
  patched SHA-256 is
  `58316adcf15e234f69c2b60e27c54b85f5de8e109e4d69570d4f9a8d87306e25`.
- Duckpad cancellation patch: instruction metering is enabled only as a
  cooperative cancellation poll. The bridge leaves each invocation unlimited
  at `-1`; an asynchronous atomic store of zero traps a tight interpreter
  loop. Normalized upstream/patched SHA-256 pairs are
  `wasm_runtime_common.c`
  `d2f8ce6f2a826e0bf8c733309e61f62597b446d33f66d8eab04d67625719e4e7` /
  `10388968bc146574bd6a289d125533d1d37a967906d6951cd8dd93609be71e7b`
  and `wasm_interp_classic.c`
  `0fbb845ce4f8cc5633493d96a00e2ecd5222906b492c1ed29a50795169a5c3b4` /
  `bf3ac6e09ef0083aa7539caf02f2c9dbf13ebc0b2a1cd2b0a8b2782913f5c8c5`.

Regenerate only into an absent target directory with
`scripts/vendor_wamr_2_4_5.sh`. The script validates HTTPS/TLS, checksum,
archive paths and links, and publishes with Darwin `RENAME_EXCL`.
