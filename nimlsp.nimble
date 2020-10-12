# Package

version       = "0.2.4"
author        = "PMunch"
description   = "Nim Language Server Protocol - nimlsp implements the Language Server Protocol"
license       = "MIT"
srcDir        = "src"
binDir        = "out"
bin           = @["nimlsp"]

# Dependencies

requires "nim >= 1.0.0"
#requires "packedjson"
requires "astpatternmatching"
requires "jsonschema >= 0.2.1"

task debug, "Builds the language server":
  exec "nim c --threads:on -d:nimcore -d:nimsuggest -d:debugCommunication -d:debugLogging --outDir:out src/nimlsp"

task debugGdb, "Builds the language server":
  exec "nim c --threads:on -d:nimcore -d:nimsuggest -d:debugCommunication -d:debugLogging --outDir:out --debugger:native src/nimlsp"

before test:
  if not fileExists("out/nimlsp"):
    exec "nimble debugGdb"

task test, "Runs the test suite":
  exec "nim r --outDir:out/tests tests/tnimlsp.nim"
  exec "nim r --outDir:out/tests -d:debugLogging -d:jsonSchemaDebug tests/test_messages2.nim"

task findNim, "Tries to find the current Nim installation":
  echo NimVersion
  echo currentSourcePath
