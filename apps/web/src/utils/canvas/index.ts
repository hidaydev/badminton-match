// Social export surface: sizes from the community config, pure layouts, thin
// drawing. A page needs `exportDimensions` to size a canvas, a `render*`
// function per composition, and `loadImage` for the photos and logos.

export {
  EXPORT_KEYS,
  EXPORT_MAX_DIMENSION,
  EXPORT_MIN_DIMENSION,
  exportDimensions,
} from './dimensions'
export type { ExportDimensionKey, ExportDimensions } from './dimensions'

export {
  box,
  boxCenter,
  DESIGN,
  insideCanvas,
  transformedBounds,
  unionBounds,
} from './geometry'
export type { CanvasSize, Point, Rect, Transform } from './geometry'

export {
  canvasMeasureText,
  contextTextMeasure,
  edoszFont,
  monoFont,
  ordinal,
  roadRageFont,
  sansFont,
  textBlock,
  truncateToWidth,
} from './text'
export type { TextAlign, TextBlock, TextMeasure, TextSpec } from './text'

export {
  ACCENT,
  BG_DARK,
  BORDER,
  BRAND,
  CANVAS_COLORS,
  FONT_EDOSZ,
  FONT_MONO,
  FONT_ROAD_RAGE,
  FONT_SANS,
  MONTH_ROTATION_DEG,
  MUTED,
  ROAD_RAGE_SKEW_DEG,
  TEXT,
  YEAR_PLATE_ROTATION_DEG,
} from './palette'

export {
  bracketCoverLayout,
  dateOverlayLayout,
  groupSummaryLayout,
  HEADER_HEIGHT,
  HEADER_LOGO_HEIGHT,
  headerLayout,
  matchPostLayout,
  resolveCanvas,
  standingsLayout,
  teamMatchLayout,
  TOURNAMENT_LABEL,
} from './layout'
export type {
  BracketCoverInput,
  BracketCoverLayout,
  BracketRowInput,
  DateOverlayInput,
  DateOverlayLayout,
  GroupRowInput,
  GroupSummaryInput,
  GroupSummaryLayout,
  HeaderInput,
  HeaderLayout,
  MatchPostInput,
  MatchPostLayout,
  RotatedRect,
  StandingsInput,
  StandingsLayout,
  StandingsMeta,
  StandingsRow,
  StandingsRowLayout,
  TeamMatchInput,
  TeamMatchLayout,
  TeamPartaiRowInput,
  Variant,
} from './layout'

export {
  drawBracketCover,
  drawDate,
  drawGroupSummary,
  drawHeader,
  drawMatchPost,
  drawStandings,
  drawTeamMatch,
  paintText,
  renderBracketCoverPost,
  renderBracketCoverStory,
  renderGroupSummaryPost,
  renderGroupSummaryStory,
  renderMatchPost,
  renderMatchStory,
  renderStandingsPost,
  renderStandingsStory,
  renderTeamMatchPost,
  renderTeamMatchStory,
} from './draw'
export type {
  BracketCoverCanvasInput,
  BracketCoverImages,
  GroupSummaryCanvasInput,
  GroupSummaryImages,
  MatchPostCanvasInput,
  MatchPostImages,
  PhotoCrop,
  StandingsImages,
  StandingsPostInput,
  TeamMatchCanvasInput,
  TeamMatchImages,
} from './draw'

export {
  drawCoverFill,
  drawCoverImage,
  drawImageIn,
  loadImage,
} from './images'
