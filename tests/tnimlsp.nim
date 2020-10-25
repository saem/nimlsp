import unittest
import os, osproc, options, json
import .. / src / nimlsppkg / baseprotocol
include .. / src / nimlsppkg / messages

let
  nimlsp = parentDir(parentDir(currentSourcePath())) / "out" / "nimlsp"
  p = startProcess(nimlsp, options = {})
  i = p.inputStream()
  o = p.outputStream()

suite "Nim LSP basic operation":
  test "Nim LSP can be initialised":
    var ir = create(RequestMessage, "2.0", 0, "initialize", some(
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
      check data["id"].getInt == 0
      echo data["result"]
    else:
      check false

    echo message
  
  test "Nim LSP can handle bad input":
    i.sendFrame "\"This should fail\""
    var frame = o.readFrame
    echo frame

    var message = frame.parseJson
    if message.isValid(ResponseMessage):
      var data = ResponseMessage(message)
      check data["error"].isSome
      var error = data["error"].get
      check error.isValid(ResponseError, allowExtra = true)
      var errResp = ResponseError(error)
      check errResp["code"].getInt == cast[int](InvalidRequest)
      
      echo error
    else:
      check false

    echo message

p.terminate()
