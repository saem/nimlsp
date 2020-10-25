import unittest
import options, json, streams
import sequtils, strutils

import nimlsppkg / languageserver

from .. / src / nimlsppkg / baseprotocol import nil
include .. / src / nimlsppkg / messages

let
  i = newStringStream("")
  o = newStringStream("")
  nimpath = "/foo/bar/nim"
  version = "0.0.1"
  ls = initServer(nimpath, version, o, i)
  clientPid = 37

var
  id = 0
  iwp = i.getPosition
  irp = i.getPosition
  owp = o.getPosition
  orp = o.getPosition

proc sendFrame(data: string) =
    irp = i.getPosition
    i.setPosition(iwp)
    baseprotocol.sendFrame(i, data)
    iwp = i.getPosition
    i.setPosition(irp)
proc sendJson(data: JsonNode) =
    irp = i.getPosition
    i.setPosition(iwp)
    baseprotocol.sendJson(i, data)
    iwp = i.getPosition
    i.setPosition(irp)
proc readFrame(): string =
    owp = o.getPosition
    o.setPosition(orp)
    result = baseprotocol.readFrame(o)
    orp = o.getPosition
    o.setPosition(owp)

proc nextId(): int =
  inc id
  id

suite "Nim Language Server Core Tests":
  setup:
    inc id

  test "Needs to be initialized or will error on any other requests":
    let r = create(RequestMessage, "2.0", id, "lol", none(JsonNode)).JsonNode
    sendJson r

    check ls.process

    var frame = readFrame()
    var message = frame.parseJson
    if message.isValid(ResponseMessage):
      var data = ResponseMessage(message)
      check data["error"].isSome
      var error = data["error"].get
      check error.isValid(ResponseError, allowExtra = true)
      var errResp = ResponseError(error)
      checkpoint "Got an error response"
      check data["id"].getInt == id
      checkpoint "Refers to the correct id"
      check errResp["code"].getInt == cast[int](ServerNotInitialized)
      checkpoint "Has the correct error code"
    else:
      check false

    echo message
  
  test "Will ignore all notifications prior to initialization except exit":
    let r = create(NotificationMessage, "2.0", "lol", none(JsonNode)).JsonNode
    sendJson r

    check ls.process

    # TODO - implement things once tests are non-blocking

  test "Can be initialized":
    let ir = create(RequestMessage, "2.0", id, "initialize", some(
      create(InitializeParams,
        processId = clientPid,
        clientInfo = none(ClientInfo),
        rootPath = none(string),
        rootUri = "file:///tmp/",
        initializationOptions = none(JsonNode),
        capabilities = create(ClientCapabilities,
          workspace = none(WorkspaceClientCapabilities),
          textDocument = none(TextDocumentClientCapabilities),
          experimental = none(JsonNode)
        ),
        trace = none(string),
        workspaceFolders = none(seq[WorkspaceFolder])
      ).JsonNode)
    ).JsonNode
    sendJson ir

    check ls.process

    var frame = readFrame()
    var message = frame.parseJson
    if message.isValid(ResponseMessage):
      var data = ResponseMessage(message)
      check data["id"].getInt == id
      echo data["result"]
    else:
      check false
    
    echo message