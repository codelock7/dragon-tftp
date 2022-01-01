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

ushort toNetworkByteOrder(ushort value) nothrow {
    return htons(value);
}

alias BlockReader = size_t delegate(scope byte[]);

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
    string fileName;
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
    BlockReader blocksSource;
}

struct ErrorPacket {
    OpCode opCode;
    ushort errorCode;
    string errorMessage;
};

static byte[] serializeTo(in ubyte value, return scope byte[] buf) nothrow {
    auto buffer = Buffer(buf);
    buffer.push(value);
    return buffer.getRemainder();
    // buf[0] = cast(byte) value;
    // return buf[1 .. $];
}

static byte[] serializeTo(in ushort value, return scope byte[] buf) nothrow {
    auto buffer = Buffer(buf);
    buffer.push(value);
    return buffer.getRemainder();
}

static byte[] serializeTo(in string value, return scope byte[] buf) {
    if (!value.length)
        return buf;
    writeln("BUFSZ ", buf.length);
    buf[0 .. value.length] = cast(byte[])value;
    buf[value.length] = 0;
    return buf[value.length + 1 .. $];
}

static byte[] serializeTo(in Mode mode, return scope byte[] buf) {
    return toString(mode).serializeTo(buf);
}

static byte[] serializeTo(BlockReader reader, return scope byte[] buf) {
    const size_t len = reader(buf[0 .. gBlockSize]);
    return buf[len .. $];
}

static byte[] serialize(T)(ref T value, return scope byte[] buf) {
    byte[] it = buf;
    foreach (item; value.tupleof)
        it = item.serializeTo(it);
    return buf[0 .. buf.length - it.length];
}

class TFTPException : Exception {
    this(string msg, string file = __FILE__, size_t line = __LINE__) {
        super(msg, file, line);
    }
}

class ClientBase {
protected:
    Socket sock;
    Address addr;
    byte[] buf;
    File file;
    Buffer mBuffer;
    bool stopped = false;

    this(in string host) {
        sock = new UdpSocket();
        addr = new InternetAddress(host, 69);
        buf = new byte[gBlockSize + 1024];
    }

    void reset() {
        stopped = false;
    }

    byte[] receivePacket() {
        const ptrdiff_t receivedBytes = receive(buf);
        if (receivedBytes == Socket.ERROR)
            return null;
        byte[] packet = buf[0 .. receivedBytes];
        return packet;
    }

    void printError(scope byte[] packet) {
        ushort errorCode;
        auto buffer = Buffer(packet);
        buffer.pop(errorCode);
        packet = buffer.getRemainder();
        //packet = errorCode.setIntegral(packet);
        auto errorMessage = fromStringz((cast(string)packet).ptr);
        writeln("Error(", errorCode, "): ", errorMessage);
    }

    void sendPacket(in byte[] packet) {
        const ptrdiff_t bytesSent = send(packet);
        if (bytesSent == Socket.ERROR)
            throw new TFTPException("Socket error while sending data");
        if (bytesSent != packet.length)
            throw new TFTPException("Packet sent incomplete");
    }

private:
    ptrdiff_t receive(scope void[] buf) {
        return sock.receiveFrom(cast(void[]) buf, addr);
    }

    ptrdiff_t send(in byte[] buf) {
        return sock.sendTo(cast(const void[]) buf, addr);
    }
};

class GetRequest : ClientBase {
    private bool mHasData;

    this(const string host) {
        super(host);
    }

    void opCall(in string fileName) {
        reset();
        sendGetRequest(fileName);
        try {
            mainLoop(fileName);
        } catch (TFTPException e) {
            writeln("Error: ", e.msg);
        }
    }

protected:
    override void reset() {
        super.reset();
        mHasData = true;
    }

private:
    struct DataDimension {
        size_t len;
        string dim;
    };

    void mainLoop(in string fileName) {
        ushort prevBlockNumber = 0;
        size_t recvDataLen = 0;
        while (!stopped) {
            byte[] packet = receivePacket();
            OpCode opCode;
            auto buffer = Buffer(packet);
            buffer.pop(opCode);
            //packet = opCode.setIntegral(packet);
            switch (opCode) {
            case OpCode.Data:
                ushort blockNumber;
                buffer.pop(blockNumber);
                byte[] data = buffer.getRemainder();
                //byte[] data = blockNumber.setIntegral(packet);
                if (blockNumber == prevBlockNumber)
                    continue;
                if (blockNumber == 1)
                    file = File(fileName, "w");
                prevBlockNumber = blockNumber;
                // recvDataLen += buffer.getRemainder().length;
                recvDataLen += data.length;
                writeDataToFile(data);
                if (!hasData())
                    stopped = true;
                DataDimension dd = getRecvDataDimension(recvDataLen);
                writef("\r%s data received is ~%s %s (%s B)",
                        fileName, dd.len, dd.dim, recvDataLen);
                sendBlockAck(blockNumber);
                break;

            case OpCode.Error:
                printError(packet);
                return;

            default:
                assert(false);
            }
        }
        scope(exit) file.close();
        scope(success) writeln();
    }
    
    DataDimension getRecvDataDimension(in size_t recvDataLen) {
        static immutable string[] dimensions = [
            "B", "KB", "MB", "GB", "TB",
        ];
        DataDimension r;
        r.len = recvDataLen;
        r.dim = dimensions[0];
        size_t remainder = recvDataLen;
        for (size_t i = 1; (remainder /= 1024) != 0; ++i) {
            r.len = remainder;
            r.dim = dimensions[i];
        }
        return r;
    }

    bool hasData() const {
        return mHasData;
    }

    void writeDataToFile(in byte[] data) {
        if (data.length > 0) {
            file.rawWrite(data);
            if (data.length == gBlockSize)
                return;
        }
        mHasData = false;
    }

    void sendBlockAck(in ushort blockNumber) {
        const byte[] packet = makeAckPacket(blockNumber);
        sendPacket(packet);
    }

    void sendGetRequest(in string fileName) {
        const byte[] packet = makeGetPacket(fileName);
        sendPacket(packet);
    }

    byte[] makeAckPacket(in ushort blockNumber) nothrow {
        AckPacket packet;
        packet.opCode = OpCode.Acknowledgment;
        packet.blockNumber = blockNumber;
        return packet.serialize(buf);
    }

    byte[] makeGetPacket(in string fileName) {
        GetPutPacket packet;
        packet.opCode = OpCode.ReadRequest;
        packet.mode = Mode.NetAscii;
        packet.fileName = fileName;
        return packet.serialize(buf);
    }
};


class PutRequest : ClientBase {
    private bool mHasNext;

    this(in string host) {
        super(host);
    }

    void opCall(in string fileName) {
        if (!exists(fileName)) {
            writeln("File doesn't exist: ", fileName);
            return;
        }
        file = File(fileName, "r");
        scope(exit) file.close();

        auto progress = Progress(file.size());

        reset();
        sendPutRequest(fileName);
        try {
            mainLoop(progress);
        } catch (TFTPException e) {
            writeln("Error: ", e.msg);
        }
    }

protected:
    override void reset() {
        super.reset();
        mHasNext = true;
    }

private:
    struct Progress {
        immutable size_t lineLen = 20;
        private float mFactor;

        this(in size_t size) {
            mFactor = calcBlockFactor(size);
        }

        void setTo(scope char[] line, in size_t blockNumber) const {
            const size_t end = cast(size_t)(blockNumber * mFactor);
            if (end == 0)
                return;
            line[0 .. end - 1] = '=';
            line[end - 1] = '>';
        }

    private:
        float calcBlockFactor(size_t size) {
            const size_t remainder = (size % gBlockSize) != 0;
            const size_t fileBlocks = size / gBlockSize + remainder;
            return float(lineLen) / float(fileBlocks);
        }
    }

    void mainLoop(in Progress progress) {
        string progressLineTemplate = "\r[%s]";
        char[Progress.lineLen] progressLine = '-';
        ushort currentBlockNumber = 0;

        while (!stopped) {
            byte[] answer = receivePacket();
            OpCode opCode;
            auto buffer = Buffer(answer);
            buffer.pop(opCode);
            byte[] remain = buffer.getRemainder();
            //byte[] remain = opCode.setIntegral(answer);

            switch (opCode) {
            case OpCode.Acknowledgment:
                ushort blockNumber;
                buffer.pop(blockNumber);
                //blockNumber.setIntegral(remain);
                if (blockNumber != currentBlockNumber)
                    continue;

                progress.setTo(progressLine, currentBlockNumber);
                writef(progressLineTemplate, progressLine);
                fflush(stdout);

                ++currentBlockNumber;
                sendNextBlock(currentBlockNumber);
                if (!hasNext())
                    stopped = true;
                break;

            case OpCode.Error:
                printError(remain);
                return;

            default:
                assert(false);
            }
        }
        scope(success) {
            progressLine = '=';
            writefln(progressLineTemplate, progressLine);
        }
    }

    bool hasNext() const nothrow {
        return mHasNext;
    }

    void sendNextBlock(in ushort blockNumber) {
        const byte[] packet = makeDataPacket(blockNumber);
        sendPacket(packet);
        const size_t expectedSize = ODataPacket.opCode.sizeof
                + ODataPacket.blockNumber.sizeof
                + gBlockSize;
        mHasNext = packet.length == expectedSize;
    }

    void sendPutRequest(in string fileName) {
        const byte[] packet = makePutPacket(fileName);
        sendPacket(packet);
    }

    byte[] makeDataPacket(in ushort blockNumber) {
        ODataPacket packet;
        packet.opCode = OpCode.Data;
        packet.blockNumber = blockNumber;
        packet.blocksSource = makeFileReaderFunc();
        return packet.serialize(buf);
    }

    byte[] makePutPacket(in string fileName) {
        GetPutPacket packet;
        packet.opCode = OpCode.WriteRequest;
        packet.mode = Mode.NetAscii;
        packet.fileName = fileName;
        return packet.serialize(buf);
    }

    BlockReader makeFileReaderFunc() nothrow {
        return delegate size_t(scope byte[] buf) {
            const byte[] res = file.rawRead(buf);
            return res.length;
        };
    }
};


union ByteRepr(T) {
    T value;
    void[T.sizeof] bytes;
};

struct Buffer
{
    // this(size_t bufferSize) {
    //     mBuffer = new byte[bufferSize];
    // }

    this(byte[] outerBuffer) nothrow {
        mBuffer = outerBuffer;
        mFree = mBuffer;
    }

    byte[] getRemainder() nothrow {
        return mFree;
    }

    void push(T)(in T integer) nothrow {
        ByteRepr!T temp;
        temp.value = toNetworkByteOrder(integer);
        auto buf = getFreeAndCut(T.sizeof);
        buf[0 .. temp.bytes.length] = cast(byte[])temp.bytes;
    }

    void push(in ubyte value) nothrow {
        auto buf = getFreeAndCut(ubyte.sizeof);
        buf[0] = cast(byte)value;
    }

    void pop(T)(ref T integer) nothrow {
        ByteRepr!T temp;
        temp.bytes = getFreeAndCut(T.sizeof);
        integer = cast(T)toNetworkByteOrder(temp.value);
    }

    size_t popBlock(size_t delegate(byte[]) writeFunc) {
        auto buf = getFreeAndCut(gBlockSize);
        return writeFunc(buf);
    }

    void opAssign(byte[] rhs) {
        mFree = rhs;
    }

protected:
    byte[] getFreeAndCut(size_t length) nothrow {
        auto result = mFree[0 .. length];
        mFree = mFree[length .. $];
        return result;
    }

private:
    byte[] mBuffer;
    byte[] mFree;
}

// static byte[] setIntegral(T)(return scope byte[] buf, in T value) nothrow {
//     ByteRepr!T temp;

//     temp.value = toNetworkByteOrder(value);
//     buf = cast(byte[]) temp.bytes;
//     return buf[T.sizeof .. $];
// }

// static byte[] setIntegral(T)(ref T value, return byte[] buf) nothrow {
//     ByteRepr!T temp;
//     temp.bytes = buf;
//     value = cast(T) toNetworkByteOrder(temp.value);
//     return buf[T.sizeof .. $];
// }

enum ExitCode {
    Success,
    InvalidArgumentsNumber,
    UnknownCommand,
};

int main(string[] args) {
    if (args.length < 4) {
        writefln("\"host\" \"put|get\" \"file name\"");
        return ExitCode.InvalidArgumentsNumber;
    }
    const string host     = args[1];
    const string command  = args[2];
    const string fileName = args[3];
    if (command == "get") {
        auto get = new GetRequest(host);
        get(fileName);
    } else if (command == "put") {
        auto put = new PutRequest(host);
        put(fileName);
    } else {
        writeln("Unknown command: ", command);
        return ExitCode.UnknownCommand;
    }
    return ExitCode.Success;
}
