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

Regenerate only into an absent target directory with
`scripts/vendor_wamr_2_4_5.sh`. The script validates HTTPS/TLS, checksum,
archive paths and links, and publishes with Darwin `RENAME_EXCL`.
