// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package main

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
)

type mirrorRegistry struct {
	mu             sync.RWMutex
	options        mirrorOptions
	git            *mirrorGit
	repositories   map[string]bool
	pool           []string
	discoveryError string
}

type mirrorRepositoryList struct {
	Repositories []string `json:"repositories"`
}

func newMirrorRegistry(options mirrorOptions, g *mirrorGit) *mirrorRegistry {
	r := &mirrorRegistry{options: options, git: g, repositories: map[string]bool{}}
	if b, err := os.ReadFile(filepath.Join(options.StateRoot, "state", "pool-repositories.json")); err == nil {
		var saved mirrorRepositoryList
		if strictMirrorJSON(b, &saved, 64<<10) == nil {
			for _, candidate := range saved.Repositories {
				if repo, e := canonicalMirrorRepository(candidate); e == nil {
					r.pool = append(r.pool, repo)
				}
			}
		}
	}
	return r
}

func (r *mirrorRegistry) reload(ctx context.Context) error {
	seed := mirrorRepositoryList{}
	if r.options.RepositoriesFile != "" {
		b, err := os.ReadFile(r.options.RepositoriesFile)
		if err != nil {
			return errors.New("repository-list-unavailable")
		}
		if err = strictMirrorJSON(b, &seed, 64<<10); err != nil {
			return errors.New("repository-list-invalid")
		}
	}
	r.mu.RLock()
	pool := append([]string(nil), r.pool...)
	r.mu.RUnlock()
	poolError := ""
	if r.options.PoolStore != "" {
		out, err := r.git.command(ctx, r.options.PoolStore, nil, "show", r.options.PoolRef+":pools.yml")
		if err == nil {
			pool, err = parseMirrorPoolRepositories(out)
		}
		if err != nil {
			poolError = "pool-store-unavailable"
			r.mu.RLock()
			pool = append([]string(nil), r.pool...)
			r.mu.RUnlock()
		} else {
			b, _ := json.Marshal(mirrorRepositoryList{Repositories: pool})
			if err := mirrorAtomicFile(filepath.Join(r.options.StateRoot, "state", "pool-repositories.json"), b, 0640); err != nil {
				poolError = "pool-discovery-state-unavailable"
			}
		}
	}
	values := append(append([]string(nil), seed.Repositories...), pool...)
	dir := filepath.Join(r.options.StateRoot, "registrations")
	entries, err := os.ReadDir(dir)
	if err != nil && !os.IsNotExist(err) {
		return errors.New("registrations-unavailable")
	}
	for _, entry := range entries {
		if entry.IsDir() || !strings.HasSuffix(entry.Name(), ".json") {
			continue
		}
		b, e := os.ReadFile(filepath.Join(dir, entry.Name()))
		if e != nil {
			return errors.New("registration-unavailable")
		}
		var registration struct {
			Repository string `json:"repository"`
		}
		if strictMirrorJSON(b, &registration, 4096) != nil {
			return errors.New("registration-invalid")
		}
		values = append(values, registration.Repository)
	}
	repos := map[string]bool{}
	for _, value := range values {
		repo, e := canonicalMirrorRepository(value)
		if e != nil {
			return errors.New("repository-list-invalid")
		}
		repos[repo] = true
	}
	if len(repos) > r.options.Limits.Repositories {
		return errMirrorBusy
	}
	r.mu.Lock()
	r.repositories = repos
	r.pool = pool
	r.discoveryError = poolError
	r.mu.Unlock()
	return nil
}

func (r *mirrorRegistry) contains(repo string) bool {
	r.mu.RLock()
	defer r.mu.RUnlock()
	return r.repositories[repo]
}
func (r *mirrorRegistry) list() []string {
	r.mu.RLock()
	defer r.mu.RUnlock()
	out := make([]string, 0, len(r.repositories))
	for repo := range r.repositories {
		out = append(out, repo)
	}
	sort.Strings(out)
	return out
}

// The pool writer emits one-line URL scalars. Parse only its two repository
// fields; unsupported YAML syntax retains the previous discovery snapshot.
func parseMirrorPoolRepositories(text string) ([]string, error) {
	if len(text) > 1<<20 {
		return nil, errors.New("pool-store-too-large")
	}
	var values []string
	for _, line := range strings.Split(text, "\n") {
		line = strings.TrimSpace(line)
		var value string
		if strings.HasPrefix(line, "frameworkUrl:") {
			value = strings.TrimSpace(strings.TrimPrefix(line, "frameworkUrl:"))
		} else if strings.HasPrefix(line, "projectUrl:") {
			value = strings.TrimSpace(strings.TrimPrefix(line, "projectUrl:"))
		} else {
			continue
		}
		if strings.HasPrefix(value, `"`) {
			unquoted, err := strconv.Unquote(value)
			if err != nil {
				return nil, err
			}
			value = unquoted
		} else if strings.HasPrefix(value, "'") {
			if !strings.HasSuffix(value, "'") {
				return nil, errors.New("invalid pool scalar")
			}
			value = strings.ReplaceAll(value[1:len(value)-1], "''", "'")
		}
		if value == "" || value == "null" || value == "~" {
			continue
		}
		if strings.HasPrefix(value, "https://github.com/") || strings.HasPrefix(value, "git@github.com:") || strings.HasPrefix(value, "ssh://git@github.com/") {
			repo, err := canonicalMirrorRepository(value)
			if err != nil {
				return nil, err
			}
			values = append(values, repo)
		} else if strings.ContainsAny(value, "&*|>{}") {
			return nil, errors.New("unsupported pool scalar")
		}
	}
	return values, nil
}

func persistMirrorRegistration(options mirrorOptions, repo string) error {
	path := filepath.Join(options.StateRoot, "registrations", mirrorRepoKey(repo)+".json")
	b, _ := json.Marshal(struct {
		Repository string `json:"repository"`
	}{repo})
	return mirrorAtomicFile(path, b, 0640)
}
