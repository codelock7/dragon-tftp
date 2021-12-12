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
    File* blocksSource;
}

struct ErrorPacket {
    OpCode opCode;
    ushort errorCode;
    string errorMessage;
};

static byte[] serializeTo(in ubyte value, scope byte[] buf) nothrow {
    buf[0] = cast(byte) value;
    return buf[1 .. $];
}

static byte[] serializeTo(in ushort value, scope byte[] buf) nothrow {
    return buf.setIntegral(value);
}

static byte[] serializeTo(in string value, scope byte[] buf) nothrow {
    if (!value.length)
        return buf;
    buf[0 .. value.length] = cast(byte[])value;
    buf[value.length] = 0;
    return buf[value.length + 1 .. $];
}

static byte[] serializeTo(in Mode mode, scope byte[] buf) nothrow {
    return toString(mode).serializeTo(buf);
}

static byte[] serializeTo(scope File* file, scope byte[] buf) {
    byte[] r = (*file).rawRead(buf[0 .. 512]);
    return buf[r.length .. $];
}

static byte[] serialize(T)(ref T value, scope byte[] buf) {
    byte[] it = buf;
    foreach (item; value.tupleof)
        it = item.serializeTo(it);
    return buf[0 .. buf.length - it.length];
}

class TftpException : Exception {
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
        const ptrdiff_t receivedBytes = sock.receiveFrom(cast(void[])buf, addr);
        if (receivedBytes == Socket.ERROR)
            return null;
        byte[] packet = buf[0 .. receivedBytes];
        return packet;
    }

    void printError(scope byte[] remain) {
        ushort errorCode;
        remain = errorCode.setIntegral(remain);
        auto errorMessage = fromStringz((cast(string)remain).ptr);
        writeln("Error(", errorCode, "): ", errorMessage);
    }

    void sendPacket(in byte[] packet) {
        const ptrdiff_t bytesSent = sock.sendTo(cast(const void[])packet, addr);
        if (bytesSent == Socket.ERROR)
            throw new TftpException("Socket error while sending data");
        if (bytesSent != packet.length)
            throw new TftpException("Packet sent incomplete");
    }
};

class GetRequest : ClientBase {
    private bool mHasNext;
    private size_t mRecvDataSize = 0;
    private char[10] mLine;

    this(const string host) {
        super(host);
    }

    void opCall(in string fileName) {
        reset();
        sendGetRequest(fileName);
        try {
            mainLoop(fileName);
        } catch (TftpException e) {
            writeln("Error: ", e.msg);
        }
    }

protected:
    override void reset() {
        super.reset();
        mHasNext = true;
    }

private:
    void mainLoop(in string fileName) {
        ushort prevBlockNumber = 0;
        while (!stopped) {
            byte[] packet = receivePacket();
            OpCode opCode;
            packet = opCode.setIntegral(packet);
            switch (opCode) {
            case OpCode.Data:
                ushort blockNumber;
                byte[] data = blockNumber.setIntegral(packet);
                if (blockNumber == prevBlockNumber) {
                    continue;
                }
                if (blockNumber == 1) {
                    file = File(fileName, "w");
                }
                prevBlockNumber = blockNumber;
                mRecvDataSize += packet.length;
                writeDataToFile(data);

                DataDimension dd = getRecvDataDimension();
                writef("\r%s data received is ~%s %s (%s B)",
                        fileName, dd.size, dd.dim, mRecvDataSize);

                sendBlockAck(blockNumber);
                if (!hasNext())
                    stopped = true;
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
    
    struct DataDimension {
        size_t size;
        string dim;
    };

    DataDimension getRecvDataDimension() {
        static immutable string[] dimensions = [
            "B", "KB", "MB", "GB", "TB",
        ];

        size_t result = mRecvDataSize;
        size_t remainder = mRecvDataSize;
        size_t i;
        for (i = 0; (remainder /= 1024) > 0; ++i)
            result = remainder;
        DataDimension dim;
        dim.size = result % 1024;
        dim.dim = dimensions[i];
        return dim;
    }

    bool hasNext() const {
        return mHasNext;
    }

    void writeDataToFile(in byte[] data) {
        if (data.length > 0) {
            file.rawWrite(data);
            if (data.length == gBlockSize)
                return;
        }
        mHasNext = false;
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
        } catch (TftpException e) {
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
            byte[] remain = opCode.setIntegral(answer);

            switch (opCode) {
            case OpCode.Acknowledgment:
                ushort blockNumber;
                blockNumber.setIntegral(remain);
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
        packet.blocksSource = &file;
        return packet.serialize(buf);
    }

    byte[] makePutPacket(in string fileName) {
        GetPutPacket packet;
        packet.opCode = OpCode.WriteRequest;
        packet.mode = Mode.NetAscii;
        packet.fileName = fileName;
        return packet.serialize(buf);
    }
};


union ByteRepr(T) {
    T value;
    void[T.sizeof] bytes;
};

static byte[] setIntegral(T)(scope byte[] buf, in T value) nothrow {
    static assert(isIntegral!T);
    ByteRepr!T br;
    static if (T.sizeof == ushort.sizeof)
        br.value = htons(value);
    else
        static assert(false);
    buf[0 .. br.bytes.length] = cast(byte[])br.bytes;
    return buf[T.sizeof .. $];
}

static byte[] setIntegral(T)(ref T value, byte[] buf) nothrow {
    static assert(isIntegral!T);
    ByteRepr!T br;
    br.bytes = buf[0 .. T.sizeof];
    static if (T.sizeof == ushort.sizeof)
        value = cast(T)htons(br.value);
    else
        static assert(false);
    return buf[T.sizeof .. $];
}

enum ExitCode {
    Success,
    InvalidArgumentsNumber,
    UnknownCommand,
};

int main(immutable string[] args) {
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
