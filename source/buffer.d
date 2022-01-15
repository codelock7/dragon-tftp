alias ReadFunc = size_t delegate(scope byte[]);

extern(C) {
    @safe ushort htons(ushort) nothrow;
}

@safe
static ushort toNetworkByteOrder(ushort value) nothrow {
    return htons(value);
}

struct Buffer {
    this(scope byte[] outerBuffer) nothrow {
        _buffer = outerBuffer;
        _freeMemory = _buffer;
    }

    byte[] getUsed() {
        const len = _buffer.length - _freeMemory.length;
        return _buffer[0 .. len];
    }

    byte[] getRemainder() nothrow {
        return _freeMemory;
    }

    size_t getFreeSize() const nothrow {
        return _freeMemory.length;
    }

    void push(in ubyte value) {
        auto buf = allocateMemory(ubyte.sizeof);
        buf[0] = cast(byte)value;
    }

    void push(in string value) {
        if (value.length <= 0)
            return;
        static assert('\0'.sizeof == 1);
        auto buf = allocateMemory(value.length + '\0'.sizeof);
        buf[0 .. value.length] = cast(byte[])value;
        buf[value.length] = '\0';
    }

    void push(T)(in T integer) {
        ByteRepr!T temp;
        temp.value = cast(T)toNetworkByteOrder(integer);
        auto buf = allocateMemory(T.sizeof);
        buf[0 .. temp.bytes.length] = cast(byte[])temp.bytes;
    }

    void push(ReadFunc funcRead)
    in { assert(funcRead); }
    do {
        const size_t sizeUsed = funcRead(_freeMemory);
        shrinkFreeMemory(sizeUsed);
    }

    void pop(T)(scope ref T integer) {
        ByteRepr!T temp;
        temp.bytes = allocateMemory(T.sizeof);
        integer = cast(T)toNetworkByteOrder(temp.value);
    }

    auto pop(T)() {
        T result;
        pop(result);
        return result;
    }

    void getAll(scope ref string value) {
        value = cast(string)_freeMemory;
    }

    void getAll(void delegate(in byte[]) readFrom) {
        readFrom(_freeMemory);
    }

    void opAssign(scope byte[] rhs) {
        _buffer = rhs;
        _freeMemory = _buffer;
    }

protected:
    union ByteRepr(T) {
        T value;
        void[T.sizeof] bytes;
    };

    byte[] allocateMemory(size_t length) {
        auto result = _freeMemory[0 .. length];
        shrinkFreeMemory(length);
        return result;
    }

    @safe
    void shrinkFreeMemory(size_t length) {
        _freeMemory = _freeMemory[length .. $];
    }

private:
    byte[] _buffer;
    byte[] _freeMemory;
}
