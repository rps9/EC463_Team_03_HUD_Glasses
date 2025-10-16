# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a Python-based chat application implementing a client-server architecture using raw TCP sockets. The application consists of two main components:

- **server.py**: Multi-threaded TCP server that handles multiple client connections and message broadcasting
- **client.py**: TCP client that connects to the server and provides a chat interface

## Architecture

### Server Architecture (server.py)
- Uses threading to handle multiple clients concurrently
- Maintains an `active_clients` list to track connected users
- Implements message broadcasting to all connected clients
- Custom message protocol: `username`*%n`message` format for client identification

### Client Architecture (client.py)
- Dual-threaded design: one thread for listening to server messages, another for sending user input
- Uses Rich library for enhanced console output with colors and formatting
- Handles connection establishment and username registration

## Common Development Tasks

### Running the Application
```bash
# Start the server first
python server.py

# Then start one or more clients
python client.py
```

### Dependencies
The project requires the `rich` library for enhanced console output:
```bash
pip install rich
```

## Key Implementation Details

- **Network Configuration**: Uses localhost (127.0.0.1) on port 1234
- **Message Protocol**: Custom delimiter `*%n` separates username from message content
- **Concurrency**: Both server and client use Python threading for concurrent operations
- **Error Handling**: Basic try-catch blocks for connection errors
- **Buffer Size**: 2048 bytes for socket message receiving

## Code Patterns

- Console output uses Rich library formatting (e.g., `[green]text[/green]`)
- Socket operations use UTF-8 encoding/decoding
- Threading pattern: main thread handles user input, background thread handles network I/O
- Server maintains client state in tuples: `(username, socket)`