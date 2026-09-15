import { useEffect, useRef } from 'react'
import { drawTeamMatchPost, loadImage, type TeamMatchPartaiRow } from '../utils/canvasPost'
import { teamLogoPath, teamColor } from '../utils/teamTournament'

const MOCK_PARTAI: TeamMatchPartaiRow[] = [
  { tier: 'C+C', nameA: 'Fahmi / Tari',   scoreA: 21, scoreB: 18, nameB: 'Dimas / Sarah' },
  { tier: 'A+A', nameA: 'Andri / Ismet',  scoreA: 17, scoreB: 21, nameB: 'Adam / Agha'  },
  { tier: 'B+B', nameA: 'Rizky / Fachri', scoreA: 21, scoreB: 16, nameB: 'Azzam / Ega'  },
]

const MATCHES = [
  { teamA: 'BLUE WAVES',      teamB: 'RED RAPTORS',     winsA: 3, winsB: 0 },
  { teamA: 'GREEN GROVE',     teamB: 'PURPLE PHANTOMS', winsA: 0, winsB: 3 },
  { teamA: 'PINK SPECTRE',    teamB: 'WHITE FURY',      winsA: 3, winsB: 0 },
]

function MatchCanvas({ teamA, teamB, winsA, winsB }: { teamA: string; teamB: string; winsA: number; winsB: number }) {
  const canvasRef = useRef<HTMLCanvasElement>(null)

  useEffect(() => {
    const canvas = canvasRef.current
    if (!canvas) return
    async function render() {
      const [summaryBg, logo, cardLogo, teamALogo, teamBLogo, teamPhoto] = await Promise.all([
        loadImage('/court-bg.png').catch(() => undefined),
        loadImage('/majadu-logo.png').catch(() => undefined),
        loadImage('/anniversary-card-logo.png').catch(() => undefined),
        teamLogoPath(teamA) ? loadImage(teamLogoPath(teamA)!).catch(() => undefined) : Promise.resolve(undefined),
        teamLogoPath(teamB) ? loadImage(teamLogoPath(teamB)!).catch(() => undefined) : Promise.resolve(undefined),
        loadImage('/team-photo-placeholder.png').catch(() => undefined),
      ])
      drawTeamMatchPost(
        canvas!, teamA, teamB, winsA, winsB, MOCK_PARTAI, 'GROUP STAGE',
        summaryBg, logo, undefined, cardLogo, teamALogo, teamBLogo,
        teamPhoto, teamPhoto, teamColor(teamA), teamColor(teamB),
      )
    }
    render()
  }, [teamA, teamB, winsA, winsB])

  return (
    <div className="flex flex-col items-center gap-2">
      <p className="text-slate-400 text-xs tracking-widest uppercase">{teamA} vs {teamB}</p>
      <canvas ref={canvasRef} style={{ width: '480px', maxWidth: '100%', borderRadius: '12px' }} />
    </div>
  )
}

export default function MatchResultPreview() {
  return (
    <div className="min-h-screen bg-slate-950 flex flex-col items-center py-8 gap-10">
      <p className="text-slate-500 text-sm tracking-widest uppercase">Match Result Preview — All Teams</p>
      {MATCHES.map(m => (
        <MatchCanvas key={`${m.teamA}-${m.teamB}`} {...m} />
      ))}
    </div>
  )
}
