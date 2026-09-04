// src/i18n/en.ts — English dictionary (satu-satunya bahasa aktif).
// Skeleton i18n ringan: typed dictionary, tanpa dependency. Kalau nanti mau
// multi-bahasa: tambah id.ts/dict lain + lang state di index.ts (tanpa
// perubahan pemakaian — key path sama).

export const en = {
  common: {
    prev: '← Prev',
    next: 'Next →',
    close: 'Close',
  },
  admin: {
    title: 'Admin',
    subtitle: 'operations',
    logout: 'Logout',
    logoutConfirm: 'Log out of admin?',
    noSessions: 'No sessions.',
    noSources: 'No sources.',
    noTournaments: 'No tournaments.',
    sectionSession: 'Session · unlock',
    sectionPlayer: 'Player',
    sectionRating: 'Rating · ingest / revert',
    sectionTournament: 'Tournament · delete',
    sectionSeason: 'Season',
    locked: 'locked',
    draft: 'draft',
    active: 'active',
    days: 'days',
    standings: 'standings',
    unlocked: 'Unlocked',
    sessionDeleted: 'Session deleted + ratings rebuilt',
    tournamentDeleted: 'Tournament deleted + ratings rebuilt',
    playerAdded: 'Player added',
    playerDeleted: 'Player deleted',
    nameChanged: 'Name changed (old name kept as alias)',
    tierChanged: 'Tier changed + recalculated',
    seasonStarted: 'Season closed & new season started',
    sessionDeleteConfirm: (title: string, date: string) =>
      `Delete session "${title}" (${date})?\n\nRating source will be removed & all ratings rebuilt.`,
    tournamentDeleteConfirm: (name: string) =>
      `Delete tournament "${name}"?\n\nRating source will be removed & all ratings rebuilt.`,
    playerDeleteConfirm: (name: string) =>
      `Delete player "${name}"? (session history stays, rating data removed)`,
    nameRequired: 'Name is required',
    newPlayerName: 'Player name',
    tierInduk: 'Tier',
    tierPrompt: (name: string) => `Tier (D..A+) for ${name}:`,
    renamePrompt: (name: string) => `Rename "${name}" to:`,
    addPlayer: 'Add',
    rebuild: 'Rebuild All',
    rebuilding: 'Rebuilding…',
    rebuildDone: 'Rebuild done — all ratings recomputed from events',
    rebuildHelp: 'Rebuild All = recompute ALL ratings from events (after rating config changes / corrections; usually not needed).',
    seasonDateLabel: 'New season start date',
    seasonHelp: 'Default = active season start. Closing archives frozen standings and resets everyone to mid tier.',
    seasonDefaultText: 'Default = active season start date. Closing archives the frozen standings & resets all players to mid tier.',
  },
  teamTournament: {
    saving: 'saving…',
    save: 'Save',
    savingLabel: 'Saving…',
    saveFailed: 'Failed to save.',
    deleteFailed: 'Failed to delete.',
    classLabel: (label: string, partai: number) => `Score ${label} partai ${partai}`,
    metaLine: (date: string) => `${date} · 6 teams · 3 doubles · rally`,
  },
} as const
