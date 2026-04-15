# Contributing to mcp-moonbit-sdk

Thank you for your interest in contributing. This guide covers how to build the SDK, run the example server, and validate correctness against the official MCP conformance suite.

---

## Prerequisites

| Tool | Minimum version | Install |
|------|-----------------|---------|
| MoonBit toolchain | 0.1.20260409 | [moonbitlang.com/download](https://www.moonbitlang.com/download/) |
| Node.js | 18 | [nodejs.org](https://nodejs.org/) |
| npx | bundled with Node.js | — |

Verify your setup:

```sh
moon version      # e.g. v0.1.20260409 (native)
node --version    # e.g. v20.x.x
```

---

## Repository layout

```
mcp-sdk/
├── mcp/
│   ├── types/      # MCP + JSON-RPC type definitions (cogna-dev/mcp-sdk/mcp/types)
│   └── server/     # Streamable HTTP transport + request dispatcher (cogna-dev/mcp-sdk/mcp/server)
├── examples/
│   └── server/     # "Everything server" that exercises every MCP feature
└── moon.mod.json
```

---

## Building

### Install dependencies

```sh
moon install
```

This fetches `moonbitlang/async@0.18.0` (the HTTP / socket runtime) into `.mooncakes/`.

### Type-check (fast feedback loop)

```sh
moon check
```

Errors are reported immediately; no binary is produced.

### Build the native binary

```sh
moon build --target native
```

The conformance server binary is written to:

```
_build/native/debug/build/examples/server/server.exe
```

---

## Running the example server

```sh
./_build/native/debug/build/examples/server/server.exe
```

Expected output:

```
MCP Conformance Test Server running on http://localhost:3000
  - MCP endpoint: http://localhost:3000/mcp
```

The server listens on **port 3000** and implements:

- All core MCP methods (`initialize`, `ping`, `tools/*`, `resources/*`, `prompts/*`, `logging/*`, `completion/complete`)
- Streamable HTTP transport (POST / GET / DELETE `/mcp`)
- Server-sent events (SSE) for push notifications, progress, and server-initiated requests (sampling / elicitation)
- DNS rebinding protection (rejects non-localhost `Host` / `Origin` headers)

---

## Validating with the MCP conformance suite

The conformance suite is the authoritative way to verify that the SDK meets the MCP protocol specification.

### One-shot run (recommended)

Start the server in the background, run all 30 scenarios, then stop the server:

```sh
./_build/native/debug/build/examples/server/server.exe &
SERVER_PID=$!

no_proxy="localhost,127.0.0.1" \
NO_PROXY="localhost,127.0.0.1" \
npx @modelcontextprotocol/conformance server \
  --url http://localhost:3000/mcp

kill $SERVER_PID
```

> **Proxy note** — If your shell has `http_proxy` / `https_proxy` set, the `no_proxy` overrides above prevent the conformance client from routing `localhost` traffic through your proxy. Omit them if you have no proxy configured.

### Expected result

```
Total: 39 passed, 0 failed
```

### Running a single scenario

Useful when iterating on a specific feature:

```sh
./_build/native/debug/build/examples/server/server.exe &
SERVER_PID=$!

no_proxy="localhost,127.0.0.1" \
NO_PROXY="localhost,127.0.0.1" \
npx @modelcontextprotocol/conformance server \
  --url http://localhost:3000/mcp \
  --scenario tools-call-with-progress \
  --verbose

kill $SERVER_PID
```

Available scenario names are listed in the [conformance suite documentation](https://github.com/modelcontextprotocol/conformance).

---

## Development workflow

1. Edit source files under `mcp/` or `examples/`.
2. Run `moon check` — fix any type errors before building.
3. Run `moon build --target native`.
4. Start the server and run the conformance suite (see above).
5. All 39 tests must pass before a change is considered correct.

### Formatting

```sh
moon fmt
```

Run this before committing. The formatter is deterministic; a clean diff means no style changes were introduced.

### Regenerating public API snapshots

```sh
moon info
```

This updates `*.mbti` files. Commit the updated snapshots alongside any public API changes.

---

## Code style notes

- Every top-level declaration must be preceded by `///|` on its own line.
- Use `let mut` only for variables that are reassigned; mutating map/array entries does not require `mut`.
- Error types are declared with `suberror`, not `error`.
- Avoid `as Any`, `@ts-ignore`, or equivalent escape hatches — fix the types instead.
- `method` is a reserved keyword in MoonBit; use `mthd` for struct fields that hold a method name.

---

## Submitting changes

1. Fork the repository and create a branch from `main`.
2. Make your changes, ensuring `moon check` is clean and all 39 conformance tests pass.
3. Open a pull request with a clear description of what was changed and why.
