when defined(newLanguageServer):
  import nimlsppkg / languageserver

  from os import getCurrentCompilerExe, parentDir, `/`
  from strutils import split, splitLines, strip, Whitespace

  const
    version = block:
      var version = "0.0.0"
      let nimbleFile = staticRead(currentSourcePath().parentDir().parentDir() / "nimlsp.nimble")
      for line in nimbleFile.splitLines:
        let keyval = line.split("=")
        if keyval.len == 2:
          if keyval[0].strip == "version":
            version = keyval[1].strip(chars = Whitespace + {'"'})
            break
      version
    # This is used to explicitly set the default source path
    nimpath {.strdefine.} = getCurrentCompilerExe().parentDir.parentDir

  initServer(nimpath, version).start
else:
  include nimlsppkg / legacyserver
