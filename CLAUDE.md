# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

mimalloc is a general purpose memory allocator with excellent performance characteristics. It's a drop-in replacement for `malloc` that offers free list sharding, eager page purging, secure mode options, and bounded worst-case allocation times.

## Build Commands

### Linux/macOS/BSD
```bash
# Standard release build
mkdir -p out/release && cd out/release
cmake ../..
make

# Debug build (includes detailed statistics and internal checks)
mkdir -p out/debug && cd out/debug
cmake -DCMAKE_BUILD_TYPE=Debug ../..
make

# Secure build (guard pages, encrypted free lists, etc.)
mkdir -p out/secure && cd out/secure
cmake -DMI_SECURE=ON ../..
make

# Do not install by make install
```

### Windows
- Open `ide/vs2022/mimalloc.sln` in Visual Studio 2022
- Build `mimalloc-lib` project for static library
- Build `mimalloc-override-dll` project for DLL override

### Alternative: Single Source Build
You can directly compile `src/static.c` as part of your project without cmake. Make sure to include the `include` directory.

## Test Commands

```bash
# Run basic tests (from build directory)
make test

# Run specific test executables (actual names from build)
./mimalloc-test-api       # Main API tests (43 tests covering aligned allocation, heap ops, STL)
./mimalloc-test-api-fill  # API tests with memory filling
./mimalloc-test-stress    # Stress testing
./mimalloc-test-stress-dynamic  # Dynamic stress testing

# Example workflow:
mkdir -p out/debug-2 && cd out/debug-2
cmake ../..
make
./mimalloc-test-api
```

## Key Build Options

- `MI_SECURE=ON` - Full security mitigations (guard pages, randomization, etc.)
- `MI_DEBUG_FULL=ON` - Full internal heap invariant checking (expensive)
- `MI_OVERRIDE=ON` - Override standard malloc interface (default: ON)
- `MI_GUARDED=ON` - Guard pages behind object allocations
- `MI_TRACK_VALGRIND=ON` - Valgrind support
- `MI_TRACK_ASAN=ON` - Address sanitizer support

## Code Architecture

### Core Components

- **Memory Management Core**: `src/alloc.c`, `src/free.c` - Main allocation/deallocation logic
- **Page Management**: `src/page.c`, `src/page-queue.c`, `src/page-map.c` - Manages mimalloc pages (typically 64KiB blocks containing same-size objects)
- **Arena System**: `src/arena.c`, `src/arena-meta.c` - Higher-level memory region management
- **Statistics & Options**: `src/stats.c`, `src/options.c` - Runtime configuration and metrics
- **OS Abstraction**: `src/os.c`, `src/prim/` - Platform-specific primitives and OS calls
- **Heap Management**: `src/heap.c` - Thread-local and shared heap structures

### Key Design Concepts

1. **Free List Sharding**: Each page has its own free lists rather than global ones, reducing contention and improving locality
2. **Multi-Sharding**: Separate free lists for thread-local vs. concurrent operations on each page
3. **Eager Purging**: Empty pages are quickly returned to OS to reduce memory pressure
4. **Bounded Operations**: No internal contention points, uses only atomic operations

### Thread Safety

- Thread-local heaps for allocation performance
- Lock-free concurrent operations using atomic primitives
- Separate free lists handle cross-thread deallocations efficiently

### Memory Layout

- Objects grouped by size class within pages
- Pages are typically 64KiB on 64-bit systems
- Arenas manage larger memory regions (usually 1GiB)

## Environment Variables for Testing

```bash
# Show statistics on program exit
MIMALLOC_SHOW_STATS=1

# Verbose output
MIMALLOC_VERBOSE=1

# Show errors and warnings
MIMALLOC_SHOW_ERRORS=1

# Disable dynamic override (Windows)
MIMALLOC_DISABLE_REDIRECT=1
```

## Notable Files

- `include/mimalloc.h` - Main public API
- `include/mimalloc-override.h` - Header for static malloc override
- `include/mimalloc-new-delete.h` - C++ new/delete overrides
- `src/static.c` - Single file build option
- `test/test-api.c` - API usage examples