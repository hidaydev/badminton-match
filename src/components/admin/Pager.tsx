// src/components/admin/Pager.tsx — Pagination kontrol untuk admin pages.
import { useEffect } from 'react'
import { t } from '../../i18n'

const PAGE = 10

interface PagerProps {
  page: number
  total: number
  onPage: (p: number) => void
}

export default function Pager({ page, total, onPage }: PagerProps) {
  const pages = Math.max(1, Math.ceil(total / PAGE))

  // Clamp page when total shrinks (e.g. last item deleted on last page)
  useEffect(() => {
    if (page > pages - 1) {
      onPage(Math.max(0, pages - 1))
    }
  }, [page, pages, onPage])

  if (pages <= 1) return null
  return (
    <div className="flex items-center justify-between px-1">
      <button
        onClick={() => onPage(page - 1)}
        disabled={page <= 0}
        className="text-xs font-mono text-fg-dim hover:text-fg disabled:opacity-30"
      >
        {t('common.prev')}
      </button>
      <span className="text-[10px] font-mono text-fg-dim">{page + 1} / {pages}</span>
      <button
        onClick={() => onPage(page + 1)}
        disabled={page >= pages - 1}
        className="text-xs font-mono text-fg-dim hover:text-fg disabled:opacity-30"
      >
        {t('common.next')}
      </button>
    </div>
  )
}
