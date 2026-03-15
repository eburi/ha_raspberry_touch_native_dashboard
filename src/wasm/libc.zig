///! C standard library stubs for WASM freestanding target.
///! These are needed because the C compiler (used to compile LVGL) emits
///! calls to memset/memcpy/memmove for struct init, array ops, etc.
///! even when LVGL uses its own lv_memset/lv_memcpy internally.

const std = @import("std");

// Use Zig's WASM page allocator for any C malloc/free calls
var wasm_allocator = std.heap.wasm_allocator;

// --- Memory operations ---

export fn memset(dest: [*]u8, c: c_int, n: usize) [*]u8 {
    @setRuntimeSafety(false);
    const byte: u8 = @truncate(@as(c_uint, @bitCast(c)));
    const slice = dest[0..n];
    @memset(slice, byte);
    return dest;
}

export fn memcpy(dest: [*]u8, src: [*]const u8, n: usize) [*]u8 {
    @setRuntimeSafety(false);
    const d = dest[0..n];
    const s = src[0..n];
    @memcpy(d, s);
    return dest;
}

export fn memmove(dest: [*]u8, src: [*]const u8, n: usize) [*]u8 {
    @setRuntimeSafety(false);
    if (n == 0) return dest;

    const d = dest[0..n];
    const s = src[0..n];

    if (@intFromPtr(dest) < @intFromPtr(src)) {
        // Forward copy
        @memcpy(d, s);
    } else if (@intFromPtr(dest) > @intFromPtr(src)) {
        // Backward copy (overlapping)
        var i: usize = n;
        while (i > 0) {
            i -= 1;
            d[i] = s[i];
        }
    }
    return dest;
}

export fn memcmp(s1: [*]const u8, s2: [*]const u8, n: usize) c_int {
    @setRuntimeSafety(false);
    for (0..n) |i| {
        if (s1[i] != s2[i]) {
            return @as(c_int, s1[i]) - @as(c_int, s2[i]);
        }
    }
    return 0;
}

// --- String operations ---

export fn strlen(s: [*]const u8) usize {
    @setRuntimeSafety(false);
    var len: usize = 0;
    while (s[len] != 0) : (len += 1) {}
    return len;
}

// --- Memory allocation ---
// LVGL uses LV_STDLIB_BUILTIN (TLSF allocator) so these should rarely be called.
// But just in case the C compiler inserts calls.

const Allocation = struct {
    ptr: [*]u8,
    len: usize,
};

export fn malloc(size: usize) ?[*]u8 {
    const mem = wasm_allocator.alloc(u8, size) catch return null;
    return mem.ptr;
}

export fn calloc(nmemb: usize, size: usize) ?[*]u8 {
    const total = nmemb *| size;
    const mem = wasm_allocator.alloc(u8, total) catch return null;
    @memset(mem, 0);
    return mem.ptr;
}

export fn realloc(ptr: ?[*]u8, size: usize) ?[*]u8 {
    // WASM page allocator doesn't support realloc properly,
    // so we just allocate new + copy. This is rarely called.
    if (ptr == null) return malloc(size);
    if (size == 0) {
        free(ptr);
        return null;
    }
    const new_mem = malloc(size) orelse return null;
    // We don't know the old size, so we copy `size` bytes
    // (caller guarantees the old buffer has at least `size` bytes when growing)
    @memcpy(new_mem[0..size], ptr.?[0..size]);
    return new_mem;
}

export fn free(ptr: ?[*]u8) void {
    // WASM page allocator doesn't support free
    // Memory is reclaimed when the WASM instance is destroyed
    _ = ptr;
}

// --- Misc C runtime ---

export fn abort() noreturn {
    @trap();
}

export fn __stack_chk_fail() noreturn {
    @trap();
}
