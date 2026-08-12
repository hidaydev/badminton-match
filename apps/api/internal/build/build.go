// Package build — informasi versi binary (di-set via ldflags saat build).
package build

var (
	// Version — semver atau "dev".
	Version = "dev"
	// Commit — short git sha.
	Commit = "none"
	// Date — waktu build (RFC3339).
	Date = "unknown"
)
