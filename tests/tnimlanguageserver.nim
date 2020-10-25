import unittest
import os, osproc, options, json, streams
import sequtils, strutils

import .. / src / nimlsppkg / baseprotocol
include .. / src / nimlsppkg / messages

let
  langServer = parentDir(parentDir(currentSourcePath())) / "out" / "nimlanguageserver"
  p = startProcess(langServer, options = {})
  i = p.inputStream()
  o = p.peekableOutputStream()

var
  id = 0

proc nextId(): int =
  inc id
  id

suite "Nim Language Server Basic Operation":
  setup:
    inc id

  test "Needs to be initialized or will error on any other requests":
    let r = create(RequestMessage, "2.0", id, "lol", none(JsonNode)).JsonNode
    i.sendJson r

    var frame = o.readFrame
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
    i.sendJson r

    # TODO - implement things once tests are non-blocking

  test "Can be initialized":
    let ir = create(RequestMessage, "2.0", id, "initialize", some(
      create(InitializeParams,
        processId = getCurrentProcessId(),
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
    i.sendJson ir

    var frame = o.readFrame
    var message = frame.parseJson
    if message.isValid(ResponseMessage):
      var data = ResponseMessage(message)
      check data["id"].getInt == id
      echo data["result"]
    else:
      check false
    
    echo message

p.terminate()