import stdiodriver

from streams import newFileStream, writeLine, readLine, atEnd
from os import getCurrentDir, sleep
from osproc import Process, startProcess, ProcessOption,
  inputStream, peekableOutputStream,
  close
from strutils import startsWith

type
  Backend {.pure.} = enum
    c, js, cpp, objc
  NimSuggest* = object
    process*: Process
    driver*: StdioDriver
    backend*: Backend
    file*: string

proc getNimSuggestCmd(): string =
  ## TODO have this handle various platforms
  return "nimsuggest"

proc initNimSuggest(
  send: ptr Channel[Send],
  recv: ptr Channel[Msg],
  file: string,
  backend: Backend,
  cwd: string = getCurrentDir()
  ): owned NimSuggest =
  let p = startProcess(
      command = getNimSuggestCmd(),
      workingDir = cwd,
      args = ["--backend:" & $backend, "--stdin", file],
      options = {poStdErrToStdOut, poUsePath}
    )
  result = NimSuggest(
      process: p,
      driver: initStdioDriver(send, recv, p.peekableOutputStream, p.inputStream),
      backend: backend,
      file: file
    )

when isMainModule:
  proc sendWorker(sug: StdioDriverSend) {.thread.} =
    var msgCount = 0
    while true:
      try:
        var send = sug.send[].recv()
        echo "sending " & send.frame
        sug.outs.writeLine send.frame
        inc msgCount
        sug.recv[].send Msg(
          kind: MsgKind.sent,
          meta: MsgMeta(count: msgCount),
          sendId: send.id
        )
      except CatchableError as e:
        sug.recv[].send Msg(
          kind: MsgKind.sendErr,
          meta: MsgMeta(count: msgCount),
          error: e
        )
  proc recvWorker(sug: StdioDriverRecv) {.thread.} =
    var msgCount = 0
    while true:
      try:
        inc msgCount
        sug.recv[].send Msg(
          kind: MsgKind.recv,
          meta: MsgMeta(count: msgCount),
          frame: sug.ins.readLine
        )
      except CatchableError as e:
        sug.recv[].send Msg(
          kind: MsgKind.recvErr,
          meta: MsgMeta(count: msgCount),
          error: e
        )

  var
    sugSend: Channel[Send]
    sugRecv: Channel[Msg]
    sug = initNimSuggest(sugSend.addr, sugRecv.addr, "src/nimlsp.nim", Backend.c)

  sugSend.open(100)
  sugRecv.open(100)
  createThread(sug.driver.sendWorker, sendWorker, sug.driver.initStdioDriverSend)
  createThread(sug.driver.recvWorker, recvWorker, sug.driver.initStdioDriverRecv)

  sleep(0)

  var
    ready = false
    id = 0
  while true:
    let m = sugRecv.recv()
    case m.kind:
    of MsgKind.recv:
      echo $m
      if ready:
        if id > 5: quit(0)
        inc id
        sugSend.send(Send(
          id: uint32(id),
          kind: SendKind.msg,
          frame: "def src/nimlsppkg/legacyserver.nim:27:12\n")
        )
      else:
        if m.frame.startsWith("usage: "):
          ready = true
    of MsgKind.sent:
      echo $m
    of MsgKind.recvErr, MsgKind.sendErr:
      echo $m
      break
  
  sug.process.close()