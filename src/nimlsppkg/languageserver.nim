include messages

from streams import newFileStream, Stream
from baseprotocol import readFrame, sendJson, InvalidRequestId, MalformedFrame
from strutils import join, parseInt
from messageenums import TextDocumentSyncKind

type
  NimPath* = string
  ServerVersion* = string
  IdSeq* = int

  ServerStartParams* = object
    nimpath*: NimPath
    version*: ServerVersion
  
  LspState* {.pure.} = enum
    uninitialized, initializing, initialized, shuttingdown, stopped

  InputStream = Stream
  OutputStream = Stream

  ClientCap* {.pure, size: sizeof(int).} = enum
    capWorkspaceConfig, capWorkspaceFolder, capDiagnosticRelatedInfo
  ClientCaps* = set[ClientCap]

  ServerState = ref object
    lspState*: LspState
    idSeq*: IdSeq
    gotShutdownMsg*: bool
    getFromClient*: OutputStream
    sendToClient*: InputStream
    initParams*: InitializeParams
    rawClientCapabilities*: ClientCapabilities
    clientCaps*: ClientCaps

  LanguageServer* = object
    startParams*: ServerStartParams
    state: ServerState

let
  serverCapabilities* = create(ServerCapabilities,
    textDocumentSync = some(create(TextDocumentSyncOptions,
      openClose = some(true),
      change = some(TextDocumentSyncKind.Full.int),
      willSave = some(true),
      willSaveWaitUntil = some(true),
      save = some(create(SaveOptions, includeText = some(true))),
    )),
    completionProvider = some(create(CompletionOptions,
      resolveProvider = some(true),
      allCommitCharacters = none(seq[string]),
      triggerCharacters = some(@[".", " "])
    )),
    hoverProvider = some(true),
    signatureHelpProvider = some(create(SignatureHelpOptions,
      triggerCharacters = some(@["(", " "]),
      retriggerCharacters = some(@[","])
    )),
    declarationProvider = none(bool),
    definitionProvider = some(true),
    typeDefinitionProvider = none(bool),
    implementationProvider = none(bool),
    referencesProvider = some(true),
    documentHighlightProvider = none(bool),
    documentSymbolProvider = some(true),
    codeActionProvider = none(bool),
    codeLensProvider = none(CodeLensOptions),
    documentLinkProvider = none(DocumentLinkOptions),
    colorProvider = none(bool),
    documentFormattingProvider = some(true),
    documentRangeFormattingProvider = none(bool),
    documentOnTypeFormattingProvider = none(DocumentOnTypeFormattingOptions),
    renameProvider = some(true),
    foldingRangeProvider = none(bool),
    executeCommandProvider = none(ExecuteCommandOptions),
    selectionRangeProvider = none(bool),
    workspaceSymbolProvider = some(true),
    workspace = none(WorkspaceCapability),
    experimental = none(JsonNode)
  )

template debugEcho*(args: varargs[string, `$`]) =
  when defined(debugLogging):
    stderr.write(join args)
    stderr.write("\n")

proc initServer*(
  nimpath: NimPath,
  version: ServerVersion,
  cis: Stream = newFileStream(stdOut),
  cos: Stream = newFileStream(stdIn)
): LanguageServer =
  result = LanguageServer(
    startParams: ServerStartParams(nimpath: nimpath, version: version),
    state: ServerState(
      lspState: uninitialized,
      idSeq: 0,
      getFromClient: cos,
      sendToClient: cis,
      gotShutdownMsg: false,
      clientCaps: {}
    )
  )

template whenValid(data, kind, body) {.dirty.} =
  if data.isValid(kind, allowExtra = true):
    var data = kind(data)
    body
  else:
    debugEcho("Unable to parse data as " & $kind)

template whenValid(data, kind, body, elseblock) {.dirty.} =
  if data.isValid(kind, allowExtra = true):
    var data = kind(data)
    body
  else:
    elseblock

proc parseId(node: JsonNode): int =
  # TODO - confirm whether expecting id to be an int is valid

  if node.kind == JString:
    parseInt(node.getStr)
  elif node.kind == JInt:
    node.getInt
  else:
    var e = newException(InvalidRequestId, "Invalid id node: " & repr(node))
    e.id = node
    raise e

proc respond(
    server: LanguageServer,
    id: int,
    data: JsonNode
  ) =
  server.state.sendToClient.sendJson create(
    ResponseMessage,
    "2.0",
    id,
    some(data),
    none(ResponseError)
  ).JsonNode

proc respond(
    server: LanguageServer,
    request: RequestMessage,
    data: JsonNode
  ) =
  server.respond(parseId(request["id"]), data)

proc error(
    server: LanguageServer,
    request: RequestMessage,
    errorCode: ErrorCode,
    message: string,
    data: JsonNode
  ) =
  server.state.sendToClient.sendJson create(
      ResponseMessage,
      "2.0",
      parseId(request["id"]),
      none(JsonNode),
      some(create(ResponseError, cast[int](errorCode), message, data))
    ).JsonNode

proc error(
    server: LanguageServer,
    errorCode: ErrorCode,
    message: string
  ) =
  server.state.sendToClient.sendJson create(
      ResponseMessage,
      "2.0",
      Nil,
      none(JsonNode),
      some(create(ResponseError, cast[int](errorCode), message, newJNull()))
    ).JsonNode

proc processInputUninitialized(server: LanguageServer, message: JsonNode) =
  ## only call this method if the server's lspState is uninitialized

  whenValid(message, RequestMessage):
    debugEcho "Got valid Request message of type " & message["method"].getStr
    if message["method"].getStr != "initialize":
      debugEcho "Server uninitialized, only initialize request is allowed"
      server.error(
        message,
        ServerNotInitialized,
        "Unable to accept requests before being initialized", newJNull()
      )
    elif message["params"].isSome:
      debugEcho "Got initialize request, answering"
      let params = message["params"].unsafeGet
      whenValid(params, InitializeParams):
        server.state.initParams = params

        params["clientInfo"].map do (c: JsonNode) -> void:
          whenValid(c, ClientInfo):
            debugEcho "Client name: " & c["name"].getStr & " version: " &
              c["version"].get(nil).getStr "unknown"

        # Negotiate Capabilities - start
        let caps = params["capabilities"]
        whenValid(caps, ClientCapabilities) do:
          server.state.rawClientCapabilities = caps
          if caps["workspace"].isSome:
            var ws = WorkspaceClientCapabilities(caps["workspace"].unsafeGet)
            if ws["configuration"].get(newJBool(false)).getBool(false):
              incl(server.state.clientCaps, capWorkspaceConfig)
            if ws["workspaceFolders"].get(newJBool(false)).getBool(false):
              incl(server.state.clientCaps, capWorkspaceFolder)
          if caps["textDocument"].isSome:
            var td = TextDocumentClientCapabilities(caps["textDocument"].unsafeGet)
            if td["publishDiagnostics"].isSome:
              var pd = PublishDiagnosticsClientCapabilities(td["publishDiagnostics"].unsafeGet)
              if pd["relatedInformation"].get(newJBool(false)).getBool(false):
                incl(server.state.clientCaps, capDiagnosticRelatedInfo)

          if capWorkspaceFolder in server.state.clientCaps:
            cast[var JsonNode](serverCapabilities["workspace"]) = 
              create(WorkspaceCapability,
                workspaceFolders = some(create(WorkspaceFoldersServerCapabilities,
                  supported = some(true),
                  changeNotifications = some(true)
                ))
              ).JsonNode
          # Negotiate Capabilities - end

          server.state.lspState = initializing

          debugEcho "Initializing server, awaiting 'initialized' notification"
          server.respond(
            message,
            create(InitializeResult, serverCapabilities).JsonNode
          )
          return

      server.error(
        message,
        InvalidParams,
        "Invalid initialization parameters or client capabilities",
        create(InitializeError, retry = false).JsonNode
      )
    return
  whenValid(message, NotificationMessage):
    debugEcho "Got valid Notification message of type " & message["method"].getStr
    if message["method"].getStr == "exit":
      debugEcho "Exiting"
      quit (if server.state.gotShutdownMsg: 0 else: 1)

  debugEcho "Unhandled message while uninitilized: " & repr(message)

proc processInputInitializing(server: LanguageServer, message: JsonNode) =
  ## only call this method if the server's lspState is initializing
  
  whenValid(message, RequestMessage):
    debugEcho "Expected 'initialized' notification, got message of type " &
      message["method"].getStr
    server.error(
        message,
        ServerNotInitialized,
        "Initialized notification not received from client",
        newJNull()
      )
    return
  whenValid(message, NotificationMessage):
    case message["method"].getStr
    of "initialized":
      server.state.lspState = initialized
      debugEcho "Server initialized with params " & repr(message["params"])
    else:
      debugEcho "Ignoring client notification of type " & message["method"].getStr
    return
  debugEcho "Unhandled message while uninitilized: " & repr(message)

proc processInputInitialized(server: LanguageServer, message: JsonNode) =
  ## only call this method if the server's lspState is initialized

  debugEcho("Got message: " & repr(message))
  server.respond(try: parseId(message["id"]) except: -1, message)

proc process(server: LanguageServer): bool = 
  try:
    # TODO - periodically check parent PID and exist if dead
    debugEcho "Trying to read frame"
    let frame = server.state.getFromClient.readFrame
    debugEcho "Got frame:\n" & frame
    let message = frame.parseJson

    case server.state.lspState
    of uninitialized:
      server.processInputUninitialized(message)
    of initializing:
      server.processInputInitializing(message)
    of initialized:
      server.processInputInitialized(message)
    of shuttingdown:
      server.processInputInitialized(message)
    of stopped:
      server.processInputInitialized(message)
  except IOError as e:
    debugEcho "IOError exception: ", e.msg
    return false
  except InvalidRequestId as e:
    debugEcho e.msg

    server.error(InvalidRequest, e.msg)
    return true
  except MalformedFrame as e:
    debugEcho "MalformedFrame exception (unrecoverable): ", e.msg
    # Exit because a stream error like this is unrecoverable
    # should stop listening, processing, dispose resources, and exit
    return false
  except CatchableError as e:
    debugEcho "Got exception: ", e.msg
    return true

  return true

when defined(testing): export process

proc start*(server: LanguageServer) =
  var loop = true
  while loop:
    loop = server.process