from os import getCurrentCompilerExe, parentDir, `/`

include messages

type
# Common Types
  Version* = distinct string

# Server Types
  NimPath* = distinct string
  ServerVersion* = Version
  ServerStartParams* = object
    nimpath*: NimPath
    version*: ServerVersion

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
  RemoteClient* = ref object
    capabilities*: ClientCapabilities
  Protocol = ref object
    stage*: ProtocolStage
    capabilities*: ProtocolCapabilities
    client*: RemoteClient

  Server = ref object
    startParams*: ServerStartParams
    protocol*: Protocol

when isMainModule:
  const
    maxMessagCount = 4
  let server = Server(
    startParams: ServerStartParams(
      nimpath: NimPath(getCurrentCompilerExe().parentDir.parentDir),
      version: Version("0.0.1")
    ),
    protocol: Protocol(
      stage: uninitialized,
      capabilities: {},
      client: RemoteClient()
    )
  )

  import baseprotocol
  import streams
  import os

  type
    MsgKind {.pure.} = enum
      str, err
    Msg = ref MsgObj
    MsgMeta = object
      count: int
    MsgObj = object
      meta*: MsgMeta
      case kind: MsgKind
      of MsgKind.str: frame*: TaintedString
      of MsgKind.err: error*: ref CatchableError

  var
    inputFrames: Channel[Msg]
    prod, cons: Thread[void]

  proc inputReader() {.gcsafe.} =
    var
      msgCount = 0
      ins = newFileStream(stdin)
    while msgCount <= maxMessagCount:
      try:
        var wasSent = inputFrames.trySend Msg(
          kind: MsgKind.str,
          meta: MsgMeta(count: msgCount),
          frame: ins.readLine
          # frame: ins.readFrame()
        )
        if wasSent:
          inc msgCount
        else:
          sleep(10) # just wait, hopefully that'll clear it out
      except CatchableError as e:
        inputFrames.send Msg(
          kind: MsgKind.err,
          meta: MsgMeta(count: msgCount),
          error: e
        )

  proc `$`(m: Msg): string =
    result = "count: " & $(m.meta.count) & " " & (case m.kind
      of MsgKind.str: m.frame
      of MsgKind.err: m.error.msg)

  proc inputConsumer() {.gcsafe.} =
    var msgCount: int
    while msgCount < maxMessagCount:
      var msg = inputFrames.recv
      msgCount = msg.meta.count
      echo "echo: " & $(msg)

  inputFrames.open()
  createThread(prod, inputReader)
  createThread(cons, inputConsumer)
  prod.joinThread()
  cons.joinThread()
  inputFrames.close()
  echo "exit"
