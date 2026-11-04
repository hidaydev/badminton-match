import { useParams } from 'react-router-dom'
import { ClassicEditorPage } from '../tournament/classic/ClassicEditorPage'
import { ClassicNewPage } from '../tournament/classic/ClassicNewPage'

/**
 * `/c/:slug/tournaments/classic/new` draws a tournament; the `:id` route edits
 * one. Both live in the classic editor module so the page stays a thin switch.
 */
export default function TournamentClassicPage() {
  const { slug = '', id } = useParams<{ slug: string; id: string }>()
  if (id === undefined || id === '') return <ClassicNewPage slug={slug} />
  return <ClassicEditorPage slug={slug} id={id} />
}
