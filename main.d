import std.string;
import std.string: fromStringz;
import std.socket;
import std.stdio: File, writefln, writeln, write, chunks;
import std.digest: toHexString, Order;
import std.traits: isIntegral;


extern(C)
{
    ushort htons(ushort);
}

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

string toString(Mode mode) {
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

static byte[] serializeTo(in ubyte value, scope byte[] buf) {
    buf[0] = cast(byte) value;
    return buf[1 .. $];
}

static byte[] serializeTo(in ushort value, scope byte[] buf) {
    value.setToBuf(buf);
    return buf[2 .. $];
}

static byte[] serializeTo(in string value, scope byte[] buf) {
    if (!value.length)
        return buf;
    writeln("char[] size ", value.length);
    buf[0 .. value.length] = cast(byte[])value;
    buf[value.length] = 0;
    return buf[value.length + 1 .. $];
}

static byte[] serializeTo(in Mode mode, scope byte[] buf) {
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

class TFtpBase {
protected:
    Socket sock;
    Address addr;
    byte[] buf;
    File file;
    size_t blockSize;
    bool stopped = false;

    this(in string host) {
        sock = new UdpSocket();
        addr = new InternetAddress(host, 69);
        blockSize = 512;
        buf = new byte[blockSize + 1024];
    }

    byte[] receivePacket() {
        const ptrdiff_t receivedBytes = sock.receiveFrom(cast(void[])buf, addr);
        writeln("Receive bytes: ", receivedBytes);
        if (receivedBytes == Socket.ERROR) {
            writeln("RECV ERROR");
            return null;
        }
        byte[] packet = buf[0 .. receivedBytes];
        writeln(toHexString(cast(const ubyte[])packet));
        return packet;
    }

    void printError(scope byte[] remain) {
        ushort errorCode;
        remain = errorCode.setFromBuf(remain);
        auto errorMessage = fromStringz((cast(string)remain).ptr);
        writeln("Error(", errorCode, "): ", errorMessage);
    }
};

class GetCommand : TFtpBase {
    this(const string host) {
        super(host);
    }

    void opCall(in string fileName) {
        if (!sendGetRequest(fileName)) {
            writeln("Failed to get file");
            return;
        }

        ushort prevBlockNumber = 0;
        while (true) {
            byte[] packet = receivePacket();
            OpCode opCode;
            packet = opCode.setFromBuf(packet);
            switch (opCode) {
            case OpCode.Data:
                ushort blockNumber;
                byte[] block = blockNumber.setFromBuf(packet);
                writeln("Block Number ", blockNumber);
                if (blockNumber == prevBlockNumber) {
                    writeln("Skip block: ", blockNumber);
                    continue;
                }
                prevBlockNumber = blockNumber;
                if (blockNumber == 1) {
                    file = File(fileName, "w");
                }
                if (block.length == 0) {
                    return;
                }
                file.write(cast(const char[])block);
                if (block.length < blockSize) {
                    return;
                }
                sendBlockConfirmation(blockNumber);
                break;

            case OpCode.Error:
                printError(packet);
                return;

            default:
                assert(false);
            }
        }
        scope(exit) file.close();
    }

private:
    void sendBlockConfirmation(in ushort blockNumber) {
        const byte[] packet = makeAckPacket(blockNumber);
        sock.sendTo(cast(const void[])packet, addr);
    }

    bool sendGetRequest(in string fileName) {
        const byte[] packet = makeGetPacket(fileName);
        const ptrdiff_t bytesSent = sock.sendTo(cast(const void[])packet, addr);
        if (bytesSent == Socket.ERROR) {
            writeln("GET ERROR");
            return false;
        }
        return true;
    }

    byte[] makeAckPacket(in ushort blockNumber) {
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


class PutCommand : TFtpBase {
    this(in string host) {
        super(host);
    }

    void opCall(in string fileName) {
        file = File(fileName, "r");
        scope(exit) file.close();

        if (!sendPutRequest(fileName)) {
            writeln("Failed to get file");
            return;
        }
        ushort currentBlockNumber = 0;
        while (!stopped) {
            byte[] answer = receivePacket();
            OpCode opCode;
            byte[] remain = opCode.setFromBuf(answer);

            switch (opCode) {
            case OpCode.Acknowledgment:
                ushort blockNumber;
                blockNumber.setFromBuf(remain);
                if (blockNumber != currentBlockNumber) {
                    continue;
                }
                ++currentBlockNumber;
                if (!sendNextBlock(currentBlockNumber)) {
                    return;
                }
                break;

            case OpCode.Error:
                printError(remain);
                return;

            default:
                assert(false);
            }
        }
    }

private:
    byte[] makeDataPacket(in ushort blockNumber) {
        ODataPacket packet;
        packet.opCode = OpCode.Data;
        packet.blockNumber = blockNumber;
        packet.blocksSource = &file;
        return packet.serialize(buf);
    }

    bool sendNextBlock(in ushort blockNumber) {
        const byte[] packet = makeDataPacket(blockNumber);
        const size_t bytesSent = sock.sendTo(cast(const void[])packet, addr);
        if (bytesSent != packet.length) {
            return false;
        }
        if (bytesSent < blockSize + 4) {
            return false;
        }
        return true;
    }

    bool sendPutRequest(in string fileName) {
        const byte[] packet = makePutPacket(fileName);
        const ptrdiff_t bytesSent = sock.sendTo(cast(const void[])packet, addr);
        writeln("Sent ", bytesSent);
        if (bytesSent == Socket.ERROR) {
            writeln("GET ERROR");
            return false;
        }
        return true;
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

static byte[] setToBuf(T)(in T value, scope byte[] buf) {
    static assert(isIntegral!T);
    ByteRepr!T br;
    static if (T.sizeof == ushort.sizeof)
        br.value = htons(value);
    else
        static assert(false);
    buf[0 .. br.bytes.length] = cast(byte[])br.bytes;
    return buf[T.sizeof .. $];
}

static byte[] setFromBuf(T)(ref T value, byte[] buf) {
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
    const string host = args[1];
    const string command = args[2];
    const string fileName = args[3];
    if (command == "get") {
        GetCommand get = new GetCommand(host);
        get(fileName);
    } else if (command == "put") {
        PutCommand put = new PutCommand(host);
        put(fileName);
    } else {
        writeln("Unknown command: ", command);
        return ExitCode.UnknownCommand;
    }
    return ExitCode.Success;
}
