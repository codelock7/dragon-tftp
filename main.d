import std.string;
import std.string: fromStringz;
import std.socket;
import std.stdio: File, writefln, writeln, writef, write, chunks;
import std.file: exists;
import std.digest: toHexString, Order;
import std.traits: isIntegral;
import core.stdc.stdio;


extern(C) {
    @safe
    ushort htons(ushort) nothrow;
}

@safe
static ushort toNetworkByteOrder(ushort value) nothrow {
    return htons(value);
}

enum MultibyteUnits {
    b, kb, mb, gb, tb, eb, zb, yb,
}

@safe
string toString(MultibyteUnits value) {
    static immutable string[] table = [
        "B", "KB", "MB", "GB", "TB", "EB", "ZB", "YB"
    ];
    return table[value];
}

struct DataSize {
    size_t value;
    MultibyteUnits unit;
};

@safe
static DataSize toDataSize(size_t bytesSize) {
    DataSize r;
    r.value = bytesSize;
    size_t remainder = bytesSize;
    while ((remainder /= 1024) != 0) {
        r.value = remainder;
        ++r.unit;
    }
    return r;
}


alias ReadFunc = size_t delegate(scope byte[]);

static immutable size_t gBlockSize = 512;

enum OpCode : ushort {
    ReadRequest = 1,
    WriteRequest,
    Data,
    Acknowledgment,
    Error,
};

enum Mode {
    NetAscii,
    Octet,
    Mail,
};

@safe
static string toString(Mode mode) nothrow {
    final switch (mode) {
    case Mode.NetAscii:
        return "netascii";
    case Mode.Octet:
        return "octet";
    case Mode.Mail:
        return "mail";
    }
}

struct GetPutPacket {
    OpCode opCode;
    string filename;
    Mode mode;
};

struct AckPacket {
    OpCode opCode;
    ushort blockNumber;
};

struct DataPacket {
    OpCode opCode;
    ushort blockNumber;
    string block;
};

struct ODataPacket {
    OpCode opCode;
    ushort blockNumber;
    ReadFunc blocksSource;
}

struct ErrorPacket {
    OpCode opCode;
    ushort errorCode;
    string errorMessage;
};

struct Serializer {
    this(scope byte[] data) {
        mBuffer = Buffer(data);
    }

    byte[] opCall(T)(scope ref T value) {
        foreach (item; value.tupleof)
            serialize(item);
        return mBuffer.getUsed();
    }

private:
    void serialize(in Mode mode) {
        mBuffer.push(toString(mode));
    }

    void serialize(in ReadFunc readFunc)
    in {
        assert(readFunc);
    } do {
        mBuffer.pushBlock(readFunc);
    }

    void serialize(T)(in T value) {
        mBuffer.push(value);
    }

private:
    Buffer mBuffer;
}


class TFTPException : Exception {
    this(string msg, string file = __FILE__, size_t line = __LINE__) {
        super(msg, file, line);
    }
}

class ClientBase {
protected:
    Socket mSocket;
    Address mAddress;
    byte[] buf;
    File mFile;
    Buffer mBuffer;
    bool mStopped = false;

    this(in string host)
    in {
        assert(host.length > 0);
    } do {
        mSocket = new UdpSocket();
        static immutable ushort port = 69;
        mAddress = new InternetAddress(host, port);
        buf = new byte[gBlockSize + 1024];
    }

    void reset() {
        mStopped = false;
    }

    bool receiveData() {
        mBuffer = buf;
        mBuffer.pushBlock(delegate size_t(scope byte[] data) {
            const ptrdiff_t len = receive(data);
            return len != Socket.ERROR ? len : 0;
        });
        const isBufferChanged = mBuffer.getFreeSize() != buf.length;
        if (isBufferChanged)
            mBuffer = mBuffer.getUsed();
        return isBufferChanged;
    }

    void printError() {
        const code = getErrorCode();
        const message = getErrorMessage();
        writefln("Error(%s): %s", code, message);
    }

    void sendData(in byte[] data) {
        const ptrdiff_t len = send(data);
        if (len == Socket.ERROR)
            throw new TFTPException("Socket error while sending data");
        if (len != data.length)
            throw new TFTPException("Data sent incomplete");
    }

private:
    ptrdiff_t receive(scope void[] data) {
        const len = mSocket.receiveFrom(data, mAddress);
        return len;
    }

    ushort getErrorCode() {
        ushort result;
        mBuffer.pop(result);
        return result;
    }

    string getErrorMessage() {
        string result;
        mBuffer.getAll(result);
        return result[0 .. $ - 1];
    }

    ptrdiff_t send(in void[] data) {
        const len = mSocket.sendTo(data, mAddress);
        return len;
    }
};

class GetRequest : ClientBase {
    private Context mContext;
    void delegate(in ref Context) outputHandler;

    this(const string host) {
        super(host);
    }

    void opCall(in string filename) {
        reset();
        sendReadRequest(filename);
        try {
            mContext.filename = filename;
            mainLoop();
        } catch (TFTPException e) {
            writeln("Error: ", e.msg);
        }
    }

private:
    struct Context {
        string filename;
        ushort lastBlockNumber;
        size_t receivedDataLength;
    }

    bool checkBlockNumberAndUpdate(ushort blockNumber) {
        const isNewDataPiece = blockNumber > mContext.lastBlockNumber;
        if (!isNewDataPiece)
            return false;
        mContext.lastBlockNumber = blockNumber;
        return true;
    }

    void mainLoop() {
        while (!mStopped) {
            if (!receiveData())
                return;
            switch (getOpCode()) {
            case OpCode.Data:
                const ushort blockNumber = getBlockNumber();
                if (!checkBlockNumberAndUpdate(blockNumber))
                    continue;
                const size_t blockSize = mBuffer.getFreeSize();
                mContext.receivedDataLength += blockSize;
                mBuffer.getAll(delegate void(in byte[] data) {
                    if (!mFile.isOpen())
                        mFile = File(mContext.filename, "w");
                    mFile.rawWrite(data);
                });
                const isLastBlock = blockSize < gBlockSize;
                if (isLastBlock)
                    mStopped = true;
                if (outputHandler)
                    outputHandler(mContext);
                sendBlockAck(blockNumber);
                break;

            case OpCode.Error:
                printError();
                return;

            default:
                assert(false);
            }
        }
        scope(exit) mFile.close();
    }

    ushort getBlockNumber() {
        ushort result;
        mBuffer.pop(result);
        return result;
    }

    OpCode getOpCode() {
        OpCode result;
        mBuffer.pop(result);
        return result;
    }
    
    void sendBlockAck(in ushort blockNumber) {
        const byte[] packet = makeBlockAck(blockNumber);
        sendData(packet);
    }

    void sendReadRequest(in string filename) {
        const byte[] packet = makeReadRequest(filename);
        sendData(packet);
    }

    byte[] makeBlockAck(in ushort blockNumber) {
        AckPacket packet;
        packet.opCode = OpCode.Acknowledgment;
        packet.blockNumber = blockNumber;
        auto serializeFunc = Serializer(buf);
        return serializeFunc(packet);
    }

    byte[] makeReadRequest(in string filename) {
        GetPutPacket packet;
        packet.opCode = OpCode.ReadRequest;
        packet.mode = Mode.NetAscii;
        packet.filename = filename;
        auto serializeFunc = Serializer(buf);
        return serializeFunc(packet);
    }
};


class PutRequest : ClientBase {
    private bool mHasNext;
    private Context mContext;

    this(in string host) {
        super(host);
    }

    void opCall(in string filename) {
        if (!exists(filename)) {
            writeln("File doesn't exist: ", filename);
            return;
        }
        mFile = File(filename, "r");
        scope(exit) mFile.close();

        reset();

        sendPutRequest(filename);
        try {
            mContext.dataSize = mFile.size();
            mainLoop();
        } catch (TFTPException e) {
            writeln("Error: ", e.msg);
        }
    }

    struct Context {
        ushort sentBlockNumber;
        size_t dataSize;
    }

    void delegate(in ref Context) outputHandler;

protected:
    override void reset() {
        super.reset();
        mHasNext = true;
        mBuffer = buf;
    }

private:
    OpCode getOpCode() {
        OpCode result;
        mBuffer.pop(result);
        return result;
    }

    ushort readBlockNumber() {
        ushort result;
        mBuffer.pop(result);
        return result;
    }

    ushort getSentBlockNumber() const
    {
        return mContext.sentBlockNumber;
    }

    ushort getPrevBlockNumber() const
    {
        return cast(ushort)(mContext.sentBlockNumber - 1);
    }

    byte[] makeNextDataRequest()
    {
        ++mContext.sentBlockNumber;
        return makeDataRequest(mContext.sentBlockNumber);
    }

    void mainLoop()
    {
        byte[] lastDataRequest;
        ubyte retryAttemptCount;

        while (!mStopped) {
            if (!receiveData())
                return;
            switch (getOpCode()) {
            case OpCode.Acknowledgment:
                const ushort blockNumber = readBlockNumber();
                const isAcknowledged = blockNumber == getSentBlockNumber();
                if (isAcknowledged) {
                    if (retryAttemptCount > 0)
                        retryAttemptCount = 0;
                    if (outputHandler)
                        outputHandler(mContext);
                    //sendNextBlock();
                    lastDataRequest = makeNextDataRequest();
                    sendData(lastDataRequest);
                    if (lastDataRequest.length != getDataPacketExpectedSize())
                        mStopped = true;
                } else {
                    const isPendingResend = blockNumber == getPrevBlockNumber();
                    if (isPendingResend) {
                        static immutable ubyte attemptsMaximumNumber = 3;
                        if (retryAttemptCount >= attemptsMaximumNumber)
                            return;
                        ++retryAttemptCount;
                        sendData(lastDataRequest);
                    }
                    else
                        assert(false);
                }
                break;

            case OpCode.Error:
                printError();
                return;

            default:
                assert(false);
            }
        }
    }

    bool hasNext() const nothrow
    {
        return mHasNext;
    }

    size_t getDataPacketExpectedSize() const
    {
        return ODataPacket.opCode.sizeof
            + ODataPacket.blockNumber.sizeof
            + gBlockSize;
    }

    void sendNextBlock() {
        ++mContext.sentBlockNumber;
        const request = makeDataRequest(mContext.sentBlockNumber);
        sendData(request);
        const size_t expectedSize = getDataPacketExpectedSize();
        mHasNext = request.length == expectedSize;
    }

    void sendPutRequest(in string filename) {
        const byte[] request = makePutRequest(filename);
        sendData(request);
    }

    byte[] makeDataRequest(in ushort blockNumber) {
        ODataPacket packet;
        packet.opCode = OpCode.Data;
        packet.blockNumber = blockNumber;
        packet.blocksSource = makeFileReadFunc();
        auto serializeFunc = Serializer(buf);
        return serializeFunc(packet);
    }

    byte[] makePutRequest(in string filename) {
        GetPutPacket packet;
        packet.opCode = OpCode.WriteRequest;
        packet.mode = Mode.NetAscii;
        packet.filename = filename;
        auto serializeFunc = Serializer(buf);
        auto result = serializeFunc(packet);
        return result;
    }

    ReadFunc makeFileReadFunc() nothrow {
        return delegate size_t(scope byte[] data) {
            const byte[] r = mFile.rawRead(data);
            return r.length;
        };
    }
};


struct BlockNumberAccessor {
    this(scope char[] buffer, size_t blockCount) {
        _blockCount = blockCount;
        _accessor = Accessor(PercentageAccessor(buffer));
    }

    auto getBuffer() nothrow { return _accessor; }
    auto getBuffer() const nothrow { return _accessor; }
    size_t getMaximum() const nothrow { return _blockCount; }

private:
    alias Accessor = BufferAccessor!PercentageAccessor;

    size_t _blockCount;
    Accessor _accessor;
}

struct PercentageAccessor {
    this(scope char[] buffer) { _buffer = buffer; }
    char[] getBuffer() nothrow { return _buffer; }
    const(char[]) getBuffer() const nothrow { return _buffer; }
    size_t getMaximum() const nothrow { return 100; }

private:
    char[] _buffer;
}


struct BufferAccessor(T) {
    this(T impl) {
        _impl = impl;
        _indexScale = calculateIndexScale();
        writeln("IndexScale ", _indexScale);
    }

    bool isValid() const nothrow { return _indexScale > 0.0; }
    size_t getMaximum() const nothrow { return _impl.getMaximum(); }

    ref char opIndex(size_t i) {
        i = toBufferIndex(i);
        auto buf = getBuffer();
        return buf[i];
    }

    size_t opDollar() {
        auto buf = getBuffer();
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
    auto getBuffer() { return _impl.getBuffer(); }
    auto getBuffer() const { return _impl.getBuffer(); }

    size_t toBufferIndex(size_t i) const nothrow {
        if (i > 0) {
            i = filterIndex(i);
            i = toUnderlyingIndex(i);
        }
        return i;
    }

    double calculateIndexScale() const nothrow {
        const buf = getBuffer();
        return cast(double)buf.length / cast(double)getMaximum();
    }
    
    size_t filterIndex(size_t i) const nothrow {
        return i < getMaximum() ? i : getMaximum();
    }

    size_t toUnderlyingIndex(size_t i) const nothrow {
        return cast(size_t)(i * _indexScale);
    }

private:
    double _indexScale;
    T _impl;
}

size_t length(scope ref const(BufferAccessor!PercentageAccessor) lhs) nothrow {
    return lhs.getMaximum();
}

struct Progress {
    this(scope char[] line, size_t blockCount) {
        auto impl = BlockNumberAccessor(line, blockCount);
        _accessor = Accessor(impl);
    }

    bool isValid() const { return _accessor.isValid(); }

    void setValue(size_t value) {
        if (value == 0) {
            _accessor[] = '-';
        } else {
            _accessor[0 .. value - 1] = '=';
            _accessor[value - 1] = getEndingChar(value);
        }
    }

    char getEndingChar(size_t index) const {
        return index == _accessor.getMaximum() ? '=' : '>';
    }

private:
    alias Accessor = BufferAccessor!BlockNumberAccessor;

    Accessor _accessor;
}


struct Buffer
{
    this(scope byte[] outerBuffer) nothrow {
        mBuffer = outerBuffer;
        mFree = mBuffer;
    }

    byte[] getUsed() {
        const len = mBuffer.length - mFree.length;
        return mBuffer[0 .. len];
    }

    byte[] getRemainder() nothrow {
        return mFree;
    }

    size_t getFreeSize() const nothrow {
        return mFree.length;
    }

    void push(in ubyte value) {
        auto buf = getFreeAndCut(ubyte.sizeof);
        buf[0] = cast(byte)value;
    }

    void push(in string value) {
        if (value.length <= 0)
            return;
        static assert('\0'.sizeof == 1);
        auto buf = getFreeAndCut(value.length + '\0'.sizeof);
        buf[0 .. value.length] = cast(byte[])value;
        buf[value.length] = '\0';
    }

    void push(T)(in T integer) {
        ByteRepr!T temp;
        temp.value = cast(T)toNetworkByteOrder(integer);
        auto buf = getFreeAndCut(T.sizeof);
        buf[0 .. temp.bytes.length] = cast(byte[])temp.bytes;
    }

    void pushBlock(ReadFunc readFunc) {
        auto buf = getFree(gBlockSize);
        const size_t len = readFunc(buf);
        cut(len);
    }

    void pop(T)(scope ref T integer) {
        ByteRepr!T temp;
        temp.bytes = getFreeAndCut(T.sizeof);
        integer = cast(T)toNetworkByteOrder(temp.value);
    }

    void getAll(scope ref string value) {
        value = cast(string)mFree;
    }

    void getAll(void delegate(in byte[]) readFrom) {
        readFrom(mFree);
    }

    void opAssign(scope byte[] rhs) {
        mBuffer = rhs;
        mFree = mBuffer;
    }

protected:
    union ByteRepr(T) {
        T value;
        void[T.sizeof] bytes;
    };

    byte[] getFreeAndCut(size_t length) {
        auto result = getFree(length);
        cut(length);
        return result;
    }

    byte[] getFree(size_t length) {
        return mFree[0 .. length];
    }

    @safe
    void cut(size_t length) {
        mFree = mFree[length .. $];
    }

private:
    byte[] mBuffer;
    byte[] mFree;
}

enum ExitCode {
    success,
    invalidArgumentCount,
    unknownCommand,
};

int main(string[] args) {
    if (args.length < 4) {
        writefln("\"host\" \"put|get\" \"file name\"");
        return ExitCode.invalidArgumentCount;
    }

    const string host     = args[1];
    const string command  = args[2];
    const string filename = args[3];

    if (command == "get") {
        auto get = new GetRequest(host);
        get.outputHandler = delegate void(in ref GetRequest.Context c) {
            const size = toDataSize(c.receivedDataLength);
            writef("\r%s data received is ~%s %s (%s B)",
                    c.filename, size.value, toString(size.unit), c.receivedDataLength);
            fflush(stdout);
        };
        get(filename);
        writeln();
    } else if (command == "put") {
        auto put = new PutRequest(host);

        char[50] progressLine;
        Progress progress;

        put.outputHandler = delegate void(in ref PutRequest.Context c) {
            if (!progress.isValid()) {
                const blockCount = c.dataSize / gBlockSize;
                progress = Progress(progressLine, blockCount);
            }
            progress.setValue(c.sentBlockNumber);
            writef("\r[%s]", progressLine);
            fflush(stdout);
        };
        put(filename);
    } else {
        writeln("Unknown command: ", command);
        return ExitCode.unknownCommand;
    }
    return ExitCode.success;
}
