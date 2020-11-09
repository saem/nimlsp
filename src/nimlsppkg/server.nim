import langserv
import baseprotocol
import stdiodriver
import streams
import os
from strutils import strip

# nim c -r --threads:on --outDir:out src/nimlsppkg/server.nim

type
  Processor = tuple
    send: ptr Channel[Send]
    recv: ptr Channel[Msg]

var
  inputFrames: Channel[Msg]
  outputFrames: Channel[Send]
  processor: Thread[Processor] 
  clientDriver = initClientDriver(outputFrames.addr, inputFrames.addr)

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