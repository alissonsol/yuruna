// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package main

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/url"
	"path/filepath"
	"regexp"
	"strings"
	"time"
	"unicode/utf8"
)

const mirrorAPIVersion = 1

var (
	mirrorSlug    = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9_.-]{0,99}/[A-Za-z0-9][A-Za-z0-9_.-]{0,99}$`)
	mirrorOID     = regexp.MustCompile(`^[0-9a-f]{40}$`)
	mirrorNonce   = regexp.MustCompile(`^[A-Za-z0-9_-]{22,128}$`)
	errMirrorBusy = errors.New("mirror-capacity-exhausted")
)

// Limits belong to the constructor so transport tests exercise the real paths
// with short deadlines instead of sleeping through production timeouts.
type mirrorLimits struct {
	Query, Job, Population, Maintenance, Handler, Pending, BodyRead time.Duration
	CancelGrace, Read, CGI, Refresh, Retention, RetentionGrace      time.Duration
	StorageInterval                                                 time.Duration
	Workers, Queue, Repositories                                    int
	ReserveBytes, CapBytes                                          uint64
}

func defaultMirrorLimits() mirrorLimits {
	return mirrorLimits{
		Query: 10 * time.Second, Job: 120 * time.Second, Population: 30 * time.Minute,
		Maintenance: 30 * time.Minute, Handler: 15 * time.Second, Pending: 13 * time.Second,
		BodyRead: 2 * time.Second, CancelGrace: 5 * time.Second, Read: 120 * time.Second,
		CGI: 600 * time.Second, Refresh: time.Minute, Retention: 14 * 24 * time.Hour,
		RetentionGrace:  5*time.Minute + time.Minute + 600*time.Second + 5*time.Second,
		StorageInterval: time.Second, Workers: 2, Queue: 32, Repositories: 32,
		ReserveBytes: 4 << 30, CapBytes: 32 << 30,
	}
}

type mirrorOptions struct {
	Role, Root, StateRoot, RuntimeRoot, ReaderRoot, RepositoriesFile string
	SigningKey, Credentials, PoolStore, PoolRef, NoUpstreamPath      string
	BuildSource                                                      mirrorBuildSource
	Limits                                                           mirrorLimits
	Now                                                              func() time.Time
}

type mirrorBuildSource struct {
	Source     string `json:"source"`
	Repository string `json:"repository"`
	Commit     string `json:"commit"`
}

type mirrorRequest struct {
	Repository  string `json:"repository"`
	Ref         string `json:"ref"`
	Nonce       string `json:"nonce"`
	OperationID string `json:"operationId,omitempty"`
}

type mirrorEnvelope struct {
	KeyID     string `json:"keyId"`
	Payload   string `json:"payload"`
	Signature string `json:"signature"`
}

type mirrorReceipt struct {
	SchemaVersion         int    `json:"schemaVersion"`
	KeyID                 string `json:"keyId"`
	Nonce                 string `json:"nonce"`
	Repository            string `json:"repository"`
	Ref                   string `json:"ref"`
	ResolvedDefaultBranch string `json:"resolvedDefaultBranch"`
	SelectedSHA           string `json:"selectedSha"`
	FetchRef              string `json:"fetchRef"`
	ObjectReady           bool   `json:"objectReady"`
	UpstreamOutcome       string `json:"upstreamOutcome"`
	OriginCheckedAt       string `json:"originCheckedAt"`
	IssuedAt              string `json:"issuedAt"`
	ExpiresAt             string `json:"expiresAt"`
	Status                string `json:"status"`
	Reason                string `json:"reason"`
	Detail                string `json:"detail,omitempty"`
	OperationID           string `json:"operationId,omitempty"`
	OperationExpiresAt    string `json:"operationExpiresAt,omitempty"`
}

type mirrorRef struct {
	ObjectSHA   string    `json:"objectSha"`
	CommitSHA   string    `json:"commitSha"`
	ConfirmedAt time.Time `json:"confirmedAt"`
}

type mirrorPin struct {
	Confirmations map[string]time.Time `json:"confirmations"`
	RetainUntil   time.Time            `json:"retainUntil"`
}

type mirrorState struct {
	Repository    string               `json:"repository"`
	Refs          map[string]mirrorRef `json:"refs"`
	Pins          map[string]mirrorPin `json:"pins"`
	DefaultBranch string               `json:"defaultBranch"`
	LastCheckedAt time.Time            `json:"lastCheckedAt"`
	LastUpdatedAt time.Time            `json:"lastUpdatedAt"`
	Outcome       string               `json:"outcome"`
	Detail        string               `json:"detail,omitempty"`
}

func newMirrorState(repo string) mirrorState {
	return mirrorState{Repository: repo, Refs: map[string]mirrorRef{}, Pins: map[string]mirrorPin{}}
}

func canonicalMirrorRepository(raw string) (string, error) {
	value := strings.TrimSpace(raw)
	if value != raw || strings.ContainsAny(value, "\x00\r\n\t\\?#%") {
		return "", errors.New("invalid repository")
	}
	if strings.HasPrefix(value, "git@github.com:") {
		value = strings.TrimPrefix(value, "git@github.com:")
	} else if strings.Contains(value, "://") {
		u, err := url.Parse(value)
		if err != nil || !strings.EqualFold(u.Host, "github.com") || u.User != nil && !(u.Scheme == "ssh" && u.User.String() == "git") ||
			(u.Scheme != "https" && u.Scheme != "ssh") || u.RawQuery != "" || u.Fragment != "" {
			return "", errors.New("invalid repository")
		}
		value = strings.TrimPrefix(u.Path, "/")
	}
	value = strings.TrimSuffix(value, ".git")
	if !mirrorSlug.MatchString(value) || strings.Contains(value, "..") || strings.HasSuffix(value, ".") {
		return "", errors.New("invalid repository")
	}
	return strings.ToLower(value), nil
}

func validMirrorRef(ref string) bool {
	if ref == "HEAD" || mirrorOID.MatchString(ref) {
		return true
	}
	if !strings.HasPrefix(ref, "refs/heads/") && !strings.HasPrefix(ref, "refs/tags/") {
		return false
	}
	if len(ref) > 256 || strings.Contains(ref, "..") || strings.Contains(ref, "@{") || strings.ContainsAny(ref, " ~^:?*[\\\x00\r\n\t") || strings.HasSuffix(ref, "/") || strings.HasSuffix(ref, ".") {
		return false
	}
	for _, part := range strings.Split(ref, "/") {
		if part == "" || strings.HasPrefix(part, ".") || strings.HasSuffix(part, ".lock") {
			return false
		}
	}
	return true
}

func mirrorRepoPath(root, repo string) string {
	return filepath.Join(root, filepath.FromSlash(repo)+".git")
}
func mirrorRepoKey(repo string) string { return base64.RawURLEncoding.EncodeToString([]byte(repo)) }
func mirrorStamp(t time.Time) string {
	if t.IsZero() {
		return ""
	}
	return t.UTC().Format(time.RFC3339Nano)
}

// Validate original bytes before decoding. encoding/json otherwise accepts
// duplicate keys and replaces invalid UTF-8, which makes signed data ambiguous.
func strictMirrorJSON(data []byte, dst any, limit int) error {
	if len(data) > limit || !utf8.Valid(data) {
		return errors.New("invalid JSON size or encoding")
	}
	dec := json.NewDecoder(bytes.NewReader(data))
	var walk func(int) error
	walk = func(depth int) error {
		if depth > 16 {
			return errors.New("JSON nesting limit")
		}
		token, err := dec.Token()
		if err != nil {
			return err
		}
		if d, ok := token.(json.Delim); ok {
			switch d {
			case '{':
				keys := map[string]bool{}
				for dec.More() {
					k, e := dec.Token()
					if e != nil {
						return e
					}
					key, ok := k.(string)
					if !ok || keys[key] {
						return errors.New("duplicate JSON key")
					}
					keys[key] = true
					if e = walk(depth + 1); e != nil {
						return e
					}
				}
			case '[':
				for dec.More() {
					if err = walk(depth + 1); err != nil {
						return err
					}
				}
			default:
				return errors.New("invalid JSON delimiter")
			}
			_, err = dec.Token()
			return err
		}
		return nil
	}
	if err := walk(0); err != nil {
		return err
	}
	if _, err := dec.Token(); err != io.EOF {
		return errors.New("trailing JSON")
	}
	dec = json.NewDecoder(bytes.NewReader(data))
	dec.DisallowUnknownFields()
	if err := dec.Decode(dst); err != nil {
		return fmt.Errorf("invalid JSON document: %w", err)
	}
	return nil
}
