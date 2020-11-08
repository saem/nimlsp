from os import getCurrentCompilerExe, parentDir, `/`
from uri import Uri
from streams import Stream
from tables import OrderedTable

include messages

type
# Common Types
  Version* = distinct string
  RawFrame* = string

  #                                                                        +---------------------+
  #                                                                        |                     |
  #                                                                        | nimsuggest process  |
  #                                                                        |                     |
  #                                                                        |                     |
  #                                                                        +---------------------+
  # +--------------------------+           +---------------------+
  # |                          |           |                     |         +---------------------+
  # |                          |           |                     |         |                     |
  # | Language Client          |           |    Language Server  |         |  nimsuggest process |
  # |                          |           |                     |         |                     |
  # |                          |           |                     |         +---------------------+
  # |                          |           |                     |
  # |                          |           +---------------------+         +---------------------+
  # +--------------------------+                                           |                     |
  #                                                                        |  nimpretty          |
  #                                                                        |                     |
  #                                                                        +---------------------+

# Server Types
  NimPath* = distinct string
  ServerVersion* = Version
  ServerStartParams* = object
    nimpath*: NimPath
    version*: ServerVersion
  IdSeq = uint32
  Id = uint32

  SendKind {.pure.} = enum
    msg, exit
  Send = object
    id*: Id
    case kind*: SendKind
    of msg: frame*: RawFrame
    of exit: discard
  MsgKind {.pure.} = enum
    recv, sent, recvErr, sendErr
  MsgMeta = object
    count: int
  Msg = object
    meta*: MsgMeta
    case kind*: MsgKind
    of MsgKind.sent: sendId*: Id
    of MsgKind.recv: frame*: TaintedString
    of MsgKind.recvErr, MsgKind.sendErr: error*: ref CatchableError
  ClientDriverSend = tuple
    send: ptr Channel[Send]
    recv: ptr Channel[Msg]
    outs: Stream
  ClientDriverRecv = tuple
    recv: ptr Channel[Msg]
    ins: Stream
  ClientDriver = object
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

  ProtocolClient* = ref object
    capabilities*: ClientCapabilities
    framesReceived*: OrderedTable[Id, ReceivedFrame]
    framesPending*: OrderedTable[Id, PendingFrame]
  Protocol = ref object
    stage*: ProtocolStage
    capabilities*: ProtocolCapabilities
    client*: ProtocolClient
    rootUri*: Option[Uri]

  Server = ref object
    startParams*: ServerStartParams
    protocol*: Protocol
    idSeq*: IdSeq

proc initClientDriverSend(c: var ClientDriver): ClientDriverSend {.inline.} =
  result = (c.send, c.recv, c.outs)

proc initClientDriverRecv(c: var ClientDriver): ClientDriverRecv {.inline.} =
  result = (c.recv, c.ins)

when isMainModule:
  # nim c -r --threads:on --outDir:out src/nimlsppkg/langserv.nim
  let server = Server(
    startParams: ServerStartParams(
      nimpath: NimPath(getCurrentCompilerExe().parentDir.parentDir),
      version: Version("0.0.1")
    ),
    protocol: Protocol(
      stage: uninitialized,
      capabilities: {},
      client: ProtocolClient()
    )
  )

  import baseprotocol
  import streams
  import os
  from strutils import strip

  type
    Processor = tuple
      send: ptr Channel[Send]
      recv: ptr Channel[Msg]

  var
    inputFrames: Channel[Msg]
    outputFrames: Channel[Send]
    processor: Thread[Processor] 
    clientDriver = ClientDriver(
      send: outputFrames.addr,
      recv: inputFrames.addr,
      ins: newFileStream(stdin),
      outs: newFileStream(stdout)
    )

  proc inputReader(clnt: ClientDriverRecv) {.thread.} =
    template recv(): var Channel[Msg] = clnt.recv[]
    var
      msgCount = 0
      ins = clnt.ins
      doNotQuit = true
    while doNotQuit:
      try:
        var read = ins.readLine
        # var read = ins.readFrame
        recv.send Msg(
          kind: MsgKind.recv,
          meta: MsgMeta(count: msgCount),
          frame: read
        )
        inc msgCount
        doNotQuit = read.strip() != "quit"
      except CatchableError as e:
        recv.send Msg(
          kind: MsgKind.recvErr,
          meta: MsgMeta(count: msgCount),
          error: e
        )

  proc `$`(m: Msg): string =
    result = "count: " & $(m.meta.count) & " " & (case m.kind
      of MsgKind.recv: m.frame
      of MsgKind.sent: $m.sendId
      of MsgKind.recvErr, MsgKind.sendErr: m.error.msg)

  proc process(processor: Processor) {.thread.} =
    template frames(): var Channel[Msg] = processor.recv[]
    template output(): var Channel[Send] = processor.send[]
    var
      msgCount = 0
      sentCount = 0
      recvCount = 0
      errCount = 0
      id: uint32 = 0
      doNotQuit = true
    while doNotQuit:
      var msg = frames.recv
      msgCount = max(msgCount, msg.meta.count)
      case msg.kind
      of MsgKind.recv:
        inc id
        recvCount = max(msg.meta.count, recvCount)
        if msg.frame.strip() == "quit":
          doNotQuit = false
          output.send Send(id: id, kind: SendKind.msg, frame: "Total Msgs: " & $msgCount)
          output.send Send(id: id, kind: SendKind.exit)
          continue
        output.send Send(id: id, kind: SendKind.msg, frame: msg.frame)
      of MsgKind.sent:
        sentCount = max(msg.meta.count, sentCount)
      of MsgKind.recvErr, MsgKind.sendErr:
        inc id
        inc errCount
        output.send Send(id: id, kind: SendKind.msg, frame: "error " & $msg)
      msgCount = sentCount + recvCount + errCount

  proc outputWriter(clnt: ClientDriverSend) {.thread.} =
    template toClnt(): var Channel[Send] = clnt.send[]
    template sendStatus(): var Channel[Msg] = clnt.recv[]
    var
      msgCount = 0
      outs = clnt.outs
      doNotQuit = true
    while doNotQuit:
      try:
        let send = toClnt.recv
        inc msgCount

        if send.kind == SendKind.exit:
          outs.sendFrame "Got quit message"
          doNotQuit = false
          continue

        outs.sendFrame "Frame: (" & $send.id & ") " & send.frame
        sendStatus.send Msg(
          kind: MsgKind.sent,
          meta: MsgMeta(count: msgCount),
          sendId: send.id
        )
      except CatchableError as e:
        outs.sendFrame "Failed to write frame last message count: " & $msgCount
        sendStatus.send Msg(
          kind: MsgKind.sendErr,
          meta: MsgMeta(count: msgCount),
          error: e
        )

  inputFrames.open(100)
  outputFrames.open(100)
  createThread(
    clientDriver.recvWorker,
    inputReader,
    clientDriver.initClientDriverRecv()
  )
  createThread(
    processor,
    process,
    (outputFrames.addr, inputFrames.addr))
  createThread(
    clientDriver.sendWorker,
    outputWriter,
    clientDriver.initClientDriverSend()
  )
  clientDriver.recvWorker.joinThread()
  processor.joinThread()
  # clientDriver.sendWorker.joinThread() # might be asking for bugs, ignoring for now
  inputFrames.close()
  outputFrames.close()
  echo "exit"
