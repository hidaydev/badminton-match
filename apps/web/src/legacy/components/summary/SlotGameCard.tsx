import { useDraggable, useDroppable } from '@dnd-kit/core'
import { CSS } from '@dnd-kit/utilities'

interface SlotGameCardProps {
  id: string
  children: React.ReactNode
}

export default function SlotGameCard({ id, children }: SlotGameCardProps) {
  const { attributes, listeners, setNodeRef: setDragRef, transform, isDragging } = useDraggable({ id })
  const { setNodeRef: setDropRef, isOver } = useDroppable({ id })

  return (
    <div
      ref={setDropRef}
      className={isOver && !isDragging ? 'border border-dashed border-orange-400/60 rounded-lg' : 'border border-transparent rounded-lg'}
    >
      <div
        ref={setDragRef}
        style={transform ? { transform: CSS.Translate.toString(transform), position: 'relative', zIndex: 50 } : undefined}
        className={`flex items-center gap-2 ${isDragging ? 'opacity-40' : ''}`}
      >
        <span
          {...listeners}
          {...attributes}
          className="text-slate-400 hover:text-orange-400 cursor-grab active:cursor-grabbing text-[1rem] shrink-0 select-none touch-none px-0.5"
        >
          ⠿
        </span>
        {children}
      </div>
    </div>
  )
}
