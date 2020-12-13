from uri import Uri, parseUri, encodeUrl, decodeUrl, `/`, `$`
from strutils import toHex, startsWith, `%`, replace, find, split, join, strip
from sequtils import mapIt, filterIt, anyIt
from os import `/`, normalizedPath, walkDir, PathComponent, splitFile, findExe,
               isAbsolute, addFileExt, lastPathPart, parentDir, changeFileExt
from osproc import execCmdEx
from json import parseJson, `{}`, `getStr`
from streams import newStringStream, lines
from parseutils import parseIdent
from options import Option, some, none, isSome, isNone, get, map
from tables import OrderedTable, `[]`, `[]=`, hasKey
from hashes import hash, Hash
from sugar import `=>`

type
  ConfigNimsFile = object
    uri*: Uri
  NimFile = object
    uri*: Uri
  NimsFile = object
    uri*: Uri
  CfgFile = object
    uri*: Uri
  NimCfgFile = object
    uri*: Uri
  DirScan = object
    uri*: Uri
    nimble*: Option[Uri]
    cfg*: Option[CfgFile]
    configNims*: Option[ConfigNimsFile]
    nimcfgs*: seq[NimCfgFile]
    nimscripts*: seq[NimsFile]
    nims*: seq[NimFile]
    dirs*: seq[Uri]
    ignoredDirs*: seq[Uri]
    nimbledeps*: Option[Uri]
    otherFiles*: seq[Uri]
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
  ProjectKind {.pure.} = enum
    pkNim, pkNims
  ProjectContext {.pure.} = enum
    pcDir, pcNimble
  Project = object
    projectFile*: Uri
      ## project file for nimsuggest
    projectNimCfg*: bool
      ## projectfile.nim.cfg exists    
    case kind*: ProjectKind:
      of pkNim: projectNims*: bool
        ## projectfile.nims exists
      of pkNims: discard
    case context*: ProjectContext:
      of pcNimble: nimble*: Uri
      of ProjectContext.pcDir: dir*: Uri
        ## directory where context is located
  DirFind = object
    nimbleExe*: string
    start*: Uri
    scanned*: OrderedTable[Uri, DirScan]
    scannedNimble*: OrderedTable[Uri, NimbleFile]
    scannedNim*: OrderedTable[Uri, NimFile]
    scannedNims*: OrderedTable[Uri, NimsFile]
    scannedConfigNims*: OrderedTable[Uri, ConfigNimsFile]
    scannedCfg*: OrderedTable[Uri, CfgFile]
    scannedNimCfg*: OrderedTable[Uri, NimCfgFile]
    projects*: seq[Project]

  UriParseError* = object of Defect
    uri: Uri
  MoreThanOneNimble* = object of CatchableError
    uri: Uri
    existingNimble: Uri
  NimbleExeNotFound* = object of CatchableError
  NimbleDumpFailed* = object of CatchableError
  NimbleTasksFailed* = object of CatchableError

proc hash(u: Uri): Hash = hash($u)
template startDir*(f: DirFind): DirScan = f.scanned[f.start]
template `startDir=`*(f: DirFind, d: DirScan) = f.scanned[f.start] = d

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

proc isNimbleProject(s: DirScan): bool =
  result = s.nimble.isSome

proc scanDir(uri: Uri): DirScan =
  result.uri = uri
  for f in walkDir(result.uri.uriToPath):
    let
      fUri = f.path.pathToUri
      (dir, name, ext) = f.path.splitFile()
    case f.kind
    of pcDir, pcLinkToDir:
      if name.startsWith("."):
        result.ignoredDirs.add(fUri)
      elif name == "nimbledeps":
        # if there is no sibling nimble file at the end move this to dirs
        # see: https://github.com/nim-lang/nimble#nimbles-folder-structure-and-packages
        result.nimbledeps = some(fUri)
      else:
        result.dirs.add(fUri)
    of pcFile, pcLinkToFile:
      case ext
      of ".nimble":
        if result.nimble.isNone:
          result.nimble = some(fUri)
        else:
          var e = newException(MoreThanOneNimble,
            "Have $1, also got $2, max one per folder" %
              [$result.nimble.get, $fUri])
          e.uri = fUri
          e.existingNimble = result.nimble.get
          raise e
      of ".nims":
        if name == "config": result.configNims = some(ConfigNimsFile(uri: fUri))
        else: result.nimscripts.add(NimsFile(uri: fUri))
      of ".nim": result.nims.add(NimFile(uri: fUri))
      of ".cfg":
        if name == "nim": result.cfg = some(CfgFile(uri: fUri))
        else: result.nimCfgs.add(NimCfgFile(uri: fUri))
      else: result.otherFiles.add(fUri)
    
  if result.nimble.isNone and result.nimbledeps.isSome:
    # even if not a nimble project could be a source dir or misconfigured
    result.dirs.add(result.nimbledeps.get)

proc scanDir(f: var DirFind, uri: Uri): DirScan =
  result = scanDir(uri)

  for n in result.nims:
    f.scannedNim[n.uri] = n
  for n in result.nimscripts:
    f.scannedNims[n.uri] = n
  for n in result.nimcfgs:
    f.scannedNimCfg[n.uri] = n
  if result.cfg.isSome:
    f.scannedCfg[result.cfg.get.uri] = result.cfg.get
  if result.configNims.isSome:
    f.scannedConfigNims[result.configNims.get.uri] = result.configNims.get

proc scanNimble(nimbleUri: Uri, nimbleExe: string): owned NimbleFile =
  ## Separately scan nimble information after directory walk.
  ##
  ## Also required to allow handling of `nimbledeps` for local dependencies:
  ## https://github.com/nim-lang/nimble#nimbles-folder-structure-and-packages

  if nimbleExe == "":
    raise newException(NimbleExeNotFound, "Did not find nimble executable")

  let
    path = nimbleUri.uriToPath.parentDir
    d = execCmdEx(nimbleExe & " dump --json", workingDir = path)
    t = execCmdEx(nimbleExe & " tasks", workingDir = path)
    j = d.output.parseJson
    tasksOut = newStringStream(t.output)
  
  if d.exitCode != 0:
    raise newException(NimbleDumpFailed,
      "Nimble dump exited with code: " & $d.exitCode)
  if t.exitCode != 0:
    raise newException(NimbleTasksFailed,
      "Nimble tasks exited with code: " & $t.exitCode)

  result.uri = nimbleUri

  result.name = j{"name"}.getStr
  result.srcDir = (path / j{"srcDir"}.getStr).pathToUri
  result.binDir = (path / j{"binDir"}.getStr).pathToUri
  result.backend = j{"backend"}.getStr

  for l in tasksOut.lines():
    let
      possibleTask = l.strip(trailing = false).split("    ", maxsplit = 1)
      # About the odd split on four spaces:
      # nimble uses 8 spaces, but using four as a "precaution", see:
      # https://github.com/nim-lang/nimble/blob/e658bb5048172a0080725a16c93ac0961714b353/src/nimblepkg/nimscriptapi.nim#L184
      (name, desc) = case possibleTask.len
        of 2: (possibleTask[0].parseIdent(), possibleTask[1].strip)
        else: ("", "")
      isTask = name.len > 0
    
    # Because the format isn't reliable, descriptions could be multi-line
    if isTask:
      result.tasks.add(NimbleTask(name: name, description: desc))
    else:
      result.tasks[result.tasks.len - 1].description &= l

proc getProjects(f: DirFind): seq[Project] =
  if f.startDir.isNimbleProject:
    let
      startDir = f.startDir
      dirName = startDir.uri.uriToPath.lastPathPart
      nimble = f.scannedNimble[startDir.nimble.get]
      name = nimble.name
      srcDir = f.scanned[nimble.srcDir]
      guessProjFilePath = srcDir.uri.uriToPath.parentDir / name.addFileExt("nim")
      guessProjFile = guessProjFilePath.pathToUri
      guessProjFileExists = startDir.nims.anyIt(it.uri == guessProjFile)
      otherProjFiles = f.startDir.nims.filterIt(it.uri != guessProjFile).mapIt(it.uri)
      projFiles = if guessProjFileExists: @[guessProjFile] & otherProjFiles
                  else: otherProjFiles
    
    for n in srcDir.nims:
      result.add(Project(projectFile: n.uri, kind: pkNim, context: pcNimble,
                         nimble: nimble.uri))
    for n in srcDir.nimscripts:
      let possibleNim = n.uri.uriToPath.changeFileExt("nim").pathToUri
      if f.scannedNim.hasKey(possibleNim): continue
      result.add(Project(projectFile: n.uri, kind: pkNims, context: pcNimble,
                         nimble: nimble.uri))

proc doFind(uri: Uri): owned DirFind =
  result = DirFind(start: uri, nimbleExe: findExe("nimble"))

  result.startDir = result.scanDir(uri)

  # Nimble handling
  let
    nimbleExe = result.nimbleExe
    nimble = result.startDir.nimble.map(it => scanNimble(it, nimbleExe))
    srcDirUri = nimble.map(it => it.srcDir)
    isSrcDirScanned = if srcDirUri.isSome: result.scanned.hasKey(srcDirUri.get) else: false
    srcDir = if isSrcDirScanned: some(result.scanned[srcDirUri.get])
             else: some(result.scanDir(srcDirUri.get))
  if nimble.isSome:
    result.scannedNimble[nimble.get.uri] = nimble.get
    if not isSrcDirScanned:
      result.scanned[srcDir.get.uri] = srcDir.get
    
  result.projects = result.getProjects

when isMainModule:
  from os import parentDir
  from uri import isAbsolute, initUri
  from tables import pairs
  from json import `%`, pretty, newJObject, JsonNode, `[]=`

  const
    rootUri = parentDir(parentDir(parentDir(currentSourcePath()))).pathToUri

  var
    find = doFind(rootUri)
  
  proc `%`(u: Uri): JsonNode = % $u
  proc `%`(t: OrderedTable[Uri, DirScan]): JsonNode =
    result = newJObject()
    for key, val in t.pairs: result.fields[$key] = %val
  proc `%`(t: OrderedTable[Uri, NimbleFile]): JsonNode =
    result = newJObject()
    for key, val in t.pairs: result.fields[$key] = %val
  proc `%`(t: OrderedTable[Uri, NimFile]): JsonNode =
    result = newJObject()
    for key, val in t.pairs: result.fields[$key] = %val
  proc `%`(t: OrderedTable[Uri, NimsFile]): JsonNode =
    result = newJObject()
    for key, val in t.pairs: result.fields[$key] = %val
  proc `%`(t: OrderedTable[Uri, ConfigNimsFile]): JsonNode =
    result = newJObject()
    for key, val in t.pairs: result.fields[$key] = %val
  proc `%`(t: OrderedTable[Uri, CfgFile]): JsonNode =
    result = newJObject()
    for key, val in t.pairs: result.fields[$key] = %val
  proc `%`(t: OrderedTable[Uri, NimCfgFile]): JsonNode =
    result = newJObject()
    for key, val in t.pairs: result.fields[$key] = %val
  proc `%`(d: DirScan): JsonNode =
    result = %d
    result["isNimbleProject"] = %true

  echo pretty(%find)
  
  # tests for path Uri conversion
  # for s in ["/test/butts", "file:///test/butts", "/", "/home/foo/../bar/"]:
  #   let u = parseUri(s)
  #   echo "Uri: scheme: $1, hostname: $2, authority: $3, path: $4; fsPath: $5" %
  #     [u.scheme, u.hostname, u.authority, u.path, u.uriToPath]
