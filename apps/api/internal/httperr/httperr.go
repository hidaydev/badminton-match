// Package httperr — error envelope JSON konsisten + mapping ke HTTP status.
package httperr

import (
	"encoding/json"
	"log/slog"
	"net/http"
)

// Code — kode error machine-readable untuk klien.
type Code string

const (
	// CodeNotFound — resource tidak ditemukan.
	CodeNotFound Code = "not_found"
	// CodeConflict — state conflict (locked/version mismatch).
	CodeConflict Code = "conflict"
	// CodeValidation — input tidak valid.
	CodeValidation Code = "validation_error"
	// CodeUnavailable — dependency tidak tersedia.
	CodeUnavailable Code = "service_unavailable"
	// CodeInternal — kegagalan server tak terduga.
	CodeInternal Code = "internal"
	// CodeDatabase — kegagalan database.
	CodeDatabase Code = "database_error"
	// CodePrecondition — prasyarat tidak terpenuhi (mis. If-Match).
	CodePrecondition Code = "precondition_required"
	// CodeUnauthorized — admin token salah / tidak ada.
	CodeUnauthorized Code = "unauthorized"
	// CodeSourceChanged — fingerprint sumber berubah sejak ingest (wajib revert).
	CodeSourceChanged Code = "source_changed"
	// CodeTooManyRequests — rate limit / contention (retry after).
	CodeTooManyRequests Code = "too_many_requests"
)

// Error — error ter-struktur yang bisa di-map ke HTTP response.
type Error struct {
	Code    Code
	Message string
	// Err — error asli (tidak dikirim ke klien; untuk log).
	Err error
}

// Error — implementasi interface error.
func (e *Error) Error() string { return e.Message }

// Unwrap — expose error asli untuk errors.Is/errors.As.
func (e *Error) Unwrap() error { return e.Err }

// New — buat Error tanpa error asli (cause).
func New(code Code, message string) *Error {
	return &Error{Code: code, Message: message}
}

// Wrap — buat Error dengan membungkus error asli (untuk log, tak dikirim ke klien).
func Wrap(code Code, message string, err error) *Error {
	return &Error{Code: code, Message: message, Err: err}
}

// NotFound — error 404 (resource tidak ditemukan).
func NotFound(msg string) *Error { return New(CodeNotFound, msg) }

// Conflict — error 409 (state conflict, mis. locked/version mismatch).
func Conflict(msg string) *Error { return New(CodeConflict, msg) }

// Validation — error 400 (input tidak valid).
func Validation(msg string) *Error { return New(CodeValidation, msg) }

// Unavailable — error 503 (dependency tidak siap).
func Unavailable(msg string) *Error { return New(CodeUnavailable, msg) }

// Internal — error 500 (kegagalan tak terduga).
func Internal(msg string) *Error { return New(CodeInternal, msg) }

// Precondition — error 428 (prasyarat tidak terpenuhi, mis. If-Match).
func Precondition(msg string) *Error { return New(CodePrecondition, msg) }

// Unauthorized — error 401 (admin token salah / tidak ada).
func Unauthorized(msg string) *Error { return New(CodeUnauthorized, msg) }

// SourceChanged — error 409 (fingerprint sumber berubah — wajib revert dulu).
func SourceChanged(msg string) *Error { return New(CodeSourceChanged, msg) }

// TooManyRequests — error 429 (contention / rate limit, retry after).
func TooManyRequests(msg string) *Error { return New(CodeTooManyRequests, msg) }

var statusByCode = map[Code]int{
	CodeNotFound:        http.StatusNotFound,
	CodeConflict:        http.StatusConflict,
	CodeSourceChanged:   http.StatusConflict,
	CodeValidation:      http.StatusBadRequest,
	CodeUnauthorized:    http.StatusUnauthorized,
	CodeUnavailable:     http.StatusServiceUnavailable,
	CodeInternal:        http.StatusInternalServerError,
	CodeDatabase:        http.StatusInternalServerError,
	CodePrecondition:    http.StatusPreconditionRequired,
	CodeTooManyRequests: http.StatusTooManyRequests,
}

// WriteError menulis error envelope JSON. Error non-httperr → 500.
// Logger boleh nil (aman).
func WriteError(w http.ResponseWriter, logger *slog.Logger, err error) {
	var he *Error
	if !asError(err, &he) {
		if logger != nil {
			logger.Error("unhandled error", "error", err)
		}
		he = Internal("internal error")
	} else if he.Code == CodeInternal || he.Code == CodeDatabase {
		if logger != nil {
			logger.Error("server error", "code", he.Code, "message", he.Message, "cause", he.Err)
		}
	}

	status := statusByCode[he.Code]
	if status == 0 {
		status = http.StatusInternalServerError
	}

	// Contention / rate limit → inform client to retry after 1s
	if he.Code == CodeTooManyRequests {
		w.Header().Set("Retry-After", "1")
	}

	body := map[string]any{
		"error": map[string]string{
			"code":    string(he.Code),
			"message": he.Message,
		},
	}
	WriteJSON(w, status, body)
}

// WriteJSON menulis response JSON.
func WriteJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

// asError memeriksa err (termasuk wrapped) dan mengisi target.
func asError(err error, target **Error) bool {
	if err == nil {
		return false
	}
	for err != nil {
		if e, ok := err.(*Error); ok {
			*target = e
			return true
		}
		type unwrapper interface{ Unwrap() error }
		u, ok := err.(unwrapper)
		if !ok {
			return false
		}
		err = u.Unwrap()
	}
	return false
}
