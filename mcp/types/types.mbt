// MCP Protocol Version

///|
pub const PROTOCOL_VERSION : String = "2025-11-25"

// JSON-RPC version

///|
pub const JSONRPC_VERSION : String = "2.0"

// JSON-RPC error codes

///|
pub const PARSE_ERROR : Int = -32700

///|
pub const INVALID_REQUEST : Int = -32600

///|
pub const METHOD_NOT_FOUND : Int = -32601

///|
pub const INVALID_PARAMS : Int = -32602

///|
pub const INTERNAL_ERROR : Int = -32603

// ---- Error types ----

///|
/// Error raised when parsing/decoding MCP/JSON-RPC messages
pub(all) suberror McpDecodeError {
  McpDecodeError(String)
} derive(Eq)

// ---- JSON-RPC types ----

///|
/// A JSON-RPC request ID. Can be a string, int, or null.
pub(all) enum RequestId {
  String(String)
  Number(Int)
  Null
} derive(Eq)

///|
pub fn RequestId::to_json(self : RequestId) -> Json {
  match self {
    String(s) => Json::string(s)
    Number(n) => Json::number(n.to_double())
    Null => Json::null()
  }
}

///|
pub fn RequestId::from_json(json : Json) -> RequestId raise McpDecodeError {
  match json {
    String(s) => String(s)
    Number(n, ..) => Number(n.to_int())
    Null => Null
    _ => raise McpDecodeError("id: expected string, number, or null")
  }
}

///|
/// JSON-RPC Request message
pub(all) struct Request {
  id : RequestId
  mthd : String // "method" is a reserved keyword in MoonBit
  params : Json?
}

///|
pub fn Request::to_json(self : Request) -> Json {
  let obj : Map[String, Json] = {}
  obj["jsonrpc"] = Json::string(JSONRPC_VERSION)
  obj["id"] = self.id.to_json()
  obj["method"] = Json::string(self.mthd)
  match self.params {
    Some(p) => obj["params"] = p
    None => ()
  }
  Json::object(obj)
}

///|
/// JSON-RPC Notification message (no id)
pub(all) struct Notification {
  mthd : String // "method" is a reserved keyword in MoonBit
  params : Json?
}

///|
pub fn Notification::to_json(self : Notification) -> Json {
  let obj : Map[String, Json] = {}
  obj["jsonrpc"] = Json::string(JSONRPC_VERSION)
  obj["method"] = Json::string(self.mthd)
  match self.params {
    Some(p) => obj["params"] = p
    None => ()
  }
  Json::object(obj)
}

///|
/// JSON-RPC Error object
pub(all) struct RpcError {
  code : Int
  message : String
  data : Json?
}

///|
pub fn RpcError::to_json(self : RpcError) -> Json {
  let obj : Map[String, Json] = {}
  obj["code"] = Json::number(self.code.to_double())
  obj["message"] = Json::string(self.message)
  match self.data {
    Some(d) => obj["data"] = d
    None => ()
  }
  Json::object(obj)
}

///|
/// JSON-RPC Response message
pub(all) struct Response {
  id : RequestId
  result : Json?
  error : RpcError?
}

///|
pub fn Response::to_json(self : Response) -> Json {
  let obj : Map[String, Json] = {}
  obj["jsonrpc"] = Json::string(JSONRPC_VERSION)
  obj["id"] = self.id.to_json()
  match (self.result, self.error) {
    (Some(r), None) => obj["result"] = r
    (None, Some(e)) => obj["error"] = e.to_json()
    _ => obj["result"] = Json::null()
  }
  Json::object(obj)
}

///|
pub fn Response::ok(id : RequestId, result : Json) -> Response {
  { id, result: Some(result), error: None }
}

///|
pub fn Response::err(
  id : RequestId,
  code : Int,
  message : String,
  data? : Json? = None,
) -> Response {
  { id, result: None, error: Some({ code, message, data }) }
}

///|
/// A parsed JSON-RPC message - can be a request, notification, or response.
pub(all) enum Message {
  Req(Request)
  Notif(Notification)
  Resp(Response)
}

///|
pub fn Message::to_json(self : Message) -> Json {
  match self {
    Req(r) => r.to_json()
    Notif(n) => n.to_json()
    Resp(r) => r.to_json()
  }
}

///|
/// Parse a JSON value into a Message
pub fn Message::from_json(json : Json) -> Message raise McpDecodeError {
  guard json is Json::Object(obj) else {
    raise McpDecodeError("expected JSON object at root")
  }
  let has_id = obj.contains("id")
  let has_result = obj.contains("result")
  let has_error = obj.contains("error")
  let has_method = obj.contains("method")
  if has_result || has_error {
    // It's a response
    let id = match obj.get("id") {
      Some(id_val) => RequestId::from_json(id_val)
      None => RequestId::Null
    }
    let result = obj.get("result")
    let error = match obj.get("error") {
      Some(Json::Object(e)) => {
        let code = match e.get("code") {
          Some(Json::Number(c, ..)) => c.to_int()
          _ => raise McpDecodeError("error.code: expected number")
        }
        let message = match e.get("message") {
          Some(Json::String(m)) => m
          _ => raise McpDecodeError("error.message: expected string")
        }
        let data = e.get("data")
        let rpc_err : RpcError = { code, message, data }
        Some(rpc_err)
      }
      Some(_) => raise McpDecodeError("error: expected object")
      None => None
    }
    Resp({ id, result, error })
  } else if has_method {
    let mthd = match obj.get("method") {
      Some(Json::String(m)) => m
      _ => raise McpDecodeError("method: expected string")
    }
    let params = obj.get("params")
    if has_id {
      let id = RequestId::from_json(obj["id"])
      Req({ id, mthd, params })
    } else {
      Notif({ mthd, params })
    }
  } else {
    raise McpDecodeError(
      "cannot determine message type (no method, result, or error)",
    )
  }
}

///|
/// Parse a raw JSON string into a Message
pub fn parse_message(text : String) -> Message raise {
  let json = @json.parse(text)
  Message::from_json(json)
}

// ---- MCP Protocol Types ----

///|
pub(all) struct Implementation {
  name : String
  version : String
}

///|
pub fn Implementation::to_json(self : Implementation) -> Json {
  let obj : Map[String, Json] = {}
  obj["name"] = Json::string(self.name)
  obj["version"] = Json::string(self.version)
  Json::object(obj)
}

///|
/// Client capabilities
pub(all) struct ClientCapabilities {
  roots : Bool
  sampling : Bool
  elicitation : Bool
}

///|
pub fn ClientCapabilities::from_json(json : Json) -> ClientCapabilities {
  match json {
    Json::Object(obj) => {
      let roots = obj.contains("roots")
      let sampling = obj.contains("sampling")
      let elicitation = obj.contains("elicitation")
      { roots, sampling, elicitation }
    }
    _ => { roots: false, sampling: false, elicitation: false }
  }
}

///|
/// Server capabilities
pub(all) struct ServerCapabilities {
  tools : Bool
  resources : Bool
  resources_subscribe : Bool
  prompts : Bool
  logging : Bool
  completions : Bool
}

///|
pub fn ServerCapabilities::to_json(self : ServerCapabilities) -> Json {
  let obj : Map[String, Json] = {}
  if self.tools {
    let t : Map[String, Json] = { "listChanged": Json::boolean(true) }
    obj["tools"] = Json::object(t)
  }
  if self.resources {
    let res_caps : Map[String, Json] = { "listChanged": Json::boolean(true) }
    if self.resources_subscribe {
      res_caps["subscribe"] = Json::boolean(true)
    }
    obj["resources"] = Json::object(res_caps)
  }
  if self.prompts {
    let p : Map[String, Json] = { "listChanged": Json::boolean(true) }
    obj["prompts"] = Json::object(p)
  }
  if self.logging {
    obj["logging"] = Json::object({})
  }
  if self.completions {
    obj["completions"] = Json::object({})
  }
  Json::object(obj)
}

///|
/// Tool input schema (JSON Schema subset)
pub(all) struct ToolInputSchema {
  type_ : String
  properties : Json?
  required : Array[String]
}

///|
pub fn ToolInputSchema::to_json(self : ToolInputSchema) -> Json {
  let obj : Map[String, Json] = {}
  obj["type"] = Json::string(self.type_)
  match self.properties {
    Some(p) => obj["properties"] = p
    None => ()
  }
  if !self.required.is_empty() {
    obj["required"] = Json::array(self.required.map(s => Json::string(s)))
  }
  Json::object(obj)
}

///|
pub fn ToolInputSchema::empty() -> ToolInputSchema {
  { type_: "object", properties: Some(Json::object({})), required: [] }
}

///|
pub fn ToolInputSchema::with_schema(schema : Json) -> ToolInputSchema {
  match schema {
    Json::Object(obj) => {
      let type_ = match obj.get("type") {
        Some(Json::String(t)) => t
        _ => "object"
      }
      let properties = obj.get("properties")
      let required = match obj.get("required") {
        Some(Json::Array(arr)) =>
          arr.filter_map(j => {
            match j {
              Json::String(s) => Some(s)
              _ => None
            }
          })
        _ => []
      }
      { type_, properties, required }
    }
    _ => ToolInputSchema::empty()
  }
}

///|
/// Tool definition
pub(all) struct Tool {
  name : String
  description : String?
  input_schema : ToolInputSchema
}

///|
pub fn Tool::to_json(self : Tool) -> Json {
  let obj : Map[String, Json] = {}
  obj["name"] = Json::string(self.name)
  match self.description {
    Some(d) => obj["description"] = Json::string(d)
    None => ()
  }
  obj["inputSchema"] = self.input_schema.to_json()
  Json::object(obj)
}

///|
/// Content types for tool responses
pub(all) enum ContentBlock {
  Text(TextContent)
  Image(ImageContent)
  Audio(AudioContent)
  Resource(EmbeddedResource)
}

///|
pub fn ContentBlock::to_json(self : ContentBlock) -> Json {
  match self {
    Text(t) => t.to_json()
    Image(i) => i.to_json()
    Audio(a) => a.to_json()
    Resource(r) => r.to_json()
  }
}

///|
pub(all) struct TextContent {
  text : String
}

///|
pub fn TextContent::to_json(self : TextContent) -> Json {
  let obj : Map[String, Json] = {
    "type": Json::string("text"),
    "text": Json::string(self.text),
  }
  Json::object(obj)
}

///|
pub(all) struct ImageContent {
  data : String // base64
  mime_type : String
}

///|
pub fn ImageContent::to_json(self : ImageContent) -> Json {
  let obj : Map[String, Json] = {
    "type": Json::string("image"),
    "data": Json::string(self.data),
    "mimeType": Json::string(self.mime_type),
  }
  Json::object(obj)
}

///|
pub(all) struct AudioContent {
  data : String // base64
  mime_type : String
}

///|
pub fn AudioContent::to_json(self : AudioContent) -> Json {
  let obj : Map[String, Json] = {
    "type": Json::string("audio"),
    "data": Json::string(self.data),
    "mimeType": Json::string(self.mime_type),
  }
  Json::object(obj)
}

///|
pub(all) struct EmbeddedResource {
  uri : String
  mime_type : String?
  text : String?
  blob : String? // base64
}

///|
pub fn EmbeddedResource::to_json(self : EmbeddedResource) -> Json {
  let resource : Map[String, Json] = { "uri": Json::string(self.uri) }
  match self.mime_type {
    Some(m) => resource["mimeType"] = Json::string(m)
    None => ()
  }
  match self.text {
    Some(t) => resource["text"] = Json::string(t)
    None => ()
  }
  match self.blob {
    Some(b) => resource["blob"] = Json::string(b)
    None => ()
  }
  let outer : Map[String, Json] = {
    "type": Json::string("resource"),
    "resource": Json::object(resource),
  }
  Json::object(outer)
}

///|
/// Tool call result
pub(all) struct ToolResult {
  content : Array[ContentBlock]
  is_error : Bool
}

///|
pub fn ToolResult::to_json(self : ToolResult) -> Json {
  let obj : Map[String, Json] = {}
  obj["content"] = Json::array(self.content.map(c => c.to_json()))
  if self.is_error {
    obj["isError"] = Json::boolean(true)
  }
  Json::object(obj)
}

///|
pub fn ToolResult::ok(content : Array[ContentBlock]) -> ToolResult {
  { content, is_error: false }
}

///|
pub fn ToolResult::error(message : String) -> ToolResult {
  { content: [Text({ text: message })], is_error: true }
}

///|
/// Resource definition
pub(all) struct Resource {
  uri : String
  name : String
  description : String?
  mime_type : String?
}

///|
pub fn Resource::to_json(self : Resource) -> Json {
  let obj : Map[String, Json] = {
    "uri": Json::string(self.uri),
    "name": Json::string(self.name),
  }
  match self.description {
    Some(d) => obj["description"] = Json::string(d)
    None => ()
  }
  match self.mime_type {
    Some(m) => obj["mimeType"] = Json::string(m)
    None => ()
  }
  Json::object(obj)
}

///|
/// Resource template definition
pub(all) struct ResourceTemplate {
  uri_template : String
  name : String
  description : String?
  mime_type : String?
}

///|
pub fn ResourceTemplate::to_json(self : ResourceTemplate) -> Json {
  let obj : Map[String, Json] = {
    "uriTemplate": Json::string(self.uri_template),
    "name": Json::string(self.name),
  }
  match self.description {
    Some(d) => obj["description"] = Json::string(d)
    None => ()
  }
  match self.mime_type {
    Some(m) => obj["mimeType"] = Json::string(m)
    None => ()
  }
  Json::object(obj)
}

///|
/// Resource content
pub(all) struct ResourceContent {
  uri : String
  mime_type : String?
  text : String?
  blob : String? // base64
}

///|
pub fn ResourceContent::to_json(self : ResourceContent) -> Json {
  let obj : Map[String, Json] = { "uri": Json::string(self.uri) }
  match self.mime_type {
    Some(m) => obj["mimeType"] = Json::string(m)
    None => ()
  }
  match self.text {
    Some(t) => obj["text"] = Json::string(t)
    None => ()
  }
  match self.blob {
    Some(b) => obj["blob"] = Json::string(b)
    None => ()
  }
  Json::object(obj)
}

///|
/// Prompt argument definition
pub(all) struct PromptArgument {
  name : String
  description : String?
  required : Bool
}

///|
pub fn PromptArgument::to_json(self : PromptArgument) -> Json {
  let obj : Map[String, Json] = { "name": Json::string(self.name) }
  match self.description {
    Some(d) => obj["description"] = Json::string(d)
    None => ()
  }
  if self.required {
    obj["required"] = Json::boolean(true)
  }
  Json::object(obj)
}

///|
/// Prompt definition
pub(all) struct Prompt {
  name : String
  description : String?
  arguments : Array[PromptArgument]
}

///|
pub fn Prompt::to_json(self : Prompt) -> Json {
  let obj : Map[String, Json] = { "name": Json::string(self.name) }
  match self.description {
    Some(d) => obj["description"] = Json::string(d)
    None => ()
  }
  if !self.arguments.is_empty() {
    obj["arguments"] = Json::array(self.arguments.map(a => a.to_json()))
  }
  Json::object(obj)
}

///|
/// Prompt message role
pub(all) enum Role {
  User
  Assistant
}

///|
pub fn Role::to_json(self : Role) -> Json {
  match self {
    User => Json::string("user")
    Assistant => Json::string("assistant")
  }
}

///|
/// Prompt message content - can be text, image, or embedded resource
pub(all) enum PromptContent {
  Text(TextContent)
  Image(ImageContent)
  Resource(EmbeddedResource)
}

///|
pub fn PromptContent::to_json(self : PromptContent) -> Json {
  match self {
    Text(t) => t.to_json()
    Image(i) => i.to_json()
    Resource(r) => r.to_json()
  }
}

///|
/// A single message in a prompt result
pub(all) struct PromptMessage {
  role : Role
  content : PromptContent
}

///|
pub fn PromptMessage::to_json(self : PromptMessage) -> Json {
  let obj : Map[String, Json] = {
    "role": self.role.to_json(),
    "content": self.content.to_json(),
  }
  Json::object(obj)
}

///|
/// Prompt result
pub(all) struct PromptResult {
  description : String?
  messages : Array[PromptMessage]
}

///|
pub fn PromptResult::to_json(self : PromptResult) -> Json {
  let obj : Map[String, Json] = {}
  match self.description {
    Some(d) => obj["description"] = Json::string(d)
    None => ()
  }
  obj["messages"] = Json::array(self.messages.map(m => m.to_json()))
  Json::object(obj)
}

///|
/// Log levels
pub(all) enum LogLevel {
  Debug
  Info
  Notice
  Warning
  Error
  Critical
  Alert
  Emergency
} derive(Eq, Compare)

///|
pub fn LogLevel::to_json(self : LogLevel) -> Json {
  match self {
    Debug => Json::string("debug")
    Info => Json::string("info")
    Notice => Json::string("notice")
    Warning => Json::string("warning")
    Error => Json::string("error")
    Critical => Json::string("critical")
    Alert => Json::string("alert")
    Emergency => Json::string("emergency")
  }
}

///|
pub fn LogLevel::from_string(s : String) -> LogLevel? {
  match s {
    "debug" => Some(Debug)
    "info" => Some(Info)
    "notice" => Some(Notice)
    "warning" => Some(Warning)
    "error" => Some(Error)
    "critical" => Some(Critical)
    "alert" => Some(Alert)
    "emergency" => Some(Emergency)
    _ => None
  }
}

///|
/// Completion result
pub(all) struct CompletionResult {
  values : Array[String]
  total : Int?
  has_more : Bool
}

///|
pub fn CompletionResult::to_json(self : CompletionResult) -> Json {
  let obj : Map[String, Json] = {}
  obj["values"] = Json::array(self.values.map(s => Json::string(s)))
  match self.total {
    Some(t) => obj["total"] = Json::number(t.to_double())
    None => ()
  }
  if self.has_more {
    obj["hasMore"] = Json::boolean(true)
  }
  Json::object(obj)
}

///|
pub fn CompletionResult::empty() -> CompletionResult {
  { values: [], total: Some(0), has_more: false }
}

///|
/// Helper to get a string field from a JSON object
pub fn get_string(obj : Map[String, Json], key : String) -> String? {
  match obj.get(key) {
    Some(Json::String(s)) => Some(s)
    _ => None
  }
}

///|
/// Helper to get a JSON object field
pub fn get_obj(obj : Map[String, Json], key : String) -> Map[String, Json]? {
  match obj.get(key) {
    Some(Json::Object(o)) => Some(o)
    _ => None
  }
}

///|
/// Helper to get an array field from a JSON object
pub fn get_array(obj : Map[String, Json], key : String) -> Array[Json]? {
  match obj.get(key) {
    Some(Json::Array(a)) => Some(a)
    _ => None
  }
}
