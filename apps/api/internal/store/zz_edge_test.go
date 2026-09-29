package store

import (
	"context"
	"testing"
)

// TestZZTierEdge — HAPUS. Kasus tepi pengali tier.
func TestZZTierEdge(t *testing.T) {
	st, _ := ratingTestEnv(t)
	ctx := context.Background()
	cfg, err := st.LoadRatingConfig(ctx, false)
	if err != nil {
		t.Fatalf("cfg: %v", err)
	}
	for _, tier := range []string{"D", "D+", "C", "C+", "B", "B+", "A", "A+", "", "Z", "DD"} {
		v, ok := tierStrength(cfg, tier)
		t.Logf("ZZ tier=%-4q nilai=%7.1f ok=%v", tier, v, ok)
	}
	t.Logf("ZZ avg('')=%v avg('D,C')=%v avg('Z,Z')=%v", avgTierStrength(cfg, ""), avgTierStrength(cfg, "D,C"), avgTierStrength(cfg, "Z,Z"))
	pop, err := st.popTierStrength(ctx, cfg)
	t.Logf("ZZ popTierStrength=%v err=%v", pop, err)
	t.Logf("ZZ mult(pop=nol)=%v mult(opp=0)=%v", opponentMultiplier(1200, 0, cfg.RankOpponentClamp), opponentMultiplier(0, 1500, cfg.RankOpponentClamp))
	t.Logf("ZZ clamp: %v", cfg.RankOpponentClamp)
	t.Logf("ZZ gameValue(base=250,margin=21,target=30)=%v", gameValue(250, 21, 30))
	t.Logf("ZZ gameValue(target=0)=%v", gameValue(250, 21, 0))
	t.Logf("ZZ gameValue(margin>target)=%v", gameValue(250, 42, 30))
}
