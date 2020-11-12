import stdiodriver

from os import getCurrentDir
from osproc import Process, startProcess, ProcessOptions, outputStream, inputStream

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
  backend: Backend
  cwd: string = getCurrentDir()
  ): owned NimSuggest =
  let process = startProcess(
      command = getNimSuggestCmd(),
      workingDir = cwd,
      args = ["--backend:" & $backend, file]
      options = {poStdErrToStdOut, poUsePath}
    )
  result = NimSuggest(
    process: process,
    driver: initStdioDriver(
        send,
        recv,
        newFileStream(process.inputStream),
        newFileStream(process.outputStream)
      ),
    backend: backend,
    file: file
  )