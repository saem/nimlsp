## This module communicates with nimsuggest in the background.
## Original: https://github.com/nim-lang/Aporia/blob/0a11134ccf2d426f7251ce62d15c1f44474404b8/autocomplete.nim

import osproc, streams, os, net, strutils, unicode, options, strformat

type
  CommandKind* {.pure.} = enum
    cmdPrj    = "Command: Project File",
    cmdTskNew = "Command - Inform: Task Newly Started",
    cmdTskFin = "Command - Inform: Task Complete",
    cmdTskDed = "Command - Inform: Task Failed",
    cmdEnd    = "Command: End NimSuggest Process"
  Command* = object
    id*: int
    case kind*: CommandKind
    of cmdPrj: prj*: string
    of cmdTskNew, cmdTskFin, cmdTskDed, cmdEnd: discard
  Task* = tuple
    id: int
    task: string
  ResultKind* {.pure.} = enum
    rkTskNew = "Task Started",
    rkTskOut = "Task Output",
    rkTskFin = "Task Finished",
    rkTskDed = "Task Failed",
    rkCliOut = "CLI Message",
    rkCliErr = "CLI Error",
    rkCmdPos = "Last Task ID seen by Command",
    rkEnd    = "NimSuggest Process Ended",
    rkDed    = "NimSuggest Process Crashed"
  Result* = object
    id*: int
    case kind*: ResultKind
    of rkTskOut, rkTskDed, rkCliOut, rkCliErr:
      msg*: string
    of rkTskNew, rkTskFin, rkCmdPos, rkEnd, rkDed:
      discard
  LogSeverity {.pure.} = enum
    logMsg, logErr
  SugExitCode {.pure.} = enum
    exSuccess = "Task finished reading all output normally",
    exExit    = "Nimsuggest exited occurred",
    exCrash   = "Nimsuggest crashed, no more results to come"
  Suggest* = ref object
    thread*: Thread[Option[string]]
    sockThread*: Thread[void]
    taskIdSeq, lastSeen*, lastDone*, currentTask*: int
    nimSuggestRunning*: bool
    onSugLine*: proc (id: int, line: string) {.closure.}
    onSugExit*: proc (id: int, exit: SugExitCode) {.closure.}
    onSugError*: proc (id: int, error: string) {.closure.}
    onLog*: proc (id: int, sev: LogSeverity, msg: string) {.closure.}

# the compiler never produces endToken:
const
  endToken = "EOF\t"
  stopToken = "STOP\t"
  errorToken = "ERROR\t"
  port = 6000.Port

var
  commands: Channel[Command]
  results: Channel[Result]
  suggestTasks: Channel[Task]

commands.open()
results.open()
suggestTasks.open()

template debugLog(s: varargs[untyped]) =
  let pos = instantiationInfo()
  stdout.write("line: ", pos.line, " ")
  stdout.writeLine s

proc shutdown(p: Process) =
  if not p.running:
    debugLog("[Suggest] Process exited.")
  else:
    debugLog("[Suggest] Process Shutting down.")
    p.terminate()
    discard p.waitForExit()
  p.close()

proc suggestThread(nimPath: Option[string]) {.thread.} =
  let nimBinPath = findExe("nim")
  let nimPath = nimPath.get nimBinPath.splitFile.dir.parentDir
  var
    p: Process = nil
    o: Stream = nil
    lastTaskId = -1

  while true:
    if not p.isNil:
      if not p.running:
        p.shutdown()
        results.send Result(kind: rkDed, id: lastTaskId)
        p = nil
        continue

    if not o.isNil:
      if o.atEnd:
        # TODO does this only happen when the process dies?
        debugLog("[Suggest] Stream is at end")
        o.close()
        o = nil
      else:
        let line = o.readLine()
        # For some reason on Linux reading from the process
        # returns an empty line sometimes.
        if line.len == 0: continue
        debugLog("[Suggest] Got line from NimSuggest (stdout): ", line.repr)

        if unicode.toLower(line).startsWith("error:"):
          results.send Result(kind: rkCliErr, id: lastTaskId, msg: line)
        else:
          results.send Result(kind: rkCliOut, id: lastTaskId, msg: line)

    var cmds = commands.peek()
    if cmds > 0 or (o.isNil and p.isNil):
      let
        cmd = commands.recv()
        id = cmd.id
      lastTaskId = id
      debugLog(fmt"[Suggest:{id}] Got command: ", cmd)
      case cmd.kind
      of cmdPrj:
        let
          projectFile = cmd.prj.replace('\\', '/')
        # TODO: Ensure nimPath exists.
        debugLog(fmt"[Suggest:{id}] NimSuggest Work Dir: ", nimPath)
        debugLog(fmt"[Suggest:{id}] NimSuggest Project file: ", projectFile)
        p = startProcess(findExe("nimsuggest"), nimPath,
                             ["--port:" & $port, projectFile],
                             options = {poStdErrToStdOut, poUsePath,
                                        poInteractive})
        debugLog(fmt"[Suggest:{id}] NimSuggest started on port ", port)
        o = p.outputStream
      of cmdTskNew, cmdTskFin, cmdTskDed:
        results.send Result(kind: rkCmdPos, id: id)
      of cmdEnd:
        p.shutdown()
        results.send Result(kind: rkEnd, id: id)
        p = nil
        o = nil

  debugLog("[Suggest] Process thread exiting")

proc processTask(task: Task) =
  var socket = newSocket()
  socket.connect("localhost", port)
  debugLog(fmt"[Suggest:{task.id}] Socket connected")
  socket.send(task.task & "\c\l")
  while true:
    var line = ""
    socket.readLine(line)
    debugLog(fmt"[Suggest:{task.id}] Recv line: """, line, "\"")
    if line.len == 0: break
    results.send Result(id: task.id, kind: rkTskOut, msg: line)
  socket.close()
  results.send Result(id: task.id, kind: rkTskFin)

proc socketThread() {.thread.} =
  while true:
    let
      task = suggestTasks.recv()
      id = task.id
    debugLog(fmt"[Suggest:{id}] Got suggest task: ", task)
    var success = false
    for i in 0 .. 10:
      try:
        processTask(task)
        success = true
        break
      except OSError:
        debugLog(fmt"[Suggest:{id}] Error sending task, retry in 500ms")
        sleep(500)
    if not success:
      results.send Result(kind: rkTskDed, id: id,
        msg: "Couldn't connect to NimSuggest")

proc newSuggest*(nimPath: Option[string] = none(string)): Suggest =
  result = Suggest(taskIdSeq: 0, lastSeen: -1, lastDone: -1, currentTask: -1)
  createThread(result.thread, suggestThread, nimPath)
  createThread[void](result.sockThread, socketThread)

proc nextTaskId(self: Suggest): int =
  inc self.taskIdSeq
  result = self.taskIdSeq

proc taskRunning*(self: Suggest): bool = self.currentTask > 0

proc taskFinished(self: Suggest, id: int) =
  if self.currentTask == id:
    self.lastDone = self.currentTask
    self.currentTask = -1
  else:
    # Maybe behind on processing results so seeing old ids
    debugLog(fmt"[Suggest] finished old task{id}, current: {self.currentTask}")

proc startNimSuggest*(self: Suggest, projectFile: string) =
  assert(not self.nimSuggestRunning)
  commands.send Command(kind: cmdPrj, id: self.currentTask, prj: projectFile)
  self.nimSuggestRunning = true

proc processTaskOutput*(self: Suggest): bool =
  ## Call this periodically in order to check for and process output from
  ## current tasks. Best to do so during an idle period.
  result = true
  if not self.taskRunning and results.peek() == 0:
    # There is no suggest task running, so end this idle proc.
    debugLog("[Suggest] idleproc exiting")
    return false

  while true:
    let
      (available, res) = tryRecv(results)
      id = res.id
    if not available:
      break
    debugLog(fmt"[Suggest:{id}] SuggestOutput: ", $(res.kind).repr)
    if res.kind in [rkTskOut, rkTskDed, rkCliOut, rkCliErr]:
      debugLog(fmt"[Suggest:{id}] SuggestOutput:    Full: ", res.msg.repr)
    case res.kind:
    of rkTskNew:
      self.currentTask = id
    of rkTskOut:
      if self.currentTask != id:
        # only send it once
        commands.send Command(kind: cmdTskNew, id: id)
      self.currentTask = id
      self.onSugLine(id, res.msg)
    of rkTskFin:
      self.taskFinished(id)
      commands.send Command(kind: cmdTskFin, id: id)
      self.onSugExit(id, exSuccess)
    of rkTskDed:
      self.taskFinished(id)
      commands.send Command(kind: cmdTskDed, id: id)
      self.onSugError(id, res.msg)
    of rkCliOut:
      self.lastSeen = max(self.lastSeen, id)
      self.onLog(id, logMsg, res.msg)
    of rkCliErr:
      self.lastSeen = max(self.lastSeen, id)
      if id == self.currentTask:
        self.onSugError(id, res.msg)
      else:
        self.onLog(id, logErr, res.msg)
    of rkCmdPos:
      self.lastSeen = max(self.lastSeen, id)
    of rkEnd, rkDed:
      self.lastSeen = max(self.lastSeen, id)
      self.nimSuggestRunning = false
      self.taskFinished(id)
      let exitCode = if res.kind == rkEnd: exExit else: exCrash
      self.onSugExit(self.lastSeen, exitCode)

  if not result:
    debugLog("[Suggest] idle exiting")

proc startTask*(
    self: var Suggest, task: string,
    onSugLine: proc (id: int, line: string) {.closure.},
    onSugExit: proc (id: int, exit: SugExitCode) {.closure.},
    onSugError: proc (id: int, error: string) {.closure.},
    onLog: proc (id: int, sev: LogSeverity, msg: string) {.closure.}): int =
  ## Sends a new task to nimsuggest.
  # assert(not self.taskRunning)
  assert(self.nimSuggestRunning)
  result = self.nextTaskId
  debugLog(fmt"[Suggest:{result}] Starting new task: ", task)
  results.send Result(kind: rkTskNew, id: result)
  self.onSugLine = onSugLine
  self.onSugExit = onSugExit
  self.onSugError = onSugError
  self.onLog = onLog

  # Send the task
  suggestTasks.send (result, task)

proc isTaskRunning*(self: Suggest): bool =
  self.lastDone < self.taskIdSeq or results.peek() > 0

proc isNimSuggestRunning*(self: Suggest): bool =
  self.nimSuggestRunning

proc stopTask*(self: Suggest) =
  #commmands.send(stopToken)
  discard

when isMainModule:
  from random import rand

  var
    ac = newSuggest(some(getCurrentDir()))
    currentTask = 0
    lastTask = 0
  
  ac.startNimSuggest("src/nimlsp.nim")

  proc onSugLine(id: int, l: string) =
    echo(fmt"line ({id}): " & l)
  proc onSugExit(id: int, e: SugExitCode) =
    echo(fmt"exit ({id}): " & $e)
    currentTask = id
  proc onSugError(id: int, e: string) =
    echo(fmt"error ({id}): " & e)
    currentTask = id
  proc onLog(id: int, s: LogSeverity, e: string) =
    case s:
    of logMsg: echo(fmt"log msg ({id}): " & e)
    of logErr: echo(fmt"log err ({id}): " & e)

  for col in 12..15:
    lastTask = ac.startTask(fmt"def src/nimlsppkg/legacyserver.nim:27:{col}",
                         onSugLine, onSugExit, onSugError, onLog)
    sleep(rand(50..200))
    discard ac.processTaskOutput

  while currentTask < lastTask:
    if not ac.processTaskOutput: sleep(100)

  quit(0)
