import ScoreboardPage from '../../pages/ScoreboardPage'
import type { OverlayConfig } from '../../pages/ScoreboardPage'

export default function ScoreboardOverlay(props: OverlayConfig) {
  return <ScoreboardPage overlay={props} />
}
