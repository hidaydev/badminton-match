package handler

import (
	"bytes"
	"context"
	"encoding/json"
	"majadu-api/internal/httperr"
	"net/http"
	"net/http/httptest"
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
