// Every user-visible string lives here. `t()` resolves flat keys; `{name}`
// placeholders are filled from the optional vars argument.

export const en = {
  'app.name': 'Majadu',
  'app.loading': 'Loading…',

  'nav.group.main': 'Main',
  'nav.group.admin': 'Administration',
  'nav.group.owner': 'Platform',
  'nav.home': 'Home',
  'nav.sessions': 'Sessions',
  'nav.players': 'Players',
  'nav.rankings': 'Rankings',
  'nav.tournaments': 'Tournaments',
  'nav.settings': 'Community settings',
  'nav.owner': 'All communities',
  'nav.logout': 'Sign out',
  'nav.signedInAs': 'Signed in as {name}',

  'login.title': 'Sign in to Majadu',
  'login.description': 'Use your Google account. Sessions stay in an HttpOnly cookie.',
  'login.action': 'Continue with Google',
  'login.pending': 'Redirecting…',
  'login.error': 'Sign in could not be started. Try again.',

  'home.title': 'Your communities',
  'home.subtitle': 'Pick a community to continue.',
  'home.empty': 'No community yet',
  'home.emptyHint': 'Ask an administrator for an invitation, or create a community.',

  'shared.title': 'Shared session',

  'placeholder.description': 'This screen is planned. The shell is in place; {feature} arrives in a later task.',

  'error.load': 'Something went wrong while loading.',
} as const

export type MessageKey = keyof typeof en
