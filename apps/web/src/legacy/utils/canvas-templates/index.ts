// apps/web/src/utils/canvas-templates/index.ts
import { ACTIVE_TEMPLATE } from './config'
import { drawPostCanvas as drawPostCanvasT1 } from './template1/drawPostCanvas'
import { drawPostCanvas as drawPostCanvasT2 } from './template2/drawPostCanvas'

export const drawPostCanvas = ACTIVE_TEMPLATE === 2 ? drawPostCanvasT2 : drawPostCanvasT1
