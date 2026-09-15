## A small, deterministic BASIC compiler and register-machine interpreter.
## Scripts use int32 values, global one-dimensional arrays, structured if and
## while blocks, subroutines, and bounded logging. Source is compiled once;
## the runtime performs no memory allocation during normal execution.
## Native callbacks are trusted host code, and their own memory is not charged
## to the script's VM memory budget. A bounded string pool at the end of this
## module gives scripts handle-based text through metered host functions.

import
  std/[strutils, tables]

const
  DefaultMaxSourceBytes* = 1 * 1024 * 1024
  DefaultMaxCodeInstructions* = 1_000_000
  DefaultMaxArrays* = 256
  DefaultMaxArrayElements* = 4 * 1024 * 1024
  DefaultMaxGlobals* = 4096
  DefaultMaxHostData* = 1024
  DefaultMaxHostFunctions* = 256
  DefaultMaxRoutines* = 1024
  DefaultMaxParameters* = 64
  DefaultMaxRegisters* = 4096
  MaximumSyntaxDepth* = 64
  DefaultMaxSyntaxDepth* = MaximumSyntaxDepth
  DefaultMaxCallDepth* = 64
  DefaultMaxMemoryBytes* = 64'i64 * 1024 * 1024
  DefaultMaxInstructions* = 10_000_000'i64
  DefaultMaxWorkUnits* = 10_000_000'i64
  DefaultMaxPrintBytes* = 1'i64 * 1024 * 1024
  DefaultMaxPrintEvents* = 100_000'i64
  LogicalFrameBytes = 16'i64
  LogicalHostCallbackBytes = 16'i64
  EmptyArguments: array[0, int32] = []

type
  BasicError* = object of CatchableError

  Limits* = object
    maxSourceBytes*: int
    maxCodeInstructions*: int
    maxArrays*: int
    maxArrayElements*: int
    maxGlobals*: int
    maxHostData*: int
    maxHostFunctions*: int
    maxRoutines*: int
    maxParameters*: int
    maxRegisters*: int
    maxSyntaxDepth*: int
    maxCallDepth*: int
    maxMemoryBytes*: int64
    maxInstructions*: int64
    maxWorkUnits*: int64
    maxPrintBytes*: int64
    maxPrintEvents*: int64

  PrintKind* = enum
    TextPrint,
    ValuePrint,
    NewlinePrint

  PrintEvent* = object
    kind*: PrintKind
    text*: string
    value*: int32

  PrintProc* = proc(event: PrintEvent) {.closure.}

  HostProc* = proc(arguments: openArray[int32]): int32
    {.closure.}

  HostFunction = object
    name: string
    parameters: int32
    workUnits: int32
    callback: HostProc

  Host* = object
    dataNames: seq[string]
    dataValues: seq[int32]
    dataIds: OrderedTable[string, int32]
    functions: seq[HostFunction]
    functionIds: OrderedTable[string, int32]

  RunStats* = object
    instructions*: int64
    workUnits*: int64
    printBytes*: int64
    printEvents*: int64

  TokenKind = enum
    IdentifierToken,
    IntegerToken,
    StringToken,
    NewlineToken,
    LeftParenToken,
    RightParenToken,
    CommaToken,
    SemicolonToken,
    PlusToken,
    MinusToken,
    StarToken,
    SlashToken,
    EqualToken,
    NotEqualToken,
    LessToken,
    LessEqualToken,
    GreaterToken,
    GreaterEqualToken,
    EndToken

  Token = object
    kind: TokenKind
    text: string
    value: int64
    line: int32
    column: int32

  Op = enum
    MeterOp,
    LoadImmediateOp,
    MoveOp,
    LoadGlobalOp,
    LoadHostDataOp,
    StoreGlobalOp,
    StoreGlobalImmediateOp,
    MoveGlobalOp,
    AddGlobalImmediateOp,
    AddGlobalOp,
    AddGlobalHostDataOp,
    AddGlobalRegisterOp,
    ModuloGlobalImmediateOp,
    AddGlobalArrayGlobalIndexOp,
    AddOp,
    SubtractOp,
    MultiplyOp,
    DivideOp,
    ModuloOp,
    NegateOp,
    EqualOp,
    NotEqualOp,
    LessOp,
    LessEqualOp,
    GreaterOp,
    GreaterEqualOp,
    AndOp,
    OrOp,
    XorOp,
    NotOp,
    JumpOp,
    JumpIfZeroOp,
    JumpUnlessGlobalEqualImmediateOp,
    JumpUnlessGlobalNotEqualImmediateOp,
    JumpUnlessGlobalLessImmediateOp,
    JumpUnlessGlobalLessEqualImmediateOp,
    JumpUnlessGlobalGreaterImmediateOp,
    JumpUnlessGlobalGreaterEqualImmediateOp,
    JumpUnlessGlobalModuloEqualZeroOp,
    ArrayGetOp,
    ArraySetOp,
    ArrayAddGlobalsOp,
    SetArgumentOp,
    SetArgumentImmediateOp,
    SetArgumentGlobalOp,
    HostCallOp,
    CallOp,
    ReturnOp,
    HaltOp,
    PrintTextOp,
    PrintValueOp,
    PrintNewlineOp

  Instruction = object
    op: Op
    a: int32
    b: int32
    c: int32

  BasicArray = object
    name: string
    base: int32
    length: int32

  Routine = object
    name: string
    parameters: seq[string]
    headerStart: int
    bodyStart: int
    bodyEnd: int
    endAfter: int
    entry: int32
    codeLength: int32
    registerCount: int32
    parameterCount: int32

  HostFunctionSpec = object
    name: string
    parameters: int32
    workUnits: int32

  Program* = ref object
    ## A ref so sharing a program copies the handle, not the bytecode.
    code: seq[Instruction]
    arrays: seq[BasicArray]
    routines: seq[Routine]
    literals: seq[string]
    globalNames: seq[string]
    globalIds: OrderedTable[string, int32]
    arrayIds: OrderedTable[string, int32]
    routineIds: OrderedTable[string, int32]
    hostDataNames: seq[string]
    hostDataIds: OrderedTable[string, int32]
    hostFunctions: seq[HostFunctionSpec]
    hostFunctionIds: OrderedTable[string, int32]
    arrayCells: int32
    maxRegisters: int32
    maxParameters: int32

  Frame = object
    base: int32
    routine: int32
    returnPc: int32

  Runtime* = ref object
    program: Program
    limits: Limits
    globals: seq[int32]
    memory: seq[int32]
    registers: seq[int32]
    arguments: seq[int32]
    frames: seq[Frame]
    hostData: seq[int32]
    hostCallbacks: seq[HostProc]
    pc: int32
    base: int32
    routine: int32
    depth: int32
    remainingInstructions: int64
    remainingWork: int64
    printedBytes: int64
    printedEvents: int64
    allocatedBytes: int64
    finished: bool

  Expr = object
    constant: bool
    value: int32
    reg: int32
    temporary: bool

  CallArgument = object
    value: Expr
    start: int
    stop: int

  Compiler = object
    limits: Limits
    tokens: seq[Token]
    program: Program
    literalIds: OrderedTable[string, int32]
    subEnds: OrderedTable[int, int]

  Parser = object
    compiler: ptr Compiler
    routineId: int32
    pos: int
    endPos: int
    code: seq[Instruction]
    parameterIds: OrderedTable[string, int32]
    freeTemps: seq[int32]
    nextTemp: int32
    maxTemps: int32
    syntaxDepth: int32

proc defaultLimits*(): Limits =
  ## Returns conservative defaults suitable for untrusted scripts.
  Limits(
    maxSourceBytes: DefaultMaxSourceBytes,
    maxCodeInstructions: DefaultMaxCodeInstructions,
    maxArrays: DefaultMaxArrays,
    maxArrayElements: DefaultMaxArrayElements,
    maxGlobals: DefaultMaxGlobals,
    maxHostData: DefaultMaxHostData,
    maxHostFunctions: DefaultMaxHostFunctions,
    maxRoutines: DefaultMaxRoutines,
    maxParameters: DefaultMaxParameters,
    maxRegisters: DefaultMaxRegisters,
    maxSyntaxDepth: DefaultMaxSyntaxDepth,
    maxCallDepth: DefaultMaxCallDepth,
    maxMemoryBytes: DefaultMaxMemoryBytes,
    maxInstructions: DefaultMaxInstructions,
    maxWorkUnits: DefaultMaxWorkUnits,
    maxPrintBytes: DefaultMaxPrintBytes,
    maxPrintEvents: DefaultMaxPrintEvents
  )

proc fail(message: string) {.noreturn.} =
  ## Raises a BASIC-specific error without source position information.
  raise newException(BasicError, message)

proc fail(token: Token, message: string)
    {.noreturn.} =
  ## Raises a BASIC-specific error at a source token.
  fail(
    "line " & $token.line & ", column " & $token.column & ": " & message
  )

proc validate(limits: Limits) =
  ## Rejects limits that could disable a sandbox boundary.
  if limits.maxSourceBytes <= 0 or
      limits.maxCodeInstructions <= 0 or
      limits.maxArrays < 0 or
      limits.maxArrayElements < 0 or
      limits.maxGlobals < 0 or
      limits.maxHostData < 0 or
      limits.maxHostFunctions < 0 or
      limits.maxRoutines <= 0 or
      limits.maxParameters < 0 or
      limits.maxRegisters <= 0 or
      limits.maxSyntaxDepth <= 0 or
      limits.maxCallDepth <= 0 or
      limits.maxMemoryBytes < 0 or
      limits.maxInstructions < 0 or
      limits.maxWorkUnits < 0 or
      limits.maxPrintBytes < 0 or
      limits.maxPrintEvents < 0:
    fail("BASIC limits must be non-negative and retain execution capacity.")
  if limits.maxCodeInstructions > high(int32) or
      limits.maxArrays > high(int32) or
      limits.maxArrayElements > high(int32) or
      limits.maxGlobals > high(int32) or
      limits.maxHostData > high(int32) or
      limits.maxHostFunctions > high(int32) or
      limits.maxRoutines > high(int32) or
      limits.maxParameters > high(int32) or
      limits.maxRegisters > high(int32) or
      limits.maxSyntaxDepth > high(int32) or
      limits.maxCallDepth > high(int32):
    fail("BASIC structural limits must fit portable int32 indices.")
  if limits.maxSyntaxDepth > MaximumSyntaxDepth:
    fail("BASIC syntax depth exceeds the portable parser maximum.")

proc isNameStart(c: char): bool {.inline.} =
  ## Returns whether a character can begin a BASIC identifier.
  c in {'a' .. 'z', 'A' .. 'Z', '_'}

proc isNamePart(c: char): bool {.inline.} =
  ## Returns whether a character can continue a BASIC identifier.
  c.isNameStart or c in {'0' .. '9'}

proc normalized(name: string): string =
  ## Normalizes a case-insensitive BASIC name.
  name.toLowerAscii

proc sourceToken(
    kind: TokenKind,
    line: int,
    column: int,
    text = "",
    value = 0'i64
): Token {.inline.} =
  ## Constructs a source token with a compact position.
  Token(
    kind: kind,
    text: text,
    value: value,
    line: int32(line),
    column: int32(column)
  )

proc lex(source: string, limits: Limits): seq[Token] =
  ## Converts BASIC source into a case-insensitive token stream.
  if source.len > limits.maxSourceBytes:
    fail("BASIC source exceeds the configured byte limit.")
  var
    pos = 0
    line = 1
    column = 1
  while pos < source.len:
    let c = source[pos]
    case c
    of ' ', '\t', '\v', '\f':
      inc pos
      inc column
    of '\r', '\n':
      result.add sourceToken(NewlineToken, line, column)
      if c == '\r' and pos + 1 < source.len and source[pos + 1] == '\n':
        inc pos
      inc pos
      inc line
      column = 1
    of ':':
      result.add sourceToken(NewlineToken, line, column)
      inc pos
      inc column
    of '\'':
      while pos < source.len and source[pos] notin {'\r', '\n'}:
        inc pos
        inc column
    of '(':
      result.add sourceToken(LeftParenToken, line, column)
      inc pos
      inc column
    of ')':
      result.add sourceToken(RightParenToken, line, column)
      inc pos
      inc column
    of ',':
      result.add sourceToken(CommaToken, line, column)
      inc pos
      inc column
    of ';':
      result.add sourceToken(SemicolonToken, line, column)
      inc pos
      inc column
    of '+':
      result.add sourceToken(PlusToken, line, column)
      inc pos
      inc column
    of '-':
      result.add sourceToken(MinusToken, line, column)
      inc pos
      inc column
    of '*':
      result.add sourceToken(StarToken, line, column)
      inc pos
      inc column
    of '/':
      result.add sourceToken(SlashToken, line, column)
      inc pos
      inc column
    of '=':
      result.add sourceToken(EqualToken, line, column)
      inc pos
      inc column
    of '<':
      let start = column
      inc pos
      inc column
      if pos < source.len and source[pos] == '=':
        result.add sourceToken(LessEqualToken, line, start)
        inc pos
        inc column
      elif pos < source.len and source[pos] == '>':
        result.add sourceToken(NotEqualToken, line, start)
        inc pos
        inc column
      else:
        result.add sourceToken(LessToken, line, start)
    of '>':
      let start = column
      inc pos
      inc column
      if pos < source.len and source[pos] == '=':
        result.add sourceToken(GreaterEqualToken, line, start)
        inc pos
        inc column
      else:
        result.add sourceToken(GreaterToken, line, start)
    of '"':
      let
        startLine = line
        startColumn = column
      var value = ""
      inc pos
      inc column
      var closed = false
      while pos < source.len:
        if source[pos] in {'\r', '\n'}:
          fail(
            sourceToken(StringToken, startLine, startColumn),
            "unterminated print string"
          )
        if source[pos] == '"':
          if pos + 1 < source.len and source[pos + 1] == '"':
            value.add '"'
            pos += 2
            column += 2
          else:
            inc pos
            inc column
            closed = true
            break
        else:
          value.add source[pos]
          inc pos
          inc column
      if not closed:
        fail(
          sourceToken(StringToken, startLine, startColumn),
          "unterminated print string"
        )
      result.add sourceToken(
        StringToken,
        startLine,
        startColumn,
        value
      )
    of '0' .. '9':
      let
        start = pos
        startColumn = column
      var value = 0'i64
      while pos < source.len and source[pos] in {'0' .. '9'}:
        value = value * 10 + int64(ord(source[pos]) - ord('0'))
        if value > 2_147_483_648'i64:
          fail(
            sourceToken(IntegerToken, line, startColumn),
            "integer literal is outside the int32 range"
          )
        inc pos
        inc column
      result.add sourceToken(
        IntegerToken,
        line,
        startColumn,
        source[start ..< pos],
        value
      )
    else:
      if c.isNameStart:
        let
          start = pos
          startColumn = column
        while pos < source.len and source[pos].isNamePart:
          inc pos
          inc column
        let name = normalized(source[start ..< pos])
        result.add sourceToken(
          IdentifierToken,
          line,
          startColumn,
          name
        )
        if name == "rem":
          while pos < source.len and source[pos] notin {'\r', '\n'}:
            inc pos
            inc column
      else:
        fail(
          sourceToken(EndToken, line, column),
          "unexpected character '" & $c & "'"
        )
  result.add sourceToken(EndToken, line, column)

proc isKeyword(token: Token, word: string): bool
    {.inline.} =
  ## Returns whether a token is a normalized keyword.
  token.kind == IdentifierToken and token.text == word

proc isReserved(name: string): bool =
  ## Returns whether a name is reserved by the BASIC grammar.
  case name
  of "and", "call", "dim", "else", "end", "exit", "false", "gosub",
      "goto", "if", "let", "mod", "not", "or", "print", "rem",
      "return", "stop", "sub", "then", "true", "wend", "while", "xor":
    true
  else:
    false

proc initHost*(): Host =
  ## Creates an empty host interface for data and native functions.
  result.dataIds = initOrderedTable[string, int32]()
  result.functionIds = initOrderedTable[string, int32]()

proc requireHostName(host: Host, name: string): string =
  ## Normalizes and validates one name in the shared BASIC namespace.
  result = normalized(name)
  if result.len == 0 or not result[0].isNameStart:
    fail("invalid BASIC host name '" & name & "'")
  for c in result:
    if not c.isNamePart:
      fail("invalid BASIC host name '" & name & "'")
  if isReserved(result):
    fail("reserved keyword cannot name BASIC host data or a function")
  if host.dataIds.getOrDefault(result, -1'i32) >= 0 or
      host.functionIds.getOrDefault(result, -1'i32) >= 0:
    fail("duplicate BASIC host name '" & name & "'")

proc addData*(host: var Host, name: string, value = 0'i32): int32 =
  ## Exposes one host-controlled read-only int32 value to BASIC.
  let key = host.requireHostName(name)
  result = int32(host.dataNames.len)
  host.dataIds[key] = result
  host.dataNames.add key
  host.dataValues.add value

proc addFunction*(
    host: var Host,
    name: string,
    parameters: int,
    callback: HostProc,
    workUnits = 16
): int32 =
  ## Exposes one trusted int32 host callback to BASIC scripts.
  let key = host.requireHostName(name)
  if parameters < 0 or parameters > high(int32):
    fail("BASIC host function parameter count is outside int32 range")
  if workUnits <= 0 or workUnits > high(int32):
    fail("BASIC host function work cost must be a positive int32")
  if callback == nil:
    fail("BASIC host function callback cannot be nil")
  result = int32(host.functions.len)
  host.functionIds[key] = result
  host.functions.add HostFunction(
    name: key,
    parameters: int32(parameters),
    workUnits: int32(workUnits),
    callback: callback
  )

proc findData(host: Host, name: string): int32 =
  ## Finds host data by its case-insensitive BASIC name.
  host.dataIds.getOrDefault(normalized(name), -1'i32)

proc getData*(host: Host, name: string): int32 =
  ## Reads a configured host data value before runtime creation.
  let id = host.findData(name)
  if id < 0:
    fail("unknown BASIC host data '" & name & "'")
  host.dataValues[int(id)]

proc setData*(host: var Host, name: string, value: int32) =
  ## Updates a host data value used by subsequently created runtimes.
  let id = host.findData(name)
  if id < 0:
    fail("unknown BASIC host data '" & name & "'")
  host.dataValues[int(id)] = value

proc instruction(
    op: Op,
    a = 0'i32,
    b = 0'i32,
    c = 0'i32
): Instruction {.inline.} =
  ## Constructs one register-machine instruction.
  Instruction(op: op, a: a, b: b, c: c)

proc declarationLineEnd(tokens: seq[Token], pos: int): bool
    {.inline.} =
  ## Returns whether a declaration ends at a token position.
  tokens[pos].kind in {NewlineToken, EndToken}

proc addRoutine(
    compiler: var Compiler,
    name: string,
    parameters: seq[string],
    headerStart: int,
    bodyStart: int,
    bodyEnd: int,
    endAfter: int,
    token: Token
) =
  ## Registers a subroutine discovered during the declaration pass.
  if isReserved(name):
    fail(token, "reserved keyword cannot name a subroutine")
  if compiler.program.routineIds.getOrDefault(name, -1'i32) >= 0 or
      compiler.program.arrayIds.getOrDefault(name, -1'i32) >= 0 or
      compiler.program.hostDataIds.getOrDefault(name, -1'i32) >= 0 or
      compiler.program.hostFunctionIds.getOrDefault(name, -1'i32) >= 0:
    fail(token, "duplicate BASIC name '" & name & "'")
  if compiler.program.routines.len >= compiler.limits.maxRoutines:
    fail(token, "subroutine count exceeds the configured limit")
  let id = int32(compiler.program.routines.len)
  compiler.program.routineIds[name] = id
  compiler.program.routines.add Routine(
    name: name,
    parameters: parameters,
    headerStart: headerStart,
    bodyStart: bodyStart,
    bodyEnd: bodyEnd,
    endAfter: endAfter,
    parameterCount: int32(parameters.len)
  )
  compiler.subEnds[headerStart] = endAfter

proc addArray(
    compiler: var Compiler,
    name: string,
    upperBound: int64,
    token: Token
) =
  ## Registers a global array with a QBasic-style inclusive upper bound.
  if isReserved(name):
    fail(token, "reserved keyword cannot name an array")
  if compiler.program.arrayIds.getOrDefault(name, -1'i32) >= 0 or
      compiler.program.routineIds.getOrDefault(name, -1'i32) >= 0 or
      compiler.program.hostDataIds.getOrDefault(name, -1'i32) >= 0 or
      compiler.program.hostFunctionIds.getOrDefault(name, -1'i32) >= 0:
    fail(token, "duplicate BASIC name '" & name & "'")
  if compiler.program.arrays.len >= compiler.limits.maxArrays:
    fail(token, "array count exceeds the configured limit")
  let length = upperBound + 1
  if upperBound < 0 or length > int64(high(int32)):
    fail(token, "array upper bound is outside the supported range")
  let total = int64(compiler.program.arrayCells) + length
  if total > int64(compiler.limits.maxArrayElements):
    fail(token, "array storage exceeds the configured element limit")
  let id = int32(compiler.program.arrays.len)
  compiler.program.arrayIds[name] = id
  compiler.program.arrays.add BasicArray(
    name: name,
    base: compiler.program.arrayCells,
    length: int32(length)
  )
  compiler.program.arrayCells = int32(total)

proc skipNewlines(tokens: seq[Token], pos: var int) =
  ## Advances over consecutive statement separators.
  while tokens[pos].kind == NewlineToken:
    inc pos

proc collectDeclarations(compiler: var Compiler) =
  ## Collects global arrays and subroutine ranges before code generation.
  compiler.program.routines.add Routine(name: "main")
  compiler.program.routineIds["main"] = 0
  var pos = 0
  while compiler.tokens[pos].kind != EndToken:
    compiler.tokens.skipNewlines(pos)
    if compiler.tokens[pos].kind == EndToken:
      break
    if compiler.tokens[pos].isKeyword("sub"):
      let headerStart = pos
      inc pos
      let nameToken = compiler.tokens[pos]
      if nameToken.kind != IdentifierToken:
        fail(nameToken, "expected a subroutine name")
      let name = nameToken.text
      inc pos
      if compiler.tokens[pos].kind != LeftParenToken:
        fail(compiler.tokens[pos], "expected '(' after subroutine name")
      inc pos
      var
        parameters: seq[string]
        parameterIds = initOrderedTable[string, bool]()
      if compiler.tokens[pos].kind != RightParenToken:
        while true:
          let parameter = compiler.tokens[pos]
          if parameter.kind != IdentifierToken or isReserved(parameter.text):
            fail(parameter, "expected a parameter name")
          if parameterIds.getOrDefault(parameter.text, false):
            fail(parameter, "duplicate subroutine parameter")
          if parameters.len >= compiler.limits.maxParameters:
            fail(parameter, "parameter count exceeds the configured limit")
          parameterIds[parameter.text] = true
          parameters.add parameter.text
          inc pos
          if compiler.tokens[pos].kind != CommaToken:
            break
          inc pos
      if compiler.tokens[pos].kind != RightParenToken:
        fail(compiler.tokens[pos], "expected ')' after parameters")
      inc pos
      if not compiler.tokens.declarationLineEnd(pos):
        fail(compiler.tokens[pos], "expected a new line after sub header")
      if compiler.tokens[pos].kind == NewlineToken:
        inc pos
      let bodyStart = pos
      var bodyEnd = -1
      while compiler.tokens[pos].kind != EndToken:
        if compiler.tokens[pos].isKeyword("end") and
            compiler.tokens[pos + 1].isKeyword("sub"):
          bodyEnd = pos
          break
        inc pos
      if bodyEnd < 0:
        fail(nameToken, "subroutine is missing 'end sub'")
      pos += 2
      if not compiler.tokens.declarationLineEnd(pos):
        fail(compiler.tokens[pos], "expected a new line after 'end sub'")
      if compiler.tokens[pos].kind == NewlineToken:
        inc pos
      compiler.addRoutine(
        name,
        parameters,
        headerStart,
        bodyStart,
        bodyEnd,
        pos,
        nameToken
      )
    elif compiler.tokens[pos].isKeyword("dim"):
      inc pos
      let nameToken = compiler.tokens[pos]
      if nameToken.kind != IdentifierToken:
        fail(nameToken, "expected an array name after 'dim'")
      let name = nameToken.text
      inc pos
      if compiler.tokens[pos].kind != LeftParenToken:
        fail(compiler.tokens[pos], "expected '(' after array name")
      inc pos
      let bound = compiler.tokens[pos]
      if bound.kind != IntegerToken:
        fail(bound, "array upper bound must be a non-negative constant")
      inc pos
      if compiler.tokens[pos].kind != RightParenToken:
        fail(compiler.tokens[pos], "expected ')' after array upper bound")
      inc pos
      if not compiler.tokens.declarationLineEnd(pos):
        fail(compiler.tokens[pos], "expected a new line after 'dim'")
      compiler.addArray(name, bound.value, nameToken)
      if compiler.tokens[pos].kind == NewlineToken:
        inc pos
    else:
      while compiler.tokens[pos].kind notin {NewlineToken, EndToken}:
        inc pos
  for routine in compiler.program.routines:
    for parameter in routine.parameters:
      if compiler.program.arrayIds.getOrDefault(parameter, -1'i32) >= 0 or
          compiler.program.routineIds.getOrDefault(parameter, -1'i32) >= 0 or
          compiler.program.hostDataIds.getOrDefault(parameter, -1'i32) >= 0 or
          compiler.program.hostFunctionIds.getOrDefault(
            parameter,
            -1'i32
          ) >= 0:
        fail(
          compiler.tokens[routine.headerStart],
          "parameter '" & parameter & "' conflicts with a global name"
        )

proc current(parser: Parser): Token {.inline.} =
  ## Returns the parser's current token.
  parser.compiler[].tokens[parser.pos]

proc peek(parser: Parser, offset: int): Token {.inline.} =
  ## Returns a token at a small offset from the parser cursor.
  parser.compiler[].tokens[parser.pos + offset]

proc atKeyword(parser: Parser, word: string): bool
    {.inline.} =
  ## Returns whether the parser is positioned at a keyword.
  parser.current.isKeyword(word)

proc atPair(parser: Parser, first, second: string): bool
    {.inline.} =
  ## Returns whether two keywords occur at the parser cursor.
  parser.current.isKeyword(first) and parser.peek(1).isKeyword(second)

proc advance(parser: var Parser): Token {.inline.} =
  ## Consumes and returns one token.
  result = parser.current
  inc parser.pos

proc expectKind(parser: var Parser, kind: TokenKind, message: string): Token =
  ## Consumes a token of an expected kind.
  if parser.current.kind != kind:
    fail(parser.current, message)
  parser.advance

proc expectKeyword(parser: var Parser, word: string) =
  ## Consumes an expected keyword.
  if not parser.atKeyword(word):
    fail(parser.current, "expected '" & word & "'")
  inc parser.pos

proc lineEnd(parser: var Parser) =
  ## Consumes the end of a BASIC statement.
  if parser.pos >= parser.endPos:
    return
  if parser.current.kind == EndToken:
    return
  if parser.current.kind != NewlineToken:
    fail(parser.current, "expected the end of the statement")
  inc parser.pos

proc emit(
    parser: var Parser,
    op: Op,
    a = 0'i32,
    b = 0'i32,
    c = 0'i32
): int =
  ## Appends one unmetered instruction and returns its location.
  if parser.code.len >= parser.compiler[].limits.maxCodeInstructions:
    fail(parser.current, "bytecode exceeds the configured instruction limit")
  result = parser.code.len
  parser.code.add instruction(op, a, b, c)

proc allocateTemp(parser: var Parser): int32 =
  ## Allocates a reusable expression register.
  if parser.freeTemps.len > 0:
    result = parser.freeTemps.pop
  else:
    result = parser.nextTemp
    inc parser.nextTemp
    if parser.nextTemp > int32(parser.compiler[].limits.maxRegisters):
      fail(parser.current, "expression needs too many registers")
    parser.maxTemps = max(parser.maxTemps, parser.nextTemp)

proc release(parser: var Parser, value: Expr) =
  ## Releases a temporary expression register for reuse.
  if value.temporary:
    parser.freeTemps.add value.reg

proc enterSyntax(parser: var Parser) =
  ## Enters one bounded recursive syntax construct.
  inc parser.syntaxDepth
  if parser.syntaxDepth > int32(parser.compiler[].limits.maxSyntaxDepth):
    fail(parser.current, "syntax nesting exceeds the configured limit")

proc leaveSyntax(parser: var Parser) {.inline.} =
  ## Leaves one recursive syntax construct.
  dec parser.syntaxDepth

proc constant(value: int32): Expr {.inline.} =
  ## Constructs a compile-time integer expression.
  Expr(constant: true, value: value)

proc materialize(parser: var Parser, value: var Expr) =
  ## Places a constant expression into a temporary register when needed.
  if value.constant:
    value.reg = parser.allocateTemp
    value.temporary = true
    value.constant = false
    discard parser.emit(LoadImmediateOp, value.reg, value.value)

proc globalId(
    compiler: var Compiler,
    name: string,
    token: Token
): int32 =
  ## Resolves or creates an implicitly declared global int32 variable.
  result = compiler.program.globalIds.getOrDefault(name, -1'i32)
  if result >= 0:
    return
  if compiler.program.arrayIds.getOrDefault(name, -1'i32) >= 0 or
      compiler.program.routineIds.getOrDefault(name, -1'i32) >= 0 or
      compiler.program.hostDataIds.getOrDefault(name, -1'i32) >= 0 or
      compiler.program.hostFunctionIds.getOrDefault(name, -1'i32) >= 0 or
      isReserved(name):
    fail(token, "name '" & name & "' is not a scalar variable")
  if compiler.program.globalNames.len >= compiler.limits.maxGlobals:
    fail(token, "global count exceeds the configured limit")
  result = int32(compiler.program.globalNames.len)
  compiler.program.globalIds[name] = result
  compiler.program.globalNames.add name

proc literalId(compiler: var Compiler, value: string): int32 =
  ## Interns a print-only string literal.
  result = compiler.literalIds.getOrDefault(value, -1'i32)
  if result < 0:
    result = int32(compiler.program.literals.len)
    compiler.literalIds[value] = result
    compiler.program.literals.add value

proc wrapNegate(value: int32): int32 {.inline.} =
  ## Negates an int32 using defined two's-complement wrapping.
  0'i32 -% value

proc safeDivide(left, right: int32): int32
    {.inline.} =
  ## Divides two int32 values with deterministic overflow behavior.
  if right == 0:
    fail("division by zero")
  if left == low(int32) and right == -1:
    return low(int32)
  left div right

proc safeModulo(left, right: int32): int32
    {.inline.} =
  ## Calculates an int32 remainder with deterministic overflow behavior.
  if right == 0:
    fail("division by zero")
  if left == low(int32) and right == -1:
    return 0
  left mod right

proc evaluate(op: Op, left, right: int32): int32 =
  ## Evaluates one binary operation during constant folding.
  case op
  of AddOp: left +% right
  of SubtractOp: left -% right
  of MultiplyOp: left *% right
  of DivideOp: safeDivide(left, right)
  of ModuloOp: safeModulo(left, right)
  of EqualOp: int32(left == right)
  of NotEqualOp: int32(left != right)
  of LessOp: int32(left < right)
  of LessEqualOp: int32(left <= right)
  of GreaterOp: int32(left > right)
  of GreaterEqualOp: int32(left >= right)
  of AndOp: int32(left != 0 and right != 0)
  of OrOp: int32(left != 0 or right != 0)
  of XorOp: int32((left != 0) xor (right != 0))
  else: fail("invalid constant operation")

proc binaryResult(
    parser: var Parser,
    op: Op,
    leftValue: Expr,
    rightValue: Expr
): Expr =
  ## Folds or emits one binary expression operation.
  var
    left = leftValue
    right = rightValue
  if left.constant and right.constant:
    return constant(evaluate(op, left.value, right.value))
  parser.materialize(left)
  parser.materialize(right)
  let destination =
    if left.temporary:
      left.reg
    elif right.temporary:
      right.reg
    else:
      parser.allocateTemp
  discard parser.emit(op, destination, left.reg, right.reg)
  if left.temporary and left.reg != destination:
    parser.release(left)
  if right.temporary and right.reg != destination:
    parser.release(right)
  Expr(reg: destination, temporary: true)

proc precedence(token: Token, op: var Op): int =
  ## Returns the precedence and opcode of a binary operator.
  case token.kind
  of EqualToken: op = EqualOp; 3
  of NotEqualToken: op = NotEqualOp; 3
  of LessToken: op = LessOp; 3
  of LessEqualToken: op = LessEqualOp; 3
  of GreaterToken: op = GreaterOp; 3
  of GreaterEqualToken: op = GreaterEqualOp; 3
  of PlusToken: op = AddOp; 4
  of MinusToken: op = SubtractOp; 4
  of StarToken: op = MultiplyOp; 5
  of SlashToken: op = DivideOp; 5
  of IdentifierToken:
    case token.text
    of "or": op = OrOp; 1
    of "xor": op = XorOp; 1
    of "and": op = AndOp; 2
    of "mod": op = ModuloOp; 5
    else: 0
  else: 0

proc parseExpression(parser: var Parser, minimum = 1): Expr


proc parseHostCall(
    parser: var Parser,
    name: Token,
    keepResult: bool
): Expr


proc parsePrimary(parser: var Parser): Expr =
  ## Parses a literal, scalar, array access, or parenthesized expression.
  let token = parser.advance
  case token.kind
  of IntegerToken:
    if token.value > int64(high(int32)):
      fail(token, "positive integer literal is outside the int32 range")
    result = constant(int32(token.value))
  of LeftParenToken:
    parser.enterSyntax
    result = parser.parseExpression
    discard parser.expectKind(RightParenToken, "expected ')'")
    parser.leaveSyntax
  of IdentifierToken:
    if token.text == "true":
      return constant(1)
    if token.text == "false":
      return constant(0)
    let hostData =
      parser.compiler[].program.hostDataIds.getOrDefault(
        token.text,
        -1'i32
      )
    if hostData >= 0:
      if parser.current.kind == LeftParenToken:
        fail(token, "host data cannot be called as a function")
      let destination = parser.allocateTemp
      discard parser.emit(LoadHostDataOp, destination, hostData)
      return Expr(reg: destination, temporary: true)
    let hostFunction =
      parser.compiler[].program.hostFunctionIds.getOrDefault(
        token.text,
        -1'i32
      )
    if hostFunction >= 0:
      if parser.current.kind != LeftParenToken:
        fail(token, "host function call requires parentheses")
      return parser.parseHostCall(token, true)
    let arrayId =
      parser.compiler[].program.arrayIds.getOrDefault(token.text, -1'i32)
    if arrayId >= 0:
      discard parser.expectKind(
        LeftParenToken,
        "expected '(' after array name"
      )
      var index = parser.parseExpression
      discard parser.expectKind(RightParenToken, "expected ')' after index")
      parser.materialize(index)
      let destination =
        if index.temporary:
          index.reg
        else:
          parser.allocateTemp
      discard parser.emit(ArrayGetOp, destination, arrayId, index.reg)
      return Expr(reg: destination, temporary: true)
    if parser.current.kind == LeftParenToken and
        parser.compiler[].program.routineIds.getOrDefault(
          token.text,
          -1'i32
        ) >= 0:
      fail(token, "subroutines do not return expression values")
    let parameter = parser.parameterIds.getOrDefault(token.text, -1'i32)
    if parameter >= 0:
      return Expr(reg: parameter)
    let id = parser.compiler[].globalId(token.text, token)
    let destination = parser.allocateTemp
    discard parser.emit(LoadGlobalOp, destination, id)
    result = Expr(reg: destination, temporary: true)
  else:
    fail(token, "expected an integer expression")

proc parseUnary(parser: var Parser): Expr =
  ## Parses unary plus, minus, and logical not.
  if parser.current.kind == PlusToken:
    inc parser.pos
    parser.enterSyntax
    result = parser.parseUnary
    parser.leaveSyntax
    return
  if parser.current.kind == MinusToken:
    discard parser.advance
    if parser.current.kind == IntegerToken and
        parser.current.value == 2_147_483_648'i64:
      inc parser.pos
      return constant(low(int32))
    parser.enterSyntax
    var value = parser.parseUnary
    parser.leaveSyntax
    if value.constant:
      return constant(wrapNegate(value.value))
    parser.materialize(value)
    let destination =
      if value.temporary:
        value.reg
      else:
        parser.allocateTemp
    discard parser.emit(NegateOp, destination, value.reg)
    return Expr(reg: destination, temporary: true)
  if parser.atKeyword("not"):
    inc parser.pos
    parser.enterSyntax
    var value = parser.parseUnary
    parser.leaveSyntax
    if value.constant:
      return constant(int32(value.value == 0))
    parser.materialize(value)
    let destination =
      if value.temporary:
        value.reg
      else:
        parser.allocateTemp
    discard parser.emit(NotOp, destination, value.reg)
    return Expr(reg: destination, temporary: true)
  parser.parsePrimary

proc parseExpression(parser: var Parser, minimum = 1): Expr =
  ## Parses a precedence-ordered integer expression.
  result = parser.parseUnary
  while true:
    var op = AddOp
    let level = precedence(parser.current, op)
    if level < minimum:
      break
    inc parser.pos
    let right = parser.parseExpression(level + 1)
    result = parser.binaryResult(op, result, right)

proc parseDim(parser: var Parser) =
  ## Validates and consumes a top-level global array declaration.
  let keyword = parser.advance
  if parser.routineId != 0 or parser.syntaxDepth != 0:
    fail(keyword, "arrays can only be declared at top level")
  let name = parser.expectKind(IdentifierToken, "expected an array name")
  discard parser.expectKind(LeftParenToken, "expected '(' after array name")
  discard parser.expectKind(IntegerToken, "expected an array upper bound")
  discard parser.expectKind(RightParenToken, "expected ')' after array bound")
  parser.lineEnd

proc fusesAdd(
    operation, first, second: Instruction,
    destination: int32
): bool {.inline.} =
  ## Returns whether three instructions form one two-input addition.
  operation.op == AddOp and operation.a == destination and
    ((operation.b == first.a and operation.c == second.a) or
    (operation.b == second.a and operation.c == first.a))

proc fuseGlobalAssignment(
    parser: var Parser,
    start: int,
    global: int32,
    value: Expr
): bool =
  ## Fuses common scalar assignments into direct global operations.
  let count = parser.code.len - start
  if count == 1:
    let item = parser.code[start]
    if item.a != value.reg:
      return
    case item.op
    of LoadImmediateOp:
      parser.code.setLen(start)
      discard parser.emit(StoreGlobalImmediateOp, global, item.b)
      return true
    of LoadGlobalOp:
      parser.code.setLen(start)
      discard parser.emit(MoveGlobalOp, global, item.b)
      return true
    else:
      return
  if count == 2:
    let
      first = parser.code[start]
      operation = parser.code[start + 1]
      parameterCount = parser.compiler[].program.routines[
        int(parser.routineId)
      ].parameterCount
    if first.op == LoadGlobalOp and first.b == global and
        operation.op == AddOp and operation.a == value.reg:
      var source = -1'i32
      if operation.b == first.a and operation.c < parameterCount:
        source = operation.c
      elif operation.c == first.a and operation.b < parameterCount:
        source = operation.b
      if source >= 0:
        parser.code.setLen(start)
        discard parser.emit(AddGlobalRegisterOp, global, source)
        return true
    return
  if count == 4:
    let
      targetLoad = parser.code[start]
      indexLoad = parser.code[start + 1]
      arrayGet = parser.code[start + 2]
      operation = parser.code[start + 3]
    if targetLoad.op == LoadGlobalOp and targetLoad.b == global and
        indexLoad.op == LoadGlobalOp and
        arrayGet.op == ArrayGetOp and
        arrayGet.a == indexLoad.a and arrayGet.c == indexLoad.a and
        fusesAdd(operation, targetLoad, arrayGet, value.reg):
      parser.code.setLen(start)
      discard parser.emit(
        AddGlobalArrayGlobalIndexOp,
        global,
        arrayGet.b,
        indexLoad.b
      )
      return true
    return
  if count != 3:
    return
  let
    first = parser.code[start]
    second = parser.code[start + 1]
    operation = parser.code[start + 2]
  if first.op == LoadGlobalOp and second.op == LoadImmediateOp and
      operation.op == ModuloOp and operation.a == value.reg and
      operation.b == first.a and operation.c == second.a:
    parser.code.setLen(start)
    discard parser.emit(
      ModuloGlobalImmediateOp,
      global,
      first.b,
      second.b
    )
    return true
  if not fusesAdd(operation, first, second, value.reg):
    return
  if first.op == LoadGlobalOp and first.b == global and
      second.op == LoadImmediateOp:
    parser.code.setLen(start)
    discard parser.emit(AddGlobalImmediateOp, global, second.b)
    return true
  if first.op == LoadImmediateOp and
      second.op == LoadGlobalOp and second.b == global:
    parser.code.setLen(start)
    discard parser.emit(AddGlobalImmediateOp, global, first.b)
    return true
  if first.op == LoadGlobalOp and second.op == LoadGlobalOp:
    var source = -1'i32
    if first.b == global:
      source = second.b
    elif second.b == global:
      source = first.b
    if source >= 0:
      parser.code.setLen(start)
      discard parser.emit(AddGlobalOp, global, source)
      return true
  if first.op == LoadGlobalOp and first.b == global and
      second.op == LoadHostDataOp:
    parser.code.setLen(start)
    discard parser.emit(AddGlobalHostDataOp, global, second.b)
    return true
  if first.op == LoadHostDataOp and
      second.op == LoadGlobalOp and second.b == global:
    parser.code.setLen(start)
    discard parser.emit(AddGlobalHostDataOp, global, first.b)
    return true

proc fuseArrayAssignment(
    parser: var Parser,
    start: int,
    array: int32,
    index, value: Expr
): bool =
  ## Fuses an indexed array increment sourced from two globals.
  if parser.code.len - start != 5:
    return
  let
    targetIndex = parser.code[start]
    valueIndex = parser.code[start + 1]
    arrayGet = parser.code[start + 2]
    valueLoad = parser.code[start + 3]
    operation = parser.code[start + 4]
  if targetIndex.op != LoadGlobalOp or targetIndex.a != index.reg or
      valueIndex.op != LoadGlobalOp or
      valueIndex.b != targetIndex.b or
      arrayGet.op != ArrayGetOp or arrayGet.b != array or
      arrayGet.a != valueIndex.a or arrayGet.c != valueIndex.a or
      valueLoad.op != LoadGlobalOp or
      not fusesAdd(operation, arrayGet, valueLoad, value.reg):
    return
  parser.code.setLen(start)
  discard parser.emit(
    ArrayAddGlobalsOp,
    array,
    targetIndex.b,
    valueLoad.b
  )
  true

proc falseBranch(op: Op): Op =
  ## Maps a comparison operation to its direct global-immediate branch.
  case op
  of EqualOp: JumpUnlessGlobalEqualImmediateOp
  of NotEqualOp: JumpUnlessGlobalNotEqualImmediateOp
  of LessOp: JumpUnlessGlobalLessImmediateOp
  of LessEqualOp: JumpUnlessGlobalLessEqualImmediateOp
  of GreaterOp: JumpUnlessGlobalGreaterImmediateOp
  of GreaterEqualOp: JumpUnlessGlobalGreaterEqualImmediateOp
  else: fail("compiler attempted to branch on a non-comparison operation")

proc reverseComparison(op: Op): Op =
  ## Reverses comparison operands while preserving its truth value.
  case op
  of EqualOp, NotEqualOp: op
  of LessOp: GreaterOp
  of LessEqualOp: GreaterEqualOp
  of GreaterOp: LessOp
  of GreaterEqualOp: LessEqualOp
  else: fail("compiler attempted to reverse a non-comparison operation")

proc emitFalseJump(
    parser: var Parser,
    start: int,
    condition: var Expr
): int =
  ## Emits a false branch, fusing a global-immediate comparison when possible.
  parser.materialize(condition)
  if parser.code.len - start == 5:
    let
      globalLoad = parser.code[start]
      divisorLoad = parser.code[start + 1]
      modulo = parser.code[start + 2]
      zeroLoad = parser.code[start + 3]
      comparison = parser.code[start + 4]
    if globalLoad.op == LoadGlobalOp and
        divisorLoad.op == LoadImmediateOp and
        modulo.op == ModuloOp and modulo.a == globalLoad.a and
        modulo.b == globalLoad.a and modulo.c == divisorLoad.a and
        zeroLoad.op == LoadImmediateOp and zeroLoad.b == 0 and
        comparison.op == EqualOp and comparison.a == condition.reg and
        comparison.b == modulo.a and comparison.c == zeroLoad.a:
      parser.code.setLen(start)
      return parser.emit(
        JumpUnlessGlobalModuloEqualZeroOp,
        globalLoad.b,
        divisorLoad.b,
        -1
      )
  if parser.code.len - start == 3:
    let
      first = parser.code[start]
      second = parser.code[start + 1]
      comparison = parser.code[start + 2]
    if comparison.a == condition.reg and
        comparison.op in {
          EqualOp,
          NotEqualOp,
          LessOp,
          LessEqualOp,
          GreaterOp,
          GreaterEqualOp
        }:
      var
        global = -1'i32
        immediate = 0'i32
        compare = comparison.op
      if first.op == LoadGlobalOp and
          second.op == LoadImmediateOp and
          comparison.b == first.a and comparison.c == second.a:
        global = first.b
        immediate = second.b
      elif first.op == LoadImmediateOp and
          second.op == LoadGlobalOp and
          comparison.b == first.a and comparison.c == second.a:
        global = second.b
        immediate = first.b
        compare = reverseComparison(compare)
      if global >= 0:
        parser.code.setLen(start)
        return parser.emit(falseBranch(compare), global, immediate, -1)
  parser.emit(JumpIfZeroOp, condition.reg, -1)

proc patchFalseJump(parser: var Parser, location, target: int) =
  ## Patches either register or fused global false-branch bytecode.
  case parser.code[location].op
  of JumpIfZeroOp:
    parser.code[location].b = int32(target)
  of JumpUnlessGlobalEqualImmediateOp,
      JumpUnlessGlobalNotEqualImmediateOp,
      JumpUnlessGlobalLessImmediateOp,
      JumpUnlessGlobalLessEqualImmediateOp,
      JumpUnlessGlobalGreaterImmediateOp,
      JumpUnlessGlobalGreaterEqualImmediateOp,
      JumpUnlessGlobalModuloEqualZeroOp:
    parser.code[location].c = int32(target)
  else:
    fail("compiler attempted to patch a non-conditional branch")

proc parseAssignment(parser: var Parser, name: Token) =
  ## Compiles scalar or array assignment.
  if parser.compiler[].program.hostDataIds.getOrDefault(
      name.text,
      -1'i32
    ) >= 0:
    fail(name, "host data is read-only")
  if parser.compiler[].program.hostFunctionIds.getOrDefault(
      name.text,
      -1'i32
    ) >= 0:
    fail(name, "host function cannot be assigned")
  let arrayId =
    parser.compiler[].program.arrayIds.getOrDefault(name.text, -1'i32)
  if parser.current.kind == LeftParenToken:
    if arrayId < 0:
      fail(name, "only arrays can be indexed")
    let assignmentStart = parser.code.len
    inc parser.pos
    var index = parser.parseExpression
    discard parser.expectKind(RightParenToken, "expected ')' after index")
    discard parser.expectKind(EqualToken, "expected '=' in assignment")
    var value = parser.parseExpression
    parser.materialize(index)
    parser.materialize(value)
    if not parser.fuseArrayAssignment(
      assignmentStart,
      arrayId,
      index,
      value
    ):
      discard parser.emit(ArraySetOp, arrayId, index.reg, value.reg)
    parser.release(index)
    parser.release(value)
    parser.lineEnd
    return
  if arrayId >= 0:
    fail(name, "array assignment requires an index")
  discard parser.expectKind(EqualToken, "expected '=' in assignment")
  let expressionStart = parser.code.len
  var value = parser.parseExpression
  parser.materialize(value)
  let parameter = parser.parameterIds.getOrDefault(name.text, -1'i32)
  if parameter >= 0:
    discard parser.emit(MoveOp, parameter, value.reg)
  else:
    let id = parser.compiler[].globalId(name.text, name)
    if not parser.fuseGlobalAssignment(expressionStart, id, value):
      discard parser.emit(StoreGlobalOp, id, value.reg)
  parser.release(value)
  parser.lineEnd

proc parseArguments(
    parser: var Parser,
    name: Token,
    expected: int,
    callable: string
): seq[CallArgument] =
  ## Parses call arguments while preserving values across nested calls.
  ## A quoted string argument compiles to its interned literal id, so hosts
  ## can accept references to compile-time text without a runtime string type.
  discard parser.expectKind(
    LeftParenToken,
    "expected '(' after " & callable & " name"
  )
  if parser.current.kind != RightParenToken:
    while true:
      if result.len >= expected:
        fail(parser.current, "too many " & callable & " arguments")
      let start = parser.code.len
      let value =
        if parser.current.kind == StringToken:
          constant(parser.compiler[].literalId(parser.advance.text))
        else:
          parser.parseExpression
      result.add CallArgument(
        value: value,
        start: start,
        stop: parser.code.len
      )
      if parser.current.kind != CommaToken:
        break
      inc parser.pos
  discard parser.expectKind(RightParenToken, "expected ')' after arguments")
  if result.len != expected:
    fail(name, "incorrect " & callable & " argument count")

proc emitArguments(parser: var Parser, arguments: var seq[CallArgument]) =
  ## Moves parsed call arguments into the bounded call scratch space.
  var
    kinds = newSeq[Op](arguments.len)
    operands = newSeq[int32](arguments.len)
  if arguments.len > 0:
    for i in countdown(arguments.high, 0):
      let argument = arguments[i]
      kinds[i] = SetArgumentOp
      if argument.value.constant:
        kinds[i] = SetArgumentImmediateOp
        operands[i] = argument.value.value
      elif argument.stop - argument.start == 1:
        let item = parser.code[argument.start]
        if item.op == LoadGlobalOp and item.a == argument.value.reg:
          kinds[i] = SetArgumentGlobalOp
          operands[i] = item.b
          parser.code.delete(argument.start)
  for i, argument in arguments:
    case kinds[i]
    of SetArgumentImmediateOp, SetArgumentGlobalOp:
      discard parser.emit(kinds[i], int32(i), operands[i])
    else:
      discard parser.emit(SetArgumentOp, int32(i), argument.value.reg)
    parser.release(argument.value)

proc parseHostCall(
    parser: var Parser,
    name: Token,
    keepResult: bool
): Expr =
  ## Compiles a trusted host function call that returns one int32 value.
  let functionId =
    parser.compiler[].program.hostFunctionIds.getOrDefault(
      name.text,
      -1'i32
    )
  if functionId < 0:
    fail(name, "unknown host function '" & name.text & "'")
  let function =
    parser.compiler[].program.hostFunctions[int(functionId)]
  var arguments = parser.parseArguments(
    name,
    int(function.parameters),
    "host function"
  )
  parser.emitArguments(arguments)
  let destination =
    if keepResult:
      parser.allocateTemp
    else:
      -1'i32
  discard parser.emit(
    HostCallOp,
    destination,
    functionId,
    function.workUnits
  )
  if keepResult:
    result = Expr(reg: destination, temporary: true)

proc parseCall(parser: var Parser, name: Token) =
  ## Compiles a subroutine or discarded-result host function call.
  let routine =
    parser.compiler[].program.routineIds.getOrDefault(name.text, -1'i32)
  if routine > 0:
    let count =
      int(parser.compiler[].program.routines[int(routine)].parameterCount)
    var arguments = parser.parseArguments(name, count, "subroutine")
    parser.emitArguments(arguments)
    discard parser.emit(CallOp, routine)
  elif parser.compiler[].program.hostFunctionIds.getOrDefault(
      name.text,
      -1'i32
    ) >= 0:
    discard parser.parseHostCall(name, false)
  else:
    fail(name, "unknown callable '" & name.text & "'")
  parser.lineEnd

proc parsePrint(parser: var Parser) =
  ## Compiles bounded print events without runtime string construction.
  discard parser.advance
  var trailingSemicolon = false
  while parser.pos < parser.endPos and
      parser.current.kind notin {NewlineToken, EndToken}:
    trailingSemicolon = false
    if parser.current.kind == StringToken:
      let token = parser.advance
      let id = parser.compiler[].literalId(token.text)
      discard parser.emit(PrintTextOp, id)
    else:
      var value = parser.parseExpression
      parser.materialize(value)
      discard parser.emit(PrintValueOp, value.reg)
      parser.release(value)
    if parser.current.kind == SemicolonToken:
      trailingSemicolon = true
      inc parser.pos
    elif parser.current.kind == CommaToken:
      let id = parser.compiler[].literalId(" ")
      discard parser.emit(PrintTextOp, id)
      inc parser.pos
    else:
      break
  if not trailingSemicolon:
    discard parser.emit(PrintNewlineOp)
  parser.lineEnd

proc parseStatement(parser: var Parser)

proc parseIf(parser: var Parser) =
  ## Compiles a structured multiline if, else, and end-if block.
  parser.enterSyntax
  discard parser.advance
  let conditionStart = parser.code.len
  var condition = parser.parseExpression
  parser.expectKeyword("then")
  parser.lineEnd
  let falseJump = parser.emitFalseJump(conditionStart, condition)
  parser.release(condition)
  while parser.pos < parser.endPos and
      not parser.atKeyword("else") and
      not parser.atPair("end", "if"):
    parser.parseStatement
  if parser.pos >= parser.endPos:
    fail(parser.current, "if block is missing 'end if'")
  if parser.atKeyword("else"):
    inc parser.pos
    parser.lineEnd
    let endJump = parser.emit(JumpOp, -1)
    parser.patchFalseJump(falseJump, parser.code.len)
    while parser.pos < parser.endPos and
        not parser.atPair("end", "if"):
      parser.parseStatement
    if parser.pos >= parser.endPos:
      fail(parser.current, "if block is missing 'end if'")
    parser.code[endJump].a = int32(parser.code.len)
  else:
    parser.patchFalseJump(falseJump, parser.code.len)
  parser.expectKeyword("end")
  parser.expectKeyword("if")
  parser.lineEnd
  parser.leaveSyntax

proc parseWhile(parser: var Parser) =
  ## Compiles a QBasic-style while and wend loop.
  parser.enterSyntax
  discard parser.advance
  let loopStart = int32(parser.code.len)
  let conditionStart = parser.code.len
  var condition = parser.parseExpression
  parser.lineEnd
  let endJump = parser.emitFalseJump(conditionStart, condition)
  parser.release(condition)
  while parser.pos < parser.endPos and not parser.atKeyword("wend"):
    parser.parseStatement
  if parser.pos >= parser.endPos:
    fail(parser.current, "while block is missing 'wend'")
  parser.expectKeyword("wend")
  parser.lineEnd
  discard parser.emit(JumpOp, loopStart)
  parser.patchFalseJump(endJump, parser.code.len)
  parser.leaveSyntax

proc parseReturn(parser: var Parser) =
  ## Compiles an explicit return from a subroutine.
  let token = parser.advance
  if parser.routineId == 0:
    fail(token, "return can only be used inside a subroutine")
  discard parser.emit(ReturnOp)
  parser.lineEnd

proc parseExit(parser: var Parser) =
  ## Compiles QBasic-style exit sub syntax.
  let token = parser.advance
  parser.expectKeyword("sub")
  if parser.routineId == 0:
    fail(token, "exit sub can only be used inside a subroutine")
  discard parser.emit(ReturnOp)
  parser.lineEnd

proc parseStatement(parser: var Parser) =
  ## Compiles one complete BASIC statement.
  while parser.pos < parser.endPos and
      parser.current.kind == NewlineToken:
    inc parser.pos
  if parser.pos >= parser.endPos or parser.current.kind == EndToken:
    return
  if parser.routineId == 0:
    let skip = parser.compiler[].subEnds.getOrDefault(parser.pos, -1)
    if skip >= 0:
      if parser.syntaxDepth != 0:
        fail(parser.current, "subroutines can only be declared at top level")
      parser.pos = skip
      return
  if parser.atKeyword("dim"):
    parser.parseDim
  elif parser.atKeyword("if"):
    parser.parseIf
  elif parser.atKeyword("while"):
    parser.parseWhile
  elif parser.atKeyword("print"):
    parser.parsePrint
  elif parser.atKeyword("return"):
    parser.parseReturn
  elif parser.atKeyword("exit"):
    parser.parseExit
  elif parser.atKeyword("stop"):
    discard parser.advance
    discard parser.emit(HaltOp)
    parser.lineEnd
  elif parser.atKeyword("end"):
    let token = parser.advance
    if parser.atKeyword("if") or parser.atKeyword("sub"):
      fail(token, "unexpected block terminator")
    discard parser.emit(HaltOp)
    parser.lineEnd
  elif parser.atKeyword("rem"):
    while parser.pos < parser.endPos and
        parser.current.kind notin {NewlineToken, EndToken}:
      inc parser.pos
    parser.lineEnd
  elif parser.atKeyword("call"):
    discard parser.advance
    let name = parser.expectKind(
      IdentifierToken,
      "expected a subroutine name after 'call'"
    )
    parser.parseCall(name)
  elif parser.atKeyword("let"):
    discard parser.advance
    let name = parser.expectKind(
      IdentifierToken,
      "expected a variable name after 'let'"
    )
    parser.parseAssignment(name)
  elif parser.current.kind == IdentifierToken:
    let name = parser.advance
    if parser.current.kind == EqualToken or
        parser.compiler[].program.arrayIds.getOrDefault(
          name.text,
          -1'i32
        ) >= 0:
      parser.parseAssignment(name)
    elif parser.current.kind == LeftParenToken:
      parser.parseCall(name)
    else:
      fail(name, "expected an assignment or subroutine call")
  else:
    fail(parser.current, "unexpected token at the start of a statement")

proc workCost(item: Instruction): int32 {.inline.} =
  ## Returns a deterministic weight for one bytecode operation.
  case item.op
  of HostCallOp:
    item.c
  of DivideOp, ModuloOp, PrintTextOp, PrintValueOp, PrintNewlineOp:
    4
  of StoreGlobalImmediateOp, MoveGlobalOp, SetArgumentImmediateOp,
      SetArgumentGlobalOp:
    2
  of AddGlobalRegisterOp:
    3
  of AddGlobalImmediateOp, AddGlobalOp, AddGlobalHostDataOp,
      JumpUnlessGlobalEqualImmediateOp,
      JumpUnlessGlobalNotEqualImmediateOp,
      JumpUnlessGlobalLessImmediateOp,
      JumpUnlessGlobalLessEqualImmediateOp,
      JumpUnlessGlobalGreaterImmediateOp,
      JumpUnlessGlobalGreaterEqualImmediateOp:
    4
  of AddGlobalArrayGlobalIndexOp:
    6
  of ModuloGlobalImmediateOp:
    7
  of ArrayAddGlobalsOp:
    8
  of JumpUnlessGlobalModuloEqualZeroOp:
    9
  of CallOp:
    8
  of ArrayGetOp, ArraySetOp:
    2
  else:
    1

proc meter(raw: seq[Instruction]): seq[Instruction] =
  ## Inserts one budget check at each register-code basic block.
  if raw.len == 0:
    return
  var starts = newSeq[bool](raw.len)
  starts[0] = true
  for i, item in raw:
    template markTarget(target: int32) =
      if target < 0 or int(target) >= raw.len:
        fail("compiler produced an invalid branch target")
      starts[int(target)] = true
    case item.op
    of JumpOp:
      markTarget(item.a)
      if i + 1 < raw.len:
        starts[i + 1] = true
    of JumpIfZeroOp:
      markTarget(item.b)
      if i + 1 < raw.len:
        starts[i + 1] = true
    of JumpUnlessGlobalEqualImmediateOp,
        JumpUnlessGlobalNotEqualImmediateOp,
        JumpUnlessGlobalLessImmediateOp,
        JumpUnlessGlobalLessEqualImmediateOp,
        JumpUnlessGlobalGreaterImmediateOp,
        JumpUnlessGlobalGreaterEqualImmediateOp,
        JumpUnlessGlobalModuloEqualZeroOp:
      markTarget(item.c)
      if i + 1 < raw.len:
        starts[i + 1] = true
    of HostCallOp, CallOp, ReturnOp, HaltOp:
      if i + 1 < raw.len:
        starts[i + 1] = true
    else:
      discard
  var targets = newSeq[int32](raw.len)
  for i in 0 ..< raw.len:
    targets[i] = -1
  var i = 0
  while i < raw.len:
    if starts[i]:
      var next = i + 1
      while next < raw.len and not starts[next]:
        inc next
      var cost = 0'i64
      for item in raw.toOpenArray(i, next - 1):
        cost += int64(item.workCost)
      if cost > int64(high(int32)):
        fail("compiler produced a basic block with excessive work cost")
      targets[i] = int32(result.len)
      result.add instruction(MeterOp, int32(cost), int32(next - i))
    result.add raw[i]
    inc i
  for item in result.mitems:
    case item.op
    of JumpOp:
      item.a = targets[int(item.a)]
    of JumpIfZeroOp:
      item.b = targets[int(item.b)]
    of JumpUnlessGlobalEqualImmediateOp,
        JumpUnlessGlobalNotEqualImmediateOp,
        JumpUnlessGlobalLessImmediateOp,
        JumpUnlessGlobalLessEqualImmediateOp,
        JumpUnlessGlobalGreaterImmediateOp,
        JumpUnlessGlobalGreaterEqualImmediateOp,
        JumpUnlessGlobalModuloEqualZeroOp:
      item.c = targets[int(item.c)]
    else:
      discard

proc appendRoutine(compiler: var Compiler, routineId: int32) =
  ## Compiles, meters, and appends one routine to the immutable program.
  let routine = compiler.program.routines[int(routineId)]
  var parser = Parser(
    compiler: addr compiler,
    routineId: routineId,
    pos: routine.bodyStart,
    endPos: routine.bodyEnd,
    parameterIds: initOrderedTable[string, int32](),
    nextTemp: routine.parameterCount,
    maxTemps: routine.parameterCount
  )
  for i, parameter in routine.parameters:
    parser.parameterIds[parameter] = int32(i)
  while parser.pos < parser.endPos:
    parser.parseStatement
  if routineId == 0:
    discard parser.emit(HaltOp)
  else:
    discard parser.emit(ReturnOp)
  var code = meter(parser.code)
  let base = int32(compiler.program.code.len)
  for item in code.mitems:
    case item.op
    of JumpOp:
      item.a += base
    of JumpIfZeroOp:
      item.b += base
    of JumpUnlessGlobalEqualImmediateOp,
        JumpUnlessGlobalNotEqualImmediateOp,
        JumpUnlessGlobalLessImmediateOp,
        JumpUnlessGlobalLessEqualImmediateOp,
        JumpUnlessGlobalGreaterImmediateOp,
        JumpUnlessGlobalGreaterEqualImmediateOp,
        JumpUnlessGlobalModuloEqualZeroOp:
      item.c += base
    else:
      discard
  if compiler.program.code.len + code.len >
      compiler.limits.maxCodeInstructions:
    fail("bytecode exceeds the configured instruction limit")
  compiler.program.routines[int(routineId)].entry = base
  compiler.program.routines[int(routineId)].codeLength = int32(code.len)
  compiler.program.routines[int(routineId)].registerCount = parser.maxTemps
  compiler.program.maxRegisters = max(
    compiler.program.maxRegisters,
    parser.maxTemps
  )
  compiler.program.maxParameters = max(
    compiler.program.maxParameters,
    routine.parameterCount
  )
  compiler.program.code.add code

proc validRegister(routine: Routine, value: int32): bool
    {.inline.} =
  ## Returns whether an operand addresses a register in its routine.
  value >= 0 and value < routine.registerCount

proc verify(program: Program) =
  ## Verifies all static bytecode indices before trusted execution.
  for routineId, routine in program.routines:
    let
      first = int(routine.entry)
      last = first + int(routine.codeLength)
    if first < 0 or last > program.code.len or first >= last or
        program.code[first].op != MeterOp:
      fail("compiler produced an invalid routine range")
    for pc in first ..< last:
      let item = program.code[pc]
      template requireRegister(value: int32) =
        if not routine.validRegister(value):
          fail("compiler produced an invalid register index")
      template requireTarget(value: int32) =
        if value < int32(first) or value >= int32(last) or
            program.code[int(value)].op != MeterOp:
          fail("compiler produced an invalid branch target")
      template requireGlobal(value: int32) =
        if value < 0 or value >= int32(program.globalNames.len):
          fail("compiler produced an invalid global index")
      template requireArray(value: int32) =
        if value < 0 or value >= int32(program.arrays.len):
          fail("compiler produced an invalid array index")
      template requireHostData(value: int32) =
        if value < 0 or value >= int32(program.hostDataNames.len):
          fail("compiler produced an invalid host data index")
      template requireHostFunction(value: int32) =
        if value < 0 or value >= int32(program.hostFunctions.len):
          fail("compiler produced an invalid host function index")
      case item.op
      of MeterOp:
        if item.a <= 0 or item.b <= 0:
          fail("compiler produced an invalid meter instruction")
      of LoadImmediateOp:
        requireRegister(item.a)
      of MoveOp, NegateOp, NotOp:
        requireRegister(item.a)
        requireRegister(item.b)
      of LoadGlobalOp:
        requireRegister(item.a)
        requireGlobal(item.b)
      of LoadHostDataOp:
        requireRegister(item.a)
        requireHostData(item.b)
      of StoreGlobalOp:
        requireGlobal(item.a)
        requireRegister(item.b)
      of StoreGlobalImmediateOp, AddGlobalImmediateOp:
        requireGlobal(item.a)
      of MoveGlobalOp, AddGlobalOp:
        requireGlobal(item.a)
        requireGlobal(item.b)
      of AddGlobalHostDataOp:
        requireGlobal(item.a)
        requireHostData(item.b)
      of AddGlobalRegisterOp:
        requireGlobal(item.a)
        requireRegister(item.b)
      of ModuloGlobalImmediateOp:
        requireGlobal(item.a)
        requireGlobal(item.b)
      of AddGlobalArrayGlobalIndexOp:
        requireGlobal(item.a)
        requireArray(item.b)
        requireGlobal(item.c)
      of AddOp, SubtractOp, MultiplyOp, DivideOp, ModuloOp, EqualOp,
          NotEqualOp, LessOp, LessEqualOp, GreaterOp, GreaterEqualOp,
          AndOp, OrOp, XorOp:
        requireRegister(item.a)
        requireRegister(item.b)
        requireRegister(item.c)
      of JumpOp:
        requireTarget(item.a)
      of JumpIfZeroOp:
        requireRegister(item.a)
        requireTarget(item.b)
      of JumpUnlessGlobalEqualImmediateOp,
          JumpUnlessGlobalNotEqualImmediateOp,
          JumpUnlessGlobalLessImmediateOp,
          JumpUnlessGlobalLessEqualImmediateOp,
          JumpUnlessGlobalGreaterImmediateOp,
          JumpUnlessGlobalGreaterEqualImmediateOp,
          JumpUnlessGlobalModuloEqualZeroOp:
        requireGlobal(item.a)
        requireTarget(item.c)
      of ArrayGetOp:
        requireRegister(item.a)
        requireArray(item.b)
        requireRegister(item.c)
      of ArraySetOp:
        requireArray(item.a)
        requireRegister(item.b)
        requireRegister(item.c)
      of ArrayAddGlobalsOp:
        requireArray(item.a)
        requireGlobal(item.b)
        requireGlobal(item.c)
      of SetArgumentOp:
        if item.a < 0 or item.a >= program.maxParameters:
          fail("compiler produced an invalid argument index")
        requireRegister(item.b)
      of SetArgumentImmediateOp:
        if item.a < 0 or item.a >= program.maxParameters:
          fail("compiler produced an invalid argument index")
      of SetArgumentGlobalOp:
        if item.a < 0 or item.a >= program.maxParameters:
          fail("compiler produced an invalid argument index")
        requireGlobal(item.b)
      of HostCallOp:
        if item.a < -1:
          fail("compiler produced an invalid host result register")
        if item.a >= 0:
          requireRegister(item.a)
        requireHostFunction(item.b)
        if item.c != program.hostFunctions[int(item.b)].workUnits:
          fail("compiler produced an invalid host function work cost")
      of CallOp:
        if item.a <= 0 or item.a >= int32(program.routines.len):
          fail("compiler produced an invalid call target")
      of PrintTextOp:
        if item.a < 0 or item.a >= int32(program.literals.len):
          fail("compiler produced an invalid print literal")
      of PrintValueOp:
        requireRegister(item.a)
      of ReturnOp:
        if routineId == 0:
          fail("compiler produced a return in the main routine")
      of HaltOp, PrintNewlineOp:
        discard

proc configureHost(
    program: var Program,
    host: Host,
    limits: Limits
) =
  ## Copies a bounded host ABI schema into a program being compiled.
  if host.dataNames.len > limits.maxHostData:
    fail("BASIC host data count exceeds the configured limit")
  if host.functions.len > limits.maxHostFunctions:
    fail("BASIC host function count exceeds the configured limit")
  program.hostDataIds = initOrderedTable[string, int32]()
  program.hostFunctionIds = initOrderedTable[string, int32]()
  for i, name in host.dataNames:
    program.hostDataIds[name] = int32(i)
    program.hostDataNames.add name
  for i, function in host.functions:
    if function.parameters > int32(limits.maxParameters):
      fail("BASIC host function parameter count exceeds the configured limit")
    program.hostFunctionIds[function.name] = int32(i)
    program.hostFunctions.add HostFunctionSpec(
      name: function.name,
      parameters: function.parameters,
      workUnits: function.workUnits
    )
    program.maxParameters = max(
      program.maxParameters,
      function.parameters
    )

proc compileProgram(
    source: string,
    host: Host,
    limits: Limits
): Program =
  ## Compiles BASIC source against one immutable host ABI schema.
  limits.validate
  var compiler = Compiler(
    limits: limits,
    tokens: lex(source, limits),
    program: Program(),
    literalIds: initOrderedTable[string, int32](),
    subEnds: initOrderedTable[int, int]()
  )
  compiler.program.globalIds = initOrderedTable[string, int32]()
  compiler.program.arrayIds = initOrderedTable[string, int32]()
  compiler.program.routineIds = initOrderedTable[string, int32]()
  compiler.program.configureHost(host, limits)
  compiler.collectDeclarations
  compiler.program.routines[0].bodyStart = 0
  compiler.program.routines[0].bodyEnd = compiler.tokens.len - 1
  for routineId in 0 ..< compiler.program.routines.len:
    compiler.appendRoutine(int32(routineId))
  compiler.program.verify
  result = move(compiler.program)

proc compile*(source: string, limits = defaultLimits()): Program =
  ## Compiles BASIC source without host data or native functions.
  let host = initHost()
  compileProgram(source, host, limits)

proc compile*(
    source: string,
    host: Host,
    limits = defaultLimits()
): Program =
  ## Compiles BASIC source with named host data and native functions.
  compileProgram(source, host, limits)

proc portableCells(value: int64, message: string): int =
  ## Converts a bounded cell count to a native sequence length.
  if value < 0 or value > int64(high(int32)):
    fail(message)
  int(value)

proc clear(values: var seq[int32]) =
  ## Clears preallocated int32 storage without changing its capacity.
  if values.len > 0:
    zeroMem(addr values[0], values.len * sizeof(int32))

proc initRuntimeState(
    program: Program,
    host: Host,
    limits: Limits
): Runtime =
  ## Allocates bounded runtime state and binds its trusted host callbacks.
  limits.validate
  if program.code.len == 0:
    fail("cannot execute an empty or uncompiled BASIC program")
  if program.code.len > limits.maxCodeInstructions or
      program.arrays.len > limits.maxArrays or
      program.arrayCells > int32(limits.maxArrayElements) or
      program.globalNames.len > limits.maxGlobals or
      program.hostDataNames.len > limits.maxHostData or
      program.hostFunctions.len > limits.maxHostFunctions or
      program.routines.len > limits.maxRoutines or
      program.maxParameters > int32(limits.maxParameters) or
      program.maxRegisters > int32(limits.maxRegisters):
    fail("compiled BASIC program exceeds the configured structural limits")
  for name in program.hostDataNames:
    if host.dataIds.getOrDefault(name, -1'i32) < 0:
      fail("missing BASIC host data binding '" & name & "'")
  for function in program.hostFunctions:
    let id = host.functionIds.getOrDefault(function.name, -1'i32)
    if id < 0:
      fail("missing BASIC host function binding '" & function.name & "'")
    let binding = host.functions[int(id)]
    if binding.parameters != function.parameters or
        binding.workUnits != function.workUnits or
        binding.callback == nil:
      fail("incompatible BASIC host function binding '" & function.name & "'")
  let
    registerCells =
      int64(program.maxRegisters) * int64(limits.maxCallDepth)
    globalCells = int64(program.globalNames.len)
    arrayCells = int64(program.arrayCells)
    argumentCells = int64(program.maxParameters)
    hostDataCells = int64(program.hostDataNames.len)
    hostCallbackBytes =
      int64(program.hostFunctions.len) * LogicalHostCallbackBytes
  var allocatedBytes =
    int64(limits.maxCallDepth) * LogicalFrameBytes + hostCallbackBytes
  if allocatedBytes > limits.maxMemoryBytes:
    fail("BASIC runtime exceeds the configured memory limit")
  for cells in [
    registerCells,
    globalCells,
    arrayCells,
    argumentCells,
    hostDataCells
  ]:
    if cells > (limits.maxMemoryBytes - allocatedBytes) div 4:
      fail("BASIC runtime exceeds the configured memory limit")
    allocatedBytes += cells * 4
  result = Runtime(
    program: program,
    limits: limits,
    globals: newSeq[int32](portableCells(
      globalCells,
      "too many BASIC globals for this target"
    )),
    memory: newSeq[int32](portableCells(
      arrayCells,
      "too many BASIC array cells for this target"
    )),
    registers: newSeq[int32](portableCells(
      registerCells,
      "too many BASIC registers for this target"
    )),
    arguments: newSeq[int32](portableCells(
      argumentCells,
      "too many BASIC arguments for this target"
    )),
    frames: newSeq[Frame](limits.maxCallDepth),
    hostData: newSeq[int32](program.hostDataNames.len),
    hostCallbacks: newSeq[HostProc](program.hostFunctions.len),
    pc: program.routines[0].entry,
    remainingInstructions: limits.maxInstructions,
    remainingWork: limits.maxWorkUnits,
    allocatedBytes: allocatedBytes
  )
  for i, name in program.hostDataNames:
    let id = host.dataIds.getOrDefault(name, -1'i32)
    result.hostData[i] = host.dataValues[int(id)]
  for i, function in program.hostFunctions:
    let id = host.functionIds.getOrDefault(function.name, -1'i32)
    result.hostCallbacks[i] = host.functions[int(id)].callback

proc initRuntime*(program: Program, limits = defaultLimits()): Runtime =
  ## Allocates a runtime for a program without host bindings.
  let host = initHost()
  initRuntimeState(program, host, limits)

proc initRuntime*(
    program: Program,
    host: Host,
    limits = defaultLimits()
): Runtime =
  ## Allocates a runtime and binds named host data and functions.
  initRuntimeState(program, host, limits)

proc reset*(runtime: var Runtime) =
  ## Restores a runtime to its initial zero-filled program state.
  runtime.globals.clear
  runtime.memory.clear
  runtime.registers.clear
  runtime.arguments.clear
  runtime.pc = runtime.program.routines[0].entry
  runtime.base = 0
  runtime.routine = 0
  runtime.depth = 0
  runtime.remainingInstructions = runtime.limits.maxInstructions
  runtime.remainingWork = runtime.limits.maxWorkUnits
  runtime.printedBytes = 0
  runtime.printedEvents = 0
  runtime.finished = false

proc restart*(runtime: var Runtime) =
  ## Restarts execution and budgets while preserving globals and arrays.
  runtime.registers.clear
  runtime.arguments.clear
  runtime.pc = runtime.program.routines[0].entry
  runtime.base = 0
  runtime.routine = 0
  runtime.depth = 0
  runtime.remainingInstructions = runtime.limits.maxInstructions
  runtime.remainingWork = runtime.limits.maxWorkUnits
  runtime.printedBytes = 0
  runtime.printedEvents = 0
  runtime.finished = false

proc memoryBytes*(runtime: Runtime): int64 {.inline.} =
  ## Returns the logical bytes preallocated for runtime state.
  runtime.allocatedBytes

proc workUsed*(runtime: Runtime): int64 {.inline.} =
  ## Returns work units charged since initialization or the last reset.
  runtime.limits.maxWorkUnits - runtime.remainingWork

proc instructionsUsed*(runtime: Runtime): int64 {.inline.} =
  ## Returns executable VM instructions charged since the last reset.
  runtime.limits.maxInstructions - runtime.remainingInstructions

proc instructions*(program: Program): int {.inline.} =
  ## Returns the number of metered register-machine instructions.
  program.code.len

proc globals*(program: Program): int {.inline.} =
  ## Returns the number of implicitly declared scalar globals.
  program.globalNames.len

proc arrays*(program: Program): int {.inline.} =
  ## Returns the number of declared global arrays.
  program.arrays.len

proc routines*(program: Program): int {.inline.} =
  ## Returns the main routine plus the number of declared subs.
  program.routines.len

proc literalCount*(program: Program): int {.inline.} =
  ## Returns the number of interned compile-time string literals.
  program.literals.len

proc literal*(program: Program, id: int32): string =
  ## Returns one interned print or call-argument literal by its id.
  if id < 0 or int(id) >= program.literals.len:
    fail("unknown BASIC literal id " & $id)
  program.literals[int(id)]

proc findGlobal(program: Program, name: string): int32 =
  ## Finds a global scalar by its case-insensitive source name.
  program.globalIds.getOrDefault(normalized(name), -1'i32)

proc findArray(program: Program, name: string): int32 =
  ## Finds a global array by its case-insensitive source name.
  program.arrayIds.getOrDefault(normalized(name), -1'i32)

proc findHostData(program: Program, name: string): int32 =
  ## Finds bound host data by its case-insensitive source name.
  program.hostDataIds.getOrDefault(normalized(name), -1'i32)

proc hostDataIndex*(program: Program, name: string): int32 =
  ## Returns a host data slot, or -1 when the name is unbound.
  program.findHostData(name)

proc getData*(runtime: Runtime, name: string): int32 =
  ## Reads one host data value currently visible to BASIC.
  let id = runtime.program.findHostData(name)
  if id < 0:
    fail("unknown BASIC host data '" & name & "'")
  runtime.hostData[int(id)]

proc setData*(runtime: var Runtime, id: int32, value: int32) =
  ## Updates one host data slot by its compile-time binding index.
  if id < 0 or id >= int32(runtime.hostData.len):
    fail("unknown BASIC host data id")
  runtime.hostData[int(id)] = value

proc setData*(runtime: var Runtime, name: string, value: int32) =
  ## Updates one host data value without resetting other VM state.
  let id = runtime.program.findHostData(name)
  if id < 0:
    fail("unknown BASIC host data '" & name & "'")
  runtime.hostData[int(id)] = value

proc getGlobal*(runtime: Runtime, name: string): int32 =
  ## Reads a scalar global after case-insensitive name resolution.
  let id = runtime.program.findGlobal(name)
  if id < 0:
    fail("unknown BASIC global '" & name & "'")
  runtime.globals[int(id)]

proc setGlobal*(runtime: var Runtime, name: string, value: int32) =
  ## Writes a scalar global after case-insensitive name resolution.
  let id = runtime.program.findGlobal(name)
  if id < 0:
    fail("unknown BASIC global '" & name & "'")
  runtime.globals[int(id)] = value

proc arrayLength*(runtime: Runtime, name: string): int32 =
  ## Returns an array's element count, including its zero index.
  let id = runtime.program.findArray(name)
  if id < 0:
    fail("unknown BASIC array '" & name & "'")
  runtime.program.arrays[int(id)].length

proc checkedArrayIndex(
    runtime: Runtime,
    arrayId: int32,
    index: int32
): int {.inline.} =
  ## Resolves an array index after one unsigned bounds comparison.
  let
    length = runtime.program.arrays[int(arrayId)].length
    base = runtime.program.arrays[int(arrayId)].base
  if cast[uint32](index) >= cast[uint32](length):
    let name = runtime.program.arrays[int(arrayId)].name
    fail(
      "BASIC array '" & name & "' index " & $index &
      " is outside 0 .. " & $(length - 1)
    )
  int(base + index)

proc getArray*(runtime: Runtime, name: string, index: int32): int32 =
  ## Reads one global array element with an explicit bounds check.
  let id = runtime.program.findArray(name)
  if id < 0:
    fail("unknown BASIC array '" & name & "'")
  runtime.memory[runtime.checkedArrayIndex(id, index)]

proc setArray*(
    runtime: var Runtime,
    name: string,
    index: int32,
    value: int32
) =
  ## Writes one global array element with an explicit bounds check.
  let id = runtime.program.findArray(name)
  if id < 0:
    fail("unknown BASIC array '" & name & "'")
  runtime.memory[runtime.checkedArrayIndex(id, index)] = value

proc printedIntegerBytes(value: int32): int64 =
  ## Counts decimal print bytes without formatting or allocation.
  var magnitude = int64(value)
  result = 1
  if magnitude < 0:
    inc result
    magnitude = -magnitude
  while magnitude >= 10:
    magnitude = magnitude div 10
    inc result

proc chargePrint(runtime: var Runtime, bytes: int64) =
  ## Charges one output event before invoking untrusted host logging.
  if runtime.printedEvents >= runtime.limits.maxPrintEvents:
    fail("BASIC print event limit exceeded")
  if bytes > runtime.limits.maxPrintBytes - runtime.printedBytes:
    fail("BASIC print byte limit exceeded")
  inc runtime.printedEvents
  runtime.printedBytes += bytes

proc run*(runtime: var Runtime, print: PrintProc = nil): RunStats =
  ## Executes verified bytecode with bounded work, memory, calls, and output.
  if runtime.finished:
    return
  let
    startInstructions = runtime.remainingInstructions
    startWork = runtime.remainingWork
    startBytes = runtime.printedBytes
    startEvents = runtime.printedEvents
  template register(index: int32): untyped =
    runtime.registers[int(runtime.base + index)]
  template fetch(): Instruction =
    runtime.program.code[int(runtime.pc)]
  while not runtime.finished:
    var item = fetch()
    if item.op == MeterOp:
      let
        cost = int64(item.a)
        instructionCount = int64(item.b)
      if runtime.remainingInstructions < instructionCount or
          runtime.remainingWork < cost:
        if runtime.remainingInstructions < instructionCount:
          fail("BASIC instruction limit exceeded")
        fail("BASIC work limit exceeded")
      runtime.remainingInstructions -= instructionCount
      runtime.remainingWork -= cost
      inc runtime.pc
      item = fetch()
    case item.op
    of MeterOp:
      fail("BASIC bytecode contains consecutive meter instructions")
    of LoadImmediateOp:
      register(item.a) = item.b
      inc runtime.pc
    of MoveOp:
      register(item.a) = register(item.b)
      inc runtime.pc
    of LoadGlobalOp:
      register(item.a) = runtime.globals[int(item.b)]
      inc runtime.pc
    of LoadHostDataOp:
      register(item.a) = runtime.hostData[int(item.b)]
      inc runtime.pc
    of StoreGlobalOp:
      runtime.globals[int(item.a)] = register(item.b)
      inc runtime.pc
    of StoreGlobalImmediateOp:
      runtime.globals[int(item.a)] = item.b
      inc runtime.pc
    of MoveGlobalOp:
      runtime.globals[int(item.a)] = runtime.globals[int(item.b)]
      inc runtime.pc
    of AddGlobalImmediateOp:
      runtime.globals[int(item.a)] =
        runtime.globals[int(item.a)] +% item.b
      inc runtime.pc
    of AddGlobalOp:
      runtime.globals[int(item.a)] =
        runtime.globals[int(item.a)] +% runtime.globals[int(item.b)]
      inc runtime.pc
    of AddGlobalHostDataOp:
      runtime.globals[int(item.a)] =
        runtime.globals[int(item.a)] +% runtime.hostData[int(item.b)]
      inc runtime.pc
    of AddGlobalRegisterOp:
      runtime.globals[int(item.a)] =
        runtime.globals[int(item.a)] +% register(item.b)
      inc runtime.pc
    of ModuloGlobalImmediateOp:
      runtime.globals[int(item.a)] = safeModulo(
        runtime.globals[int(item.b)],
        item.c
      )
      inc runtime.pc
    of AddGlobalArrayGlobalIndexOp:
      let index = runtime.checkedArrayIndex(
        item.b,
        runtime.globals[int(item.c)]
      )
      runtime.globals[int(item.a)] =
        runtime.globals[int(item.a)] +% runtime.memory[index]
      inc runtime.pc
    of AddOp:
      register(item.a) = register(item.b) +% register(item.c)
      inc runtime.pc
    of SubtractOp:
      register(item.a) = register(item.b) -% register(item.c)
      inc runtime.pc
    of MultiplyOp:
      register(item.a) = register(item.b) *% register(item.c)
      inc runtime.pc
    of DivideOp:
      register(item.a) = safeDivide(register(item.b), register(item.c))
      inc runtime.pc
    of ModuloOp:
      register(item.a) = safeModulo(register(item.b), register(item.c))
      inc runtime.pc
    of NegateOp:
      register(item.a) = wrapNegate(register(item.b))
      inc runtime.pc
    of EqualOp:
      register(item.a) = int32(register(item.b) == register(item.c))
      inc runtime.pc
    of NotEqualOp:
      register(item.a) = int32(register(item.b) != register(item.c))
      inc runtime.pc
    of LessOp:
      register(item.a) = int32(register(item.b) < register(item.c))
      inc runtime.pc
    of LessEqualOp:
      register(item.a) = int32(register(item.b) <= register(item.c))
      inc runtime.pc
    of GreaterOp:
      register(item.a) = int32(register(item.b) > register(item.c))
      inc runtime.pc
    of GreaterEqualOp:
      register(item.a) = int32(register(item.b) >= register(item.c))
      inc runtime.pc
    of AndOp:
      register(item.a) = int32(
        register(item.b) != 0 and register(item.c) != 0
      )
      inc runtime.pc
    of OrOp:
      register(item.a) = int32(
        register(item.b) != 0 or register(item.c) != 0
      )
      inc runtime.pc
    of XorOp:
      register(item.a) = int32(
        (register(item.b) != 0) xor (register(item.c) != 0)
      )
      inc runtime.pc
    of NotOp:
      register(item.a) = int32(register(item.b) == 0)
      inc runtime.pc
    of JumpOp:
      runtime.pc = item.a
    of JumpIfZeroOp:
      if register(item.a) == 0:
        runtime.pc = item.b
      else:
        inc runtime.pc
    of JumpUnlessGlobalEqualImmediateOp:
      if runtime.globals[int(item.a)] != item.b:
        runtime.pc = item.c
      else:
        inc runtime.pc
    of JumpUnlessGlobalNotEqualImmediateOp:
      if runtime.globals[int(item.a)] == item.b:
        runtime.pc = item.c
      else:
        inc runtime.pc
    of JumpUnlessGlobalLessImmediateOp:
      if runtime.globals[int(item.a)] >= item.b:
        runtime.pc = item.c
      else:
        inc runtime.pc
    of JumpUnlessGlobalLessEqualImmediateOp:
      if runtime.globals[int(item.a)] > item.b:
        runtime.pc = item.c
      else:
        inc runtime.pc
    of JumpUnlessGlobalGreaterImmediateOp:
      if runtime.globals[int(item.a)] <= item.b:
        runtime.pc = item.c
      else:
        inc runtime.pc
    of JumpUnlessGlobalGreaterEqualImmediateOp:
      if runtime.globals[int(item.a)] < item.b:
        runtime.pc = item.c
      else:
        inc runtime.pc
    of JumpUnlessGlobalModuloEqualZeroOp:
      if safeModulo(runtime.globals[int(item.a)], item.b) != 0:
        runtime.pc = item.c
      else:
        inc runtime.pc
    of ArrayGetOp:
      let index = runtime.checkedArrayIndex(item.b, register(item.c))
      register(item.a) = runtime.memory[index]
      inc runtime.pc
    of ArraySetOp:
      let index = runtime.checkedArrayIndex(item.a, register(item.b))
      runtime.memory[index] = register(item.c)
      inc runtime.pc
    of ArrayAddGlobalsOp:
      let index = runtime.checkedArrayIndex(
        item.a,
        runtime.globals[int(item.b)]
      )
      runtime.memory[index] =
        runtime.memory[index] +% runtime.globals[int(item.c)]
      inc runtime.pc
    of SetArgumentOp:
      runtime.arguments[int(item.a)] = register(item.b)
      inc runtime.pc
    of SetArgumentImmediateOp:
      runtime.arguments[int(item.a)] = item.b
      inc runtime.pc
    of SetArgumentGlobalOp:
      runtime.arguments[int(item.a)] = runtime.globals[int(item.b)]
      inc runtime.pc
    of HostCallOp:
      let
        functionId = int(item.b)
        count = int(
          runtime.program.hostFunctions[functionId].parameters
        )
        callback = runtime.hostCallbacks[functionId]
      let value =
        if count == 0:
          callback(EmptyArguments)
        else:
          callback(runtime.arguments.toOpenArray(0, count - 1))
      if item.a >= 0:
        register(item.a) = value
      inc runtime.pc
    of CallOp:
      if runtime.depth + 1 >= int32(runtime.frames.len):
        fail("BASIC call depth limit exceeded")
      let
        calleeRegisters =
          runtime.program.routines[int(item.a)].registerCount
        calleeParameters =
          int(runtime.program.routines[int(item.a)].parameterCount)
        calleeEntry = runtime.program.routines[int(item.a)].entry
        callerRegisters =
          runtime.program.routines[int(runtime.routine)].registerCount
        nextBase = runtime.base + callerRegisters
        nextEnd = nextBase + calleeRegisters
      if nextEnd > int32(runtime.registers.len):
        fail("BASIC register stack exceeds its memory limit")
      runtime.frames[int(runtime.depth)] = Frame(
        base: runtime.base,
        routine: runtime.routine,
        returnPc: runtime.pc + 1
      )
      if calleeRegisters > 0:
        zeroMem(
          addr runtime.registers[int(nextBase)],
          int(calleeRegisters) * sizeof(int32)
        )
      for i in 0 ..< calleeParameters:
        runtime.registers[int(nextBase) + i] = runtime.arguments[i]
      inc runtime.depth
      runtime.base = nextBase
      runtime.routine = item.a
      runtime.pc = calleeEntry
    of ReturnOp:
      if runtime.depth == 0:
        runtime.finished = true
      else:
        dec runtime.depth
        let frame = runtime.frames[int(runtime.depth)]
        runtime.base = frame.base
        runtime.routine = frame.routine
        runtime.pc = frame.returnPc
    of HaltOp:
      runtime.finished = true
    of PrintTextOp:
      runtime.chargePrint(
        int64(runtime.program.literals[int(item.a)].len)
      )
      if print != nil:
        print(PrintEvent(
          kind: TextPrint,
          text: runtime.program.literals[int(item.a)]
        ))
      inc runtime.pc
    of PrintValueOp:
      let value = register(item.a)
      runtime.chargePrint(printedIntegerBytes(value))
      if print != nil:
        print(PrintEvent(kind: ValuePrint, value: value))
      inc runtime.pc
    of PrintNewlineOp:
      runtime.chargePrint(1)
      if print != nil:
        print(PrintEvent(kind: NewlinePrint))
      inc runtime.pc
  result = RunStats(
    instructions: startInstructions - runtime.remainingInstructions,
    workUnits: startWork - runtime.remainingWork,
    printBytes: runtime.printedBytes - startBytes,
    printEvents: runtime.printedEvents - startEvents
  )

## String pool
##
## Bounded string values for untrusted scripts.
##
## Scripts never hold string data directly. A string is an int32 handle into
## a per-runtime pool of immutable byte spans, and every operation on one is
## a metered host function, so the register machine stays pure int32 and the
## interpreter needs no string type. The pool preallocates its arena and caps
## the handle count, the total bytes, and the length of any single string, so
## a script that builds strings in a loop hits a deterministic BasicError
## instead of growing host memory. Costly operations are priced for their
## worst case against these caps, and substring search additionally carries
## its own comparison cap because its worst case is quadratic.
##
## The pool is meant to reset alongside `restart` every decision, which makes
## handles ephemeral: nothing a script builds survives into the next decision
## except through host-side channels such as a mailbox. A handle kept in a
## global across decisions goes stale and reads fail deterministically.
##
## Operations that address storage out of range fail hard, like array reads.
## Operations that examine content are lenient, because scripts will parse
## loosely formatted text such as chat from an LLM player: `strVal` of
## non-numeric text is 0, `strFind` of an absent needle is -1, `strMid`
## clamps, and `strWord` past the last word is the empty string.

const
  DefaultMaxStrings* = 256
  DefaultMaxStringBytes* = 64 * 1024
  DefaultMaxStringLength* = 1024
  EmptyHandle* = 0'i32
  SearchCapFactor = 64

type
  StringLimits* = object
    maxStrings*: int
    maxStringBytes*: int
    maxStringLength*: int

  StringSpan = object
    start: int32
    length: int32

  StringPool* = ref object
    limits: StringLimits
    program: Program
    arena: string
    spans: seq[StringSpan]
    literalHandles: seq[int32]

proc defaultStringLimits*(): StringLimits =
  ## Returns conservative defaults suitable for untrusted scripts.
  StringLimits(
    maxStrings: DefaultMaxStrings,
    maxStringBytes: DefaultMaxStringBytes,
    maxStringLength: DefaultMaxStringLength
  )

proc validate(limits: StringLimits) =
  ## Rejects limits that could disable a pool boundary.
  if limits.maxStrings < 1 or
      limits.maxStringBytes < 0 or
      limits.maxStringLength < 1:
    fail("BASIC string limits must retain pool capacity")
  if limits.maxStringLength > limits.maxStringBytes:
    fail("BASIC string length limit exceeds the pool byte limit")
  if limits.maxStrings > high(int32) or
      limits.maxStringBytes > high(int32) or
      limits.maxStringLength > high(int32):
    fail("BASIC string limits must fit portable int32 indices")

proc reset*(pool: StringPool) =
  ## Discards every handle and interned literal while keeping capacity.
  ## Call this alongside `restart` so each decision starts with an empty
  ## pool and stale handles from earlier decisions fail deterministically.
  pool.arena.setLen(0)
  pool.spans.setLen(0)
  pool.spans.add StringSpan()
  for entry in pool.literalHandles.mitems:
    entry = -1

proc initStringPool*(limits = defaultStringLimits()): StringPool =
  ## Preallocates a bounded pool; handle 0 is always the empty string.
  limits.validate
  result = StringPool(
    limits: limits,
    arena: newStringOfCap(limits.maxStringBytes),
    spans: newSeqOfCap[StringSpan](limits.maxStrings)
  )
  result.reset

proc bindProgram*(pool: StringPool, program: Program) =
  ## Attaches the compiled program whose interned literals strNew copies.
  ## Bind after `compile` and before the first run; binding resets the pool.
  pool.program = program
  pool.literalHandles = newSeq[int32](program.literalCount)
  pool.reset

proc stringCount*(pool: StringPool): int =
  ## Returns the live handle count, including the shared empty string.
  pool.spans.len

proc bytesUsed*(pool: StringPool): int =
  ## Returns the arena bytes used since the last reset.
  pool.arena.len

proc checkedSpan(pool: StringPool, handle: int32): StringSpan =
  ## Resolves a handle after one unsigned bounds comparison, so forged
  ## and stale handles fail instead of reading another string's bytes.
  if cast[uint32](handle) >= cast[uint32](pool.spans.len):
    fail("invalid BASIC string handle " & $handle)
  pool.spans[int(handle)]

proc getString*(pool: StringPool, handle: int32): string =
  ## Reads one pooled string for host-side use, such as outgoing mail.
  let span = pool.checkedSpan(handle)
  if span.length == 0:
    return ""
  pool.arena[int(span.start) ..< int(span.start + span.length)]

proc addChecked(pool: StringPool, text: openArray[char]): int32 =
  ## Copies text into the pool, charging every limit before writing.
  if text.len > pool.limits.maxStringLength:
    fail("BASIC string exceeds the configured length limit")
  if text.len == 0:
    return EmptyHandle
  if pool.spans.len >= pool.limits.maxStrings:
    fail("BASIC string count exceeds the configured limit")
  if pool.arena.len + text.len > pool.limits.maxStringBytes:
    fail("BASIC string pool exceeds the configured byte limit")
  let start = int32(pool.arena.len)
  for c in text:
    pool.arena.add c
  result = int32(pool.spans.len)
  pool.spans.add StringSpan(start: start, length: int32(text.len))

proc putString*(pool: StringPool, text: openArray[char]): int32 =
  ## Copies host text, such as incoming mail or an LLM reply, into the
  ## pool, truncating to the single-string length cap. Handle and byte
  ## exhaustion still fail, so hosts should inject bounded batches.
  let length = min(text.len, pool.limits.maxStringLength)
  pool.addChecked(text.toOpenArray(0, length - 1))

proc literalHandle(pool: StringPool, id: int32): int32 =
  ## Returns the pooled copy of one compile-time literal, interning it
  ## once per reset so strNew in a loop cannot exhaust the pool.
  if pool.program == nil:
    fail("BASIC string pool has no program bound")
  if cast[uint32](id) >= cast[uint32](pool.literalHandles.len):
    fail("unknown BASIC literal id " & $id)
  result = pool.literalHandles[int(id)]
  if result >= 0:
    return
  result = pool.addChecked(pool.program.literal(id))
  pool.literalHandles[int(id)] = result

proc concat(pool: StringPool, left, right: int32): int32 =
  ## Joins two strings, rejecting results above the length cap.
  let
    leftSpan = pool.checkedSpan(left)
    rightSpan = pool.checkedSpan(right)
  if int(leftSpan.length) + int(rightSpan.length) >
      pool.limits.maxStringLength:
    fail("BASIC string exceeds the configured length limit")
  if leftSpan.length == 0:
    return right
  if rightSpan.length == 0:
    return left
  pool.addChecked(pool.getString(left) & pool.getString(right))

proc byteAt(pool: StringPool, handle, index: int32): int32 =
  ## Reads one byte with a hard bounds check, like an array element.
  let span = pool.checkedSpan(handle)
  if cast[uint32](index) >= cast[uint32](span.length):
    fail(
      "BASIC string index " & $index &
      " is outside 0 .. " & $(span.length - 1)
    )
  int32(ord(pool.arena[int(span.start + index)]))

proc slice(pool: StringPool, handle, start, length: int32): int32 =
  ## Copies a clamped substring, QBasic MID$ style.
  let span = pool.checkedSpan(handle)
  let begin = clamp(start, 0'i32, span.length)
  let count = clamp(length, 0'i32, span.length - begin)
  if count == 0:
    return EmptyHandle
  if begin == 0 and count == span.length:
    return handle
  pool.addChecked(pool.arena.toOpenArray(
    int(span.start + begin),
    int(span.start + begin + count) - 1
  ))

proc findAt(pool: StringPool, handle, needle, start: int32): int32 =
  ## Searches for a substring from a clamped byte offset, returning -1
  ## when absent. The naive scan's worst case is quadratic, so it fails
  ## once its comparison cap is exceeded rather than stalling the host.
  let
    haystack = pool.getString(handle)
    pattern = pool.getString(needle)
    cap = pool.limits.maxStringLength * SearchCapFactor
    first = int(clamp(start, 0'i32, int32(haystack.len)))
  if pattern.len == 0:
    return int32(first)
  var comparisons = 0
  for base in first .. haystack.len - pattern.len:
    var i = 0
    while i < pattern.len:
      inc comparisons
      if comparisons > cap:
        fail("BASIC string search exceeded its comparison cap")
      if haystack[base + i] != pattern[i]:
        break
      inc i
    if i == pattern.len:
      return int32(base)
  -1

proc parsedValue(pool: StringPool, handle: int32): int32 =
  ## Parses a leading integer, QBasic VAL style: whitespace then an
  ## optional minus then digits. No digits is 0; overflow saturates.
  let text = pool.getString(handle)
  var i = 0
  while i < text.len and text[i] in Whitespace:
    inc i
  var negative = false
  if i < text.len and text[i] == '-':
    negative = true
    inc i
  var
    value = 0'i64
    sawDigit = false
  while i < text.len and text[i] in {'0' .. '9'}:
    sawDigit = true
    if value <= int64(high(int32)):
      value = value * 10 + int64(ord(text[i]) - ord('0'))
    inc i
  if not sawDigit:
    return 0
  if negative:
    int32(max(-value, int64(low(int32))))
  else:
    int32(min(value, int64(high(int32))))

proc wordAt(pool: StringPool, handle, index: int32): int32 =
  ## Returns the whitespace-separated word at an index, or the empty
  ## string past the last word, so parse loops can probe without cost.
  if index < 0:
    return EmptyHandle
  let span = pool.checkedSpan(handle)
  let
    first = int(span.start)
    last = int(span.start + span.length)
  var
    i = first
    count = 0'i32
  while i < last:
    while i < last and pool.arena[i] in Whitespace:
      inc i
    if i >= last:
      break
    let start = i
    while i < last and pool.arena[i] notin Whitespace:
      inc i
    if count == index:
      return pool.addChecked(pool.arena.toOpenArray(start, i - 1))
    inc count
  EmptyHandle

proc wordCount(pool: StringPool, handle: int32): int32 =
  ## Counts whitespace-separated words.
  let span = pool.checkedSpan(handle)
  let last = int(span.start + span.length)
  var i = int(span.start)
  while i < last:
    while i < last and pool.arena[i] in Whitespace:
      inc i
    if i >= last:
      break
    inc result
    while i < last and pool.arena[i] notin Whitespace:
      inc i

proc addStringFunctions*(host: var Host, pool: StringPool) =
  ## Registers the bounded string toolkit onto a host. Work costs are
  ## computed from the pool limits, so the compile-time schema host and
  ## each player's live host must be built with identical limits or
  ## `initRuntime` rejects the binding.
  let
    linearCost = 4 + pool.limits.maxStringLength div 16
    searchCost = 4 + pool.limits.maxStringLength

  let strNewProc: HostProc = proc(arguments: openArray[int32]): int32 =
    pool.literalHandle(arguments[0])
  discard host.addFunction("strNew", 1, strNewProc, linearCost)

  let strLenProc: HostProc = proc(arguments: openArray[int32]): int32 =
    pool.checkedSpan(arguments[0]).length
  discard host.addFunction("strLen", 1, strLenProc, 2)

  let strByteProc: HostProc = proc(arguments: openArray[int32]): int32 =
    pool.byteAt(arguments[0], arguments[1])
  discard host.addFunction("strByte", 2, strByteProc, 3)

  let strAscProc: HostProc = proc(arguments: openArray[int32]): int32 =
    let span = pool.checkedSpan(arguments[0])
    if span.length == 0:
      -1'i32
    else:
      int32(ord(pool.arena[int(span.start)]))
  discard host.addFunction("strAsc", 1, strAscProc, 3)

  let strChrProc: HostProc = proc(arguments: openArray[int32]): int32 =
    if arguments[0] < 0 or arguments[0] > 255:
      fail("BASIC strChr code is outside 0 .. 255")
    pool.addChecked([char(arguments[0])])
  discard host.addFunction("strChr", 1, strChrProc, 6)

  let strFromIntProc: HostProc = proc(arguments: openArray[int32]): int32 =
    pool.addChecked($arguments[0])
  discard host.addFunction("strFromInt", 1, strFromIntProc, 8)

  let strValProc: HostProc = proc(arguments: openArray[int32]): int32 =
    pool.parsedValue(arguments[0])
  discard host.addFunction("strVal", 1, strValProc, linearCost)

  let strCatProc: HostProc = proc(arguments: openArray[int32]): int32 =
    pool.concat(arguments[0], arguments[1])
  discard host.addFunction("strCat", 2, strCatProc, linearCost)

  let strCatIntProc: HostProc = proc(arguments: openArray[int32]): int32 =
    let digits = pool.addChecked($arguments[1])
    pool.concat(arguments[0], digits)
  discard host.addFunction("strCatInt", 2, strCatIntProc, linearCost)

  let strMidProc: HostProc = proc(arguments: openArray[int32]): int32 =
    pool.slice(arguments[0], arguments[1], arguments[2])
  discard host.addFunction("strMid", 3, strMidProc, linearCost)

  let strFindProc: HostProc = proc(arguments: openArray[int32]): int32 =
    pool.findAt(arguments[0], arguments[1], arguments[2])
  discard host.addFunction("strFind", 3, strFindProc, searchCost)

  let strEqProc: HostProc = proc(arguments: openArray[int32]): int32 =
    int32(pool.getString(arguments[0]) == pool.getString(arguments[1]))
  discard host.addFunction("strEq", 2, strEqProc, linearCost)

  let strCmpProc: HostProc = proc(arguments: openArray[int32]): int32 =
    int32(clamp(
      cmp(pool.getString(arguments[0]), pool.getString(arguments[1])),
      -1,
      1
    ))
  discard host.addFunction("strCmp", 2, strCmpProc, linearCost)

  let strWordProc: HostProc = proc(arguments: openArray[int32]): int32 =
    pool.wordAt(arguments[0], arguments[1])
  discard host.addFunction("strWord", 2, strWordProc, linearCost)

  let strWordCountProc: HostProc = proc(arguments: openArray[int32]): int32 =
    pool.wordCount(arguments[0])
  discard host.addFunction("strWordCount", 1, strWordCountProc, linearCost)

  let strUpperProc: HostProc = proc(arguments: openArray[int32]): int32 =
    pool.addChecked(pool.getString(arguments[0]).toUpperAscii)
  discard host.addFunction("strUpper", 1, strUpperProc, linearCost)

  let strLowerProc: HostProc = proc(arguments: openArray[int32]): int32 =
    pool.addChecked(pool.getString(arguments[0]).toLowerAscii)
  discard host.addFunction("strLower", 1, strLowerProc, linearCost)

  let strTrimProc: HostProc = proc(arguments: openArray[int32]): int32 =
    pool.addChecked(pool.getString(arguments[0]).strip)
  discard host.addFunction("strTrim", 1, strTrimProc, linearCost)
