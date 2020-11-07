when isMainModule:
  # nim c -r --threads:on --outDir:out src/nimlsppkg/langclient.nim

  import baseprotocol
  import os
  import streams
  import sequtils

  type
    SendId = Natural
    Send = object
      sendId: SendId
      frame: string
    MsgKind {.pure.} = enum
      recv, sent, recvErr, sendErr
    MsgMeta = object
      count: int
    Msg = object
      meta*: MsgMeta
      case kind: MsgKind
      of MsgKind.sent: sendId*: SendId
      of MsgKind.recv: frame*: TaintedString
      of MsgKind.recvErr, MsgKind.sendErr: error*: ref CatchableError

    RemSrvrSend = tuple
      send: ptr Channel[Send]
      recv: ptr Channel[Msg]
      outs: Stream
    RemSrvrRecv = tuple
      recv: ptr Channel[Msg]
      ins: Stream

  proc sendWorker(remServer: RemSrvrSend) {.gcsafe, thread.} =
    template forServer(): var Channel[Send] {.dirty.} = remServer.send[]
    template sendStatus(): var Channel[Msg] {.dirty.} = remServer.recv[]

    var msgCount = 0
    while true:
      try:
        var send = forServer.recv()
        remServer.outs.sendFrame send.frame
        inc msgCount
        sendStatus.send Msg(
          kind: MsgKind.sent,
          meta: MsgMeta(count: msgCount),
          sendId: send.sendId
        )
      except CatchableError as e:
        sendStatus.send Msg(
          kind: MsgKind.sendErr,
          meta: MsgMeta(count: msgCount),
          error: e
        )

  proc receiveWorker(remServer: RemSrvrRecv) {.gcsafe, thread.} =
    template fromServer(): var Channel[Msg] {.dirty.} = remServer.recv[]
    var msgCount: int
    while true:
      try:
        inc msgCount
        fromServer.send Msg(
          kind: MsgKind.recv,
          meta: MsgMeta(count: msgCount),
          frame: remServer.ins.readLine
          # frame: ins.readFrame()
        )
      except CatchableError as e:
        fromServer.send Msg(
          kind: MsgKind.recvErr,
          meta: MsgMeta(count: msgCount),
          error: e
        )

  proc `$`(m: Msg): string =
    result = "count: " & $(m.meta.count) & " " & (case m.kind
      of MsgKind.recv: m.frame
      of MsgKind.sent: $(m.sendId)
      of MsgKind.recvErr, MsgKind.sendErr: m.error.msg)

  var
    serverSend: Channel[Send]
    serverRecv: Channel[Msg]
    sender: Thread[RemSrvrSend]
    receiver: Thread[RemSrvrRecv]

  serverSend.open(100)
  serverRecv.open(100)
  createThread(
    sender,
    sendWorker,
    (serverSend.addr, serverRecv.addr, newFileStream(stdout))
  )
  createThread(
    receiver,
    receiveWorker,
    (serverRecv.addr, newFileStream(stdin))
  )

  for i, m in @["test", "best", "worst"].mapIt(it & "\n"):
    serverSend.send(Send(sendId: i, frame: m))
  
  echo "waiting for input"
  sleep(3000)
  var
    sentCount = 0
    recvCount = 0
    errCount = 0
    msgCount = 0
    msgsToProcess = serverRecv.peek()
  echo "Msgs to process: " & $(msgsToProcess)
  while msgCount < msgsToProcess:
    let msg = serverRecv.recv
    case msg.kind
    of MsgKind.sent:
      sentCount = max(msg.meta.count, sentCount)
      echo "sent count " & $(sentCount)
    of MsgKind.recv:
      recvCount = max(msg.meta.count, recvCount)
      echo "received " & $(msg)
    of MsgKind.recvErr, MsgKind.sendErr:
      inc errCount
      echo "error " & $(msg)
    msgCount = sentCount + recvCount + errCount
    echo "current msg count: " & $msgCount
  echo "done"
  quit(0)

  sender.joinThread()
  receiver.joinThread()
  serverSend.close()
  serverRecv.close()
  echo "exit"