# Zig TFTP Server

A robust, threaded Trivial File Transfer Protocol (TFTP) server implementation (RFC 1350) written from scratch in Zig.

This project serves as a practical introduction to **Systems Programming** and **Zig**, demonstrating how to build low-level network services that are safe, performant, and understandable.

## Getting Started

### Prerequisites
You need the [Zig Compiler](https://ziglang.org/download/) (version 0.11.0 or later).

### Running the Server
The server defaults to port **6969** to avoid needing root privileges.

```bash
# Compile and run in one step
zig build run
```

### Testing with a Client
You can use any standard TFTP client (usually pre-installed on macOS/Linux).

Open a new terminal:
```bash
# Create a test file to download
echo "Hello Zig Systems Programming!" > test.txt

# Connect to the server
tftp 127.0.0.1 6969

# Set mode to binary (octet) and download
tftp> binary
tftp> get test.txt
tftp> quit
```

To upload files, ensure the server has write permissions in its running directory.

### Running Tests
This project follows **Test-Driven Development (TDD)**. You can run the comprehensive test suite which checks packet parsing, transfer logic, and server integration.

```bash
zig build test
```

---

## Why Zig for Systems Programming?

We chose Zig for this project because it strikes a perfect balance between control and safety, making it ideal for network protocols.

### 1. Explicit Memory Management

In C/C++, memory leaks are common. In Rust, the borrow checker can be steep to learn.
**Zig** takes a middle ground: You must pass an `Allocator` to any function that needs memory.
*   **Concept:** This makes it obvious *where* and *when* memory is allocated.
*   **In this project:** See `src/main.zig` where we create a `GeneralPurposeAllocator` and pass it to the server. If we leak memory, Zig detects it automatically at shutdown!

### 2. Binary Layout Control

Network protocols define exact byte structures (headers, opcodes).
**Zig** allows us to define `extern structs` and `packed structs` that map 1:1 to the bytes on the wire.
*   **Concept:** Zero-overhead parsing. We "cast" bytes to a struct safely.
*   **In this project:** See `src/root.zig` where we define the packet format.

### 3. Native Endian Handling

Computers store numbers differently (Little Endian vs Big Endian). Network protocols usually use Big Endian.
**Zig** forces us to be explicit.
*   **Concept:** Preventing bugs where a number `1` (0x0001) is interpreted as `256` (0x0100).
*   **In this project:** We use `std.mem.readInt(u16, buffer, .big)` to ensure data is correct on any CPU architecture.

### 4. "No Hidden Control Flow"

Zig has no exceptions and no hidden memory allocations.
*   **Concept:** When you read the code, you know exactly what it does. `try` simply means "check for error and return it if present".
*   **In this project:** The error handling path for a failed file download is just as visible as the success path.

---

## Project Structure

| File | Purpose | Systems Concepts |
| :--- | :--- | :--- |
| **`src/main.zig`** | Entry point. Configures allocator and starts server. | Dependency Injection, Allocators |
| **`src/server.zig`** | Main UDP server loop. Spawns threads for clients. | UDP Sockets, Concurrency (Threads), Ephemeral Ports |
| **`src/root.zig`** | Packet definitions (RRQ, WRQ, ACK, DATA). | Binary Serialization, Endianness, Enums |
| **`src/transfer.zig`** | State machines for reading/writing files. | State Machines, File I/O, Flow Control |

## Key Concepts Explained

### The Protocol (RFC 1350)

TFTP is simple. It uses **UDP** (User Datagram Protocol), which is unreliable.
1.  **RRQ (Read Request):** Client asks for a file.
2.  **DATA:** Server sends 512 bytes.
3.  **ACK:** Client confirms receipt.
4.  **Repeat** until a packet < 512 bytes is sent.

### Concurrency Model

The server listens on port 6969. When a request comes in:
1.  It spawns a **new thread**.
2.  It opens a **new socket** on a random port (Ephemeral Port).
3.  All future communication for that file happens on the new socket.
This allows the main server to keep listening for new clients while transfers happen in parallel.

### Error Handling

We use Zig's `union(enum)` to represent packets. This is a **Sum Type**.
It means a Packet can be *either* an RRQ, *or* a DATA, *or* an ERROR. Zig ensures we handle the specific case we are in, preventing "undefined behavior".
