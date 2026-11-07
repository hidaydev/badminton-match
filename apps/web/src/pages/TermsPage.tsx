import { Link } from 'react-router-dom'
import type { ReactNode } from 'react'

const LAST_UPDATED = '7 November 2026'
const CONTACT_EMAIL = 'hello@qouver.com'
const SECURITY_ADVISORY =
  'https://github.com/hidaydev/badminton-match/security/advisories/new'

function Section({
  id,
  title,
  children,
}: {
  id: string
  title: string
  children: ReactNode
}) {
  return (
    <section aria-labelledby={id}>
      <h2 id={id} className="text-sm font-semibold text-fg">
        {title}
      </h2>
      <div className="mt-2 space-y-2 text-sm leading-relaxed text-fg-dim">
        {children}
      </div>
    </section>
  )
}

/** Public terms of service. Plain language, no legal entity invented. */
export default function TermsPage() {
  return (
    <main className="min-h-screen bg-ground text-fg">
      <article className="mx-auto max-w-2xl px-4 py-8 sm:py-12">
        <Link
          to="/"
          className="inline-flex min-h-11 items-center rounded-lg text-sm text-fg-dim hover:text-fg focus-visible:ring-2 focus-visible:ring-accent"
        >
          Back to Majadu
        </Link>

        <h1 className="mt-2 text-2xl font-bold tracking-tight text-fg">
          Terms of Service
        </h1>
        <p className="mt-1 font-mono text-xs uppercase tracking-wide text-fg-dim">
          Last updated: {LAST_UPDATED}
        </p>

        <p className="mt-6 text-sm leading-relaxed text-fg-dim">
          Majadu is a small badminton club tool, not a company. These terms say
          what the service does, what it expects from you, and what it does not
          promise. By signing in or using the app, you agree to them. If you do
          not agree, please do not use the app.
        </p>

        <div className="mt-8 space-y-8">
          <Section id="what-this-is" title="What this service is">
            <p>
              Majadu records recreational badminton: sessions and courts, game
              scores, a rolling rank points table, tournaments, and the
              communities that play in them. You can also share a read-only view
              of a session with a link.
            </p>
            <p>
              It is free to use and is run personally by a single operator, not
              by a company. There is no paid tier and no advertising. Anything
              this page says about duties and limits reflects that: one person
              keeps the service running in their own time.
            </p>
          </Section>

          <Section id="your-account" title="Your account">
            <p>
              You sign in with your Google account. There is no separate Majadu
              password, and the app keeps only a session cookie in your browser;
              no token is exposed to page scripts.
            </p>
            <p>
              Use one account per person. Do not share a sign-in, and do not
              create accounts on behalf of other people. You are responsible for
              keeping access to your Google account safe: anyone who can sign in
              as you can act with your permissions inside the app.
            </p>
            <p>
              You must be at least 13 years old, and old enough under the rules
              that apply where you live to hold a Google account on your own.
            </p>
          </Section>

          <Section id="acceptable-use" title="Acceptable use">
            <p>
              Use Majadu to record and follow badminton in communities you
              belong to. Do not:
            </p>
            <ul className="list-disc space-y-1 pl-5">
              <li>
                leak, reuse, or keep relying on a share link after the community
                revokes it, or forward a link to people who should not see that
                session;
              </li>
              <li>
                enter another person's data, including names, contact details,
                or match history, without their permission;
              </li>
              <li>
                interrupt, overload, or automate requests against the service,
                or probe it for weaknesses without asking first;
              </li>
              <li>
                try to reach sessions, members, or data of a community you do
                not belong to, or work around the roles and permissions the app
                gives you;
              </li>
              <li>
                use the app for betting, gambling, or anything illegal.
              </li>
            </ul>
            <p>
              If you find a security problem, report it privately through the
              security advisory link below instead of exploiting it.
            </p>
          </Section>

          <Section id="community-admins" title="Community administrators">
            <p>
              Each community has its own administrators and hosts. They decide
              who joins, manage members, sessions, and tournament data, and
              handle player records and rating corrections inside their
              community.
            </p>
            <p>
              Their decisions are theirs, not the platform's. If you disagree
              with an admin's call, raise it with that community. The operator
              of the app can open communities and can remove communities,
              sessions, players, or rating data when something is clearly
              broken; that is housekeeping, not a ruling on your club's
              affairs.
            </p>
          </Section>

          <Section id="your-content" title="Your content">
            <p>
              What you enter stays yours: names, scores, schedules, and player
              records belong to you and to the community they were entered for.
              You give the app permission to store, process, and display that
              content as needed to run the service: session pages, ranking
              tables, tournament brackets, share links you create, and generated
              post images.
            </p>
            <p>
              That permission is limited to running the service and ends when
              the content is deleted, except where it remains in history that
              other players' records and ratings depend on. Do not enter content
              you have no right to share.
            </p>
          </Section>

          <Section id="ratings" title="Ratings and scores">
            <p>
              Rank points, tiers, and standings are calculated automatically
              from match results using fixed formulas and the parameters
              configured for this installation. They are not official ratings
              and are not audited by anyone.
            </p>
            <p>
              When a result is corrected, deleted, or re-entered, ratings are
              recalculated. They can go up or down, including for players who
              did not play in the corrected game. Scores entered by admins and
              hosts are their responsibility, and no accuracy is guaranteed. Do
              not use Majadu ratings or scores for betting, gambling, or any
              competition with money on it.
            </p>
          </Section>

          <Section id="availability" title="Availability">
            <p>
              The service runs on a best-effort basis. It can be changed,
              paused, or shut down at any time without notice. There is no
              service level agreement, no uptime commitment, and no support
              guarantee.
            </p>
            <p>
              Outages, failed deployments, bugs, and data loss are possible.
              Whether backups exist depends on how the installation is operated,
              and nothing here promises that lost data can be recovered. Keep
              your own record of anything you cannot afford to lose.
            </p>
          </Section>

          <Section id="termination" title="Termination">
            <p>
              You can stop using Majadu at any time. To close your account, write
              to the contact address below. Closure is carried out by the
              operator; as implemented today it anonymises your sign-in
              identity, releases your player claims, and removes your community
              memberships, while match history and ratings stay with the
              communities because other players' records depend on them.
            </p>
            <p>
              The operator may suspend or block an account that abuses the
              service or breaks these terms. If a community is removed, its data
              may be removed with it.
            </p>
          </Section>

          <Section id="liability" title="Liability and governing law">
            <p>
              Majadu is provided as is, without warranties of any kind, express
              or implied, including fitness for a particular purpose and
              accuracy of results. To the extent the law allows, the operator is
              not liable for indirect or consequential loss, lost data, missed
              sessions, or decisions made from ratings, standings, or tournament
              draws.
            </p>
            <p>
              Nothing here excludes liability that cannot be excluded under
              applicable law. These terms are governed by Indonesian law. If a
              disagreement cannot be settled directly, it belongs to the
              Indonesian courts that have jurisdiction.
            </p>
          </Section>

          <Section id="changes" title="Changes and contact">
            <p>
              These terms can change as the app changes. The current version is
              always on this page, and the date at the top shows when it was
              last edited. Continuing to use the app after a change means you
              accept the new version.
            </p>
            <p>
              Questions about these terms: <a
                href={`mailto:${CONTACT_EMAIL}`}
                className="text-accent underline underline-offset-2 hover:opacity-90 focus-visible:ring-2 focus-visible:ring-accent"
              >
                {CONTACT_EMAIL}
              </a>
              . This is a one-person project, so replies may take a while.
            </p>
            <p>
              Security reports:{' '}
              <a
                href={SECURITY_ADVISORY}
                target="_blank"
                rel="noreferrer"
                className="text-accent underline underline-offset-2 hover:opacity-90 focus-visible:ring-2 focus-visible:ring-accent"
              >
                private security advisory
              </a>
              . Please do not open a public issue, and do not include session
              cookies or share codes in a report.
            </p>
          </Section>
        </div>
      </article>
    </main>
  )
}