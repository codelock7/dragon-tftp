import std.string;
import std.string: fromStringz;
import std.socket;
import std.stdio: File, writefln, writeln, writef, write, chunks;
import std.file: exists;
import std.digest: toHexString, Order;
import std.traits: isIntegral;
import core.stdc.stdio;
import buffer;


@safe
size_t getBlockSize() nothrow {
    return 512;
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
}


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


// alias ReadFunc = size_t delegate(scope byte[]);

// static immutable size_t getBlockSize() = 512;


enum OpCode : ushort {
    ReadRequest = 1,
    WriteRequest,
    Data,
    Acknowledgment,
    Error,
}


enum Mode {
    NetAscii,
    Octet,
    Mail,
}


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
}


struct AckPacket {
    OpCode opCode;
    ushort blockNumber;
}


struct DataPacket {
    OpCode opCode;
    ushort blockNumber;
    string block;
}


struct ODataPacket {
    OpCode opCode;
    ushort blockNumber;
    ReadFunc blocksSource;
}


struct ErrorPacket {
    OpCode opCode;
    ushort errorCode;
    string errorMessage;
}


struct Serializer {
    this(scope byte[] data) {
        _buffer = Buffer(data);
    }

    byte[] opCall(T)(scope ref T value) {
        foreach (item; value.tupleof)
            serialize(item);
        return _buffer.getUsed();
    }

private:
    void serialize(in Mode mode) {
        _buffer.push(toString(mode));
    }

    // void serialize(in ReadFunc funcRead)
    // in { assert(funcRead); }
    // do {
    //     _buffer.push(funcRead);
    // }

    void serialize(T)(in T value) {
        _buffer.push(value);
    }

private:
    Buffer _buffer;
}


class TFTPException : Exception {
    this(string msg, string file = __FILE__, size_t line = __LINE__) {
        super(msg, file, line);
    }
}


class ClientBase {
protected:
    Socket _socket;
    Address _address;
    byte[] buf;
    File _file;
    Buffer _buffer;
    bool _stopped = false;

    this(in string host)
    in {
        assert(host.length > 0);
    } do {
        _socket = new UdpSocket();
        static immutable ushort port = 69;
        _address = new InternetAddress(host, port);
        buf = new byte[getBlockSize() + 1024];
    }

    void reset() {
        _stopped = false;
    }

    bool receiveData() {
        _buffer = buf;
        _buffer.push(makeReceiveDataFunction());
        if (_buffer.getFreeSize() == buf.length)
            return false;
        _buffer = _buffer.getUsed();
        return true;
    }

    auto makeReceiveDataFunction() {
        return delegate size_t(scope byte[] data) {
            const ptrdiff_t len = receive(data);
            return len != Socket.ERROR ? len : 0;
        };
    }

    void printError() {
        const code = getErrorCode();
        const message = getErrorMessage();
        writefln("Error(%s): %s", code, message);
    }

    void sendPacket(in byte[] data) {
        const ptrdiff_t len = send(data);
        if (len == Socket.ERROR)
            throw new TFTPException("Socket error while sending data");
        if (len != data.length)
            throw new TFTPException("Data sent incomplete");
    }

private:
    ptrdiff_t receive(scope void[] data) {
        const len = _socket.receiveFrom(data, _address);
        return len;
    }

    ushort getErrorCode() {
        ushort result;
        _buffer.pop(result);
        return result;
    }

    string getErrorMessage() {
        string result;
        _buffer.getAll(result);
        return result[0 .. $ - 1];
    }

    ptrdiff_t send(in void[] data) {
        const len = _socket.sendTo(data, _address);
        return len;
    }
}


class GetRequest : ClientBase {
    private Context _context;
    void delegate(in ref Context) outputHandler;

    this(const string host) {
        super(host);
    }

    void opCall(in string filename) {
        reset();
        sendReadRequest(filename);
        try {
            _context.filename = filename;
            mainLoop();
        } catch (TFTPException e) {
            writeln("Error: ", e.msg);
        }
    }

private:
    struct Context {
        string filename;
        ushort lastBlockNumber;
        size_t receivedDataSize;
    }

    void mainLoop() {
        while (!_stopped) {
            if (!receiveData())
                return;
            const opCode = _buffer.pop!OpCode();
            handleOperation(opCode);
        }
        scope(exit) {
            if (_file.isOpen())
                _file.close();
        }
    }

    void handleOperation(OpCode opCode) {
        switch (opCode) {
        case OpCode.Data:
            onData();
            break;

        case OpCode.Error:
            onError();
            break;

        default:
            assert(false);
        }
    }

    void onData() {
        const blockNumber = _buffer.pop!ushort();
        const nextBlockNumber = _context.lastBlockNumber + 1;
        if (blockNumber != nextBlockNumber)
            return;
        _context.lastBlockNumber = blockNumber;
        const size_t blockSize = _buffer.getFreeSize();
        _context.receivedDataSize += blockSize;
        _buffer.getAll(makeDataReadFunction());
        const isLastBlock = blockSize < getBlockSize();
        if (isLastBlock)
            _stopped = true;
        if (outputHandler)
            outputHandler(_context);
        sendBlockAck(blockNumber);
    }

    auto makeDataReadFunction() {
        return delegate void(in byte[] data) {
            if (!_file.isOpen())
                _file = File(_context.filename, "w");
            _file.rawWrite(data);
        };
    }

    void onError() {
        printError();
    }

    void sendBlockAck(in ushort blockNumber) {
        const byte[] packet = makeBlockAck(blockNumber);
        sendPacket(packet);
    }

    void sendReadRequest(in string filename) {
        const byte[] packet = makeReadRequest(filename);
        sendPacket(packet);
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
}


class PutRequest : ClientBase {
    void delegate(in ref Context) outputHandler;
    private bool mHasNext;
    private Context _context;

    struct Context {
        ushort sentBlocksNumber;
        size_t blockCount;
    }

    this(in string host)
    in { assert(host.length > 0); }
    do {
        super(host);
    }

    size_t calcBlockCount()
    in { assert(getBlockSize() > 0); }
    do {
        const size_t modulo = _file.size() % getBlockSize();
        size_t blockCount = modulo > 0 ? 1 : 0;
        blockCount += _file.size() / getBlockSize();
        return blockCount;
    }

    void opCall(in string filename) {
        if (!exists(filename)) {
            writeln("File doesn't exist: ", filename);
            return;
        }
        _file = File(filename, "r");
        scope(exit) _file.close();

        reset();

        sendWriteRequest(filename);
        try {
            _context.blockCount = calcBlockCount();
            mainLoop();
        } catch (TFTPException e) {
            writeln("Error: ", e.msg);
        }
    }

protected:
    override void reset() {
        super.reset();
        mHasNext = true;
        _buffer = buf;
    }

private:
    ushort _blockNumber;

    byte[] makeNextDataPacket() {
        ++_context.sentBlocksNumber;
        return makeDataPacket(_context.sentBlocksNumber);
    }

    bool isBlockAcknowledged() const {
        return _blockNumber == _context.sentBlocksNumber;
    }

    bool isNeedToResendBlock() const {
        const prevBlockNumber = cast(ushort)(_context.sentBlocksNumber - 1);
        return _blockNumber == prevBlockNumber;
    }

    bool hasUnsentData() {
        const sentDataSize = _context.sentBlocksNumber * getBlockSize();
        const hasDataOrEndsWithEmptyBlock = sentDataSize <= _file.size();
        return hasDataOrEndsWithEmptyBlock;
    }

    void mainLoop() {
        byte[] lastDataPacket;
        ubyte resendAttemptCounter = void;

        while (!_stopped) {
            if (!receiveData()) {
                return;
            }
            const opCode = _buffer.pop!OpCode();
            switch (opCode) {
            case OpCode.Acknowledgment:
                _blockNumber = _buffer.pop!ushort();
                if (isBlockAcknowledged()) {
                    if (resendAttemptCounter > 0)
                        resendAttemptCounter = 0;
                    if (outputHandler)
                        outputHandler(_context);
                    lastDataPacket = makeNextDataPacket();
                    sendPacket(lastDataPacket);
                    if (!hasUnsentData())
                        _stopped = true;
                } else if (isNeedToResendBlock()) {
                    static immutable ubyte maximum = 3;
                    if (resendAttemptCounter++ >= maximum)
                        return;
                    sendPacket(lastDataPacket);
                } else {
                    assert(false);
                }
                break;

            case OpCode.Error:
                onError();
                break;

            default:
                assert(false);
            }
        }
    }

    void onError() {
        printError();
    }

    bool hasNext() const nothrow {
        return mHasNext;
    }

    void sendWriteRequest(in string filename) {
        sendPacket(makeWriteRequestPacket(filename));
    }

    byte[] makeDataPacket(in ushort blockNumber) {
        ODataPacket packet;
        packet.opCode = OpCode.Data;
        packet.blockNumber = blockNumber;
        packet.blocksSource = makeFileReadFunc();
        auto serializeFunc = Serializer(buf);
        return serializeFunc(packet);
    }

    byte[] makeWriteRequestPacket(in string filename) {
        GetPutPacket packet;
        packet.opCode = OpCode.WriteRequest;
        packet.mode = Mode.NetAscii;
        packet.filename = filename;
        auto serializeFunc = Serializer(buf);
        auto result = serializeFunc(packet);
        return result;
    }

    ReadFunc makeFileReadFunc() nothrow {
        return delegate size_t(scope byte[] data)
        in { assert(data.length >= getBlockSize()); }
        do {
            auto block = data[0 .. getBlockSize()];
            const byte[] r = _file.rawRead(block);
            return r.length;
        };
    }
}


enum ExitCode {
    success,
    invalidArgumentCount,
    unknownCommand,
}


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
            const size = toDataSize(c.receivedDataSize);
            writef("\r%s data received is ~%s %s (%s B)",
                    c.filename, size.value, toString(size.unit), c.receivedDataSize);
            fflush(stdout);
        };
        get(filename);
        writeln();

    } else if (command == "put") {
        import progress_line: ProgressLine;

        char[50] line;
        ProgressLine progressLine;

        auto put = new PutRequest(host);
        put.outputHandler = delegate void(in ref PutRequest.Context c) {
            if (!progressLine.isValid())
                progressLine = ProgressLine(line, c.blockCount);
            progressLine.setValue(c.sentBlocksNumber);
            writef("\r[%s]", line);
            fflush(stdout);
        };
        put(filename);
        writeln();

    } else {
        writeln("Unknown command: ", command);
        return ExitCode.unknownCommand;
    }
    return ExitCode.success;
}
