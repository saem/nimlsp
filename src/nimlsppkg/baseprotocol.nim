import streams, strutils, parseutils, json

type
  BaseProtocolError* = object of CatchableError

  MalformedFrame* = object of BaseProtocolError
  UnsupportedEncoding* = object of BaseProtocolError
  InvalidRequestId* = object of BaseProtocolError
    id*: JsonNode

proc skipWhitespace(x: string, pos: int): int =
  result = pos
  while result < x.len and x[result] in Whitespace:
    inc result

template stringToFrame*(s: string): string =
  "Content-Length: " & $s.len & "\r\n\r\n" & s

template jsonToFrame*(data: JsonNode): string =
  var frame = newStringOfCap(1024)
  toUgly(frame, data)
  frame

proc sendFrame*(s: Stream, frame: string) =
  when defined(debugCommunication):
    stderr.write(frame)
    stderr.write("\n")
  s.write stringToFrame(frame)
  s.flush

proc sendJson*(s: Stream, data: JsonNode) =
  s.sendFrame(jsonToFrame(data))

proc readFrame*(s: Stream): TaintedString =
  var contentLen = -1
  var headerStarted = false

  while true:
    var ln = string s.readLine()

    if ln.len != 0:
      headerStarted = true
      let sep = ln.find(':')
      if sep == -1:
        raise newException(MalformedFrame, "invalid header line: " & ln)

      let valueStart = ln.skipWhitespace(sep + 1)

      case ln[0 ..< sep]
      of "Content-Type":
        if ln.find("utf-8", valueStart) == -1 and ln.find("utf8", valueStart) == -1:
          raise newException(UnsupportedEncoding, "only utf-8 is supported")
      of "Content-Length":
        if parseInt(ln, contentLen, valueStart) == 0:
          raise newException(MalformedFrame, "invalid Content-Length: " &
                                              ln.substr(valueStart))
      else:
        # Unrecognized headers are ignored
        discard
    elif not headerStarted:
      continue
    else:
      if contentLen != -1:
        when defined(debugCommunication):
          let msg = s.readStr(contentLen)
          stderr.write(msg)
          stderr.write("\n")
          return msg
        else:
          return s.readStr(contentLen)
      else:
        raise newException(MalformedFrame, "missing Content-Length header")
