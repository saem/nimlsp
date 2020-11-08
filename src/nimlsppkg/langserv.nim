from os import getCurrentCompilerExe, parentDir, `/`
from uri import Uri
from streams import Stream
from tables import OrderedTableRef, `[]=`, pairs, newOrderedTable

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
  NimPath* = distinct string
  ServerVersion* = Version
  ServerStartParams* = object
    nimpath*: NimPath
    version*: ServerVersion
  IdSeq = uint32
  Id = uint32

  SendKind* {.pure.} = enum
    msg, exit
  Send* = object
    id*: Id
    case kind*: SendKind
    of msg: frame*: RawFrame
    of exit: discard
  MsgKind* {.pure.} = enum
    recv, sent, recvErr, sendErr
  MsgMeta* = object
    count*: int
  Msg* = object
    meta*: MsgMeta
    case kind*: MsgKind
    of MsgKind.sent: sendId*: Id
    of MsgKind.recv: frame*: TaintedString
    of MsgKind.recvErr, MsgKind.sendErr: error*: ref CatchableError

  ClientDriverSend* = tuple
    send: ptr Channel[Send]
    recv: ptr Channel[Msg]
    outs: Stream
  ClientDriverRecv* = tuple
    recv: ptr Channel[Msg]
    ins: Stream
  ClientDriver* = object
    sendWorker*: Thread[ClientDriverSend]
    recvWorker*: Thread[ClientDriverRecv]
    send*: ptr Channel[Send]
    recv*: ptr Channel[Msg]
    ins*: Stream
    outs*: Stream

  ProtocolStage* {.pure.} = enum
    # Represents the lifecycle of the LSP
    # see: https://github.com/microsoft/language-server-protocol/issues/227
    uninitialized, ## started but haven't received initialize
    initializing, ## successful initialize, awaiting initialized notification
    initialized, ## receieved initialized notification
    shuttingdown, ## received shutdown request, doing shut down work
    stopped ## done shut down work, awaiting exit notification
  ProtocolCapability* {.pure, size: sizeof(int32).} = enum
    workspaceFolders
  ProtocolCapabilities* = set[ProtocolCapability]

  ReceivedFrame = object
    frameId*: Id
    frame*: TaintedString
  PendingFrame = object
    frameId*: Id
    frame*: RawFrame

  ProtocolClient* = object
    capabilities*: ClientCapabilities
    framesReceived*: OrderedTableRef[Id, ReceivedFrame]
    framesPending*: OrderedTableRef[Id, PendingFrame]
    driver: ClientDriver
  Protocol = ref object
    stage*: ProtocolStage
    capabilities*: ProtocolCapabilities
    client*: ProtocolClient
    rootUri*: Option[Uri]

  Server = ref object
    startParams*: ServerStartParams
    protocol*: Protocol
    idSeq*: IdSeq

proc nextId(s: var Server): Id =
  inc s.idSeq
  result = s.idSeq

proc `$`*(m: Msg): string =
  result = "count: " & $(m.meta.count) & " " & (case m.kind
    of MsgKind.recv: m.frame
    of MsgKind.sent: $m.sendId
    of MsgKind.recvErr, MsgKind.sendErr: m.error.msg)

proc initClientDriverSend*(c: var ClientDriver): ClientDriverSend {.inline.} =
  result = (c.send, c.recv, c.outs)

proc initClientDriverRecv*(c: var ClientDriver): ClientDriverRecv {.inline.} =
  result = (c.recv, c.ins)

proc recvDriverInput(c: var ProtocolClient, s: var Server) =
  let tried = c.driver.recv[].tryRecv()
  if tried.dataAvailable:
    case tried.msg.kind
    of MsgKind.recv:
      let id = s.nextId
      c.framesReceived[id] = ReceivedFrame(frameId: id, frame: tried.msg.frame)
    of MsgKind.sent, MsgKind.recvErr, MsgKind.sendErr:
      echo $tried.msg

when isMainModule:
  # nim c -r --threads:on --outDir:out src/nimlsppkg/langserv.nim

  from streams import newStringStream
  from baseprotocol import stringToFrame

  var
    clientMsgs: Channel[Msg]
    msgsToClient: Channel[Send]
    clientDriver = ClientDriver(
      send: msgsToClient.addr,
      recv: clientMsgs.addr,
      ins: newStringStream(""),
      outs: newStringStream("")
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
          framesReceived: newOrderedTable[Id, ReceivedFrame](),
          driver: clientDriver
        )
      )
    )
  
  clientMsgs.open(100)
  clientMsgs.send Msg(
    meta: MsgMeta(count: 1),
    kind: MsgKind.recv,
    frame: stringToFrame $create(
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

  recvDriverInput(server.protocol.client, server)
  for k, v in server.protocol.client.framesReceived.pairs():
    echo "key: " & $k & " value: " & v.frame & "\n"
