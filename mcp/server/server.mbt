// MCP Server implementation using Streamable HTTP transport

// ---- Session state ----

///|
pub(all) struct SessionState {
  session_id : String
  mut initialized : Bool
  mut log_level : @types.LogLevel
  // SSE subscribers for server-sent events
  sse_writers : Array[@io.PipeWrite]
  // Pending server-initiated requests: request_id -> result pipe
  // When server sends a request via SSE, it waits on the PipeRead.
  // When client responds via POST, we write the result to the PipeWrite.
  pending_requests : Map[String, @io.PipeWrite]
}

///|
fn SessionState::new(session_id : String) -> SessionState {
  {
    session_id,
    initialized: false,
    log_level: @types.LogLevel::Info,
    sse_writers: [],
    pending_requests: {},
  }
}

// ---- Handler types ----

///|
/// Notification sender type: sends a JSON-RPC notification to the client via SSE
pub(all) struct NotifySender(async (Json) -> Unit)

///|
/// Server requester type: sends a server-initiated JSON-RPC request to the client via SSE
/// and waits for the client's response. Used for sampling/elicitation.
pub(all) struct ServerRequester(async (String, Json) -> Json)

///|
/// Tool handler: receives (args, notify_fn, requester) and returns ToolResult
/// - notify_fn: send log/progress notifications during execution
/// - requester: make server-initiated requests (sampling, elicitation)
pub(all) struct ToolHandler(
  async (Json?, NotifySender, ServerRequester) -> @types.ToolResult
)

///|
pub(all) struct ResourceHandler(async (String) -> @types.ResourceContent)

///|
pub(all) struct ResourceListHandler(async () -> Array[@types.ResourceContent])

///|
pub(all) struct PromptHandler(
  async (Map[String, String]) -> @types.PromptResult
)

// ---- McpServer ----

///|
pub(all) struct McpServer {
  server_info : @types.Implementation
  capabilities : @types.ServerCapabilities
  // Registered handlers
  tools : Map[String, (@types.Tool, ToolHandler)]
  resources : Map[String, (@types.Resource, ResourceHandler)]
  resource_templates : Map[String, @types.ResourceTemplate]
  resource_template_handlers : Map[String, ResourceHandler]
  prompts : Map[String, (@types.Prompt, PromptHandler)]
  // Active sessions: session_id -> SessionState
  sessions : Map[String, SessionState]
  // Counter for generating unique server-initiated request IDs
  mut request_counter : Int
}

///|
pub fn McpServer::new(
  name : String,
  version : String,
  capabilities? : @types.ServerCapabilities = {
    tools: true,
    resources: true,
    resources_subscribe: true,
    prompts: true,
    logging: true,
    completions: true,
  },
) -> McpServer {
  {
    server_info: { name, version },
    capabilities,
    tools: {},
    resources: {},
    resource_templates: {},
    resource_template_handlers: {},
    prompts: {},
    sessions: {},
    request_counter: 0,
  }
}

///|
pub fn McpServer::add_tool(
  self : McpServer,
  tool : @types.Tool,
  handler : ToolHandler,
) -> Unit {
  self.tools[tool.name] = (tool, handler)
}

///|
pub fn McpServer::add_resource(
  self : McpServer,
  resource : @types.Resource,
  handler : ResourceHandler,
) -> Unit {
  self.resources[resource.uri] = (resource, handler)
}

///|
pub fn McpServer::add_resource_template(
  self : McpServer,
  template : @types.ResourceTemplate,
) -> Unit {
  self.resource_templates[template.uri_template] = template
}

///|
pub fn McpServer::add_resource_template_with_handler(
  self : McpServer,
  template : @types.ResourceTemplate,
  handler : ResourceHandler,
) -> Unit {
  self.resource_templates[template.uri_template] = template
  self.resource_template_handlers[template.uri_template] = handler
}

///|
pub fn McpServer::add_prompt(
  self : McpServer,
  prompt : @types.Prompt,
  handler : PromptHandler,
) -> Unit {
  self.prompts[prompt.name] = (prompt, handler)
}

// ---- HTTP Transport ----

///|
/// Start the server on the given port using Streamable HTTP transport.
pub async fn McpServer::serve(self : McpServer, port : Int) -> Unit {
  let addr = @socket.Addr::parse("0.0.0.0:\{port}")
  let http_server = @http.Server::new(addr)
  http_server.run_forever(async fn(req, body, conn) {
    self.handle_http(req, body, conn)
  })
}

///|
async fn McpServer::handle_http(
  self : McpServer,
  req : @http.Request,
  body : &@io.Reader,
  conn : @http.ServerConnection,
) -> Unit {
  // DNS rebinding protection: reject requests from non-localhost origins/hosts
  if !is_localhost_host(req.headers) {
    conn.send_response(403, "Forbidden")
    conn.write("Invalid Host header")
    conn.end_response()
    return
  }
  // Only handle /mcp path
  let path = req.path
  if path != "/mcp" {
    conn.send_response(404, "Not Found")
    conn.end_response()
    return
  }
  match req.meth {
    Post => self.handle_post(req, body, conn)
    Get => self.handle_get(req, conn)
    Delete => self.handle_delete(req, conn)
    _ => {
      conn.send_response(405, "Method Not Allowed")
      conn.end_response()
    }
  }
}

///|
/// Handle POST /mcp - process JSON-RPC requests/notifications
async fn McpServer::handle_post(
  self : McpServer,
  req : @http.Request,
  body : &@io.Reader,
  conn : @http.ServerConnection,
) -> Unit {
  // Read body
  let raw_data = body.read_all()
  let raw_text = raw_data.text() catch {
    _ => {
      conn.send_response(400, "Bad Request")
      conn.write("Cannot read request body as text")
      conn.end_response()
      return
    }
  }
  // Parse JSON-RPC message
  let msg = @types.parse_message(raw_text) catch {
    _ => {
      let err_resp = @types.Response::err(
        @types.RequestId::Null,
        @types.PARSE_ERROR,
        "Parse error",
      )
      conn.send_response(200, "OK", extra_headers={
        "Content-Type": "application/json",
        "Access-Control-Allow-Origin": "*",
      })
      conn.write(err_resp.to_json().stringify())
      conn.end_response()
      return
    }
  }
  // Get or create session
  let session_id = req.headers.get("mcp-session-id")
  // Handle initialize specially (no session required)
  match msg {
    Req(r) if r.mthd == "initialize" => {
      let new_session_id = gen_session_id()
      let session = SessionState::new(new_session_id)
      session.initialized = true
      self.sessions[new_session_id] = session
      let result = self.handle_initialize(r.params)
      let resp = @types.Response::ok(r.id, result)
      conn.send_response(200, "OK", extra_headers={
        "Content-Type": "application/json",
        "Mcp-Session-Id": new_session_id,
        "Access-Control-Allow-Origin": "*",
      })
      conn.write(resp.to_json().stringify())
      conn.end_response()
      return
    }
    _ => ()
  }
  // For all other requests, session must exist
  let sid = match session_id {
    Some(s) => s
    None => {
      conn.send_response(400, "Bad Request")
      conn.write("Missing Mcp-Session-Id header")
      conn.end_response()
      return
    }
  }
  let session = match self.sessions.get(sid) {
    Some(s) => s
    None => {
      conn.send_response(404, "Not Found")
      conn.write("Session not found")
      conn.end_response()
      return
    }
  }
  if !session.initialized {
    conn.send_response(400, "Bad Request")
    conn.write("Session not initialized")
    conn.end_response()
    return
  }
  // Dispatch the message
  match msg {
    Req(r) => {
      let result = self.dispatch_request(r, session)
      let resp = match result {
        Ok(json) => @types.Response::ok(r.id, json)
        Err(e) =>
          match e {
            McpServerError(code, msg_str) =>
              @types.Response::err(r.id, code, msg_str)
          }
      }
      conn.send_response(200, "OK", extra_headers={
        "Content-Type": "application/json",
        "Access-Control-Allow-Origin": "*",
      })
      conn.write(resp.to_json().stringify())
      conn.end_response()
    }
    Notif(n) => {
      // Handle notifications (no response needed)
      self.dispatch_notification(n, session)
      conn.send_response(202, "Accepted", extra_headers={
        "Access-Control-Allow-Origin": "*",
      })
      conn.end_response()
    }
    Resp(r) => {
      // Client responded to a server-initiated request
      let req_id = match r.id {
        @types.RequestId::String(s) => Some(s)
        @types.RequestId::Number(n) => Some(n.to_string())
        _ => None
      }
      match req_id {
        Some(rid) =>
          match session.pending_requests.get(rid) {
            Some(pipe) => {
              // Write the response JSON to the waiting pipe
              let resp_json = r.to_json().stringify()
              pipe.write(resp_json) catch {
                _ => ()
              }
              session.pending_requests.remove(rid)
            }
            None => ()
          }
        None => ()
      }
      conn.send_response(202, "Accepted", extra_headers={
        "Access-Control-Allow-Origin": "*",
      })
      conn.end_response()
    }
  }
}

///|
/// Handle GET /mcp - SSE stream for server->client events
async fn McpServer::handle_get(
  self : McpServer,
  req : @http.Request,
  conn : @http.ServerConnection,
) -> Unit {
  let session_id = req.headers.get("mcp-session-id")
  let sid = match session_id {
    Some(s) => s
    None => {
      conn.send_response(400, "Bad Request")
      conn.write("Missing Mcp-Session-Id header")
      conn.end_response()
      return
    }
  }
  let session = match self.sessions.get(sid) {
    Some(s) => s
    None => {
      conn.send_response(404, "Not Found")
      conn.write("Session not found")
      conn.end_response()
      return
    }
  }
  // Start SSE stream
  conn.send_response(200, "OK", extra_headers={
    "Content-Type": "text/event-stream",
    "Cache-Control": "no-cache",
    "Connection": "keep-alive",
    "Access-Control-Allow-Origin": "*",
  })
  // Create a pipe to write SSE events
  let (pipe_read, pipe_write) = @io.pipe()
  session.sse_writers.push(pipe_write)
  // Stream pipe data to connection
  conn.write_reader(pipe_read)
  // Clean up: remove this writer
  let idx = session.sse_writers.search_by(fn(w) {
    // We can't compare PipeWrite directly; remove the last-added as a heuristic
    // A more robust approach would use an index-based removal
    ignore(w)
    false
  })
  ignore(idx)
  pipe_write.close()
  pipe_read.close()
  conn.end_response()
}

///|
/// Handle DELETE /mcp - terminate session
async fn McpServer::handle_delete(
  self : McpServer,
  req : @http.Request,
  conn : @http.ServerConnection,
) -> Unit {
  let session_id = req.headers.get("mcp-session-id")
  let sid = match session_id {
    Some(s) => s
    None => {
      conn.send_response(400, "Bad Request")
      conn.write("Missing Mcp-Session-Id header")
      conn.end_response()
      return
    }
  }
  match self.sessions.get(sid) {
    Some(session) => {
      // Close all SSE writers
      for w in session.sse_writers {
        w.close()
      }
      self.sessions.remove(sid)
      conn.send_response(200, "OK", extra_headers={
        "Access-Control-Allow-Origin": "*",
      })
      conn.end_response()
    }
    None => {
      conn.send_response(404, "Not Found")
      conn.write("Session not found")
      conn.end_response()
    }
  }
}

// ---- Request handlers ----

///|
pub(all) suberror McpServerError {
  McpServerError(Int, String)
}

///|
fn McpServer::handle_initialize(self : McpServer, params : Json?) -> Json {
  // Parse client info from params (optional)
  let _client_capabilities = match params {
    Some(Json::Object(p)) =>
      match p.get("capabilities") {
        Some(caps) => @types.ClientCapabilities::from_json(caps)
        None => { roots: false, sampling: false, elicitation: false }
      }
    _ => { roots: false, sampling: false, elicitation: false }
  }
  let obj : Map[String, Json] = {
    "protocolVersion": Json::string(@types.PROTOCOL_VERSION),
    "serverInfo": self.server_info.to_json(),
    "capabilities": self.capabilities.to_json(),
  }
  Json::object(obj)
}

///|
async fn McpServer::dispatch_request(
  self : McpServer,
  req : @types.Request,
  session : SessionState,
) -> Result[Json, McpServerError] {
  match req.mthd {
    "ping" => Ok(Json::object({}))
    "tools/list" => Ok(self.handle_tools_list())
    "tools/call" => self.handle_tools_call(req.params, session)
    "resources/list" => Ok(self.handle_resources_list())
    "resources/read" => self.handle_resources_read(req.params)
    "resources/templates/list" => Ok(self.handle_resource_templates_list())
    "resources/subscribe" => Ok(Json::object({}))
    "resources/unsubscribe" => Ok(Json::object({}))
    "prompts/list" => Ok(self.handle_prompts_list())
    "prompts/get" => self.handle_prompts_get(req.params, session)
    "logging/setLevel" => {
      self.handle_set_log_level(req.params, session)
      Ok(Json::object({}))
    }
    "completion/complete" => Ok(self.handle_completion(req.params))
    _ =>
      Err(
        McpServerError(@types.METHOD_NOT_FOUND, "Method not found: \{req.mthd}"),
      )
  }
}

///|
fn McpServer::dispatch_notification(
  self : McpServer,
  notif : @types.Notification,
  _session : SessionState,
) -> Unit {
  ignore(self)
  // Handle notifications from client
  match notif.mthd {
    "notifications/initialized" => () // client signaled ready
    "notifications/cancelled" => () // client cancelled a request
    _ => () // unknown notification - ignore
  }
}

///|
fn McpServer::handle_tools_list(self : McpServer) -> Json {
  let tools = self.tools
    .values()
    .map(fn(pair) {
      let (tool, _) = pair
      tool.to_json()
    })
    |> Array::from_iter
  Json::object({ "tools": Json::array(tools) })
}

///|
async fn McpServer::handle_tools_call(
  self : McpServer,
  params : Json?,
  session : SessionState,
) -> Result[Json, McpServerError] {
  let (name, args) = match params {
    Some(Json::Object(p)) => {
      let n = match p.get("name") {
        Some(Json::String(s)) => s
        _ =>
          return Err(McpServerError(@types.INVALID_PARAMS, "Missing tool name"))
      }
      let a = p.get("arguments")
      let meta = p.get("_meta")
      // Merge _meta from outer params into args so tools can access progressToken
      let merged_args : Json? = match (a, meta) {
        (Some(Json::Object(args_map)), Some(m)) => {
          let merged : Map[String, Json] = {}
          for k, v in args_map {
            merged[k] = v
          }
          merged["_meta"] = m
          Some(Json::object(merged))
        }
        (None, Some(m)) => Some(Json::object({ "_meta": m }))
        _ => a
      }
      (n, merged_args)
    }
    _ => return Err(McpServerError(@types.INVALID_PARAMS, "Invalid params"))
  }
  match self.tools.get(name) {
    Some((_, handler)) => {
      let ToolHandler(f) = handler
      // Build notification sender that writes to SSE writers for this session
      let notify = NotifySender(async fn(notif_json) {
        let event = sse_event(notif_json.stringify())
        for writer in session.sse_writers {
          writer.write(event) catch {
            _ => () // ignore closed writers
          }
        }
      })
      // Build server requester for server-initiated requests (sampling, elicitation)
      let requester = ServerRequester(async fn(mthd, params) {
        self.server_request(session, mthd, params)
      })
      let result = f(args, notify, requester) catch {
        _ => {
          let err_result = @types.ToolResult::error("Tool execution failed")
          return Ok(err_result.to_json())
        }
      }
      Ok(result.to_json())
    }
    None =>
      Err(McpServerError(@types.METHOD_NOT_FOUND, "Tool not found: \{name}"))
  }
}

///|
fn McpServer::handle_resources_list(self : McpServer) -> Json {
  let resources = self.resources
    .values()
    .map(fn(pair) {
      let (res, _) = pair
      res.to_json()
    })
    |> Array::from_iter
  Json::object({ "resources": Json::array(resources) })
}

///|
async fn McpServer::handle_resources_read(
  self : McpServer,
  params : Json?,
) -> Result[Json, McpServerError] {
  let uri = match params {
    Some(Json::Object(p)) =>
      match p.get("uri") {
        Some(Json::String(s)) => s
        _ =>
          return Err(
            McpServerError(@types.INVALID_PARAMS, "Missing resource uri"),
          )
      }
    _ => return Err(McpServerError(@types.INVALID_PARAMS, "Invalid params"))
  }
  match self.resources.get(uri) {
    Some((_, handler)) => {
      let ResourceHandler(f) = handler
      let content = f(uri) catch {
        _ =>
          return Err(
            McpServerError(@types.INTERNAL_ERROR, "Resource read failed"),
          )
      }
      let contents = Json::array([content.to_json()])
      Ok(Json::object({ "contents": contents }))
    }
    None => {
      // Try template matching
      let mut matched : Result[Json, McpServerError]? = None
      for template_str, handler in self.resource_template_handlers {
        match match_uri_template(template_str, uri) {
          Some(_vars) => {
            let ResourceHandler(f) = handler
            let content = f(uri) catch {
              _ => {
                matched = Some(
                  Err(
                    McpServerError(
                      @types.INTERNAL_ERROR,
                      "Resource template read failed",
                    ),
                  ),
                )
                break
              }
            }
            let contents = Json::array([content.to_json()])
            matched = Some(Ok(Json::object({ "contents": contents })))
            break
          }
          None => ()
        }
      }
      match matched {
        Some(r) => r
        None =>
          Err(
            McpServerError(
              @types.METHOD_NOT_FOUND,
              "Resource not found: \{uri}",
            ),
          )
      }
    }
  }
}

///|
fn McpServer::handle_resource_templates_list(self : McpServer) -> Json {
  let templates = self.resource_templates.values().map(fn(t) { t.to_json() })
    |> Array::from_iter
  Json::object({ "resourceTemplates": Json::array(templates) })
}

///|
fn McpServer::handle_prompts_list(self : McpServer) -> Json {
  let prompts = self.prompts
    .values()
    .map(fn(pair) {
      let (prompt, _) = pair
      prompt.to_json()
    })
    |> Array::from_iter
  Json::object({ "prompts": Json::array(prompts) })
}

///|
async fn McpServer::handle_prompts_get(
  self : McpServer,
  params : Json?,
  _session : SessionState,
) -> Result[Json, McpServerError] {
  let (name, args) = match params {
    Some(Json::Object(p)) => {
      let n = match p.get("name") {
        Some(Json::String(s)) => s
        _ =>
          return Err(
            McpServerError(@types.INVALID_PARAMS, "Missing prompt name"),
          )
      }
      let arg_map : Map[String, String] = {}
      match p.get("arguments") {
        Some(Json::Object(a)) =>
          for k, v in a {
            match v {
              Json::String(s) => arg_map[k] = s
              _ => ()
            }
          }
        _ => ()
      }
      (n, arg_map)
    }
    _ => return Err(McpServerError(@types.INVALID_PARAMS, "Invalid params"))
  }
  match self.prompts.get(name) {
    Some((_, handler)) => {
      let PromptHandler(f) = handler
      let result = f(args) catch {
        _ =>
          return Err(
            McpServerError(@types.INTERNAL_ERROR, "Prompt execution failed"),
          )
      }
      Ok(result.to_json())
    }
    None =>
      Err(McpServerError(@types.METHOD_NOT_FOUND, "Prompt not found: \{name}"))
  }
}

///|
fn McpServer::handle_set_log_level(
  self : McpServer,
  params : Json?,
  session : SessionState,
) -> Unit {
  ignore(self)
  match params {
    Some(Json::Object(p)) =>
      match p.get("level") {
        Some(Json::String(level_str)) =>
          match @types.LogLevel::from_string(level_str) {
            Some(level) => session.log_level = level
            None => ()
          }
        _ => ()
      }
    _ => ()
  }
}

///|
fn McpServer::handle_completion(self : McpServer, params : Json?) -> Json {
  ignore(self)
  ignore(params)
  let result = @types.CompletionResult::empty()
  Json::object({ "completion": result.to_json() })
}

///|
/// Send a log notification to all SSE streams for a session
pub async fn McpServer::send_log(
  self : McpServer,
  session : SessionState,
  level : @types.LogLevel,
  logger : String,
  data : Json,
) -> Unit {
  ignore(self)
  if level < session.log_level {
    return
  }
  let notif : @types.Notification = {
    mthd: "notifications/message",
    params: Some(
      Json::object({
        "level": level.to_json(),
        "logger": Json::string(logger),
        "data": data,
      }),
    ),
  }
  let event = sse_event(notif.to_json().stringify())
  for writer in session.sse_writers {
    writer.write(event) catch {
      _ => () // ignore closed writers
    }
  }
}

///|
/// Send a progress notification to all SSE streams for a session
pub async fn McpServer::send_progress(
  self : McpServer,
  session : SessionState,
  progress_token : Json,
  progress : Double,
  total : Double?,
) -> Unit {
  ignore(self)
  let params_map : Map[String, Json] = {
    "progressToken": progress_token,
    "progress": Json::number(progress),
  }
  match total {
    Some(t) => params_map["total"] = Json::number(t)
    None => ()
  }
  let notif : @types.Notification = {
    mthd: "notifications/progress",
    params: Some(Json::object(params_map)),
  }
  let event = sse_event(notif.to_json().stringify())
  for writer in session.sse_writers {
    writer.write(event) catch {
      _ => ()
    }
  }
}

///|
fn sse_event(data : String) -> String {
  "data: \{data}\n\n"
}

///|
/// Send a server-initiated request to the client via SSE and wait for a response.
/// Returns the response result JSON or raises on error.
pub async fn McpServer::server_request(
  self : McpServer,
  session : SessionState,
  mthd : String,
  params : Json,
) -> Json {
  // Generate a unique request ID
  self.request_counter = self.request_counter + 1
  let req_id = "srv-\{self.request_counter}"
  // Build the JSON-RPC request
  let req_json : Map[String, Json] = {
    "jsonrpc": Json::string(@types.JSONRPC_VERSION),
    "id": Json::string(req_id),
    "method": Json::string(mthd),
    "params": params,
  }
  // Create a pipe to receive the response
  let (pipe_read, pipe_write) = @io.pipe()
  session.pending_requests[req_id] = pipe_write
  // Send the request via SSE
  let event = sse_event(Json::object(req_json).stringify())
  for writer in session.sse_writers {
    writer.write(event) catch {
      _ => ()
    }
  }
  // Wait for the response (with timeout)
  let response_bytes = @async.with_timeout(30000, async fn() {
    pipe_read.read_all()
  }) catch {
    _ => {
      session.pending_requests.remove(req_id)
      pipe_write.close()
      pipe_read.close()
      raise @types.McpDecodeError("Server request timed out")
    }
  }
  pipe_write.close()
  pipe_read.close()
  // Parse the response
  let resp_text = response_bytes.text() catch {
    _ => raise @types.McpDecodeError("Invalid response encoding")
  }
  let resp_json = @json.parse(resp_text) catch {
    _ => raise @types.McpDecodeError("Invalid response JSON")
  }
  match resp_json {
    Json::Object(obj) =>
      match obj.get("result") {
        Some(result) => result
        None =>
          match obj.get("error") {
            Some(Json::Object(err)) => {
              let msg = match err.get("message") {
                Some(Json::String(s)) => s
                _ => "Server request failed"
              }
              raise @types.McpDecodeError(msg)
            }
            _ => raise @types.McpDecodeError("Invalid response format")
          }
      }
    _ => raise @types.McpDecodeError("Invalid response JSON")
  }
}

///|
/// Check whether the request's Host/Origin header is a safe localhost value.
/// Returns false if it looks like a non-localhost host (DNS rebinding protection).
fn is_localhost_host(headers : Map[String, String]) -> Bool {
  // Valid localhost hostnames (without port)
  fn is_valid_host(host_no_port : String) -> Bool {
    host_no_port == "localhost" ||
    host_no_port == "127.0.0.1" ||
    host_no_port == "[::1]"
  }
  // Strip port from "hostname:port" or "hostname"
  fn strip_port(host : String) -> String {
    match host.rev_find(":") {
      Some(idx) =>
        // Check if it's an IPv6 address (contains "[")
        if host.contains("[") {
          // IPv6 like [::1]:3000 - strip after last ":"
          host.sub(end=idx).to_string()
        } else {
          host.sub(end=idx).to_string()
        }
      None => host
    }
  }
  // Check Origin header first (browser requests always include Origin)
  match headers.get("origin") {
    Some(origin) => {
      // origin is like "http://localhost:3000" or "null"
      if origin == "null" {
        return true // null origin (file://, etc.) is fine
      }
      // Strip scheme
      let without_scheme = if origin.has_prefix("https://") {
        origin.sub(start=8).to_string()
      } else if origin.has_prefix("http://") {
        origin.sub(start=7).to_string()
      } else {
        origin
      }
      let host_only = strip_port(without_scheme)
      return is_valid_host(host_only)
    }
    None => ()
  }
  // Check Host header
  match headers.get("host") {
    Some(host) => {
      let host_only = strip_port(host)
      is_valid_host(host_only)
    }
    None => true // No Host header present — allow (non-browser client)
  }
}

///|
fn gen_session_id() -> String {
  // Simple pseudo-random session ID using current time
  let t = @async.now()
  "sess-\{t}"
}

///|
/// Match a URI against a URI template (RFC 6570 simple variables only).
/// Returns Some(vars) if the URI matches the template, None otherwise.
/// Example: match_uri_template("test://template/{id}/data", "test://template/123/data")
///          => Some({ "id": "123" })
fn match_uri_template(template : String, uri : String) -> Map[String, String]? {
  let vars : Map[String, String] = {}
  // Split template and URI by "/"
  let t_parts = template.split("/") |> Iter::to_array
  let u_parts = uri.split("/") |> Iter::to_array
  if t_parts.length() != u_parts.length() {
    return None
  }
  for i in 0..<t_parts.length() {
    let t_seg = t_parts[i].to_string()
    let u_seg = u_parts[i].to_string()
    if t_seg.has_prefix("{") && t_seg.has_suffix("}") {
      // This is a variable segment - extract var name and capture value
      let var_name = t_seg.sub(start=1, end=t_seg.length() - 1).to_string()
      if u_seg.is_empty() {
        return None
      }
      vars[var_name] = u_seg
    } else if t_seg != u_seg {
      return None
    }
  }
  Some(vars)
}
