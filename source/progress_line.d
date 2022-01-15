struct ProgressLine {
    this(scope char[] line, size_t blockCount) {
        auto impl = BlockNumberImpl(line, blockCount);
        _accessor = Accessor(impl);
    }

    bool isValid() const nothrow {
        return _accessor.isValid();
    }

    void setValue(size_t value) {
        if (value == 0)
            _accessor[] = '-';
        else {
            _accessor[0 .. value - 1] = '=';
            _accessor[value - 1] = getEndingChar(value);
        }
    }

    char getEndingChar(size_t index) const {
        return index < _accessor.length - 1 ? '>' : '=';
    }

    /// Check invalid state
    unittest {
        ProgressLine p;
        assert(!p.isValid());
    }

    /// Check invalid state
    unittest {
        import core.exception: AssertError;

        static char[1] line;
        try
            ProgressLine(line, 0);
        catch (AssertError e)
            return;
        assert(false);
    }

private:
    alias Accessor = BufferAccessor!BlockNumberImpl;

    Accessor _accessor;
}


struct BlockNumberImpl {
    this(scope char[] buffer, size_t blockCount)
    in { assert(blockCount > 0); }
    do {
        _blockCount = blockCount;
        _accessor = Accessor(PercentageImpl(buffer));
    }

    auto getBuffer() nothrow {
        return _accessor;
    }

    auto getBuffer() const nothrow {
        return _accessor;
    }

    size_t getMaximum() const nothrow {
        return _blockCount;
    }

private:
    alias Accessor = BufferAccessor!PercentageImpl;

    size_t _blockCount;
    Accessor _accessor;
}


struct PercentageImpl {
    this(scope char[] buffer) {
        _buffer = buffer;
    }

    char[] getBuffer() nothrow {
        return _buffer;
    }

    const(char[]) getBuffer() const nothrow {
        return _buffer;
    }

    size_t getMaximum() const nothrow {
        return 100;
    }

private:
    char[] _buffer;
}


struct BufferAccessor(T) {
    this(T impl) {
        _impl = impl;
        _indexScale = calcIndexScale();
    }

    bool isValid() const nothrow {
        return _indexScale > 0.0;
    }

    @property size_t length() const {
        return _impl.getMaximum();
    }

    ref char opIndex(size_t i) {
        i = toBufferIndex(i);
        auto buf = getBuffer();
        return buf[i];
    }

    size_t opDollar() {
        const buf = getBuffer();
        return buf.length;
    }

    void opSliceAssign(char rhs) {
        auto buf = getBuffer();
        buf[] = rhs;
    }

    void opSliceAssign(char rhs, size_t i, size_t j) {
        i = toBufferIndex(i);
        j = toBufferIndex(j);
        auto buf = getBuffer();
        buf[i .. j] = rhs;
    }

private:
    auto getBuffer() {
        return _impl.getBuffer();
    }

    auto getBuffer() const {
        return _impl.getBuffer();
    }

    size_t toBufferIndex(size_t i) const nothrow {
        if (i > 0) {
            i = restrictIndex(i);
            i = cast(size_t)(i * _indexScale);
        }
        return i;
    }

    double calcIndexScale() const nothrow {
        const buf = getBuffer();
        const result = cast(double)buf.length / cast(double)length;
        return result;
    }

    size_t restrictIndex(size_t i) const nothrow {
        return i < length ? i : length - 1;
    }

private:
    double _indexScale;
    T _impl;
}
