// useGridInteraction — the schedule grid's edit-mode channel as one value.
//
// The state itself still lives in useSummaryEditModes: SummaryModal owns it and
// keeps using it for the confirm bars. This hook only bundles the six mode
// fields, the DnD sensors and the five handlers the grid reads, so ScheduleGrid
// takes one prop instead of a dozen and can be rendered without any of them.
import type { DragEndEvent, SensorDescriptor, SensorOptions } from '@dnd-kit/core'
import type { SwapTarget, TeamSwapTarget } from '../../utils/swap'

export interface GridInteractionState {
  swapSelected: SwapTarget | null
  pendingSwap: { t1: SwapTarget; t2: SwapTarget } | null
  teamSwapSelected: TeamSwapTarget | null
  pendingTeamSwap: { t1: TeamSwapTarget; t2: TeamSwapTarget } | null
  replaceTarget: string | null
  changeTarget: SwapTarget | null
  /** Drag sensors configured by the owner (slot swap is drag-driven). */
  sensors: SensorDescriptor<SensorOptions>[]
}

export interface GridInteractionActions {
  onChipClick: (target: SwapTarget) => void
  onTeamClick: (target: TeamSwapTarget) => void
  onReplaceToggle: (playerId: string) => void
  onChangeSelect: (target: SwapTarget) => void
  onDragEnd: (event: DragEndEvent) => void
}

export interface GridInteraction {
  state: GridInteractionState
  actions: GridInteractionActions
}

export function useGridInteraction({
  swapSelected,
  pendingSwap,
  teamSwapSelected,
  pendingTeamSwap,
  replaceTarget,
  changeTarget,
  sensors,
  onChipClick,
  onTeamClick,
  onReplaceToggle,
  onChangeSelect,
  onDragEnd,
}: GridInteractionState & GridInteractionActions): GridInteraction {
  return {
    state: {
      swapSelected,
      pendingSwap,
      teamSwapSelected,
      pendingTeamSwap,
      replaceTarget,
      changeTarget,
      sensors,
    },
    actions: { onChipClick, onTeamClick, onReplaceToggle, onChangeSelect, onDragEnd },
  }
}
