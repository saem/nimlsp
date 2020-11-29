from uri import parseUri, decodeUrl
from strutils import toHex, startsWith, `%`
from os import `/`, normalizedPath, walkDir, PathComponent, splitFile, findExe
from osproc import execCmdEx
from json import parseJson, `{}`, `getStr`

type
  NimbleTask = object
    nimbleUri*: string
    name*: string
    help*: string
  NimbleFile = object
    uri*: string
    name*: string
    srcDir*: string
    binDir*: string
    backend*: string
    tasks*: seq[NimbleTask]
    # add other nimble relevant things here
  FindKind {.pure.} = enum
    fkNimble, fkLoL # LoL - because it could be anything :D
  DirFind = object
    uri*: string
    nimble*: NimbleFile
    cfgs*: seq[string]
    nimscripts*: seq[string]
    nims*: seq[string]
    dirs*: seq[string]
    ignoredDirs*: seq[string]
    otherFiles*: seq[string]
    nimbleExe*: string
  UriParseError* = object of Defect
    uri: string
  MoreThanOneNimble* = object of CatchableError
    uri: string
    existingNimble: string
  NimbleExeNotFound* = object of CatchableError
  NimbleDumpFailed* = object of CatchableError

proc uriToPath(uri: string): string =
  ## Convert an RFC 8089 file URI to a native, platform-specific, absolute path.
  #let startIdx = when defined(windows): 8 else: 7
  #normalizedPath(uri[startIdx..^1])
  let parsed = uri.parseUri
  if parsed.scheme != "file":
    var e = newException(UriParseError, "Invalid scheme: " & parsed.scheme & ", only \"file\" is supported")
    e.uri = uri
    raise e
  if parsed.hostname != "":
    var e = newException(UriParseError, "Invalid hostname: " & parsed.hostname & ", only empty hostname is supported")
    e.uri = uri
    raise e
  return normalizedPath(
    when defined(windows):
      parsed.path[1..^1]
    else:
      parsed.path).decodeUrl

proc pathToUri(path: string, scheme: string = "file"): string =
  ## This is a modified copy of encodeUrl in the uri module. This doesn't encode
  ## the / character, meaning a full file path can be passed in without breaking
  ## it.
  let
    schemeLen = scheme.len + 3 # 3 is for ://
    assumedNonAlnumChars = path.len shr 2 # assume 12% non-alnum-chars
  result = newStringOfCap(schemeLen + path.len + assumedNonAlnumChars)
  result.add scheme
  result.add "://"
  for c in path:
    case c
    # https://tools.ietf.org/html/rfc3986#section-2.3
    of 'a'..'z', 'A'..'Z', '0'..'9', '-', '.', '_', '~', '/': add(result, c)
    else:
      add(result, '%')
      add(result, toHex(ord(c), 2))

proc `$`(f: DirFind): string =
  result = ""
  result.add "uri: " & f.uri & "\n"
  result.add "nimble file: " & $f.nimble & "\n"
  result.add "nims files: " & $f.nimscripts & "\n"
  result.add "cfg files: " & $f.cfgs & "\n"
  result.add "nim files: " & $f.nims & "\n"
  result.add "directories: " & $f.dirs & "\n"
  result.add "other files: " & $f.otherFiles & "\n"
  result.add "ignored directories: " & $f.ignoredDirs & "\n"

proc isNimbleProject(f: DirFind): bool =
  result = f.nimble.uri.len > 0

proc doFind(uri: string): owned DirFind =
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
        if result.nimble.uri.len == 0:
          result.nimble.uri = fUri
        else:
          var e = newException(MoreThanOneNimble,
            "Have $1, also got $2, max one per folder" %
              [result.nimble.uri, fUri])
          e.uri = fUri
          e.existingNimble = result.nimble.uri
          raise e
      of ".nims": result.nimscripts.add(fUri)
      of ".nim": result.nims.add(fUri)
      of ".cfg": result.cfgs.add(fUri)
      else: result.otherFiles.add(fUri)
  
  if result.isNimbleProject:
    let
      nimbleExe = result.nimbleExe
      path = result.uri.uriToPath
    if nimbleExe == "":
      raise newException(NimbleExeNotFound, "Did not find nimble executable")
    var
      d = execCmdEx(nimbleExe & " dump --json", workingDir = uri.uriToPath)
      j = d.output.parseJson
    
    if d.exitCode != 0:
      raise newException(NimbleDumpFailed,
        "Nimble dump exited with code: " & $d.exitCode)

    result.nimble.name = j{"name"}.getStr
    result.nimble.srcDir = path / j{"srcDir"}.getStr
    result.nimble.binDir = path / j{"binDir"}.getStr
    result.nimble.backend = j{"backend"}.getStr

when isMainModule:
  from os import parentDir

  const
    rootUri = parentDir(parentDir(parentDir(currentSourcePath()))).pathToUri

  var
    find = doFind(rootUri)
    nimbleDump = execCmdEx("nimble")

  echo $find
  
  if find.isNimbleProject:
    echo "It's a nimble project"