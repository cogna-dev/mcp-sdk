# MCP MoonBit SDK

<div align="center">

<strong>MoonBit implementation of the Model Context Protocol (MCP)</strong>

[![MIT licensed][mit-badge]][mit-url]
[![MoonBit][moonbit-badge]][moonbit-url]
[![Protocol][protocol-badge]][protocol-url]
[![Specification][spec-badge]][spec-url]
[![Conformance][conformance-badge]][conformance-url]

</div>

<!-- omit in toc -->
## Table of Contents

- [Overview](#overview)
- [Installation](#installation)
- [Quickstart](#quickstart)
- [What is MCP?](#what-is-mcp)
- [Core Concepts](#core-concepts)
  - [Server](#server)
  - [Tools](#tools)
    - [Progress Notifications](#progress-notifications)
    - [Logging from Tools](#logging-from-tools)
    - [Error Results](#error-results)
  - [Resources](#resources)
    - [Static Resources](#static-resources)
    - [Resource Templates](#resource-templates)
  - [Prompts](#prompts)
  - [Sampling](#sampling)
  - [Elicitation](#elicitation)
  - [Content Types](#content-types)
- [Running Your Server](#running-your-server)
  - [Build and Run](#build-and-run)
  - [MCP Inspector](#mcp-inspector)
  - [Claude Code Integration](#claude-code-integration)
- [Conformance Testing](#conformance-testing)
- [MCP Primitives](#mcp-primitives)
- [Server Capabilities](#server-capabilities)
- [Contributing](#contributing)
- [License](#license)

[mit-badge]: https://img.shields.io/badge/license-MIT-blue.svg
[mit-url]: https://github.com/cogna-dev/mcp-sdk/blob/main/LICENSE
[moonbit-badge]: https://img.shields.io/badge/language-MoonBit-blueviolet.svg
[moonbit-url]: https://www.moonbitlang.com
[protocol-badge]: https://img.shields.io/badge/protocol-modelcontextprotocol.io-blue.svg
[protocol-url]: https://modelcontextprotocol.io
[spec-badge]: https://img.shields.io/badge/spec-2025--11--25-blue.svg
[spec-url]: https://modelcontextprotocol.io/specification/latest
[conformance-badge]: https://img.shields.io/badge/conformance-39%2F39-brightgreen.svg
[conformance-url]: #conformance-testing

## Overview

The Model Context Protocol allows applications to provide context for LLMs in a standardized way, separating the concerns of providing context from the actual LLM interaction. This MoonBit SDK implements the full MCP specification, making it easy to:

- Create MCP servers that expose resources, prompts, and tools
- Use the Streamable HTTP transport with Server-Sent Events (SSE)
- Handle all MCP protocol messages and lifecycle events
- Leverage MoonBit's native compilation target for high-performance servers

## Installation

### Prerequisites

- [MoonBit toolchain](https://www.moonbitlang.com/download/) (`moon` CLI)

### Adding the SDK to your project

Add the `cogna-dev/mcp-sdk` package to your `moon.mod.json`:

```json
{
  "name": "your-org/your-server",
  "version": "0.1.0",
  "deps": {
    "cogna-dev/mcp-sdk": "0.1.0",
    "moonbitlang/async": "0.18.0"
  }
}
```

Then install dependencies:

```bash
moon install
```

### Package imports

In your `moon.pkg.json`, import the packages you need:

```json
{
  "import": [
    "cogna-dev/mcp-sdk/mcp/server",
    "cogna-dev/mcp-sdk/mcp/types"
  ]
}
```

## Quickstart

Let's create a simple MCP server that exposes a greeting tool, a resource, and a prompt:

```moonbit
fn main {
  let server = @server.McpServer::new("my-server", "1.0.0")

  // Add a tool
  server.add_tool(
    {
      name: "greet",
      description: Some("Generate a greeting"),
      input_schema: {
        type_: "object",
        properties: Some(Json::object({
          "name": Json::object({
            "type": Json::string("string"),
            "description": Json::string("Name to greet"),
          }),
        })),
        required: ["name"],
      },
    },
    @server.ToolHandler(async fn(args, _notify, _req) {
      let name = match args {
        Some(Json::Object(p)) => match p.get("name") {
          Some(Json::String(s)) => s
          _ => "World"
        }
        _ => "World"
      }
      @types.ToolResult::ok(
        [@types.ContentBlock::Text({ text: "Hello, \{name}!" })],
      )
    }),
  )

  // Add a resource
  server.add_resource(
    {
      uri: "config://settings",
      name: "App Settings",
      description: Some("Application configuration"),
      mime_type: Some("application/json"),
    },
    @server.ResourceHandler(async fn(_uri) {
      {
        uri: "config://settings",
        mime_type: Some("application/json"),
        text: Some("{\"theme\":\"dark\",\"language\":\"en\"}"),
        blob: None,
      }
    }),
  )

  // Add a prompt
  server.add_prompt(
    {
      name: "review_code",
      description: Some("Ask the LLM to review code"),
      arguments: [{ name: "code", description: Some("Code to review"), required: true }],
    },
    @server.PromptHandler(async fn(args) {
      let code = args.get("code").or("// paste your code here")
      {
        description: None,
        messages: [{
          role: @types.Role::User,
          content: @types.PromptContent::Text({
            text: "Please review this code:\n\n\{code}",
          }),
        }],
      }
    }),
  )

  println("Server listening on http://localhost:3000/mcp")
  try {
    server.serve(3000)
  } catch {
    e => println("Server error: \{e}")
  }
}
```

Build and run:

```bash
moon build --target native
./_build/native/debug/build/my-server/my-server.exe
```

Test it with the MCP Inspector:

```bash
npx -y @modelcontextprotocol/inspector
```

Connect to `http://localhost:3000/mcp` in the inspector UI.

## What is MCP?

The [Model Context Protocol (MCP)](https://modelcontextprotocol.io) lets you build servers that expose data and functionality to LLM applications in a secure, standardized way. Think of it like a web API designed specifically for LLM interactions. MCP servers can:

- Expose data through **Resources** (similar to GET endpoints — load information into the LLM's context)
- Provide functionality through **Tools** (similar to POST endpoints — execute code or produce side effects)
- Define interaction patterns through **Prompts** (reusable templates for LLM interactions)
- Send **Notifications** (stream progress and log updates to clients in real time)
- Make **Server-initiated Requests** (ask the client to perform sampling or elicitation)

## Core Concepts

### Server

`McpServer` is your entry point to the MCP protocol. It manages HTTP sessions, protocol negotiation, message routing, and SSE streaming:

```moonbit
// Minimal server with default capabilities
let server = @server.McpServer::new("my-server", "1.0.0")

// Server with explicit capabilities
let server = @server.McpServer::new(
  "my-server",
  "1.0.0",
  capabilities~={
    tools: true,
    resources: true,
    resources_subscribe: true,
    prompts: true,
    logging: true,
    completions: false,
  },
)
```

### Tools

Tools let LLMs take actions through your server. Unlike resources, tools are expected to perform computation and may have side effects.

The `ToolHandler` receives three arguments:
- `args: Json?` — the tool's input arguments (already validated against `input_schema`)
- `notify: NotifySender` — send SSE notifications (progress, logs) mid-execution
- `req: ServerRequester` — make server-initiated requests to the client (sampling, elicitation)

```moonbit
server.add_tool(
  {
    name: "add",
    description: Some("Add two numbers"),
    input_schema: {
      type_: "object",
      properties: Some(Json::object({
        "a": Json::object({ "type": Json::string("number") }),
        "b": Json::object({ "type": Json::string("number") }),
      })),
      required: ["a", "b"],
    },
  },
  @server.ToolHandler(async fn(args, _notify, _req) {
    let (a, b) = match args {
      Some(Json::Object(p)) => (
        match p.get("a") { Some(Json::Number(n, ..)) => n | _ => 0.0 },
        match p.get("b") { Some(Json::Number(n, ..)) => n | _ => 0.0 },
      )
      _ => (0.0, 0.0)
    }
    @types.ToolResult::ok(
      [@types.ContentBlock::Text({ text: (a + b).to_string() })],
    )
  }),
)
```

For a tool with no parameters, use `ToolInputSchema::empty()`:

```moonbit
server.add_tool(
  {
    name: "ping",
    description: Some("Check if the server is alive"),
    input_schema: @types.ToolInputSchema::empty(),
  },
  @server.ToolHandler(async fn(_args, _notify, _req) {
    @types.ToolResult::ok([@types.ContentBlock::Text({ text: "pong" })])
  }),
)
```

#### Progress Notifications

Tools can stream real-time progress updates to the client. The `_meta.progressToken` from the request is automatically merged into `args`:

```moonbit
server.add_tool(
  {
    name: "long_task",
    description: Some("A long-running task with progress"),
    input_schema: @types.ToolInputSchema::empty(),
  },
  @server.ToolHandler(async fn(args, notify, _req) {
    let @server.NotifySender(send) = notify

    // Extract progressToken (merged from _meta by the framework)
    let token : Json = match args {
      Some(Json::Object(p)) => match p.get("_meta") {
        Some(Json::Object(m)) => match m.get("progressToken") {
          Some(t) => t
          None => Json::number(0.0)
        }
        _ => Json::number(0.0)
      }
      _ => Json::number(0.0)
    }

    // Send progress notifications
    send(Json::object({
      "jsonrpc": Json::string("2.0"),
      "method": Json::string("notifications/progress"),
      "params": Json::object({
        "progressToken": token,
        "progress": Json::number(0.0),
        "total": Json::number(100.0),
        "message": Json::string("Starting..."),
      }),
    }))

    // ... do work ...

    send(Json::object({
      "jsonrpc": Json::string("2.0"),
      "method": Json::string("notifications/progress"),
      "params": Json::object({
        "progressToken": token,
        "progress": Json::number(100.0),
        "total": Json::number(100.0),
        "message": Json::string("Done"),
      }),
    }))

    @types.ToolResult::ok([@types.ContentBlock::Text({ text: "complete" })])
  }),
)
```

#### Logging from Tools

Send structured log messages to the client during tool execution:

```moonbit
@server.ToolHandler(async fn(_args, notify, _req) {
  let @server.NotifySender(send) = notify

  send(Json::object({
    "jsonrpc": Json::string("2.0"),
    "method": Json::string("notifications/message"),
    "params": Json::object({
      "level": Json::string("info"),
      "logger": Json::string("my-tool"),
      "data": Json::string("Processing started"),
    }),
  }))

  @types.ToolResult::ok([@types.ContentBlock::Text({ text: "done" })])
})
```

Available log levels: `debug`, `info`, `notice`, `warning`, `error`, `critical`, `alert`, `emergency`.

#### Error Results

Return a structured error result (not a protocol error):

```moonbit
@server.ToolHandler(async fn(_args, _notify, _req) {
  @types.ToolResult::error("Something went wrong: file not found")
})
```

### Resources

Resources expose data to LLMs. They're similar to GET endpoints — they provide data without significant computation or side effects.

#### Static Resources

```moonbit
server.add_resource(
  {
    uri: "docs://readme",
    name: "README",
    description: Some("Project documentation"),
    mime_type: Some("text/markdown"),
  },
  @server.ResourceHandler(async fn(_uri) {
    {
      uri: "docs://readme",
      mime_type: Some("text/markdown"),
      text: Some("# My Project\n\nWelcome to the documentation."),
      blob: None,
    }
  }),
)
```

For binary content, use `blob` (base64-encoded) instead of `text`:

```moonbit
@server.ResourceHandler(async fn(_uri) {
  {
    uri: "assets://logo.png",
    mime_type: Some("image/png"),
    text: None,
    blob: Some(base64_encoded_png_data),
  }
})
```

#### Resource Templates

Resource templates use URI templates (RFC 6570 simple variables) to serve parameterized resources:

```moonbit
server.add_resource_template_with_handler(
  {
    uri_template: "users://{id}/profile",
    name: "User Profile",
    description: Some("Fetch a user's profile by ID"),
    mime_type: Some("application/json"),
  },
  @server.ResourceHandler(async fn(uri) {
    // Extract 'id' from the resolved URI
    let id = extract_id_from_uri(uri)
    {
      uri,
      mime_type: Some("application/json"),
      text: Some("{\"id\":\"\{id}\",\"name\":\"User \{id}\"}"),
      blob: None,
    }
  }),
)
```

If you only want to advertise a template without a handler (letting clients resolve it themselves), use `add_resource_template`:

```moonbit
server.add_resource_template({
  uri_template: "logs://{date}",
  name: "Daily Logs",
  description: Some("Access logs for a given date (YYYY-MM-DD)"),
  mime_type: Some("text/plain"),
})
```

### Prompts

Prompts are reusable message templates that help LLMs interact with your server effectively. They appear in the client's prompt picker.

```moonbit
server.add_prompt(
  {
    name: "summarize",
    description: Some("Summarize a piece of text"),
    arguments: [
      { name: "text", description: Some("Text to summarize"), required: true },
      { name: "style", description: Some("Summary style: brief or detailed"), required: false },
    ],
  },
  @server.PromptHandler(async fn(args) {
    let text = args.get("text").or("")
    let style = args.get("style").or("brief")
    {
      description: Some("Summarization prompt"),
      messages: [
        {
          role: @types.Role::User,
          content: @types.PromptContent::Text({
            text: "Please write a \{style} summary of the following text:\n\n\{text}",
          }),
        },
      ],
    }
  }),
)
```

Prompts can include multi-turn conversations and image content:

```moonbit
@server.PromptHandler(async fn(_args) {
  {
    description: None,
    messages: [
      {
        role: @types.Role::User,
        content: @types.PromptContent::Image({ data: image_base64, mime_type: "image/png" }),
      },
      {
        role: @types.Role::User,
        content: @types.PromptContent::Text({ text: "Describe what you see in this image." }),
      },
    ],
  }
})
```

### Sampling

Tools can request the client to perform LLM inference on their behalf (sampling). This requires the client to declare `sampling: true` capability during initialization.

```moonbit
@server.ToolHandler(async fn(args, _notify, req) {
  let prompt = match args {
    Some(Json::Object(p)) => match p.get("prompt") {
      Some(Json::String(s)) => s
      _ => "Hello"
    }
    _ => "Hello"
  }

  let @server.ServerRequester(request) = req
  let result = try {
    request("sampling/createMessage", Json::object({
      "messages": Json::array([
        Json::object({
          "role": Json::string("user"),
          "content": Json::object({
            "type": Json::string("text"),
            "text": Json::string(prompt),
          }),
        }),
      ]),
      "maxTokens": Json::number(100.0),
    }))
  } catch {
    _ => return @types.ToolResult::error("Sampling not supported by this client")
  }

  let response_text = match result {
    Json::Object(r) => match r.get("content") {
      Some(Json::Object(c)) => match c.get("text") {
        Some(Json::String(s)) => s
        _ => "(no text)"
      }
      _ => "(no content)"
    }
    _ => "(unexpected result)"
  }

  @types.ToolResult::ok([@types.ContentBlock::Text({ text: response_text })])
})
```

### Elicitation

Tools can request additional structured input from the user mid-execution. This requires the client to declare `elicitation: true` capability.

```moonbit
@server.ToolHandler(async fn(_args, _notify, req) {
  let @server.ServerRequester(request) = req
  let result = try {
    request("elicitation/create", Json::object({
      "message": Json::string("Please confirm the operation"),
      "requestedSchema": Json::object({
        "type": Json::string("object"),
        "properties": Json::object({
          "confirmed": Json::object({
            "type": Json::string("boolean"),
            "description": Json::string("Confirm the operation"),
          }),
        }),
      }),
    }))
  } catch {
    _ => return @types.ToolResult::error("Elicitation not supported by this client")
  }

  let action = match result {
    Json::Object(r) => match r.get("action") {
      Some(Json::String(s)) => s
      _ => "cancel"
    }
    _ => "cancel"
  }

  @types.ToolResult::ok([@types.ContentBlock::Text({ text: "User action: \{action}" })])
})
```

### Content Types

`ContentBlock` supports four content types that tools and prompts can return:

```moonbit
// Plain text
@types.ContentBlock::Text({ text: "Hello, world!" })

// Image (base64-encoded)
@types.ContentBlock::Image({ data: base64_png, mime_type: "image/png" })

// Audio (base64-encoded)
@types.ContentBlock::Audio({ data: base64_wav, mime_type: "audio/wav" })

// Embedded resource reference
@types.ContentBlock::Resource({
  uri: "docs://readme",
  mime_type: Some("text/plain"),
  text: Some("Inline content"),
  blob: None,
})
```

Tools can return multiple content blocks in a single response:

```moonbit
@types.ToolResult::ok([
  @types.ContentBlock::Text({ text: "Here is the chart:" }),
  @types.ContentBlock::Image({ data: chart_png, mime_type: "image/png" }),
  @types.ContentBlock::Text({ text: "And the raw data:" }),
  @types.ContentBlock::Resource({
    uri: "data://chart.json",
    mime_type: Some("application/json"),
    text: Some(json_data),
    blob: None,
  }),
])
```

## Running Your Server

### Build and Run

```bash
# Build for the native target
moon build --target native

# Run the server
./_build/native/debug/build/<package-name>/<binary-name>.exe

# The MCP endpoint is at:
# http://localhost:<port>/mcp
```

For a release build:

```bash
moon build --target native --release
```

### MCP Inspector

The [MCP Inspector](https://github.com/modelcontextprotocol/inspector) is the fastest way to test your server interactively:

```bash
# Start your server first
./_build/native/debug/build/my-server/my-server.exe

# In another terminal, start the inspector
npx -y @modelcontextprotocol/inspector
```

Open the inspector UI and connect to `http://localhost:3000/mcp`.

### Claude Code Integration

Once your server is running, add it to [Claude Code](https://docs.claude.com/en/docs/claude-code/mcp):

```bash
claude mcp add --transport http my-server http://localhost:3000/mcp
```

## Conformance Testing

This SDK passes all **39/39** tests in the [MCP conformance test suite](https://github.com/modelcontextprotocol/conformance):

```bash
# Start the conformance test server (built from examples/server)
./_build/native/debug/build/examples/server/server.exe

# In another terminal, run the conformance tests
no_proxy="localhost,127.0.0.1" \
NO_PROXY="localhost,127.0.0.1" \
npx @modelcontextprotocol/conformance server --url http://localhost:3000/mcp
```

> **Note**: The `no_proxy` / `NO_PROXY` variables are needed if your environment uses an HTTP proxy. They ensure the test tool connects directly to `localhost`.

Expected output:
```
39 passing
```

The conformance test server source is at [`examples/server/main.mbt`](examples/server/main.mbt). It demonstrates every supported protocol feature: all content types, logging, progress, resource templates, prompts, sampling, elicitation, and DNS rebinding protection.

See [CONTRIBUTING.md](CONTRIBUTING.md) for detailed build and test instructions.

## MCP Primitives

The MCP protocol defines three core primitives that servers implement:

| Primitive   | Control                 | Description                                        | Example Use                  |
|-------------|-------------------------|----------------------------------------------------|------------------------------|
| Prompts     | User-controlled         | Interactive templates invoked by user choice       | Slash commands, menu options |
| Resources   | Application-controlled  | Contextual data managed by the client application  | File contents, API responses |
| Tools       | Model-controlled        | Functions exposed to the LLM to take actions       | API calls, data updates      |

## Server Capabilities

`McpServer` declares capabilities during the MCP initialization handshake. Clients use these to know what features they can use:

| Capability            | Description                                               |
|-----------------------|-----------------------------------------------------------|
| `tools`               | Server exposes callable tools                             |
| `resources`           | Server exposes readable resources                         |
| `resources_subscribe` | Clients can subscribe to resource change notifications    |
| `prompts`             | Server exposes prompt templates                           |
| `logging`             | Server sends log notifications via SSE                    |
| `completions`         | Server provides argument completion suggestions           |

All capabilities are enabled by default when you call `McpServer::new`. Pass an explicit `capabilities~` struct to opt out of specific features.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for how to set up the development environment, build the SDK, and run the conformance test suite.

## License

This project is licensed under the MIT License — see the [LICENSE](LICENSE) file for details.
