package middleware

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestOriginAllowed(t *testing.T) {
	cases := []struct {
		origin  string
		allowed []string
		want    bool
	}{
		{"https://app.vercel.app", []string{"https://app.vercel.app"}, true},
		{"https://app.vercel.app", []string{"https://other.com"}, false},
		{"https://foo.vercel.app", []string{"https://*.vercel.app"}, true},
		{"https://sub.foo.vercel.app", []string{"https://*.vercel.app"}, true},
		{"https://majadu-dev.vercel.app", []string{"https://majadu-dev.vercel.app"}, true},
		{"https://evilvercel.app", []string{"https://*.vercel.app"}, false},
		{"http://localhost:5173", []string{"http://localhost:5173", "https://*.vercel.app"}, true},
		{"https://anything.com", []string{"*"}, true},
		{"https://anything.com", []string{}, false},
	}
	for _, c := range cases {
		if got := originAllowed(c.origin, c.allowed); got != c.want {
			t.Fatalf("originAllowed(%q, %v) = %v, want %v", c.origin, c.allowed, got, c.want)
		}
	}
}

func TestCORSReflectsAllowedOrigin(t *testing.T) {
	next := http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
	})
	h := CORS([]string{"https://app.vercel.app"})(next)
	req := httptest.NewRequest("GET", "/", nil)
	req.Header.Set("Origin", "https://app.vercel.app")
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	if got := rec.Header().Get("Access-Control-Allow-Origin"); got != "https://app.vercel.app" {
		t.Fatalf("Allow-Origin = %q", got)
	}
}
