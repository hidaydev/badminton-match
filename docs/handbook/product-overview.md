# Product Overview

## Purpose

`badminton-match` is a badminton operations app. It is optimized for real
session management rather than long-term ranking analysis.

The app is designed to answer these operational questions:

- How many courts and players do we have today?
- How do we create a fair doubles schedule?
- How do we preserve requested pairings or rivalries?
- How do we run the session live and keep everyone aligned?
- How do we present session outcomes and tournament results cleanly?

## Core product areas

### 1. Session setup

Users configure:

- session title
- date
- number of courts
- session start time
- per-court availability
- game duration
- target player count

### 2. Player management

Users can:

- add players one by one
- bulk import players from pasted text
- edit names inline
- assign gender
- assign skill tier

### 3. Constraints

Users can define fixed matches such as:

- specific partners together
- specific opponents against each other
- partial fixed matches with open slots

### 4. Schedule generation

The app generates a doubles schedule that tries to balance:

- total play count
- repeated partners
- repeated opponents
- team strength by tier
- back-to-back fatigue

### 5. Shared live session

Once a session is published:

- a shared URL becomes the live source
- scores and played flags can be updated
- players can be swapped
- slots can be swapped
- teams can be swapped
- one player in a specific game can be changed
- absences can be recorded
- player stats (play count, sit count, partners, opponents) are visible
- session can be locked to prevent further changes
- locked sessions reject all mutations at the server level

### 6. Player history

The app derives player stats from stored session history:

- games played
- wins/losses
- points for/against
- sessions attended
- top partners
- top opponents

### 7. Tournament

The tournament module supports:

- 16 fixed pairs
- 4 groups of 4
- round-robin group stage
- knockout bracket propagation
- leaderboard and podium surfaces
- media generation for bracket content

### 8. Social export

The app can render session and tournament visuals for sharing:

- Instagram-style post assets
- standings cards
- bracket cover and result assets

## Relationship to `MDEF`

`badminton-match` is not the ELO system.

Its role is:

- operational source of session truth
- source of raw match outcomes
- live workflow and tournament UX

`MDEF` remains the historical analytics and rating system.
