// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

// Package imagestore owns the Download pool: generation-addressed artifacts on
// the pool share, the pointer/sidecar metadata that makes one of them servable,
// the family resolvers, the freshness scanner, the single-flight download
// pipeline, the single-writer lease and the aggregator-driven auto-seed pass.
package imagestore

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"syscall"
	"time"

	"download-agent-service/internal/config"
)

// SchemaVersion is stamped into every pointer and sidecar the agent writes, so
// a future layout change can be detected rather than silently misread.
const SchemaVersion = 1

// Checksum verdicts recorded in the sidecar. "unpublished" is a soft pass (the
// publisher offers no checksum for this artifact); "none" means the family has
// no checksum source at all; only "verified" means bytes were proven.
const (
	VerdictVerified    = "verified"
	VerdictUnpublished = "unpublished"
	VerdictNone        = "none"
)

// Host types are the host/ directory names; nothing else may become a pool
// directory, so a malformed request can never create a stray tree.
const (
	HostTypeHyperV = "windows.hyper-v"
	HostTypeKVM    = "ubuntu.kvm"
	HostTypeUTM    = "macos.utm"
)

// Image keys are the guest folder names, plus the shared extension-image key
// the four service guests collapse onto and the auxiliary artifacts that belong
// to no guest folder of their own.
const (
	KeyUbuntuServer24  = "guest.ubuntu.server.24"
	KeyUbuntuServer26  = "guest.ubuntu.server.26"
	KeyUbuntuExtension = "ubuntu.extension.26"
	KeyAmazonLinux2023 = "guest.amazon.linux.2023"
	KeyWindows11       = "guest.windows.11"
	// KeyVirtioWin is the QEMU driver bundle a Windows guest needs on KVM. It is
	// an auxiliary artifact rather than a guest image, so it carries its own key
	// instead of hiding inside the Windows one: the two come from different
	// publishers and go stale independently.
	KeyVirtioWin = "virtio-win"
)

// Architectures and variants. variant names the client's requested preference
// (mirroring -PreferDaily); the resolved outcome is recorded in the sidecar.
const (
	ArchAMD64     = "amd64"
	ArchARM64     = "arm64"
	VariantStable = "stable"
	VariantDaily  = "daily"
)

// HostTypes is the closed set of pool directories, in display order.
var HostTypes = []string{HostTypeHyperV, HostTypeKVM, HostTypeUTM}

// deleteDeadline bounds the CIFS retry-in-deadline delete idiom: an SMB share
// can hold a deleted name visible for a moment after the last handle closes, so
// a single failed unlink is not proof the file is stuck.
const deleteDeadline = 30 * time.Second

// deleteRetryInterval paces that retry loop.
const deleteRetryInterval = 250 * time.Millisecond

// segmentRE bounds every path segment that arrives from a request, so nothing a
// client sends can escape the pool root.
var segmentRE = regexp.MustCompile(`^[a-z0-9][a-zA-Z0-9._-]{0,127}$`)

// ImageID is the full identity of one pool entry.
type ImageID struct {
	HostType string `json:"hostType"`
	ImageKey string `json:"imageKey"`
	Arch     string `json:"arch"`
	Variant  string `json:"variant"`
}

// String renders the identity for logs, audit records and flight keys.
func (id ImageID) String() string {
	return id.HostType + "/" + id.ImageKey + "/" + id.Arch + "/" + id.Variant
}

// Key is the single-flight / bookkeeping key for this identity.
func (id ImageID) Key() string { return id.String() }

// ValidateLocation checks the pair that names a pool directory. The byte route
// needs exactly this and no more: every arch/variant of one key shares a
// directory and the artifact inside it is content-named, so requiring an arch
// there would refuse the very URL the catalog advertises.
func ValidateLocation(hostType, imageKey string) error {
	switch hostType {
	case HostTypeHyperV, HostTypeKVM, HostTypeUTM:
	default:
		return fmt.Errorf("unknown hostType %q", hostType)
	}
	if !segmentRE.MatchString(imageKey) {
		return fmt.Errorf("invalid imageKey %q", imageKey)
	}
	return nil
}

// Validate rejects anything that is not a known host type, a syntactically safe
// image key, and a known arch/variant pair.
func (id ImageID) Validate() error {
	if err := ValidateLocation(id.HostType, id.ImageKey); err != nil {
		return err
	}
	switch id.Arch {
	case ArchAMD64, ArchARM64:
	default:
		return fmt.Errorf("unknown arch %q", id.Arch)
	}
	switch id.Variant {
	case VariantStable, VariantDaily:
	default:
		return fmt.Errorf("unknown variant %q", id.Variant)
	}
	return nil
}

// Pointer is current.<arch>.<variant>.json: the small file whose atomic
// replacement is what changes which generation is served.
type Pointer struct {
	SchemaVersion    int    `json:"schemaVersion"`
	UpstreamFilename string `json:"upstreamFilename"`
	GenerationFile   string `json:"generationFile"`
	SHA256           string `json:"sha256"`
	UpdatedAt        string `json:"updatedAt"`
}

// Sidecar is <generation>.meta.json: everything a host needs to write its
// 4-line sentinel, plus what the agent's own re-verification compares against.
type Sidecar struct {
	SchemaVersion int    `json:"schemaVersion"`
	ImageKey      string `json:"imageKey"`
	HostType      string `json:"hostType"`
	Arch          string `json:"arch"`
	Variant       string `json:"variant"`
	// ResolvedVariant is the preference the resolver actually landed on, which
	// differs from Variant whenever preference-with-fallback fired. Variant
	// stays the requested one because it is the identity-attribution key; a
	// separate field is what lets metadata and the UI name the real build.
	ResolvedVariant  string `json:"resolvedVariant,omitempty"`
	SourceURL        string `json:"sourceUrl"`
	UpstreamFilename string `json:"upstreamFilename"`
	ByteCount        int64  `json:"byteCount"`
	LastModified     string `json:"lastModified"`
	SHA256           string `json:"sha256"`
	ChecksumVerdict  string `json:"checksumVerdict"`
	DownloadedAt     string `json:"downloadedAt"`
	LastVerifiedAt   string `json:"lastVerifiedAt"`
	AgentVersion     string `json:"agentVersion"`
}

// GenerationInfo is one artifact on disk.
type GenerationInfo struct {
	Name    string    `json:"name"`
	Bytes   int64     `json:"bytes"`
	ModTime time.Time `json:"-"`
	Current bool      `json:"current"`
}

// Entry is the on-disk view of one ImageID: pointer, its sidecar, and every
// generation in the directory that belongs to this identity.
type Entry struct {
	ID            ImageID
	Pointer       *Pointer
	Sidecar       *Sidecar
	Generations   []GenerationInfo
	CurrentBytes  int64
	PreviousBytes int64
}

// Store is the pool layout. It is stateless apart from the root path, so two
// callers never disagree about where a file lives.
type Store struct {
	poolDir string
}

// NewStore roots a Store at the pool mount (empty = no pool configured).
func NewStore(poolDir string) *Store { return &Store{poolDir: poolDir} }

// PoolDir returns the configured pool mount.
func (s *Store) PoolDir() string { return s.poolDir }

// ImagesDir returns the Download pool root.
func (s *Store) ImagesDir() string { return config.ImagesDirFor(s.poolDir) }

// Available reports whether the images root is reachable. A pool share that is
// not mounted answers false, which is what turns every ensure into a 503 rather
// than a mysterious download failure.
//
// It is deliberately stat-only. Creating the images root here would create it on
// the guest's local disk whenever the CIFS mount had failed: the empty mount
// point would be masked, the agent would report itself healthy, and seeding
// would write multi-gigabyte artifacts to the root filesystem where they become
// invisible the moment the share does come up. Every writer does its own
// MkdirAll, so nothing needs this one.
func (s *Store) Available() bool {
	if s.poolDir == "" {
		return false
	}
	fi, err := os.Stat(s.ImagesDir())
	return err == nil && fi.IsDir()
}

// Dir is the directory holding every generation for one (hostType, imageKey).
// Note that all arch/variant combinations of one key share this directory: the
// pointer name carries the arch and variant, the artifacts are content-named.
func (s *Store) Dir(id ImageID) string {
	return filepath.Join(s.ImagesDir(), id.HostType, id.ImageKey)
}

// PointerPath is the servable pointer for one identity.
func (s *Store) PointerPath(id ImageID) string {
	return filepath.Join(s.Dir(id), config.PointerName(id.Arch, id.Variant))
}

// StagingDir is the agent-private temp area for one key.
func (s *Store) StagingDir(id ImageID) string {
	return filepath.Join(s.Dir(id), config.StagingDirName)
}

// GenerationName is the upstream filename suffixed with the first 12 hex chars
// of the artifact's SHA-256. Content-addressing means promote never renames
// over a path http.ServeContent may be streaming, and a re-download whose bytes
// are unchanged lands on the generation that already exists.
func GenerationName(upstreamFilename, sha string) string {
	short := sha
	if len(short) > 12 {
		short = short[:12]
	}
	return upstreamFilename + "." + short
}

// SidecarName is the metadata file for a generation.
func SidecarName(generation string) string { return generation + config.SidecarSuffix }

// ValidGenerationName rejects anything that is not a plain artifact filename in
// the image directory.
func ValidGenerationName(name string) bool {
	if name == "" || strings.HasPrefix(name, ".") {
		return false
	}
	if strings.ContainsAny(name, `/\`) || name == "." || name == ".." {
		return false
	}
	if strings.HasSuffix(name, config.SidecarSuffix) {
		return false
	}
	if strings.HasPrefix(name, "current.") && strings.HasSuffix(name, ".json") {
		return false
	}
	return true
}

// ReadPointer loads the servable pointer; found=false when there is none.
func (s *Store) ReadPointer(id ImageID) (*Pointer, bool, error) {
	b, err := os.ReadFile(s.PointerPath(id))
	if errors.Is(err, os.ErrNotExist) {
		return nil, false, nil
	}
	if err != nil {
		return nil, false, err
	}
	var p Pointer
	if err := json.Unmarshal(b, &p); err != nil {
		return nil, false, fmt.Errorf("pointer %s: %w", s.PointerPath(id), err)
	}
	if p.GenerationFile == "" {
		return nil, false, nil
	}
	return &p, true, nil
}

// ReadSidecar loads one generation's metadata.
func (s *Store) ReadSidecar(id ImageID, generation string) (*Sidecar, error) {
	b, err := os.ReadFile(filepath.Join(s.Dir(id), SidecarName(generation)))
	if err != nil {
		return nil, err
	}
	var sc Sidecar
	if err := json.Unmarshal(b, &sc); err != nil {
		return nil, err
	}
	return &sc, nil
}

// WriteSidecar replaces one generation's metadata atomically.
func (s *Store) WriteSidecar(id ImageID, generation string, sc Sidecar) error {
	sc.SchemaVersion = SchemaVersion
	return writeJSONAtomic(filepath.Join(s.Dir(id), SidecarName(generation)), sc)
}

// WritePointer replaces the servable pointer atomically.
func (s *Store) WritePointer(id ImageID, p Pointer) error {
	p.SchemaVersion = SchemaVersion
	return writeJSONAtomic(s.PointerPath(id), p)
}

// Commit makes a generation servable: sidecar first, POINTER LAST. A reader that
// races this sees either the previous generation (pointer not yet flipped) or
// the new one with its metadata already on disk -- never a pointer naming an
// artifact whose sidecar has not landed.
func (s *Store) Commit(id ImageID, generation string, sc Sidecar) error {
	if err := s.WriteSidecar(id, generation, sc); err != nil {
		return err
	}
	return s.WritePointer(id, Pointer{
		UpstreamFilename: sc.UpstreamFilename,
		GenerationFile:   generation,
		SHA256:           sc.SHA256,
		UpdatedAt:        sc.LastVerifiedAt,
	})
}

// PromoteStaging moves a verified staging artifact into the image directory
// under its generation name. If that generation already exists (identical bytes
// re-downloaded), the staging copy is discarded rather than landed over a file a
// reader may hold open.
//
// The landing is a link-then-unlink, not a stat-then-rename: a second agent can
// promote the same generation between a stat and a rename, and the rename would
// then silently replace a path a host is streaming through http.ServeContent.
// os.Link fails with EEXIST instead, and because generations are content-named
// EEXIST *is* the identical-bytes case.
func (s *Store) PromoteStaging(id ImageID, stagedPath, generation string) error {
	if err := os.MkdirAll(s.Dir(id), 0o755); err != nil {
		return err
	}
	dst := filepath.Join(s.Dir(id), generation)
	err := os.Link(stagedPath, dst)
	if err == nil || errors.Is(err, os.ErrExist) {
		return os.Remove(stagedPath)
	}
	// Not every SMB server implements hard links. Where one is refused, the
	// promote still has to complete, so fall back to the check-then-rename that
	// cannot be EEXIST-safe.
	if _, serr := os.Stat(dst); serr == nil {
		return os.Remove(stagedPath)
	}
	return os.Rename(stagedPath, dst)
}

// Generations lists the artifacts in an image directory (dot-prefixed entries,
// pointers and sidecars excluded), newest first.
func (s *Store) Generations(id ImageID) ([]GenerationInfo, error) {
	ents, err := os.ReadDir(s.Dir(id))
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var out []GenerationInfo
	for _, e := range ents {
		if e.IsDir() || !ValidGenerationName(e.Name()) {
			continue
		}
		fi, err := e.Info()
		if err != nil {
			continue
		}
		out = append(out, GenerationInfo{Name: e.Name(), Bytes: fi.Size(), ModTime: fi.ModTime()})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].ModTime.After(out[j].ModTime) })
	return out, nil
}

// Entry assembles the on-disk view of one identity.
//
// Attribution is by POINTER REFERENCE first, sidecar second. One directory holds
// every arch/variant of a key, and content addressing collapses two preferences
// that resolve to the same bytes onto a single generation with a single sidecar
// -- which can only name one of them. A pointer, by contrast, is per-identity and
// authoritative: whatever this identity's pointer names is this identity's
// current generation. The sidecar's arch/variant then attributes the generations
// no pointer names, which is how the retained previous copy is found.
func (s *Store) Entry(id ImageID) (Entry, error) {
	e := Entry{ID: id}
	p, ok, err := s.ReadPointer(id)
	if err != nil {
		return e, err
	}
	if ok {
		e.Pointer = p
		if sc, err := s.ReadSidecar(id, p.GenerationFile); err == nil {
			e.Sidecar = sc
		}
	}
	gens, err := s.Generations(id)
	if err != nil {
		return e, err
	}
	claimed := s.referencedGenerations(id)
	for _, g := range gens {
		g.Current = e.Pointer != nil && e.Pointer.GenerationFile == g.Name
		if !g.Current {
			if claimed[g.Name] {
				// Another arch/variant's pointer holds this one; it is that
				// identity's current generation, not this identity's previous.
				continue
			}
			sc, err := s.ReadSidecar(id, g.Name)
			if err != nil {
				// An artifact with no sidecar belongs to no identity; it is swept
				// by retention rather than attributed to whoever asked first.
				continue
			}
			if sc.Arch != id.Arch || sc.Variant != id.Variant {
				continue
			}
		}
		if g.Current {
			e.CurrentBytes = g.Bytes
		} else {
			e.PreviousBytes += g.Bytes
		}
		e.Generations = append(e.Generations, g)
	}
	return e, nil
}

// List walks the pool and returns every identity that has a pointer on disk.
func (s *Store) List() ([]Entry, error) {
	root := s.ImagesDir()
	if root == "" {
		return nil, nil
	}
	hostDirs, err := os.ReadDir(root)
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var out []Entry
	for _, hd := range hostDirs {
		if !hd.IsDir() || strings.HasPrefix(hd.Name(), ".") {
			continue
		}
		keyDirs, err := os.ReadDir(filepath.Join(root, hd.Name()))
		if err != nil {
			continue
		}
		for _, kd := range keyDirs {
			if !kd.IsDir() || strings.HasPrefix(kd.Name(), ".") {
				continue
			}
			files, err := os.ReadDir(filepath.Join(root, hd.Name(), kd.Name()))
			if err != nil {
				continue
			}
			for _, f := range files {
				arch, variant, ok := parsePointerName(f.Name())
				if !ok {
					continue
				}
				id := ImageID{HostType: hd.Name(), ImageKey: kd.Name(), Arch: arch, Variant: variant}
				if id.Validate() != nil {
					continue
				}
				e, err := s.Entry(id)
				if err != nil {
					continue
				}
				out = append(out, e)
			}
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].ID.String() < out[j].ID.String() })
	return out, nil
}

// parsePointerName splits "current.<arch>.<variant>.json".
func parsePointerName(name string) (arch, variant string, ok bool) {
	if !strings.HasPrefix(name, "current.") || !strings.HasSuffix(name, ".json") {
		return "", "", false
	}
	mid := strings.TrimSuffix(strings.TrimPrefix(name, "current."), ".json")
	parts := strings.Split(mid, ".")
	if len(parts) != 2 || parts[0] == "" || parts[1] == "" {
		return "", "", false
	}
	return parts[0], parts[1], true
}

// Open returns a handle on one generation for byte serving. The caller closes it.
func (s *Store) Open(id ImageID, generation string) (*os.File, os.FileInfo, error) {
	if !ValidGenerationName(generation) {
		return nil, nil, fmt.Errorf("invalid generation name %q", generation)
	}
	f, err := os.Open(filepath.Join(s.Dir(id), generation))
	if err != nil {
		return nil, nil, err
	}
	fi, err := f.Stat()
	if err != nil {
		f.Close()
		return nil, nil, err
	}
	return f, fi, nil
}

// Delete removes the pointer FIRST (so nothing new can be handed out), then
// every generation that belongs to this identity and is not still referenced by
// a surviving pointer of another arch/variant in the same directory, then this
// identity's staging entries.
func (s *Store) Delete(id ImageID) ([]string, error) {
	var removed []string
	if err := removeWithDeadline(s.PointerPath(id)); err != nil {
		return removed, err
	}
	removed = append(removed, config.PointerName(id.Arch, id.Variant))

	referenced := s.referencedGenerations(id)
	gens, err := s.Generations(id)
	if err != nil {
		return removed, err
	}
	for _, g := range gens {
		if referenced[g.Name] {
			continue
		}
		sc, err := s.ReadSidecar(id, g.Name)
		if err == nil && (sc.Arch != id.Arch || sc.Variant != id.Variant) {
			continue
		}
		if err := removeWithDeadline(filepath.Join(s.Dir(id), g.Name)); err != nil {
			return removed, err
		}
		_ = removeWithDeadline(filepath.Join(s.Dir(id), SidecarName(g.Name)))
		removed = append(removed, g.Name)
	}
	_ = s.clearStaging(id)
	return removed, nil
}

// PrunePrevious deletes every generation of this identity except the pointer's,
// reclaiming the retained previous copy. The current generation stays servable.
func (s *Store) PrunePrevious(id ImageID) (int, error) {
	p, ok, err := s.ReadPointer(id)
	if err != nil {
		return 0, err
	}
	if !ok {
		return 0, nil
	}
	return s.retainOnly(id, map[string]bool{p.GenerationFile: true})
}

// Retain enforces the retention policy: the pointer's generation plus one
// previous. Anything older is deleted with the CIFS retry-in-deadline idiom.
func (s *Store) Retain(id ImageID) (int, error) {
	e, err := s.Entry(id)
	if err != nil {
		return 0, err
	}
	if e.Pointer == nil {
		return 0, nil
	}
	keep := map[string]bool{e.Pointer.GenerationFile: true}
	for _, g := range e.Generations {
		if g.Current {
			continue
		}
		// Generations are newest-first, so the first non-current one is the
		// single previous generation the policy retains.
		keep[g.Name] = true
		break
	}
	return s.retainOnly(id, keep)
}

// retainOnly deletes this identity's generations outside `keep`, skipping any
// still referenced by another arch/variant pointer in the same directory.
func (s *Store) retainOnly(id ImageID, keep map[string]bool) (int, error) {
	referenced := s.referencedGenerations(id)
	gens, err := s.Generations(id)
	if err != nil {
		return 0, err
	}
	n := 0
	for _, g := range gens {
		if keep[g.Name] || referenced[g.Name] {
			continue
		}
		sc, err := s.ReadSidecar(id, g.Name)
		if err == nil && (sc.Arch != id.Arch || sc.Variant != id.Variant) {
			continue
		}
		if err := removeWithDeadline(filepath.Join(s.Dir(id), g.Name)); err != nil {
			return n, err
		}
		_ = removeWithDeadline(filepath.Join(s.Dir(id), SidecarName(g.Name)))
		n++
	}
	return n, nil
}

// referencedGenerations collects the generations named by every pointer in the
// image directory except `exclude`'s own (pass a zero ImageID to include all).
func (s *Store) referencedGenerations(exclude ImageID) map[string]bool {
	dir := s.Dir(ImageID{HostType: exclude.HostType, ImageKey: exclude.ImageKey})
	if exclude.HostType == "" {
		return map[string]bool{}
	}
	out := map[string]bool{}
	ents, err := os.ReadDir(dir)
	if err != nil {
		return out
	}
	for _, e := range ents {
		arch, variant, ok := parsePointerName(e.Name())
		if !ok {
			continue
		}
		if arch == exclude.Arch && variant == exclude.Variant {
			continue
		}
		p, found, err := s.ReadPointer(ImageID{HostType: exclude.HostType, ImageKey: exclude.ImageKey, Arch: arch, Variant: variant})
		if err != nil || !found {
			continue
		}
		out[p.GenerationFile] = true
	}
	return out
}

// stagingPrefix namespaces this identity's staging entries inside the shared
// .staging directory, so a delete can clear one arch/variant without touching
// another's in-flight download.
func stagingPrefix(id ImageID) string { return id.Arch + "." + id.Variant + "." }

// NewStagingPath reserves a PID-suffixed staging path for a download. The PID
// is what lets a later sweep tell an abandoned attempt from a live one.
func (s *Store) NewStagingPath(id ImageID, upstreamFilename string) (string, error) {
	dir := s.StagingDir(id)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return "", err
	}
	name := stagingPrefix(id) + upstreamFilename + "." + strconv.Itoa(os.Getpid())
	return filepath.Join(dir, name), nil
}

func (s *Store) clearStaging(id ImageID) error {
	dir := s.StagingDir(id)
	ents, err := os.ReadDir(dir)
	if err != nil {
		return nil
	}
	for _, e := range ents {
		if !strings.HasPrefix(e.Name(), stagingPrefix(id)) {
			continue
		}
		_ = removeWithDeadline(filepath.Join(dir, e.Name()))
	}
	return nil
}

// SweepStaging removes staging entries older than config.StagingMaxAge or
// belonging to a dead PID. Agent restarts are routine and a single abandoned
// attempt can be multiple gigabytes, so this runs at startup and on every scan.
func (s *Store) SweepStaging(now time.Time, alive func(pid int) bool) (int, error) {
	root := s.ImagesDir()
	if root == "" {
		return 0, nil
	}
	if alive == nil {
		alive = ProcessAlive
	}
	removed := 0
	hostDirs, err := os.ReadDir(root)
	if errors.Is(err, os.ErrNotExist) {
		return 0, nil
	}
	if err != nil {
		return 0, err
	}
	for _, hd := range hostDirs {
		if !hd.IsDir() || strings.HasPrefix(hd.Name(), ".") {
			continue
		}
		keyDirs, err := os.ReadDir(filepath.Join(root, hd.Name()))
		if err != nil {
			continue
		}
		for _, kd := range keyDirs {
			if !kd.IsDir() || strings.HasPrefix(kd.Name(), ".") {
				continue
			}
			staging := filepath.Join(root, hd.Name(), kd.Name(), config.StagingDirName)
			ents, err := os.ReadDir(staging)
			if err != nil {
				continue
			}
			for _, e := range ents {
				fi, err := e.Info()
				if err != nil {
					continue
				}
				stale := now.Sub(fi.ModTime()) > config.StagingMaxAge
				if !stale {
					if pid, ok := stagingPID(e.Name()); ok && !alive(pid) {
						stale = true
					}
				}
				if !stale {
					continue
				}
				if err := removeWithDeadline(filepath.Join(staging, e.Name())); err == nil {
					removed++
				}
			}
		}
	}
	return removed, nil
}

// stagingPID reads the PID suffix a staging entry carries.
func stagingPID(name string) (int, bool) {
	i := strings.LastIndex(name, ".")
	if i < 0 || i == len(name)-1 {
		return 0, false
	}
	pid, err := strconv.Atoi(name[i+1:])
	if err != nil || pid <= 0 {
		return 0, false
	}
	return pid, true
}

// ProcessAlive reports whether a PID is still running. Only proof of death
// counts as dead: the sweep this feeds deletes multi-gigabyte artifacts, so an
// inconclusive probe must read as alive or one agent's sweep will delete
// another agent's in-flight download.
//
// The signal probe is inconclusive in two routine cases. On Windows it is not
// implemented at all (EWINDOWS). On Linux it returns EPERM for a live process
// owned by another user -- and the pool share is shared between agents that need
// not run as the same user.
func ProcessAlive(pid int) bool {
	if pid <= 0 {
		return false
	}
	if pid == os.Getpid() {
		return true
	}
	p, err := os.FindProcess(pid)
	if err != nil {
		return false
	}
	err = p.Signal(syscall.Signal(0))
	if err == nil || !errors.Is(err, os.ErrProcessDone) {
		return true
	}
	return false
}

// removeWithDeadline unlinks a path, retrying until deleteDeadline. SMB can hold
// a name visible while a handle drains or metadata catches up, so one failure is
// not proof the file is stuck; a path that is already gone is success.
func removeWithDeadline(path string) error {
	deadline := time.Now().Add(deleteDeadline)
	for {
		err := os.Remove(path)
		if err == nil || errors.Is(err, os.ErrNotExist) {
			return nil
		}
		if time.Now().After(deadline) {
			return err
		}
		time.Sleep(deleteRetryInterval)
	}
}

// writeJSONAtomic writes via a temp file plus rename, so a reader never sees a
// half-written pointer, sidecar or lease.
//
// The temp name is UNIQUE per write, not "<path>.tmp". Two agents share one NAS
// by design, and a shared temp name means one truncates the file while the
// other's rename is still pending -- the rename then publishes a torn document
// that ReadPointer rejects and List silently drops, so the image vanishes from
// the catalog. Last-writer-wins is only allowed between VALID states. The name
// is dot-prefixed so a temp abandoned by a killed process is skipped by every
// pool walker rather than mistaken for an artifact.
func writeJSONAtomic(path string, v any) error {
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	b, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		return err
	}
	f, err := os.CreateTemp(dir, "."+filepath.Base(path)+".tmp")
	if err != nil {
		return err
	}
	tmp := f.Name()
	if _, err := f.Write(append(b, '\n')); err != nil {
		f.Close()
		_ = os.Remove(tmp)
		return err
	}
	if err := f.Close(); err != nil {
		_ = os.Remove(tmp)
		return err
	}
	// CreateTemp opens 0600; these files are world-readable metadata. A share
	// that refuses chmod is not a reason to fail the write.
	_ = os.Chmod(tmp, 0o644)
	if err := os.Rename(tmp, path); err != nil {
		_ = os.Remove(tmp)
		return err
	}
	return nil
}
