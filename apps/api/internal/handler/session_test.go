package handler

import (
	"errors"
	"net/http/httptest"
	"testing"
)

func TestVersionRequired(t *testing.T) {
	cases := []struct {
		header  string
		want    int
		wantErr error
	}{
		{`"v3"`, 3, nil},
		{"v3", 3, nil},
		{`"v12"`, 12, nil},
		{"", 0, errIfMatchMissing},
		{"garbage", 0, errIfMatchMalformed},
		{`"v0"`, 0, errIfMatchMalformed},
		{`"v-1"`, 0, errIfMatchMalformed},
		{`"x1"`, 0, errIfMatchMalformed},
	}
	for _, c := range cases {
		req := httptest.NewRequest("PUT", "/", nil)
		if c.header != "" {
			req.Header.Set("If-Match", c.header)
		}
		got, err := versionRequired(req)
		if !errors.Is(err, c.wantErr) {
			t.Fatalf("header %q: err = %v, want %v", c.header, err, c.wantErr)
		}
		if err == nil && got != c.want {
			t.Fatalf("header %q: got %d, want %d", c.header, got, c.want)
		}
	}
}

func TestMapPublishError(t *testing.T) {
	// Error non-Postgres → database error.
	err := mapPublishError(errors.New("connection refused"))
	if err.Code != "database_error" {
		t.Fatalf("expected database_error, got %s", err.Code)
	}
}
