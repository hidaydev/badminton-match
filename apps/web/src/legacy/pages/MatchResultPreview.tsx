import { useEffect, useRef } from 'react'
import { drawTeamMatchPost, drawMatchPost, drawPositionPost, loadImage, type TeamMatchPartaiRow } from '../utils/canvasPost'
import { teamLogoPath, teamColor, teamPhotoPath } from '../utils/teamTournament'
import { t } from '../../i18n'

const MOCK_PARTAI: TeamMatchPartaiRow[] = [
  { tier: 'C+C', nameA: 'Fahmi / Tari',   scoreA: 21, scoreB: 18, nameB: 'Dimas / Sarah' },
  { tier: 'A+A', nameA: 'Andri / Ismet',  scoreA: 17, scoreB: 21, nameB: 'Adam / Agha'  },
  { tier: 'B+B', nameA: 'Rizky / Fachri', scoreA: 21, scoreB: 16, nameB: 'Azzam / Ega'  },
]

/** A team logo when the team has one; the drawing functions accept undefined. */
function logoFor(team: string): Promise<HTMLImageElement | undefined> {
  const path = teamLogoPath(team)
  return path ? loadImage(path).catch(() => undefined) : Promise.resolve(undefined)
}

const MATCHES = [
  { teamA: 'BLUE WAVES',      teamB: 'RED RAPTORS',     winsA: 3, winsB: 0 },
  { teamA: 'PURPLE PHANTOMS', teamB: 'GREEN GROVE',     winsA: 0, winsB: 3 },
  { teamA: 'PINK SPECTRE',    teamB: 'WHITE FURY',      winsA: 3, winsB: 0 },
]

function MatchCanvas({ teamA, teamB, winsA, winsB }: { teamA: string; teamB: string; winsA: number; winsB: number }) {
  const canvasRef = useRef<HTMLCanvasElement>(null)

  useEffect(() => {
    const canvas = canvasRef.current
    if (!canvas) return
    const render = async () => {
      const loadTeamPhoto = (name: string) => {
        const path = teamPhotoPath(name)
        if (path) return loadImage(path).catch(() => loadImage('/team-photo-placeholder.png').catch(() => undefined))
        return loadImage('/team-photo-placeholder.png').catch(() => undefined)
      }
      const [summaryBg, logo, cardLogo, sponsor, teamALogo, teamBLogo, teamAPhoto, teamBPhoto] = await Promise.all([
        loadImage('/court-bg.png').catch(() => undefined),
        loadImage('/majadu-logo.png').catch(() => undefined),
        loadImage('/anniversary-card-logo.png').catch(() => undefined),
        loadImage('/team-sponsor-logo.png').catch(() => undefined),
        logoFor(teamA),
        logoFor(teamB),
        loadTeamPhoto(teamA),
        loadTeamPhoto(teamB),
      ])
      drawTeamMatchPost({
        canvas,
        teamAName: teamA,
        teamBName: teamB,
        teamAWins: winsA,
        teamBWins: winsB,
        partaiRows: MOCK_PARTAI,
        subtitle: 'GROUP STAGE',
        summaryBg,
        logo,
        cardLogo,
        sponsor,
        teamALogo,
        teamBLogo,
        teamAPhoto,
        teamBPhoto,
        teamAColor: teamColor(teamA),
        teamBColor: teamColor(teamB),
      })
    }
    void render()
  }, [teamA, teamB, winsA, winsB])

  return (
    <div className="flex flex-col items-center gap-2">
      <p className="text-slate-400 text-xs tracking-widest uppercase">{t('legacy.matchPreview.versus', { teamA: teamA, teamB: teamB })}</p>
      <canvas ref={canvasRef} style={{ width: '480px', maxWidth: '100%', borderRadius: '12px' }} />
    </div>
  )
}

function PartaiCanvas() {
  const canvasRef = useRef<HTMLCanvasElement>(null)
  useEffect(() => {
    const canvas = canvasRef.current
    if (!canvas) return
    const render = async () => {
      const [photo, logo, cardLogo, sponsor, teamALogo, teamBLogo] = await Promise.all([
        loadImage('/court-bg.png').catch(() => undefined),
        loadImage('/majadu-logo.png').catch(() => undefined),
        loadImage('/anniversary-card-logo.png').catch(() => undefined),
        loadImage('/team-sponsor-logo.png').catch(() => undefined),
        logoFor('BLUE WAVES'),
        logoFor('RED RAPTORS'),
      ])
      if (!photo) return
      drawMatchPost({
        canvas,
        photo,
        pairAName: 'Fahmi / Tari',
        pairBName: 'Dimas / Sarah',
        scoreA: 21,
        scoreB: 18,
        subtitle: 'GROUP MATCH · C+C',
        logo,
        cardLogo,
        sponsor,
        teamALogo,
        teamBLogo,
      })
    }
    void render()
  }, [])
  return (
    <div className="flex flex-col items-center gap-2">
      <p className="text-slate-400 text-xs tracking-widest uppercase">{t('legacy.matchPreview.exampleTitle')}</p>
      <canvas ref={canvasRef} style={{ width: '480px', maxWidth: '100%', borderRadius: '12px' }} />
    </div>
  )
}

function PositionCanvas({ positionLabel, teamName }: { positionLabel: string; teamName: string }) {
  const canvasRef = useRef<HTMLCanvasElement>(null)
  useEffect(() => {
    const canvas = canvasRef.current
    if (!canvas) return
    const render = async () => {
      const [photo, logo, cardLogo, sponsor, chevrons, teamLogo] = await Promise.all([
        loadImage('/court-bg.png').catch(() => undefined),
        loadImage('/majadu-logo.png').catch(() => undefined),
        loadImage('/anniversary-card-logo.png').catch(() => undefined),
        loadImage('/team-sponsor-logo.png').catch(() => undefined),
        loadImage('/chevrons.png').catch(() => undefined),
        logoFor(teamName),
      ])
      if (!photo) return
      drawPositionPost({
        canvas,
        photo,
        positionLabel,
        name: teamName,
        logo,
        cardLogo,
        sponsor,
        chevrons,
        teamLogo,
      })
    }
    void render()
  }, [positionLabel, teamName])

  return (
    <div className="flex flex-col items-center gap-2">
      <p className="text-slate-400 text-xs tracking-widest uppercase">{positionLabel} — {teamName}</p>
      <canvas ref={canvasRef} style={{ width: '480px', maxWidth: '100%', borderRadius: '12px' }} />
    </div>
  )
}

export default function MatchResultPreview() {
  return (
    <div className="min-h-screen bg-slate-950 flex flex-col items-center py-8 gap-10">
      <p className="text-slate-500 text-sm tracking-widest uppercase">{t('legacy.matchPreview.allTeamsTitle')}</p>
      <PositionCanvas positionLabel="🏆 CHAMPION" teamName="BLUE WAVES" />
      <PositionCanvas positionLabel="🥈 RUNNER-UP" teamName="RED RAPTORS" />
      <PartaiCanvas />
      {MATCHES.map(m => (
        <MatchCanvas key={`${m.teamA}-${m.teamB}`} {...m} />
      ))}
    </div>
  )
}
