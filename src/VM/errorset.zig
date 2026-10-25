pub const Memory = error{ BlockTooBig, OutOfMemory };

pub const Table = Memory || error{
    @"table overflow",
    @"attempt to modify a readonly table",
    @"table index is nil",
    @"table index is nan",
    @"table index contains nan",
};

pub const Runtime = error{
    Runtime,
};

pub const Coroutine = Table || Runtime || error{
    @"too many results to invoke finalizer",
};

pub const TableReadonly = Table.@"attempt to modify a readonly table";
