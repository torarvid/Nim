#
#
#           The Nim Compiler
#        (c) Copyright 2012 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

# This module handles the reading of the config file.

import
  llstream, commands, os, strutils, msgs, lexer,
  options, idents, wordrecg, strtabs, lineinfos, pathutils

# ---------------- configuration file parser -----------------------------
# we use Nim's scanner here to save space and work

proc ppGetTok(L: var TLexer, tok: var TToken) =
  # simple filter
  rawGetTok(L, tok)
  while tok.tokType in {tkComment}: rawGetTok(L, tok)

proc parseExpr(L: var TLexer, tok: var TToken; config: ConfigRef): bool
proc parseAtom(L: var TLexer, tok: var TToken; config: ConfigRef): bool =
  if tok.tokType == tkParLe:
    ppGetTok(L, tok)
    result = parseExpr(L, tok, config)
    if tok.tokType == tkParRi: ppGetTok(L, tok)
    else: lexMessage(L, errGenerated, "expected closing ')'")
  elif tok.tokType == tkNot:
    ppGetTok(L, tok)
    result = not parseAtom(L, tok, config)
  else:
    result = isDefined(config, tok.ident.s)
    ppGetTok(L, tok)

proc parseAndExpr(L: var TLexer, tok: var TToken; config: ConfigRef): bool =
  result = parseAtom(L, tok, config)
  while tok.tokType == tkAnd:
    ppGetTok(L, tok)          # skip "and"
    var b = parseAtom(L, tok, config)
    result = result and b

proc parseExpr(L: var TLexer, tok: var TToken; config: ConfigRef): bool =
  result = parseAndExpr(L, tok, config)
  while tok.tokType == tkOr:
    ppGetTok(L, tok)          # skip "or"
    var b = parseAndExpr(L, tok, config)
    result = result or b

proc evalppIf(L: var TLexer, tok: var TToken; config: ConfigRef): bool =
  ppGetTok(L, tok)            # skip 'if' or 'elif'
  result = parseExpr(L, tok, config)
  if tok.tokType == tkColon: ppGetTok(L, tok)
  else: lexMessage(L, errGenerated, "expected ':'")

#var condStack: seq[bool] = @[]

proc doEnd(L: var TLexer, tok: var TToken; condStack: var seq[bool]) =
  if high(condStack) < 0: lexMessage(L, errGenerated, "expected @if")
  ppGetTok(L, tok)            # skip 'end'
  setLen(condStack, high(condStack))

type
  TJumpDest = enum
    jdEndif, jdElseEndif

proc jumpToDirective(L: var TLexer, tok: var TToken, dest: TJumpDest; config: ConfigRef;
                     condStack: var seq[bool])
proc doElse(L: var TLexer, tok: var TToken; config: ConfigRef; condStack: var seq[bool]) =
  if high(condStack) < 0: lexMessage(L, errGenerated, "expected @if")
  ppGetTok(L, tok)
  if tok.tokType == tkColon: ppGetTok(L, tok)
  if condStack[high(condStack)]: jumpToDirective(L, tok, jdEndif, config, condStack)

proc doElif(L: var TLexer, tok: var TToken; config: ConfigRef; condStack: var seq[bool]) =
  if high(condStack) < 0: lexMessage(L, errGenerated, "expected @if")
  var res = evalppIf(L, tok, config)
  if condStack[high(condStack)] or not res: jumpToDirective(L, tok, jdElseEndif, config, condStack)
  else: condStack[high(condStack)] = true

proc jumpToDirective(L: var TLexer, tok: var TToken, dest: TJumpDest; config: ConfigRef;
                     condStack: var seq[bool]) =
  var nestedIfs = 0
  while true:
    if tok.ident != nil and tok.ident.s == "@":
      ppGetTok(L, tok)
      case whichKeyword(tok.ident)
      of wIf:
        inc(nestedIfs)
      of wElse:
        if dest == jdElseEndif and nestedIfs == 0:
          doElse(L, tok, config, condStack)
          break
      of wElif:
        if dest == jdElseEndif and nestedIfs == 0:
          doElif(L, tok, config, condStack)
          break
      of wEnd:
        if nestedIfs == 0:
          doEnd(L, tok, condStack)
          break
        if nestedIfs > 0: dec(nestedIfs)
      else:
        discard
      ppGetTok(L, tok)
    elif tok.tokType == tkEof:
      lexMessage(L, errGenerated, "expected @end")
    else:
      ppGetTok(L, tok)

proc parseDirective(L: var TLexer, tok: var TToken; config: ConfigRef; condStack: var seq[bool]) =
  ppGetTok(L, tok)            # skip @
  case whichKeyword(tok.ident)
  of wIf:
    setLen(condStack, len(condStack) + 1)
    let res = evalppIf(L, tok, config)
    condStack[high(condStack)] = res
    if not res: jumpToDirective(L, tok, jdElseEndif, config, condStack)
  of wElif: doElif(L, tok, config, condStack)
  of wElse: doElse(L, tok, config, condStack)
  of wEnd: doEnd(L, tok, condStack)
  of wWrite:
    ppGetTok(L, tok)
    msgs.msgWriteln(config, strtabs.`%`($tok, config.configVars,
                                {useEnvironment, useKey}))
    ppGetTok(L, tok)
  else:
    case tok.ident.s.normalize
    of "putenv":
      ppGetTok(L, tok)
      var key = $tok
      ppGetTok(L, tok)
      os.putEnv(key, $tok)
      ppGetTok(L, tok)
    of "prependenv":
      ppGetTok(L, tok)
      var key = $tok
      ppGetTok(L, tok)
      os.putEnv(key, $tok & os.getEnv(key))
      ppGetTok(L, tok)
    of "appendenv":
      ppGetTok(L, tok)
      var key = $tok
      ppGetTok(L, tok)
      os.putEnv(key, os.getEnv(key) & $tok)
      ppGetTok(L, tok)
    else:
      lexMessage(L, errGenerated, "invalid directive: '$1'" % $tok)

proc confTok(L: var TLexer, tok: var TToken; config: ConfigRef; condStack: var seq[bool]) =
  ppGetTok(L, tok)
  while tok.ident != nil and tok.ident.s == "@":
    parseDirective(L, tok, config, condStack)    # else: give the token to the parser

proc checkSymbol(L: TLexer, tok: TToken) =
  if tok.tokType notin {tkSymbol..tkInt64Lit, tkStrLit..tkTripleStrLit}:
    lexMessage(L, errGenerated, "expected identifier, but got: " & $tok)

proc parseAssignment(L: var TLexer, tok: var TToken;
                     config: ConfigRef; condStack: var seq[bool]) =
  if tok.ident.s == "-" or tok.ident.s == "--":
    confTok(L, tok, config, condStack)           # skip unnecessary prefix
  var info = getLineInfo(L, tok) # save for later in case of an error
  checkSymbol(L, tok)
  var s = $tok
  confTok(L, tok, config, condStack)             # skip symbol
  var val = ""
  while tok.tokType == tkDot:
    add(s, '.')
    confTok(L, tok, config, condStack)
    checkSymbol(L, tok)
    add(s, $tok)
    confTok(L, tok, config, condStack)
  if tok.tokType == tkBracketLe:
    # BUGFIX: val, not s!
    confTok(L, tok, config, condStack)
    checkSymbol(L, tok)
    add(val, '[')
    add(val, $tok)
    confTok(L, tok, config, condStack)
    if tok.tokType == tkBracketRi: confTok(L, tok, config, condStack)
    else: lexMessage(L, errGenerated, "expected closing ']'")
    add(val, ']')
  let percent = tok.ident != nil and tok.ident.s == "%="
  if tok.tokType in {tkColon, tkEquals} or percent:
    if len(val) > 0: add(val, ':')
    confTok(L, tok, config, condStack)           # skip ':' or '=' or '%'
    checkSymbol(L, tok)
    add(val, $tok)
    confTok(L, tok, config, condStack)           # skip symbol
    while tok.ident != nil and tok.ident.s == "&":
      confTok(L, tok, config, condStack)
      checkSymbol(L, tok)
      add(val, $tok)
      confTok(L, tok, config, condStack)
  if percent:
    processSwitch(s, strtabs.`%`(val, config.configVars,
                                {useEnvironment, useEmpty}), passPP, info, config)
  else:
    processSwitch(s, val, passPP, info, config)

proc readConfigFile*(filename: AbsoluteFile; cache: IdentCache;
                    config: ConfigRef): bool =
  var
    L: TLexer
    tok: TToken
    stream: PLLStream
  stream = llStreamOpen(filename, fmRead)
  if stream != nil:
    initToken(tok)
    openLexer(L, filename, stream, cache, config)
    tok.tokType = tkEof       # to avoid a pointless warning
    var condStack: seq[bool] = @[]
    confTok(L, tok, config, condStack)           # read in the first token
    while tok.tokType != tkEof: parseAssignment(L, tok, config, condStack)
    if len(condStack) > 0: lexMessage(L, errGenerated, "expected @end")
    closeLexer(L)
    return true

proc getUserConfigPath*(filename: RelativeFile): AbsoluteFile =
  result = getConfigDir().AbsoluteDir / RelativeDir"nim" / filename

proc getSystemConfigPath*(conf: ConfigRef; filename: RelativeFile): AbsoluteFile =
  # try standard configuration file (installation did not distribute files
  # the UNIX way)
  let p = getPrefixDir(conf)
  result = p / RelativeDir"config" / filename
  when defined(unix):
    if not fileExists(result): result = p / RelativeDir"etc/nim" / filename
    if not fileExists(result): result = AbsoluteDir"/etc/nim" / filename

proc loadConfigs*(cfg: RelativeFile; cache: IdentCache; conf: ConfigRef) =
  setDefaultLibpath(conf)

  var configFiles = newSeq[AbsoluteFile]()

  template readConfigFile(path) =
    let configPath = path
    if readConfigFile(configPath, cache, conf):
      add(configFiles, configPath)

  if optSkipSystemConfigFile notin conf.globalOptions:
    readConfigFile(getSystemConfigPath(conf, cfg))

  if optSkipUserConfigFile notin conf.globalOptions:
    readConfigFile(getUserConfigPath(cfg))

  let pd = if not conf.projectPath.isEmpty: conf.projectPath else: AbsoluteDir(getCurrentDir())
  if optSkipParentConfigFiles notin conf.globalOptions:
    for dir in parentDirs(pd.string, fromRoot=true, inclusive=false):
      readConfigFile(AbsoluteDir(dir) / cfg)

  if optSkipProjConfigFile notin conf.globalOptions:
    readConfigFile(pd / cfg)

    if conf.projectName.len != 0:
      # new project wide config file:
      var projectConfig = changeFileExt(conf.projectFull, "nimcfg")
      if not fileExists(projectConfig):
        projectConfig = changeFileExt(conf.projectFull, "nim.cfg")
      readConfigFile(projectConfig)

  for filename in configFiles:
    # delayed to here so that `hintConf` is honored
    rawMessage(conf, hintConf, filename.string)
