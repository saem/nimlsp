from streams import Stream, newFileStream

type
  RawFrame* = string
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

proc `$`*(m: Msg): string =
  result = "count: " & $(m.meta.count) & " " & (case m.kind
    of MsgKind.recv: m.frame
    of MsgKind.sent: $m.sendId
    of MsgKind.recvErr, MsgKind.sendErr: m.error.msg)

type
  StdioDriverSend* = tuple
    send: ptr Channel[Send]
    recv: ptr Channel[Msg]
    outs: Stream
  StdioDriverRecv* = tuple
    recv: ptr Channel[Msg]
    ins: Stream
  StdioDriver* = object
    sendWorker*: Thread[StdioDriverSend]
    recvWorker*: Thread[StdioDriverRecv]
    send*: ptr Channel[Send]
    recv*: ptr Channel[Msg]
    ins*: Stream
    outs*: Stream

  ClientDriverSend* = StdioDriverSend
  ClientDriverRecv* = StdioDriverRecv
  ClientDriver* = StdioDriver

proc initStdioDriver*(
  send: ptr Channel[Send],
  recv: ptr Channel[Msg],
  ins: Stream = newFileStream(stdin),
  outs: Stream = newFileStream(stdout)
  ): owned StdioDriver =
  result = StdioDriver(send: send, recv: recv, ins: ins, outs: outs)

proc initStdioDriverSend*(c: var StdioDriver): StdioDriverSend {.inline.} =
  result = (c.send, c.recv, c.outs)

proc initStdioDriverRecv*(c: var StdioDriver): StdioDriverRecv {.inline.} =
  result = (c.recv, c.ins)

proc initClientDriver*(
  send: ptr Channel[Send],
  recv: ptr Channel[Msg],
  ins: Stream = newFileStream(stdin),
  outs: Stream = newFileStream(stdout)
  ): owned ClientDriver =
  result = ClientDriver(send: send, recv: recv, ins: ins, outs: outs)

proc initClientDriverSend*(c: var ClientDriver): ClientDriverSend {.inline.} =
  result = (c.send, c.recv, c.outs)

proc initClientDriverRecv*(c: var ClientDriver): ClientDriverRecv {.inline.} =
  result = (c.recv, c.ins)