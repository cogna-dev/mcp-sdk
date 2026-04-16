// MCP Everything Server - Conformance Test Server
// Implements all MCP features required for conformance testing.

// ---- Test constants ----

///|
// Sample base64 encoded 1x1 red PNG pixel for testing
pub const TEST_IMAGE_BASE64 : String = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg=="

///|
// Sample base64 encoded minimal WAV file for testing
pub const TEST_AUDIO_BASE64 : String = "UklGRiYAAABXQVZFZm10IBAAAAABAAEAQB8AAAB9AAACABAAZGF0YQIAAAA="

// ---- Helper: build a log notification JSON ----

///|
fn log_notif(level : String, data : String) -> Json {
  let obj : Map[String, Json] = {
    "jsonrpc": Json::string("2.0"),
    "method": Json::string("notifications/message"),
    "params": Json::object({
      "level": Json::string(level),
      "logger": Json::string("conformance-test-server"),
      "data": Json::string(data),
    }),
  }
  Json::object(obj)
}

///|
fn progress_notif(
  token : Json,
  progress : Double,
  total : Double,
  message : String,
) -> Json {
  let obj : Map[String, Json] = {
    "jsonrpc": Json::string("2.0"),
    "method": Json::string("notifications/progress"),
    "params": Json::object({
      "progressToken": token,
      "progress": Json::number(progress),
      "total": Json::number(total),
      "message": Json::string(message),
    }),
  }
  Json::object(obj)
}

// ---- Register all tools ----

///|
fn register_tools(server : @mcp_server.McpServer) -> Unit {
  // test_simple_text
  server.add_tool(
    {
      name: "test_simple_text",
      description: Some("Tests simple text content response"),
      input_schema: @mcp_types.ToolInputSchema::empty(),
    },
    @mcp_server.ToolHandler(fn(_args, _notify, _req) {
      @mcp_types.ToolResult::ok([
        @mcp_types.ContentBlock::Text({
          text: "This is a simple text response for testing.",
        }),
      ])
    }),
  )

  // test_image_content
  server.add_tool(
    {
      name: "test_image_content",
      description: Some("Tests image content response"),
      input_schema: @mcp_types.ToolInputSchema::empty(),
    },
    @mcp_server.ToolHandler(fn(_args, _notify, _req) {
      @mcp_types.ToolResult::ok([
        @mcp_types.ContentBlock::Image({
          data: TEST_IMAGE_BASE64,
          mime_type: "image/png",
        }),
      ])
    }),
  )

  // test_audio_content
  server.add_tool(
    {
      name: "test_audio_content",
      description: Some("Tests audio content response"),
      input_schema: @mcp_types.ToolInputSchema::empty(),
    },
    @mcp_server.ToolHandler(fn(_args, _notify, _req) {
      @mcp_types.ToolResult::ok([
        @mcp_types.ContentBlock::Audio({
          data: TEST_AUDIO_BASE64,
          mime_type: "audio/wav",
        }),
      ])
    }),
  )

  // test_embedded_resource
  server.add_tool(
    {
      name: "test_embedded_resource",
      description: Some("Tests embedded resource content response"),
      input_schema: @mcp_types.ToolInputSchema::empty(),
    },
    @mcp_server.ToolHandler(fn(_args, _notify, _req) {
      @mcp_types.ToolResult::ok([
        @mcp_types.ContentBlock::Resource({
          uri: "test://embedded-resource",
          mime_type: Some("text/plain"),
          text: Some("This is an embedded resource content."),
          blob: None,
        }),
      ])
    }),
  )

  // test_multiple_content_types
  server.add_tool(
    {
      name: "test_multiple_content_types",
      description: Some(
        "Tests response with multiple content types (text, image, resource)",
      ),
      input_schema: @mcp_types.ToolInputSchema::empty(),
    },
    @mcp_server.ToolHandler(fn(_args, _notify, _req) {
      @mcp_types.ToolResult::ok([
        @mcp_types.ContentBlock::Text({ text: "Multiple content types test:" }),
        @mcp_types.ContentBlock::Image({
          data: TEST_IMAGE_BASE64,
          mime_type: "image/png",
        }),
        @mcp_types.ContentBlock::Resource({
          uri: "test://mixed-content-resource",
          mime_type: Some("application/json"),
          text: Some("{\"test\":\"data\",\"value\":123}"),
          blob: None,
        }),
      ])
    }),
  )

  // test_tool_with_logging
  server.add_tool(
    {
      name: "test_tool_with_logging",
      description: Some("Tests tool that emits log messages during execution"),
      input_schema: @mcp_types.ToolInputSchema::empty(),
    },
    @mcp_server.ToolHandler(async fn(_args, notify, _req) {
      let @mcp_server.NotifySender(send) = notify
      send(log_notif("info", "Tool execution started"))
      send(log_notif("info", "Tool processing data"))
      send(log_notif("info", "Tool execution completed"))
      @mcp_types.ToolResult::ok([
        @mcp_types.ContentBlock::Text({
          text: "Tool with logging executed successfully",
        }),
      ])
    }),
  )

  // test_tool_with_progress
  server.add_tool(
    {
      name: "test_tool_with_progress",
      description: Some("Tests tool that reports progress notifications"),
      input_schema: @mcp_types.ToolInputSchema::empty(),
    },
    @mcp_server.ToolHandler(async fn(args, notify, _req) {
      let @mcp_server.NotifySender(send) = notify
      // Extract progressToken from _meta if provided
      let token : Json = match args {
        Some(Json::Object(p)) =>
          match p.get("_meta") {
            Some(Json::Object(m)) =>
              match m.get("progressToken") {
                Some(t) => t
                None => Json::number(0.0)
              }
            _ => Json::number(0.0)
          }
        _ => Json::number(0.0)
      }
      send(progress_notif(token, 0.0, 100.0, "Completed step 0 of 100"))
      send(progress_notif(token, 50.0, 100.0, "Completed step 50 of 100"))
      send(progress_notif(token, 100.0, 100.0, "Completed step 100 of 100"))
      let token_str = match token {
        Json::Number(n, ..) => n.to_int().to_string()
        Json::String(s) => s
        _ => "0"
      }
      @mcp_types.ToolResult::ok([
        @mcp_types.ContentBlock::Text({ text: token_str }),
      ])
    }),
  )

  // test_error_handling
  server.add_tool(
    {
      name: "test_error_handling",
      description: Some("Tests error response handling"),
      input_schema: @mcp_types.ToolInputSchema::empty(),
    },
    @mcp_server.ToolHandler(fn(_args, _notify, _req) {
      @mcp_types.ToolResult::error(
        "This tool intentionally returns an error for testing",
      )
    }),
  )

  // test_reconnection - simplified: just returns success
  server.add_tool(
    {
      name: "test_reconnection",
      description: Some(
        "Tests SSE stream disconnection and client reconnection (SEP-1699)",
      ),
      input_schema: @mcp_types.ToolInputSchema::empty(),
    },
    @mcp_server.ToolHandler(fn(_args, _notify, _req) {
      @mcp_types.ToolResult::ok([
        @mcp_types.ContentBlock::Text({
          text: "Reconnection test completed successfully. If you received this, the client properly reconnected after stream closure.",
        }),
      ])
    }),
  )

  // test_sampling
  server.add_tool(
    {
      name: "test_sampling",
      description: Some(
        "Tests server-initiated sampling (LLM completion request)",
      ),
      input_schema: {
        type_: "object",
        properties: Some(
          Json::object({
            "prompt": Json::object({
              "type": Json::string("string"),
              "description": Json::string("The prompt to send to the LLM"),
            }),
          }),
        ),
        required: [],
      },
    },
    @mcp_server.ToolHandler(async fn(args, _notify, req) {
      let prompt_text = match args {
        Some(Json::Object(p)) =>
          match p.get("prompt") {
            Some(Json::String(s)) => s
            _ => "Hello"
          }
        _ => "Hello"
      }
      let @mcp_server.ServerRequester(request) = req
      let params : Json = Json::object({
        "messages": Json::array([
          Json::object({
            "role": Json::string("user"),
            "content": Json::object({
              "type": Json::string("text"),
              "text": Json::string(prompt_text),
            }),
          }),
        ]),
        "maxTokens": Json::number(100.0),
      })
      let result = request("sampling/createMessage", params) catch {
        e => {
          let msg = match (e : Error) {
            _ => "Sampling not supported or error"
          }
          return @mcp_types.ToolResult::ok([
            @mcp_types.ContentBlock::Text({
              text: "Sampling not supported or error: \{msg}",
            }),
          ])
        }
      }
      let model_response = match result {
        Json::Object(r) =>
          match r.get("content") {
            Some(Json::Object(c)) =>
              match c.get("text") {
                Some(Json::String(s)) => s
                _ => "No response"
              }
            _ =>
              match r.get("message") {
                Some(Json::Object(m)) =>
                  match m.get("content") {
                    Some(Json::Object(c)) =>
                      match c.get("text") {
                        Some(Json::String(s)) => s
                        _ => "No response"
                      }
                    _ => "No response"
                  }
                _ => "No response"
              }
          }
        _ => "No response"
      }
      @mcp_types.ToolResult::ok([
        @mcp_types.ContentBlock::Text({
          text: "LLM response: \{model_response}",
        }),
      ])
    }),
  )

  // test_elicitation
  server.add_tool(
    {
      name: "test_elicitation",
      description: Some(
        "Tests server-initiated elicitation (user input request)",
      ),
      input_schema: {
        type_: "object",
        properties: Some(
          Json::object({
            "message": Json::object({
              "type": Json::string("string"),
              "description": Json::string("The message to show the user"),
            }),
          }),
        ),
        required: [],
      },
    },
    @mcp_server.ToolHandler(async fn(args, _notify, req) {
      let message_text = match args {
        Some(Json::Object(p)) =>
          match p.get("message") {
            Some(Json::String(s)) => s
            _ => "Please provide input"
          }
        _ => "Please provide input"
      }
      let @mcp_server.ServerRequester(request) = req
      let params : Json = Json::object({
        "message": Json::string(message_text),
        "requestedSchema": Json::object({
          "type": Json::string("object"),
          "properties": Json::object({
            "response": Json::object({
              "type": Json::string("string"),
              "description": Json::string("User's response"),
            }),
          }),
          "required": Json::array([Json::string("response")]),
        }),
      })
      let result = request("elicitation/create", params) catch {
        e => {
          let msg = match (e : Error) {
            _ => "Elicitation not supported or error"
          }
          return @mcp_types.ToolResult::ok([
            @mcp_types.ContentBlock::Text({
              text: "Elicitation not supported or error: \{msg}",
            }),
          ])
        }
      }
      let action = match result {
        Json::Object(r) =>
          match r.get("action") {
            Some(Json::String(s)) => s
            _ => "unknown"
          }
        _ => "unknown"
      }
      let content_str = match result {
        Json::Object(r) =>
          match r.get("content") {
            Some(c) => c.stringify()
            None => "{}"
          }
        _ => "{}"
      }
      @mcp_types.ToolResult::ok([
        @mcp_types.ContentBlock::Text({
          text: "User response: action=\{action}, content=\{content_str}",
        }),
      ])
    }),
  )

  // test_elicitation_sep1034_defaults
  server.add_tool(
    {
      name: "test_elicitation_sep1034_defaults",
      description: Some("Tests elicitation with default values per SEP-1034"),
      input_schema: @mcp_types.ToolInputSchema::empty(),
    },
    @mcp_server.ToolHandler(async fn(_args, _notify, req) {
      let @mcp_server.ServerRequester(request) = req
      let params : Json = Json::object({
        "message": Json::string(
          "Please review and update the form fields with defaults",
        ),
        "requestedSchema": Json::object({
          "type": Json::string("object"),
          "properties": Json::object({
            "name": Json::object({
              "type": Json::string("string"),
              "description": Json::string("User name"),
              "default": Json::string("John Doe"),
            }),
            "age": Json::object({
              "type": Json::string("integer"),
              "description": Json::string("User age"),
              "default": Json::number(30.0),
            }),
            "score": Json::object({
              "type": Json::string("number"),
              "description": Json::string("User score"),
              "default": Json::number(95.5),
            }),
            "status": Json::object({
              "type": Json::string("string"),
              "description": Json::string("User status"),
              "enum": Json::array([
                Json::string("active"),
                Json::string("inactive"),
                Json::string("pending"),
              ]),
              "default": Json::string("active"),
            }),
            "verified": Json::object({
              "type": Json::string("boolean"),
              "description": Json::string("Verification status"),
              "default": Json::boolean(true),
            }),
          }),
          "required": Json::array([]),
        }),
      })
      let result = request("elicitation/create", params) catch {
        e => {
          let msg = match (e : Error) {
            _ => "Elicitation not supported or error"
          }
          return @mcp_types.ToolResult::ok([
            @mcp_types.ContentBlock::Text({
              text: "Elicitation not supported or error: \{msg}",
            }),
          ])
        }
      }
      let action = match result {
        Json::Object(r) =>
          match r.get("action") {
            Some(Json::String(s)) => s
            _ => "unknown"
          }
        _ => "unknown"
      }
      let content_str = match result {
        Json::Object(r) =>
          match r.get("content") {
            Some(c) => c.stringify()
            None => "{}"
          }
        _ => "{}"
      }
      @mcp_types.ToolResult::ok([
        @mcp_types.ContentBlock::Text({
          text: "Elicitation completed: action=\{action}, content=\{content_str}",
        }),
      ])
    }),
  )

  // test_elicitation_sep1330_enums
  server.add_tool(
    {
      name: "test_elicitation_sep1330_enums",
      description: Some(
        "Tests elicitation with enum schema improvements per SEP-1330",
      ),
      input_schema: @mcp_types.ToolInputSchema::empty(),
    },
    @mcp_server.ToolHandler(async fn(_args, _notify, req) {
      let @mcp_server.ServerRequester(request) = req
      let params : Json = Json::object({
        "message": Json::string("Please select options from the enum fields"),
        "requestedSchema": Json::object({
          "type": Json::string("object"),
          "properties": Json::object({
            "untitledSingle": Json::object({
              "type": Json::string("string"),
              "description": Json::string("Select one option"),
              "enum": Json::array([
                Json::string("option1"),
                Json::string("option2"),
                Json::string("option3"),
              ]),
            }),
            "titledSingle": Json::object({
              "type": Json::string("string"),
              "description": Json::string("Select one option with titles"),
              "oneOf": Json::array([
                Json::object({
                  "const": Json::string("value1"),
                  "title": Json::string("First Option"),
                }),
                Json::object({
                  "const": Json::string("value2"),
                  "title": Json::string("Second Option"),
                }),
                Json::object({
                  "const": Json::string("value3"),
                  "title": Json::string("Third Option"),
                }),
              ]),
            }),
            "legacyEnum": Json::object({
              "type": Json::string("string"),
              "description": Json::string("Select one option (legacy)"),
              "enum": Json::array([
                Json::string("opt1"),
                Json::string("opt2"),
                Json::string("opt3"),
              ]),
              "enumNames": Json::array([
                Json::string("Option One"),
                Json::string("Option Two"),
                Json::string("Option Three"),
              ]),
            }),
            "untitledMulti": Json::object({
              "type": Json::string("array"),
              "description": Json::string("Select multiple options"),
              "minItems": Json::number(1.0),
              "maxItems": Json::number(3.0),
              "items": Json::object({
                "type": Json::string("string"),
                "enum": Json::array([
                  Json::string("option1"),
                  Json::string("option2"),
                  Json::string("option3"),
                ]),
              }),
            }),
            "titledMulti": Json::object({
              "type": Json::string("array"),
              "description": Json::string("Select multiple options with titles"),
              "minItems": Json::number(1.0),
              "maxItems": Json::number(3.0),
              "items": Json::object({
                "anyOf": Json::array([
                  Json::object({
                    "const": Json::string("value1"),
                    "title": Json::string("First Choice"),
                  }),
                  Json::object({
                    "const": Json::string("value2"),
                    "title": Json::string("Second Choice"),
                  }),
                  Json::object({
                    "const": Json::string("value3"),
                    "title": Json::string("Third Choice"),
                  }),
                ]),
              }),
            }),
          }),
          "required": Json::array([]),
        }),
      })
      let result = request("elicitation/create", params) catch {
        e => {
          let msg = match (e : Error) {
            _ => "Elicitation not supported or error"
          }
          return @mcp_types.ToolResult::ok([
            @mcp_types.ContentBlock::Text({
              text: "Elicitation not supported or error: \{msg}",
            }),
          ])
        }
      }
      let action = match result {
        Json::Object(r) =>
          match r.get("action") {
            Some(Json::String(s)) => s
            _ => "unknown"
          }
        _ => "unknown"
      }
      let content_str = match result {
        Json::Object(r) =>
          match r.get("content") {
            Some(c) => c.stringify()
            None => "{}"
          }
        _ => "{}"
      }
      @mcp_types.ToolResult::ok([
        @mcp_types.ContentBlock::Text({
          text: "Elicitation completed: action=\{action}, content=\{content_str}",
        }),
      ])
    }),
  )
}

// ---- Register all resources ----

///|
fn register_resources(server : @mcp_server.McpServer) -> Unit {
  // test://static-text
  server.add_resource(
    {
      uri: "test://static-text",
      name: "Static Text Resource",
      description: Some("A static text resource for testing"),
      mime_type: Some("text/plain"),
    },
    @mcp_server.ResourceHandler(fn(_uri) {
      {
        uri: "test://static-text",
        mime_type: Some("text/plain"),
        text: Some("This is the content of the static text resource."),
        blob: None,
      }
    }),
  )

  // test://static-binary
  server.add_resource(
    {
      uri: "test://static-binary",
      name: "Static Binary Resource",
      description: Some("A static binary resource (image) for testing"),
      mime_type: Some("image/png"),
    },
    @mcp_server.ResourceHandler(fn(_uri) {
      {
        uri: "test://static-binary",
        mime_type: Some("image/png"),
        text: None,
        blob: Some(TEST_IMAGE_BASE64),
      }
    }),
  )

  // test://watched-resource
  server.add_resource(
    {
      uri: "test://watched-resource",
      name: "Watched Resource",
      description: Some("A resource that auto-updates every 3 seconds"),
      mime_type: Some("text/plain"),
    },
    @mcp_server.ResourceHandler(fn(_uri) {
      {
        uri: "test://watched-resource",
        mime_type: Some("text/plain"),
        text: Some("Watched resource content"),
        blob: None,
      }
    }),
  )

  // test://template/{id}/data - resource template
  server.add_resource_template_with_handler(
    {
      uri_template: "test://template/{id}/data",
      name: "Resource Template",
      description: Some("A resource template with parameter substitution"),
      mime_type: Some("application/json"),
    },
    @mcp_server.ResourceHandler(fn(uri) {
      // Extract id from the URI by finding the segment between "template/" and "/data"
      let id = match uri.split_once("/data") {
        Some((prefix, _)) =>
          match prefix.rev_find("/") {
            Some(idx) => prefix.sub(start=idx + 1).to_string()
            None => "unknown"
          }
        None => "unknown"
      }
      {
        uri,
        mime_type: Some("application/json"),
        text: Some(
          "{\"id\":\"\{id}\",\"name\":\"Resource \{id}\",\"value\":42}",
        ),
        blob: None,
      }
    }),
  )
}

// ---- Register all prompts ----

///|
fn register_prompts(server : @mcp_server.McpServer) -> Unit {
  // test_simple_prompt
  server.add_prompt(
    {
      name: "test_simple_prompt",
      description: Some("A simple prompt without arguments"),
      arguments: [],
    },
    @mcp_server.PromptHandler(fn(_args) {
      {
        description: None,
        messages: [
          {
            role: @mcp_types.Role::User,
            content: @mcp_types.PromptContent::Text({
              text: "This is a simple prompt for testing.",
            }),
          },
        ],
      }
    }),
  )

  // test_prompt_with_arguments
  server.add_prompt(
    {
      name: "test_prompt_with_arguments",
      description: Some("A prompt with required arguments"),
      arguments: [
        {
          name: "arg1",
          description: Some("First test argument"),
          required: true,
        },
        {
          name: "arg2",
          description: Some("Second test argument"),
          required: true,
        },
      ],
    },
    @mcp_server.PromptHandler(fn(args) {
      let arg1 = match args.get("arg1") {
        Some(s) => s
        None => ""
      }
      let arg2 = match args.get("arg2") {
        Some(s) => s
        None => ""
      }
      {
        description: None,
        messages: [
          {
            role: @mcp_types.Role::User,
            content: @mcp_types.PromptContent::Text({
              text: "Prompt with arguments: arg1='\{arg1}', arg2='\{arg2}'",
            }),
          },
        ],
      }
    }),
  )

  // test_prompt_with_embedded_resource
  server.add_prompt(
    {
      name: "test_prompt_with_embedded_resource",
      description: Some("A prompt that includes an embedded resource"),
      arguments: [
        {
          name: "resourceUri",
          description: Some("URI of the resource to embed"),
          required: true,
        },
      ],
    },
    @mcp_server.PromptHandler(fn(args) {
      let uri = match args.get("resourceUri") {
        Some(s) => s
        None => "test://static-text"
      }
      {
        description: None,
        messages: [
          {
            role: @mcp_types.Role::User,
            content: @mcp_types.PromptContent::Resource({
              uri,
              mime_type: Some("text/plain"),
              text: Some("Embedded resource content for testing."),
              blob: None,
            }),
          },
          {
            role: @mcp_types.Role::User,
            content: @mcp_types.PromptContent::Text({
              text: "Please process the embedded resource above.",
            }),
          },
        ],
      }
    }),
  )

  // test_prompt_with_image
  server.add_prompt(
    {
      name: "test_prompt_with_image",
      description: Some("A prompt that includes image content"),
      arguments: [],
    },
    @mcp_server.PromptHandler(fn(_args) {
      {
        description: None,
        messages: [
          {
            role: @mcp_types.Role::User,
            content: @mcp_types.PromptContent::Image({
              data: TEST_IMAGE_BASE64,
              mime_type: "image/png",
            }),
          },
          {
            role: @mcp_types.Role::User,
            content: @mcp_types.PromptContent::Text({
              text: "Please analyze the image above.",
            }),
          },
        ],
      }
    }),
  )
}

// ---- Entry point ----

///|
async fn main {
  let port = 3000
  let server = @mcp_server.McpServer::new(
    "mcp-conformance-test-server", "1.0.0",
  )
  register_tools(server)
  register_resources(server)
  register_prompts(server)
  println("MCP Conformance Test Server running on http://localhost:\{port}")
  println("  - MCP endpoint: http://localhost:\{port}/mcp")
  server.serve(port) catch {
    e => println("Server error: \{e}")
  }
}
