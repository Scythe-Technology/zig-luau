pub fn DenseHashPointer(key: *const anyopaque) usize {
    // return (@intFromPtr(key) >> 4) ^ (@intFromPtr(key) >> 9);

    // The idea to use this hash function was suggested here originally: https://maskray.me/blog/2026-06-07-recent-llvm-hash-table-improvements
    // Hash function implementation is detailed here: https://github.com/MaskRay/llvm-project/blob/main/llvm/include/llvm/ADT/DenseMapInfo.h
    // This hash produces better scattering for arena allocated types, because the pointers usually share the higher order bits.
    // When inserting lots of keys, quadratic probing is not enough to save DenseHash, although it usually takes many more elements,
    // before it becomes a problem
    var u: u64 = @intFromPtr(key);
    u *%= 0xbf58476d1ce4e5b9;
    u ^= u >> 31;
    // On 32-bit platforms uint64_t to size_t is a narrowing, so we need
    // to static cast here.
    return @truncate(u);
}
