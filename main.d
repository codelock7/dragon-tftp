import std.string;
import std.string: fromStringz;
import std.socket;
import std.stdio: File, writefln, writeln, writef, write, chunks;
import std.file: exists;
import std.digest: toHexString, Order;
import std.traits: isIntegral;
import core.stdc.stdio;


extern(C)
{
    ushort htons(ushort) nothrow;
}

static ushort toNetworkByteOrder(ushort value) nothrow {
    return htons(value);
}

struct DataDimension {
    size_t len;
    string dim;
};

@safe
static DataDimension sizeToDataDimension(size_t dataSize) {
    static immutable string[] dimensions = [
        "B", "KB", "MB", "GB", "TB",
    ];
    DataDimension r;
    r.len = dataSize;
    r.dim = dimensions[0];
    size_t remainder = dataSize;
    for (size_t i = 1; (remainder /= 1024) != 0; ++i) {
        r.len = remainder;
        r.dim = dimensions[i];
    }
    return r;
}


alias ReadFunc = size_t delegate(scope byte[]);

immutable size_t gBlockSize = 512;

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

    void serialize(in ReadFunc readFunc) {
        assert(readFunc);
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
    File file;
    Buffer mBuffer;
    bool mStopped = false;

    this(in string host) {
        mSocket = new UdpSocket();
        mAddress = new InternetAddress(host, 69);
        buf = new byte[gBlockSize + 1024];
    }

    void reset() {
        mStopped = false;
    }

    byte[] receiveData() {
        const ptrdiff_t len = receive(buf);
        if (len == Socket.ERROR)
            return null;
        byte[] data = buf[0 .. len];
        return data;
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

    ptrdiff_t receive(scope void[] data) {
        const len = mSocket.receiveFrom(data, mAddress);
        return len;
    }

    ptrdiff_t send(in void[] data) {
        const len = mSocket.sendTo(data, mAddress);
        return len;
    }
};

class GetRequest : ClientBase {
    void delegate(Context) outputHandler;

    this(const string host) {
        super(host);
    }

    void opCall(in string filename) {
        reset();
        sendReadRequest(filename);
        try {
            mainLoop(filename);
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

    void mainLoop(in string filename) {
        Context c;
        c.filename = filename;
        while (!mStopped) {
            mBuffer = receiveData();
            switch (getOpCode()) {
            case OpCode.Data:
                const ushort blockNumber = getBlockNumber();
                const isDuplicatePacket = blockNumber == c.lastBlockNumber;
                if (isDuplicatePacket)
                    continue;
                c.lastBlockNumber = blockNumber;
                const size_t blockSize = mBuffer.getFreeSize();
                c.receivedDataLength += blockSize;
                mBuffer.getAll(delegate void(in byte[] data) {
                    if (!file.isOpen())
                        file = File(filename, "w");
                    file.rawWrite(data);
                });
                const isLastBlock = blockSize < gBlockSize;
                if (isLastBlock)
                    mStopped = true;
                if (outputHandler)
                    outputHandler(c);
                sendBlockAck(blockNumber);
                break;

            case OpCode.Error:
                printError();
                return;

            default:
                assert(false);
            }
        }
        scope(exit) file.close();
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
    private bool mSucceeded;

    this(in string host) {
        super(host);
    }

    void opCall(in string filename) {
        if (!exists(filename)) {
            writeln("File doesn't exist: ", filename);
            return;
        }
        file = File(filename, "r");
        scope(exit) file.close();

        reset();

        sendPutRequest(filename);
        try {
            Context c;
            c.dataSize = file.size();
            mainLoop(c);
            mSucceeded = true;
        } catch (TFTPException e) {
            writeln("Error: ", e.msg);
        }
    }

    bool isSucceeded() const {
        return mSucceeded;
    }

    struct Context {
        ushort currentBlockNumber;
        size_t dataSize;
    }

    void delegate(Context) outputHandler;

protected:
    override void reset() {
        super.reset();
        mHasNext = true;
        mSucceeded = false;
        mBuffer = buf;
    }

private:
    OpCode getOpCode() {
        OpCode result;
        mBuffer.pop(result);
        return result;
    }

    ushort getBlockNumber() {
        ushort result;
        mBuffer.pop(result);
        return result;
    }

    void mainLoop(scope ref Context c) {
        while (!mStopped) {
            mBuffer = receiveData();
            switch (getOpCode()) {
            case OpCode.Acknowledgment:
                const blockNumber = getBlockNumber();
                const isExpiredPacket = blockNumber != c.currentBlockNumber;
                if (isExpiredPacket)
                    continue;

                if (outputHandler)
                    outputHandler(c);

                sendNextBlock(c.currentBlockNumber);
                if (!hasNext())
                    mStopped = true;
                break;

            case OpCode.Error:
                printError();
                return;

            default:
                assert(false);
            }
        }
        scope(success) {
            //progressLine = '=';
            //writefln(progressLineTemplate, progressLine);
        }
    }

    bool hasNext() const nothrow {
        return mHasNext;
    }

    void sendNextBlock(scope ref ushort blockNumber) {
        ++blockNumber;
        const request = makeDataRequest(blockNumber);
        sendData(request);
        const size_t expectedSize = ODataPacket.opCode.sizeof
                + ODataPacket.blockNumber.sizeof
                + gBlockSize;
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
        auto serialize = Serializer(buf);
        return serialize(packet);
    }

    byte[] makePutRequest(in string filename) {
        GetPutPacket packet;
        packet.opCode = OpCode.WriteRequest;
        packet.mode = Mode.NetAscii;
        packet.filename = filename;
        auto serialize = Serializer(buf);
        auto result = serialize(packet);
        return result;
    }

    ReadFunc makeFileReadFunc() nothrow {
        return delegate size_t(scope byte[] buf) {
            const byte[] res = file.rawRead(buf);
            return res.length;
        };
    }
};

struct Progress {
    private float mFactor;
    private char[] mLineBuffer;

    this(scope char[] lineBuffer, size_t dataSize) {
        mLineBuffer = lineBuffer;
        mLineBuffer[0 .. $] = '-';
        mFactor = calcBlockFactor(dataSize);
    }

    bool isValid() const {
        return mFactor > 0.0f;
    }

    void update(size_t blockNumber) {
        const end = cast(size_t)(blockNumber * mFactor);
        if (end == 0)
            return;
        mLineBuffer[0 .. end - 1] = '=';
        mLineBuffer[end - 1] = '>';
    }

    void fill() {
        mLineBuffer[0 .. $] = '=';
    }

private:
    float calcBlockFactor(size_t dataSize) {
        const size_t remainder = (dataSize % gBlockSize) != 0;
        const size_t fileBlocks = dataSize / gBlockSize + remainder;
        return float(mLineBuffer.length) / float(fileBlocks);
    }
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
        mFree = rhs;
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
    invalidArgumentsNumber,
    unknownCommand,
};

int main(string[] args) {
    if (args.length < 4) {
        writefln("\"host\" \"put|get\" \"file name\"");
        return ExitCode.invalidArgumentsNumber;
    }
    const string host     = args[1];
    const string command  = args[2];
    const string filename = args[3];
    if (command == "get") {
        auto get = new GetRequest(host);
        get.outputHandler = delegate void(GetRequest.Context c) {
            const dataDim = sizeToDataDimension(c.receivedDataLength);
            writef("\r%s data received is ~%s %s (%s B)",
                    c.filename, dataDim.len, dataDim.dim, c.receivedDataLength);
        };
        get(filename);
        writeln();
    } else if (command == "put") {
        auto put = new PutRequest(host);

        char[50] progressLine;
        Progress progress;

        put.outputHandler = delegate void(PutRequest.Context c) {
            if (!progress.isValid())
                progress = Progress(progressLine, c.dataSize);
            progress.update(c.currentBlockNumber);
            writef("\r[%s]", progressLine);
            fflush(stdout);
        };
        put(filename);
        if (put.isSucceeded()) {
            progress.fill();
            writef("\r[%s]", progressLine);
        }
    } else {
        writeln("Unknown command: ", command);
        return ExitCode.unknownCommand;
    }
    return ExitCode.success;
}
