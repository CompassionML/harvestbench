## Immediate panel placement using Silky's two-pen layout scopes.

import
  vmath, silky/layout,
  gameuis

export layout

type ScorePanels* = object
  headers*: array[3, GameUiPanel]
  sides*: array[2, GameUiPanel]
  values*: array[2, array[3, GameUiPanel]]

proc stack*(
    panel: GameUiPanel,
    direction: StackDirection,
    padding = vec2(0)
): LayoutScope =
  ## Opens a stack in a known panel without retaining a layout tree.
  initLayoutScope(
    panel.origin + padding,
    max(panel.size - padding * 2, vec2(0)),
    direction
  )

proc take*(
    scope: var LayoutScope,
    size: Vec2,
    spacing = 0.0'f
): GameUiPanel =
  ## Places one fixed panel and advances Silky's position and stretch pens.
  result = GameUiPanel(origin: scope.placedPos(size), size: size)
  scope.advancePen(size, spacing)

proc takeRow*(
    scope: var LayoutScope,
    height: float32,
    spacing = 0.0'f
): GameUiPanel =
  ## Takes a row that fills the known remaining width of a vertical stack.
  assert scope.knownW
  assert scope.direction in {TopToBottom, BottomToTop}
  scope.take(vec2(scope.remainingSpace.x, height), spacing)

proc takeColumn*(
    scope: var LayoutScope,
    width: float32,
    spacing = 0.0'f
): GameUiPanel =
  ## Takes a column that fills the known remaining height of a row stack.
  assert scope.knownH
  assert scope.direction in {LeftToRight, RightToLeft}
  scope.take(vec2(width, scope.remainingSpace.y), spacing)

proc gap*(scope: var LayoutScope, length: float32) =
  ## Advances the main axis by an explicit empty spacer.
  var size = vec2(0)
  size[scope.direction.mainAxis] = length
  discard scope.take(size)

proc takeRest*(scope: var LayoutScope): GameUiPanel =
  ## Fills the known space remaining after earlier siblings.
  assert scope.knownW and scope.knownH
  scope.take(scope.remainingSpace)

proc stackGrid*(
    panel: GameUiPanel,
    size: Vec2,
    columns: int,
    spacing: Vec2,
    cells: var openArray[GameUiPanel]
) =
  ## Places fixed cells in explicit rows, using only current-frame pens.
  assert columns > 0
  var
    rows = panel.stack(TopToBottom)
    row: LayoutScope
  for i in 0 ..< cells.len:
    if i mod columns == 0:
      row = rows.takeRow(size.y, spacing.y).stack(LeftToRight)
    cells[i] = row.take(size, spacing.x)

proc scorePanels*(panel: GameUiPanel): ScorePanels =
  ## Aligns scoreboard headings and both teams to the same three columns.
  var
    rows = panel.stack(TopToBottom, vec2(14, 11))
    headers = rows.takeRow(20).stack(LeftToRight)
  for cell in result.headers.mitems:
    cell = headers.take(vec2(88, 20), 2)
  for team in 0 ..< result.values.len:
    let row = rows.takeRow(25, 5)
    var columns = row.stack(LeftToRight)
    result.sides[team] = GameUiPanel(
      origin: row.origin + vec2(0, 4),
      size: vec2(16)
    )
    for cell in result.values[team].mitems:
      var column = columns.takeColumn(90).stack(LeftToRight)
      column.gap(29)
      cell = column.take(vec2(40, 25))
