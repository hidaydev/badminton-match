package handler

import (
	"bytes"
	"context"
	"encoding/json"
	"majadu-api/internal/httperr"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"majadu-api/internal/store"
)

// TestRatingsAdminAuth — endpoint write ratings harus 401 tanpa/ dengan token
// salah; body salah → 400. (Store tidak dipanggil untuk kasus 401/400.)
func TestRatingsAdminAuth(t *testing.T) {
	h := &RatingsHandler{Store: &store.SessionStore{}, AdminToken: "sekret-admin"}

	cases := []struct {
		name       string
		path       string
		body       string
		token      string
		wantStatus int
	}{
		{"tanpa token", "ingest-session", `{"sessionId":"x"}`, "", http.StatusUnauthorized},
		{"token salah", "ingest-session", `{"sessionId":"x"}`, "Bearer salah", http.StatusUnauthorized},
		{"token benar tapi body kosong", "ingest-session", `{}`, "Bearer sekret-admin", http.StatusBadRequest},
		{"token benar body valid → store nil panic dicegah? (tidak dipanggil)", "ingest-tournament", `{}`, "Bearer sekret-admin", http.StatusBadRequest},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			var hf http.HandlerFunc
			switch c.path {
			case "ingest-session":
				hf = h.RequireAdmin(h.IngestSession)
			case "ingest-tournament":
				hf = h.RequireAdmin(h.IngestTournament)
			}
			req := httptest.NewRequest(http.MethodPost, "/ratings/"+c.path, bytes.NewBufferString(c.body))
			if c.token != "" {
				req.Header.Set("Authorization", c.token)
			}
			rec := httptest.NewRecorder()
			hf(rec, req)
			if rec.Code != c.wantStatus {
				t.Fatalf("status = %d, want %d (body=%s)", rec.Code, c.wantStatus, rec.Body.String())
			}
		})
	}
}

// TestAdminGuardAuth — endpoint admin (tier/delete/class) harus 401 tanpa token.
func TestAdminGuardAuth(t *testing.T) {
	next := func(w http.ResponseWriter, r *http.Request) {
		httperr.WriteJSON(w, http.StatusOK, map[string]bool{"ok": true})
	}
	h := AdminGuard("sekret", next)

	req := httptest.NewRequest(http.MethodPatch, "/x", nil)
	rec := httptest.NewRecorder()
	h(rec, req)
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("tanpa token status=%d, want 401", rec.Code)
	}

	req2 := httptest.NewRequest(http.MethodPatch, "/x", nil)
	req2.Header.Set("Authorization", "Bearer salah")
	rec2 := httptest.NewRecorder()
	h(rec2, req2)
	if rec2.Code != http.StatusUnauthorized {
		t.Fatalf("token salah status=%d, want 401", rec2.Code)
	}

	req3 := httptest.NewRequest(http.MethodPatch, "/x", nil)
	req3.Header.Set("Authorization", "Bearer sekret")
	rec3 := httptest.NewRecorder()
	h(rec3, req3)
	if rec3.Code != http.StatusOK {
		t.Fatalf("token benar status=%d, want 200", rec3.Code)
	}
}

// TestRatingsHandlerErrorEnvelope — pastikan error body berbentuk
// {"error":{"code","message"}}.
func TestRatingsHandlerErrorEnvelope(t *testing.T) {
	h := &RatingsHandler{Store: &store.SessionStore{}, AdminToken: "sekret-admin"}
	req := httptest.NewRequest(http.MethodPost, "/ratings/ingest-session", bytes.NewBufferString(`{}`))
	req.Header.Set("Authorization", "Bearer sekret-admin")
	rec := httptest.NewRecorder()
	h.RequireAdmin(h.IngestSession)(rec, req)

	var body struct {
		Error struct {
			Code    string `json:"code"`
			Message string `json:"message"`
		} `json:"error"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if body.Error.Code != "validation_error" {
		t.Fatalf("code = %q, want validation_error", body.Error.Code)
	}
	_ = context.Background()
}

// TestRankingsPublicInputValidation — endpoint publik baru harus menolak input
// rusak SEBELUM menyentuh store.
//
// Bug yang dijaga test ini: as_of masuk sebagai $1::date dan playerId sebagai
// ::uuid langsung ke Postgres. String rusak → error cast → 500 dari endpoint
// publik. Store di test ini sengaja kosong: kalau ia dipanggil, test panic
// (nil pool), jadi status 400/200 di bawah juga membuktikan urutan validasi.
func TestRankingsPublicInputValidation(t *testing.T) {
	h := &RatingsHandler{Store: &store.SessionStore{}, AdminToken: "sekret-admin"}

	t.Run("as_of bukan tanggal → 400", func(t *testing.T) {
		req := httptest.NewRequest(http.MethodGet, "/rankings?as_of=garbage", nil)
		rec := httptest.NewRecorder()
		h.Rankings(rec, req)
		if rec.Code != http.StatusBadRequest {
			t.Fatalf("status = %d, want 400 (body=%s)", rec.Code, rec.Body.String())
		}
	})

	t.Run("playerId bukan uuid → 200 found:false, store tak disentuh", func(t *testing.T) {
		req := httptest.NewRequest(http.MethodGet, "/rankings/players/abc", nil)
		req.SetPathValue("playerId", "abc")
		rec := httptest.NewRecorder()
		h.PlayerRankPoints(rec, req)
		if rec.Code != http.StatusOK {
			t.Fatalf("status = %d, want 200 (body=%s)", rec.Code, rec.Body.String())
		}
		if body := strings.TrimSpace(rec.Body.String()); body != `{"found":false}` {
			t.Fatalf("body = %q, want {\"found\":false}", body)
		}
	})

	// Kasus uuid valid sengaja TIDAK diuji di sini: ia memanggil store
	// (store kosong → panic). Format uuid valid diuji lewat unit isUUIDFormat.
}

// TestIsUUIDFormat — parser uuid tanpa library.
func TestIsUUIDFormat(t *testing.T) {
	ok := []string{
		"123e4567-e89b-12d3-a456-426614174000",
		"F657DC05-1BAA-48E7-9CE9-7C84EA46002F",
	}
	bad := []string{
		"", "abc", "123e4567e89b12d3a456426614174000", // tanpa strip
		"123e4567-e89b-12d3-a456-42661417400",  // kepanjangan 1
		"123e4567-e89b-12d3-a456-42661417400g", // heks invalid
		"zzzzzzzz-1111-1111-1111-111111111111",
	}
	for _, s := range ok {
		if !isUUIDFormat(s) {
			t.Errorf("isUUIDFormat(%q) = false, want true", s)
		}
	}
	for _, s := range bad {
		if isUUIDFormat(s) {
			t.Errorf("isUUIDFormat(%q) = true, want false", s)
		}
	}
}
