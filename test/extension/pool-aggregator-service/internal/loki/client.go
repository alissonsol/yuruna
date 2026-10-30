// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
// GUID: 42cbe10c-4205-4d15-9456-02370bf0fd5a

// Package loki is the collector's Loki client: one push call, the readiness
// wait the collector runs before it reads Loki back at startup, and the outbox
// that holds pushed lines until Loki has accepted them.
package loki

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"
)

// PushError is a push that reached Loki and was answered with a non-2xx status.
type PushError struct {
	Status int
}

func (e *PushError) Error() string { return fmt.Sprintf("HTTP %d", e.Status) }

// Permanent reports whether Loki refused the payload itself, so sending the same
// bytes again cannot succeed: any 4xx but a timeout or a rate limit. A queue
// that kept retrying such a payload would never deliver anything behind it.
func Permanent(err error) bool {
	var pe *PushError
	if !errors.As(err, &pe) {
		return false
	}
	return pe.Status >= 400 && pe.Status < 500 && pe.Status != http.StatusRequestTimeout && pe.Status != http.StatusTooManyRequests
}

// Push posts one JSON push payload to pushURL and returns nil once Loki has
// accepted it (a 2xx), a *PushError for any other status, or the transport error.
func Push(ctx context.Context, client *http.Client, pushURL string, payload []byte) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, pushURL, bytes.NewReader(payload))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 64<<10))
	if resp.StatusCode/100 != 2 {
		return &PushError{Status: resp.StatusCode}
	}
	return nil
}

// BaseURL derives Loki's base URL from its push endpoint
// (http://127.0.0.1:3100/loki/api/v1/push -> http://127.0.0.1:3100).
func BaseURL(pushURL string) string {
	return strings.TrimSuffix(strings.TrimSuffix(pushURL, "/"), "/loki/api/v1/push")
}

// WaitReady polls Loki's /ready until it answers 200 or maxWait passes, with a
// backoff that starts at first and doubles up to ceiling. A Loki that started
// with the collector answers 503 while its ingester warms up, and a startup
// read made then comes back empty, so the restored counters, incidents and
// presence would silently start from nothing. It reports whether Loki became
// ready; a caller that is not ready by then reads anyway, as it always did.
func WaitReady(ctx context.Context, client *http.Client, pushURL string, maxWait, first, ceiling time.Duration) bool {
	deadline := time.Now().Add(maxWait)
	delay := first
	for {
		attempt, cancel := context.WithTimeout(ctx, client.Timeout+time.Second)
		req, err := http.NewRequestWithContext(attempt, http.MethodGet, BaseURL(pushURL)+"/ready", nil)
		if err == nil {
			if resp, derr := client.Do(req); derr == nil {
				_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 4096))
				resp.Body.Close()
				if resp.StatusCode == http.StatusOK {
					cancel()
					return true
				}
			}
		}
		cancel()
		if !time.Now().Add(delay).Before(deadline) {
			return false
		}
		select {
		case <-ctx.Done():
			return false
		case <-time.After(delay):
		}
		delay *= 2
		if delay > ceiling {
			delay = ceiling
		}
	}
}
