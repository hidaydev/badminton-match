package domain

// TournamentSnapshot — kontrak tournament (mirror TournamentSnapshot di
// src/utils/tournament.ts).
type TournamentSnapshot struct {
	Version *int                `json:"version,omitempty"`
	Name    string              `json:"name"`
	Date    string              `json:"date"`
	Pairs   []TournamentPair    `json:"pairs"`
	Groups  map[string][]string `json:"groups"`
	Matches []TournamentMatch   `json:"matches"`
}

type TournamentPair struct {
	ID   string `json:"id"`
	Name string `json:"name"`
}

type TournamentMatch struct {
	ID      string  `json:"id"`
	Phase   string  `json:"phase"`
	GroupID string  `json:"groupId,omitempty"`
	PairAID *string `json:"pairAId"`
	PairBID *string `json:"pairBId"`
	ScoreA  *int    `json:"scoreA"`
	ScoreB  *int    `json:"scoreB"`
	PICName *string `json:"picName,omitempty"`
}
