package handler

import (
	"errors"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/jackc/pgx/v5/pgconn"
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

func TestMapPublishErrorTable(t *testing.T) {
	cases := []struct {
		name        string
		err         error
		wantCode    string
		wantMsgPart string
		wantNoPart  string
	}{
		{
			name:        "locked session maps to conflict without SQLSTATE leak",
			err:         &pgconn.PgError{Message: "ERROR: session is locked and cannot be modified (SQLSTATE P0001)"},
			wantCode:    "conflict",
			wantMsgPart: "locked",
			wantNoPart:  "SQLSTATE",
		},
		{
			name:        "version mismatch maps to conflict",
			err:         &pgconn.PgError{Message: "ERROR: publish failed: version mismatch (SQLSTATE P0001)"},
			wantCode:    "conflict",
			wantMsgPart: "version mismatch",
		},
		{
			name:     "not found maps to not_found",
			err:      &pgconn.PgError{Message: "ERROR: session not found (SQLSTATE P0001)"},
			wantCode: "not_found",
		},
		{
			name:     "non-pg error maps to database_error",
			err:      errors.New("connection refused"),
			wantCode: "database_error",
		},
		{
			name:     "unknown pg error maps to validation_error",
			err:      &pgconn.PgError{Message: "ERROR: invalid input syntax for type integer"},
			wantCode: "validation_error",
		},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := mapPublishError(c.err)
			if got == nil {
				t.Fatal("mapPublishError returned nil")
			}
			if string(got.Code) != c.wantCode {
				t.Fatalf("code = %s, want %s", got.Code, c.wantCode)
			}
			if c.wantMsgPart != "" && !strings.Contains(got.Message, c.wantMsgPart) {
				t.Fatalf("message %q does not contain %q", got.Message, c.wantMsgPart)
			}
			if c.wantNoPart != "" && strings.Contains(got.Message, c.wantNoPart) {
				t.Fatalf("message %q must not contain %q", got.Message, c.wantNoPart)
			}
		})
	}
}
