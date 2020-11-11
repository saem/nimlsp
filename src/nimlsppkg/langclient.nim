when isMainModule:
  # nim c -r --threads:on --outDir:out src/nimlsppkg/langclient.nim

  import baseprotocol
  import os
  import streams
  import sequtils

  import stdiodriver

  proc sendWorker(remServer: StdioDriverSend) {.gcsafe, thread.} =
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
          sendId: send.id
        )
      except CatchableError as e:
        sendStatus.send Msg(
          kind: MsgKind.sendErr,
          meta: MsgMeta(count: msgCount),
          error: e
        )

  proc receiveWorker(remServer: StdioDriverRecv) {.gcsafe, thread.} =
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

  var
    serverSend: Channel[Send]
    serverRecv: Channel[Msg]
    serverDriver = initStdioDriver(serverSend.addr, serverRecv.addr)

  serverSend.open(100)
  serverRecv.open(100)
  createThread(
    serverDriver.sendWorker,
    sendWorker,
    serverDriver.initStdioDriverSend()
  )
  createThread(
    serverDriver.recvWorker,
    receiveWorker,
    serverDriver.initStdioDriverRecv()
  )

  for i, m in @["test", "best", "worst"].mapIt(it & "\n"):
    serverSend.send(Send(id: uint32(i), kind: SendKind.msg, frame: m))
  
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

  serverDriver.sendWorker.joinThread()
  serverDriver.recvWorker.joinThread()
  serverSend.close()
  serverRecv.close()
  echo "exit"