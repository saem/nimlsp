from os import getCurrentCompilerExe, parentDir, `/`, getConfigDir,
               expandTilde, getEnv, existsEnv, existsOrCreateDir,
               ReadEnvEffect, splitFile, fileExists, addFileExt, walkFiles,
               isRelativeTo
from osproc import execProcess
from uri import Uri, decodeUrl
from tables import OrderedTableRef, `[]=`, pairs, newOrderedTable, len
from strutils import `%`, join, parseInt, toHex, startsWith, splitLines
from sugar import `=>`
from hashes import hash

import stdiodriver
import baseprotocol

include messages

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

type
# Common Types
  Version* = distinct string
  RawFrame* = string

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
  ServerMode* {.pure.} = enum
    smSingleFile, smFolder

  Server = object
    startParams*: ServerStartParams
    mode*: ServerMode
    rootUri*: string
    protocol*: Protocol
    storage*: string
    idSeq*: IdSeq
    currId: Id
      ## id we're currently processing, acts as a context

proc getTempDir*(): string {.tags: [ReadEnvEffect, ReadIOEffect].} =
  ## Temp dir handling in nim standard library is out of date
  ##
  ## references for linux handling:
  ## * https://specifications.freedesktop.org/basedir-spec/basedir-spec-latest.html
  ## * https://maex.me/2019/12/the-power-of-the-xdg-base-directory-specification/
  result = when defined(tempDir):
      const tempDir {.strdefine.}: string = "/tmp"
      tempDir
    elif defined(windows): string(getEnv("TEMP"))
    elif defined(macos): string(getEnv("TMPDIR", "/tmp"))
    else: getEnv("XDG_CACHE_HOME", expandTilde("~/.cache")).string

proc pathToUri(path: string): string =
  # This is a modified copy of encodeUrl in the uri module. This doesn't encode
  # the / character, meaning a full file path can be passed in without breaking
  # it.
  result = newStringOfCap(path.len + path.len shr 2) # assume 12% non-alnum-chars
  for c in path:
    case c
    # https://tools.ietf.org/html/rfc3986#section-2.3
    of 'a'..'z', 'A'..'Z', '0'..'9', '-', '.', '_', '~', '/': add(result, c)
    else:
      add(result, '%')
      add(result, toHex(ord(c), 2))

type Certainty {.pure.} = enum
  None,
  Folder,
  Cfg,
  Nimble

proc getProjectFile(s: Server, fileUri: string): string =
  let
    file = fileUri.decodeUrl
    endPath = if s.mode == smFolder and fileUri.startsWith(s.rootUri):
        s.rootUri.decodeUrl
      else:
        "/"
    (dir, _, _) = result.splitFile()
  result = file
  var
    path = dir
    certainty = Certainty.None
  while path.len > 0 and path != endPath:
    let
      (dir, fname, ext) = path.splitFile()
      current = fname & ext
    if fileExists(path / current.addFileExt(".nim")) and
      certainty <= Certainty.Folder:
        result = path / current.addFileExt(".nim")
        certainty = Certainty.Folder
    if fileExists(path / current.addFileExt(".nim")) and
      (fileExists(path / current.addFileExt(".nim.cfg")) or
      fileExists(path / current.addFileExt(".nims"))) and certainty <= Cfg:
      result = path / current.addFileExt(".nim")
      certainty = Cfg
    if certainty <= Nimble:
      for nimble in walkFiles(path / "*.nimble"):
        let info = execProcess("nimble dump " & nimble)
        var sourceDir, name: string
        for line in info.splitLines:
          if line.startsWith("srcDir"):
            sourceDir = path / line[(1 + line.find '"')..^2]
          if line.startsWith("name"):
            name = line[(1 + line.find '"')..^2]
        let projectFile = sourceDir / (name & ".nim")
        if sourceDir.len != 0 and name.len != 0 and
            file.isRelativeTo(sourceDir) and fileExists(projectFile):
          result = projectFile
          certainty = Nimble
    path = dir

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

proc error(server: Server, request: RequestMessage, errorCode: ErrorCode,
           message: string, data: JsonNode = newJNull()) =
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

proc error(server: Server, errorCode: ErrorCode, message: string) =
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

proc respond(server: Server, id: int, data: JsonNode) =
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

proc respond(server: Server, request: RequestMessage, data: JsonNode) =
  server.respond(parseId(request["id"]), data)

proc serverCapabilities(): ServerCapabilities =
  result = create(ServerCapabilities,
    textDocumentSync = some(create(TextDocumentSyncOptions,
      openClose = some(true),
      change = some(TextDocumentSyncKind.Full.int),
      willSave = some(true),
      willSaveWaitUntil = some(false),
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

        let root = params["rootUri"].getStr(
          params["rootPath"].filter((r) => r != nil)
            .map((r) => pathToUri(r.getStr()))
            .get(""))
        if root == "":
          server.mode = smSingleFile
          debugLog("Server in single file mode")
        else:
          server.mode = smFolder
          server.rootUri = root
          debugLog("Server in folder mode, root set to: ", root)

        # Negotiate Capabilities - start
        let caps = params["capabilities"]
        whenValid(caps, ClientCapabilities) do:
          server.protocol.client.capabilities = caps
          # TODO - support multiple workspace folders
          # if caps["workspace"].map((j) => WorkspaceClientCapabilities(j))
          #   .map((w) => w["workspaceFolders"])
          #   .flatten()
          #   .map((w) => w.getBool)
          #   .get(false):
          #     incl(server.protocol.capabilities, capWorkspaceFolders)

        var serverCaps = serverCapabilities()
        debugLog "Client capabilities " & $server.protocol.capabilities
        # TODO - support multiple workspace folders
        # if capWorkspaceFolders in server.protocol.capabilities:
        #   serverCaps.JsonNode["workspace"] =
        #     create(WorkspaceCapability,
        #       workspaceFolders = some(create(WorkspaceFoldersServerCapabilities,
        #         supported = some(true),
        #         changeNotifications = some(true)
        #       ))
        #     ).JsonNode
        # Negotiate Capabilities - end

        server.protocol.stage = initializing

        debugLog "Initializing server, awaiting 'initialized' notification"
        server.respond(
          message,
          create(InitializeResult, serverCaps).JsonNode
        )

        # do the initializing work
        discard existsOrCreateDir(server.storage)

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
    server.error(message, ServerNotInitialized,
                 "Initialized notification not received from client")
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

template textDocumentRequest(server, message, kind, name, body) {.dirty.} =
  if message["params"].isSome:
    let name = message["params"].unsafeGet
    whenValid(name, kind):
      let
        fileuri = name["textDocument"]["uri"].getStr
        filestash = server.storage / (hash(fileuri).toHex & ".nim" )
      debugLog "Got request for URI: ", fileuri, " copied to " & filestash
      let
        rawLine = name["position"]["line"].getInt
        rawChar = name["position"]["character"].getInt
      body

template textDocumentNotification(server, message, kind, name, body) {.dirty.} =
  if message["params"].isSome:
    let name = message["params"].unsafeGet
    whenValid(name, kind):
      if name["textDocument"]{"languageId"}.getStr("nim") == "nim":
        let
          fileuri = name["textDocument"]["uri"].getStr
          filestash = server.storage / (hash(fileuri).toHex & ".nim" )
        body

proc processRequestInitialized(server: Server, message: JsonNode) =
  ## only call this method if the server's lspState is initialized

  debugLog "Got message"
  whenValid(message, NotificationMessage):
    let msgMethod = message["method"].getStr
    debugLog "Notification method: " & msgMethod
    case msgMethod
    of "DidChangeConfigurationParams":
      var params = message["params"].get(newJNull())
      whenValid(params, DidChangeConfigurationParams):
        var settings = params["settings"]{"nim"}
        debugLog "Got settings: " & repr(settings)
    of "textDocument/didOpen":
      message["params"].filter((p) => p.isValid(DidOpenTextDocumentParams))
        .map((p) => DidOpenTextDocumentParams(p))
        .map((p) => TextDocumentItem(p["textDocument"])["uri"].getStr)
        .map(proc(uri: string) = debugLog "uri: " & uri)
    of "textDocument/didChange":
      message["params"].filter((p) => p.isValid(DidChangeTextDocumentParams))
        .map((p) => DidChangeTextDocumentParams(p))
        .map((p) => VersionedTextDocumentIdentifier(p["textDocument"])["uri"].getStr)
        .map(proc(uri: string) = debugLog "uri: " & uri)
    of "textDocument/didClose":
      message["params"].filter((p) => p.isValid(DidCloseTextDocumentParams))
        .map((p) => DidCloseTextDocumentParams(p))
        .map((p) => TextDocumentIdentifier(p["textDocument"])["uri"].getStr)
        .map(proc(uri: string) = debugLog "uri: " & uri)
    of "textDocument/didSave":
      message["params"].filter((p) => p.isValid(DidSaveTextDocumentParams))
        .map((p) => DidSaveTextDocumentParams(p))
        .map((p) => TextDocumentIdentifier(p["textDocument"])["uri"].getStr)
        .map(proc(uri: string) = debugLog "uri: " & uri)
    return

  debugLog "Got message that wasn't handled: " & repr(message)
  server.respond(try: parseId(message["id"]) except: -1, message)

proc processRequest(server: var Server): Progress =
  try:
    # TODO - periodically check parent PID and exit if dead
    debugLog "Trying to read frame"
    if server.protocol.client.framesReceived.len == 0:
      return Progress.no

    let
      client = server.protocol.client
      frame = client.framesReceived.pop.frame
    debugLog "Got frame:\n" & (if frame.len > 320:
        frame.substr(0, 320) & "... [truncated after 320 characters]"
      else: frame)
    let message = frame.parseJson

    case server.protocol.stage
    of uninitialized:
      server.processRequestUninitialized(message)
    of initializing:
      server.processRequestInitializing(message)
    of initialized:
      server.processRequestInitialized(message)
    of shuttingdown, stopped:
      discard
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

proc recvDriverInput(s: var Server) =
  var c = s.protocol.client
  let tried = c.driver.recv[].tryRecv()
  if tried.dataAvailable:
    case tried.msg.kind
    of MsgKind.recv:
      let id = s.currId
      c.framesReceived.add ReceivedFrame(frameId: id, frame: tried.msg.frame)
    of MsgKind.sent, MsgKind.recvErr, MsgKind.sendErr:
      debugLog($tried.msg)

proc sendFrames(s: var Server) =
  var c = s.protocol.client
  while c.framesPending.len > 0:
    let f = c.framesPending.pop
    c.driver.send[].send Send(id: f.frameId, kind: SendKind.msg, frame: f.frame)

when isMainModule:
  # nim c -r --threads:on --outDir:out src/nimlsppkg/langserv.nim

  from streams import newStringStream
  from os import `/`, parentDir

  # assume this was built in and run from ./out project dir
  const
    src = parentDir(parentDir(currentSourcePath()))
    srcNimlspPkg = src / "nimlsppkg"
    legacyNimSrcName = srcNimlspPkg / "legacyserver.nim"
    legacyNimSrc = staticRead(legacyNimSrcName)

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
      mode: smSingleFile,
      storage: getTempDir() / "nimlanguageserver",
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

  debugLog "Temp Directory: ", server.storage

  clientMsgs.open(100)
  msgsToClient.open(100)
  clientMsgs.send Msg(
    meta: MsgMeta(count: 1),
    kind: MsgKind.recv,
    frame: $create(
      RequestMessage, "2.0", 0, "initialize",
      some(create(InitializeParams,
        processId = 1337,
        clientInfo = none(ClientInfo),
        rootPath = none(string),
        rootUri = "file://" & parentDir(src),
        initializationOptions = none(JsonNode),
        capabilities = create(ClientCapabilities,
          workspace = some(create(WorkspaceClientCapabilities,
            applyEdit = none(bool),
            workspaceEdit = none(WorkspaceEditCapability),
            didChangeConfiguration = none(DidChangeConfigurationCapability),
            didChangeWatchedFiles = none(DidChangeWatchedFilesCapability),
            symbol = none(SymbolCapability),
            executeCommand = none(ExecuteCommandCapability),
            configuration = some(true),
            workspaceFolders = some(true)
          )),
          textDocument = none(TextDocumentClientCapabilities),
          experimental = none(JsonNode)
        ),
        trace = none(string),
        workspaceFolders = some(newSeq[WorkspaceFolder]())
      ).JsonNode)).JsonNode
  )

  clientMsgs.send Msg(
    meta: MsgMeta(count: 2),
    kind: MsgKind.recv,
    frame: $create(NotificationMessage, "2.0", "initialized", none(JsonNode)).JsonNode
  )

  clientMsgs.send Msg(
    meta: MsgMeta(count: 3),
    kind: MsgKind.recv,
    frame: $create(NotificationMessage, "2.0", "textDocument/didOpen",
                   some(create(DidOpenTextDocumentParams,
                               create(TextDocumentItem,
                                      uri = "file://" & legacyNimSrcName,
                                      languageId = "nim",
                                      version = 1,
                                      text = legacyNimSrc)
                  ).JsonNode)).JsonNode
  )

  var progress = Progress.yes
  while progress == yes:
    # TODO id handling should be based on the item and source being processed
    discard server.nextId
    server.sendFrames()
    while msgsToClient.peek() > 0:
      debugLog "received " & $msgsToClient.recv
    server.recvDriverInput()
    progress = server.processRequest()
