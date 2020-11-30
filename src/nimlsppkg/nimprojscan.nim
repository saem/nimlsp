from uri import Uri, parseUri, encodeUrl, decodeUrl, `/`, `$`
from strutils import toHex, startsWith, `%`, replace, find, split, join, strip
from sequtils import mapIt, filterIt
from os import `/`, normalizedPath, walkDir, PathComponent, splitFile, findExe,
               isAbsolute
from osproc import execCmdEx
from json import parseJson, `{}`, `getStr`
from streams import newStringStream, lines
from parseutils import parseIdent
from options import Option, some, none, isSome, isNone, get

type
  NimbleTask = object
    name*: string
    description*: string
  NimbleFile = object
    uri*: Uri
    name*: string
    srcDir*: Uri
    binDir*: Uri
    backend*: string
    tasks*: seq[NimbleTask]
    # add other nimble relevant things here
  ConfigNimsFile = object
    uri*: Uri
  NimsFile = object
    uri*: Uri
  NimFile = object
    uri*: Uri
  CfgFile = object
    uri*: Uri
  NimCfgFile = object
    uri*: Uri
  DirScan = object of RootObj
    ## TODO - remove inheritance in next refactor
    uri*: Uri
    nimble*: Option[NimbleFile]
    cfg*: Option[CfgFile]
    configNims*: Option[ConfigNimsFile]
    nimcfgs*: seq[NimCfgFile]
    nimscripts*: seq[NimsFile]
    nims*: seq[NimFile]
    dirs*: seq[Uri]
    ignoredDirs*: seq[Uri]
    otherFiles*: seq[Uri]
  DirFind = object of DirScan
    nimbleExe*: string
  UriParseError* = object of Defect
    uri: Uri
  MoreThanOneNimble* = object of CatchableError
    uri: Uri
    existingNimble: Uri
  NimbleExeNotFound* = object of CatchableError
  NimbleDumpFailed* = object of CatchableError
  NimbleTasksFailed* = object of CatchableError

proc authority(uri: Uri): string =
  let
    username = if uri.username.len > 0: uri.username else: ""
    password = if uri.password.len > 0: ":$1" % [uri.password] else: ""
    userinfo = if username.len > 0: username & password & "@" else: ""
    port = if uri.port.len > 0: ":" & uri.port else: ""
  
  result = if uri.hostname.len > 0: userinfo & uri.hostname & port else: ""

proc uriToPath(uri: Uri): string =
  ## Convert an RFC 8089 file URI to a native, platform-specific, absolute path.
  ## Accepts 'file' scheme, assumes if none set, or raises
  ## hostname is only allowed if on windows for UNC support
  if uri.scheme notIn ["file", ""]:
    var e = newException(UriParseError,
      "Invalid scheme: $1, only \"file\" supported" % [uri.scheme])
    e.uri = uri
    raise e
    
  when defined(windows):
    result = if uri.hostname != "":
      "\\\\" & uri.authority.decodeUrl & uri.path.decodeUrl.replace('/', '\\')
      else: uri.path[1..^1].decodeUrl.replace('/', '\\')
  else:
    ## only windows has UNC so hostnames are allowed, but not elsehwere
    if uri.hostname != "":
      var e = newException(UriParseError, 
        "Invalid hostname: $1, only empty hostname supported" % [uri.hostname])
      e.uri = uri
      raise e
    result = uri.path.decodeUrl.normalizedPath

proc pathToUri(absolutePath: string): Uri =
  ## Based on vscode uri module: https://github.com/microsoft/vscode-uri/blob/master/src/index.ts#L752
  ## 
  ## Assumes absolute paths

  when defined(windows):
    # in windows we need to handle UNC
    # also black slashes ('\') get normalized to forward slashes ('/')
    #
    # Windows bits to know:
    # - C:\ and the rest are all absolute paths
    # - with msysgit/cygwin/etc... we might get slashes -- not fully handled
    #
    # UNC things to know:
    # - UNC start with "\\" eg: "\\share\c$\foo"
    # - 'share' part above is the authority, the rest is the path
    # - authority is as basically: user:pass@share:port
    # - except for the port the rest need to be url encoded individually
    let
      fwdSlashPath = absolutePath.normalizedPath().replace("\\", "/")
      isUnc = fwdSlashPath.startsWith("//")
      fsPath = if isUnc: fwdSlashPath[1..^1] else: fwdSlashPath
      authorityEnd = if isUnc: fsPath.find('/', 1) : 0
      rawAuthority = if authorityEnd > 0: fsPath[1..^authorityEnd] else: ""
      rawPath = if isUnc: fsPath.substr(authorityEnd)
                elif fsPath.startsWith('/'): fsPath
                else: "/" & fsPath
      path = rawPath.split('/').filterIt(it.len > 0).mapIt(it.encodeUrl())
        ## filterIt removes '/' prefix, assume absolute path and re-add later
        ## each part of the path, but not the slashes need to be URL encoded
      (user, pass, host, port) = rawAuthority.split("@", 1).mapIt(case it.len
          of 1: ("", it[0])
          of 2: (it[0], it[1])
          else: ("", "")
        ).mapIt(block:
          let
            userparts = it[0].split(':', 1)
            hostparts = it[1].split(':', 1)
            user = userparts[0]
            pass = if userparts.len > 1: userparts[1] : ""
            host = hostparts[0]
            port = if hostparts.len > 1: hostparts[1] : ""
          (user.encodeUrl, pass.encodeUrl, host.encodeUrl, port)
        )
    result.username = user
    result.password = pass
    result.hostname = host
    result.port = port
  else:
    let
      fsPath = absolutePath.normalizedPath
      path = fsPath.split("/").filterIt(it.len > 0).mapIt(it.encodeUrl())
        ## filterIt removes '/' prefix, assume absolute path and re-add later
        ## each part of the path, but not the slashes need to be URL encoded
  
  result.scheme = "file"
  result.path = "/" & path.join("/") # force absolute path assumption

proc `$`(f: DirFind): string =
  result = ""
  result.add "uri: " & $f.uri & "\n"
  result.add "nimble file: " & $f.nimble & "\n"
  result.add "cfg file: " & $f.cfg & "\n"
  result.add ".nim.cfg files: " & $f.nimcfgs & "\n"
  result.add "config.nims files: " & $f.configNims & "\n"
  result.add "nims files: " & $f.nimscripts & "\n"
  result.add "nim files: " & $f.nims & "\n"
  result.add "directories: " & $f.dirs & "\n"
  result.add "other files: " & $f.otherFiles & "\n"
  result.add "ignored directories: " & $f.ignoredDirs & "\n"

proc isNimbleProject(f: DirFind): bool =
  result = f.nimble.isSome

proc doFind(uri: Uri): owned DirFind =
  result = DirFind(uri: uri, nimbleExe: findExe("nimble"))
  for f in walkDir(result.uri.uriToPath):
    let
      fUri = f.path.pathToUri
      (dir, name, ext) = f.path.splitFile()
    case f.kind
    of pcDir, pcLinkToDir:
      if name.startsWith("."):
        result.ignoredDirs.add(fUri)
      else:
        result.dirs.add(fUri)
    of pcFile, pcLinkToFile:
      case ext
      of ".nimble":
        if result.nimble.isNone:
          result.nimble = some(NimbleFile(uri: fUri))
        else:
          var e = newException(MoreThanOneNimble,
            "Have $1, also got $2, max one per folder" %
              [$result.nimble.get.uri, $fUri])
          e.uri = fUri
          e.existingNimble = result.nimble.get.uri
          raise e
      of ".nims":
        if name == "config": result.configNims = some(ConfigNimsFile(uri: fUri))
        else: result.nimscripts.add(NimsFile(uri: fUri))
      of ".nim": result.nims.add(NimFile(uri: fUri))
      of ".cfg":
        if name == "nim": result.cfg = some(CfgFile(uri: fUri))
        else: result.nimCfgs.add(NimCfgFile(uri: fUri))
      else: result.otherFiles.add(fUri)
  
  if result.isNimbleProject:
    let
      nimbleExe = result.nimbleExe
      path = result.uri.uriToPath
    if nimbleExe == "":
      raise newException(NimbleExeNotFound, "Did not find nimble executable")
    var
      d = execCmdEx(nimbleExe & " dump --json", workingDir = uri.uriToPath)
      t = execCmdEx(nimbleExe & " tasks", workingDir = uri.uriToPath)
      j = d.output.parseJson
      tasksOut = newStringStream(t.output)
    
    template nimble(): NimbleFile = result.nimble.get()
    
    if d.exitCode != 0:
      raise newException(NimbleDumpFailed,
        "Nimble dump exited with code: " & $d.exitCode)
    if t.exitCode != 0:
      raise newException(NimbleTasksFailed,
        "Nimble tasks exited with code: " & $t.exitCode)

    nimble.name = j{"name"}.getStr
    nimble.srcDir = (path / j{"srcDir"}.getStr).pathToUri
    nimble.binDir = (path / j{"binDir"}.getStr).pathToUri
    nimble.backend = j{"backend"}.getStr

    for l in tasksOut.lines():
      let
        possibleTask = l.strip(trailing = false).split("    ", maxsplit = 1)
        (name, desc) = case possibleTask.len
          of 2: (possibleTask[0].parseIdent(), possibleTask[1].strip)
          else: ("", "")
        isTask = name.len > 0
      
      # Because the format isn't reliable, descriptions could be multi-line
      if isTask:
        nimble.tasks.add(NimbleTask(name: name, description: desc))
      else:
        nimble.tasks[nimble.tasks.len - 1].description &= l

when isMainModule:
  from os import parentDir
  from uri import isAbsolute, initUri

  const
    rootUri = parentDir(parentDir(parentDir(currentSourcePath()))).pathToUri

  var
    find = doFind(rootUri)

  echo $find
  
  if find.isNimbleProject:
    echo "It's a nimble project"
  
  for s in ["/test/butts", "file:///test/butts", "/", "/home/foo/../bar/"]:
    let u = parseUri(s)
    echo "Uri: scheme: $1, hostname: $2, authority: $3, path: $4; fsPath: $5" %
      [u.scheme, u.hostname, u.authority, u.path, u.uriToPath]
