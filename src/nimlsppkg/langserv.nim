from os import getCurrentCompilerExe, parentDir, `/`
from uri import Uri
from tables import OrderedTableRef, `[]=`, pairs, newOrderedTable, len
from strutils import `%`, join, parseInt

import stdiodriver
import baseprotocol

include messages

type
# Common Types
  Version* = distinct string
  RawFrame* = string

#                                                                        +----------------------+
#                                                                        |                      |
#                                                                        |  nimsuggest process  |
#                                                                        |                      |
#                                                                        +----------------------+
#
#                       Channel Pair
# +-------------------+              +-------------------+               +----------------------+
# |                   | +----------> |                   |               |                      |
# |  Language Client  |              |  Language Server  |               |  nimsuggest process  |
# |                   | <----------+ |                   |               |                      |
# +-------------------+              +-------------------+               +----------------------+
#
#                                                                        +----------------------+
#                                                                        |                      |
#                                                                        |      nimpretty       |
#                                                                        |                      |
#                                                                        +----------------------+

# Server Types
  IdSeq = uint32
  Id = uint32

  ProtocolStage* {.pure.} = enum
    # Represents the lifecycle of the LSP
    # see: https://github.com/microsoft/language-server-protocol/issues/227
    uninitialized, ## started but haven't received initialize
    initializing, ## successful initialize, awaiting initialized notification
    initialized, ## receieved initialized notification
    shuttingdown, ## received shutdown request, doing shut down work
    stopped ## done shut down work, awaiting exit notification
  ProtocolCapability* {.pure, size: sizeof(int32).} = enum
    capWorkspaceFolders
      ## workspaces with multiple root folders
    # capWorkspaceConfig,
    #  ## `workspace/configuration` requests
    # capDiagnosticRelatedInfo
    #  ## `relatedInformation` in `Diagnostic`
  ProtocolCapabilities* = set[ProtocolCapability]

  Progress {.pure.} = enum
    abort, failed, no, yes

  ReceivedFrame = object
    frameId*: Id
    frame*: TaintedString
  PendingFrame = object
    frameId*: Id
    frame*: RawFrame

  ProtocolClient* = ref object
    capabilities*: ClientCapabilities
    framesReceived*: seq[ReceivedFrame]
    framesPending*: seq[PendingFrame]
    driver: ClientDriver
    initParams*: InitializeParams
  Protocol = ref object
    stage*: ProtocolStage
    capabilities*: ProtocolCapabilities
    client*: ProtocolClient
    rootUri*: Option[Uri]
    gotShutdownMsg*: bool

  LogMsg = tuple
    file: string
    line: int
    level: MessageType
    msg: string

  NimPath* = distinct string
  ServerVersion* = Version
  ServerStartParams* = object
    nimpath*: NimPath
    version*: ServerVersion

  Server = object
    startParams*: ServerStartParams
    protocol*: Protocol
    idSeq*: IdSeq
    currId: Id
      ## id we're currently processing, acts as a context

proc nextId(s: var Server): Id =
  inc s.idSeq
  result = s.idSeq
  s.currId = result

proc debugLog(l: LogMsg) =
  # TODO - check log levels
  stderr.write("$1 - $2:$3: $4\n" % [$l.level, l.file, $l.line, l.msg])

template debugLog(args: varargs[string, `$`]) =
  let pos = instantiationInfo()
  debugLog((file: pos.filename, line: pos.line, level: Log, msg: join args))

proc recvDriverInput(s: var Server) =
  var c = s.protocol.client
  let tried = c.driver.recv[].tryRecv()
  if tried.dataAvailable:
    case tried.msg.kind
    of MsgKind.recv:
      let id = s.nextId
      c.framesReceived.add ReceivedFrame(frameId: id, frame: tried.msg.frame)
    of MsgKind.sent, MsgKind.recvErr, MsgKind.sendErr:
      debugLog($tried.msg)

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

proc error(
    server: Server,
    request: RequestMessage,
    errorCode: ErrorCode,
    message: string,
    data: JsonNode
  ) =
  server.protocol.client.framesPending.add PendingFrame(
    frameId: server.currId,
    frame: jsonToFrame create(
        ResponseMessage,
        "2.0",
        parseId(request["id"]),
        none(JsonNode),
        some(create(ResponseError, cast[int](errorCode), message, data))
      ).JsonNode
  )

proc error(
    server: Server,
    errorCode: ErrorCode,
    message: string
  ) =
  server.protocol.client.framesPending.add PendingFrame(
    frameId: server.currId,
    frame: jsonToFrame create(
        ResponseMessage,
        "2.0",
        Nil,
        none(JsonNode),
        some(create(ResponseError, cast[int](errorCode), message, newJNull()))
      ).JsonNode
  )

proc respond(
    server: Server,
    id: int,
    data: JsonNode
  ) =
  server.protocol.client.framesPending.add PendingFrame(
    frameId: server.currId,
    frame: jsonToFrame create(
      ResponseMessage,
      "2.0",
      id,
      some(data),
      none(ResponseError)
    ).JsonNode
  )

proc respond(
    server: Server,
    request: RequestMessage,
    data: JsonNode
  ) =
  server.respond(parseId(request["id"]), data)

proc serverCapabilities(): ServerCapabilities =
  result = create(ServerCapabilities,
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

template whenValid(data, kind, body) {.dirty.} =
  if data.isValid(kind, allowExtra = true):
    var data = kind(data)
    body
  else:
    debugLog "Unable to parse data as " & $kind

template whenValid(data, kind, body, elseblock) {.dirty.} =
  if data.isValid(kind, allowExtra = true):
    var data = kind(data)
    body
  else:
    elseblock

proc processRequestUninitialized(server: var Server, message: JsonNode) =
  ## only call this method if the server's lspState is uninitialized

  whenValid(message, RequestMessage):
    debugLog "Got valid Request message of type " & message["method"].getStr
    if message["method"].getStr != "initialize":
      debugLog "Server uninitialized, only initialize request is allowed"
      server.error(
        message,
        ServerNotInitialized,
        "Unable to accept requests before being initialized", newJNull()
      )
    elif message["params"].isSome:
      debugLog "Got initialize request, answering"
      let params = message["params"].unsafeGet
      whenValid(params, InitializeParams):
        server.protocol.client.initParams = params

        params["clientInfo"].map do (c: JsonNode) -> void:
          whenValid(c, ClientInfo):
            debugLog ("Client name: " & c["name"].getStr & " version: " &
              c["version"].get(nil).getStr "unknown")

        # Negotiate Capabilities - start
        let caps = params["capabilities"]
        whenValid(caps, ClientCapabilities) do:
          server.protocol.client.capabilities = caps
          if caps["workspace"].isSome:
            var ws = WorkspaceClientCapabilities(caps["workspace"].unsafeGet)
            # if ws["configuration"].get(newJBool(false)).getBool(false):
            #   incl(server.protocol.capabilities, capWorkspaceConfig)
            if ws["workspaceFolders"].get(newJBool(false)).getBool(false):
              incl(server.protocol.capabilities, capWorkspaceFolders)
          # if caps["textDocument"].isSome:
          #   var td = TextDocumentClientCapabilities(caps["textDocument"].unsafeGet)
          #   if td["publishDiagnostics"].isSome:
          #     var pd = PublishDiagnosticsClientCapabilities(td["publishDiagnostics"].unsafeGet)
          #     if pd["relatedInformation"].get(newJBool(false)).getBool(false):
          #       incl(server.protocol.capabilities, capDiagnosticRelatedInfo)

        var serverCaps = serverCapabilities()
        debugLog "Client capabilities " & $server.protocol.capabilities
        if capWorkspaceFolders in server.protocol.capabilities:
          serverCaps.JsonNode["workspace"] =
            create(WorkspaceCapability,
              workspaceFolders = some(create(WorkspaceFoldersServerCapabilities,
                supported = some(true),
                changeNotifications = some(true)
              ))
            ).JsonNode
        # Negotiate Capabilities - end

        server.protocol.stage = initializing

        debugLog "Initializing server, awaiting 'initialized' notification"
        server.respond(
          message,
          create(InitializeResult, serverCaps).JsonNode
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
    debugLog "Got valid Notification message of type " & message["method"].getStr
    if message["method"].getStr == "exit":
      debugLog "Exiting"
      quit (if server.protocol.gotShutdownMsg: 0 else: 1)

  debugLog "Unhandled message while uninitilized: " & repr(message)

proc processRequestInitializing(server: var Server, message: JsonNode) =
  ## only call this method if the server's lspState is initializing
  
  whenValid(message, RequestMessage):
    debugLog "Expected 'initialized' notification, got message of type " &
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
      server.protocol.stage = initialized
      debugLog "Server initialized with params " & repr(message["params"])
    else:
      debugLog "Ignoring client notification of type " & message["method"].getStr
    return
  debugLog "Unhandled message while uninitilized: " & repr(message)

proc processRequest(server: var Server): Progress =
  try:
    # TODO - periodically check parent PID and exit if dead
    debugLog "Trying to read frame"
    if server.protocol.client.framesReceived.len == 0:
      return Progress.no

    let
      client = server.protocol.client
      frame = client.framesReceived.pop.frame
    debugLog "Got frame:\n" & frame
    let message = frame.parseJson

    case server.protocol.stage
    of uninitialized:
      server.processRequestUninitialized(message)
    of initializing:
      server.processRequestInitializing(message)
    of initialized, shuttingdown, stopped:
      discard
    # of initialized:
    #   server.processRequestInitialized(message)
    # of shuttingdown:
    #   server.processRequestInitialized(message)
    # of stopped:
    #   server.processRequestInitialized(message)
  except IOError as e:
    debugLog "IOError exception: ", e.msg
    return Progress.abort
  except InvalidRequestId as e:
    debugLog e.msg

    server.error(InvalidRequest, e.msg)
    return Progress.failed
  except MalformedFrame as e:
    debugLog "MalformedFrame exception (unrecoverable): ", e.msg
    # Exit because a stream error like this is unrecoverable
    # should stop listening, processing, dispose resources, and exit
    return Progress.abort
  except CatchableError as e:
    debugLog "Got exception: ", e.msg
    return Progress.failed

  return Progress.yes

when isMainModule:
  # nim c -r --threads:on --outDir:out src/nimlsppkg/langserv.nim

  from streams import newStringStream
  from baseprotocol import stringToFrame

  var
    clientMsgs: Channel[Msg]
    msgsToClient: Channel[Send]
    clientDriver = initClientDriver(
      msgsToClient.addr,
      clientMsgs.addr,
      newStringStream(""),
      newStringStream("")
    )
    server = Server(
      startParams: ServerStartParams(
        nimpath: NimPath(getCurrentCompilerExe().parentDir.parentDir),
        version: Version("0.0.1")
      ),
      protocol: Protocol(
        stage: uninitialized,
        capabilities: {},
        client: ProtocolClient(
          framesReceived: newSeqOfCap[ReceivedFrame](100),
          framesPending: newSeqOfCap[PendingFrame](100),
          driver: clientDriver
        )
      )
    )
  
  clientMsgs.open(100)
  clientMsgs.send Msg(
    meta: MsgMeta(count: 1),
    kind: MsgKind.recv,
    frame: $create(
      RequestMessage, "2.0", 0, "initialize",
      some(create(InitializeParams,
        processId = 1337,
        clientInfo = none(ClientInfo),
        rootPath = none(string),
        rootUri = "file:///tmp",
        initializationOptions = none(JsonNode),
        capabilities = create(ClientCapabilities,
          workspace = none(WorkspaceClientCapabilities),
          textDocument = none(TextDocumentClientCapabilities),
          experimental = none(JsonNode)
        ),
        trace = none(string),
        workspaceFolders = none(seq[WorkspaceFolder])
      ).JsonNode)).JsonNode
  )

  clientMsgs.send Msg(
    meta: MsgMeta(count: 2),
    kind: MsgKind.recv,
    frame: $create(NotificationMessage, "2.0", "initialized", none(JsonNode)).JsonNode
  )

  server.recvDriverInput()
  while server.processRequest() == yes:
    server.recvDriverInput()
  # for f in server.protocol.client.framesReceived:
  #   debugLog("key: " & $f.frameId & " value: " & f.frame)
