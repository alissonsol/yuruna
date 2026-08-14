// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package imagestore

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"download-agent-service/internal/config"
)

// The Windows 11 media is the one artifact in the pool whose URL a machine is
// not always allowed to have: Microsoft mints it per session behind a bot check
// that can refuse this agent outright, and no amount of retrying converts a
// refusal into a link. A human with a browser is never refused, though, and the
// pool is still the right place for the bytes -- so when the resolver cannot
// run, the agent stops reporting only what broke and instead names the page,
// the choices to make on it, and a folder to drop the file into, then adopts
// whatever lands there.

// The pages that mint the media by hand -- one per architecture, because
// Microsoft publishes the Arm64 media on a page of its own. Same URLs, and
// below the same choices, that the host guest.windows.11 scripts print when
// their own Fido run fails: an operator meets one set of instructions whichever
// surface sent them there, and the pool ends up holding what the hosts would
// have fetched.
const (
	windows11DownloadPage      = "https://www.microsoft.com/en-us/software-download/windows11"
	windows11ARM64DownloadPage = "https://www.microsoft.com/en-us/software-download/windows11arm64"
)

// manualSettle is how long a dropped file must sit unwritten before it is
// adopted. A copy onto the share advances the file's modification time as it
// writes, so a last write this old is a copy that has finished; adopting mid-copy
// would hash a truncated ISO and publish it to every host as the real one.
const manualSettle = 2 * time.Minute

// ManualFallback is how to obtain one artifact by hand when the agent cannot
// resolve it: where the publisher hands it out, what to choose there, and where
// to put the file so the pool serves it like any other generation.
type ManualFallback struct {
	// PageURL is the publisher page that mints the download.
	PageURL string `json:"pageUrl"`
	// Selections are the choices to make on that page, in order. They name the
	// same edition, language and architecture the automated resolve asks for, so
	// a hand-fetched artifact is the one the pool would have held anyway.
	Selections []string `json:"selections"`
	// Folder is the drop folder as an operator reaches it -- on the share when
	// the pool advertises a network path, on the agent's own mount otherwise.
	Folder string `json:"folder"`
	// FolderURL is that same folder as a URL, so the UI can offer it as a link
	// instead of a path to retype.
	FolderURL string `json:"folderUrl,omitempty"`
}

// ManualDir is the drop folder for one identity. Per arch and variant, mirroring
// the pointer name: one image directory holds every arch of a key, and an ISO
// dropped for arm64 must not be published as the amd64 entry's artifact.
func (s *Store) ManualDir(id ImageID) string {
	return filepath.Join(s.Dir(id), config.ManualDirName, id.Arch+"."+id.Variant)
}

// ManualCandidate reports the file waiting in an identity's drop folder: the
// newest one that has finished being copied. Anything still being written, and
// anything that is not a plain artifact name, is left alone -- a drop folder is
// written by hand, so it must tolerate a copy in progress and a stray dot-file.
func (s *Store) ManualCandidate(id ImageID, now time.Time) (path string, info os.FileInfo, ok bool) {
	dir := s.ManualDir(id)
	ents, err := os.ReadDir(dir)
	if err != nil {
		return "", nil, false
	}
	type cand struct {
		name string
		fi   os.FileInfo
	}
	var cands []cand
	for _, e := range ents {
		if e.IsDir() || !ValidGenerationName(e.Name()) {
			continue
		}
		fi, err := e.Info()
		if err != nil || fi.Size() <= 0 {
			continue
		}
		if now.Sub(fi.ModTime()) < manualSettle {
			continue
		}
		cands = append(cands, cand{name: e.Name(), fi: fi})
	}
	if len(cands) == 0 {
		return "", nil, false
	}
	sort.Slice(cands, func(i, j int) bool { return cands[i].fi.ModTime().After(cands[j].fi.ModTime()) })
	return filepath.Join(dir, cands[0].name), cands[0].fi, true
}

// ManualFallbackFor describes the hand-download path for an identity, or nil
// when the family has none. Only a family whose artifact a person can fetch from
// a documented page gets one: pointing an operator at a folder for bytes they
// have no way to obtain would be worse than the error it replaced.
//
// networkPath is the pool share as the rest of the lab reaches it
// (//server/share/...); empty falls back to the agent's own mount point, which
// is still the truth, just only reachable from the guest.
func ManualFallbackFor(id ImageID, localDir, imagesDir, networkPath string) *ManualFallback {
	if FamilyOf(id.ImageKey) != FamilyWindows11 {
		return nil
	}
	mf := &ManualFallback{
		PageURL:    windows11Page(id.Arch),
		Selections: windows11Selections(id.Arch),
		Folder:     localDir,
	}
	if shared := shareFolder(networkPath, imagesDir, localDir); shared != "" {
		mf.Folder = shared
	}
	mf.FolderURL = folderURL(mf.Folder)
	return mf
}

// windows11Page is where an architecture's media is handed out.
func windows11Page(arch string) string {
	if arch == ArchARM64 {
		return windows11ARM64DownloadPage
	}
	return windows11DownloadPage
}

// windows11Selections is what to choose on that page to end up with the
// artifact this identity's automated resolve would have fetched. The language
// is the resolver's own constant, so the two paths cannot drift into serving
// different editions of the same row.
func windows11Selections(arch string) []string {
	edition, download := "Windows 11 (multi-edition ISO for x64 devices)", "64-bit Download"
	if arch == ArchARM64 {
		edition, download = "Windows 11 (multi-edition ISO for ARM64 devices)", "ARM64 Download"
	}
	return []string{edition, FidoLanguage, download}
}

// shareFolder re-roots an agent-local pool path onto the share's network path,
// so the folder named to an operator is the one their file manager can open
// rather than a mount point inside the guest. Empty when there is no network
// path configured or the local path is not under the images root -- a guessed
// re-rooting would name a folder on the NAS that has nothing to do with this
// pool. The network path is the share ROOT, which is why the images directory
// name is put back on top of it.
func shareFolder(networkPath, imagesDir, localDir string) string {
	networkPath = strings.TrimRight(strings.ReplaceAll(strings.TrimSpace(networkPath), `\`, "/"), "/")
	if networkPath == "" || imagesDir == "" {
		return ""
	}
	rel, ok := strings.CutPrefix(filepath.ToSlash(localDir), filepath.ToSlash(imagesDir)+"/")
	if !ok {
		return ""
	}
	return networkPath + "/" + config.ImagesDirName + "/" + rel
}

// folderURL turns a pool path into a URL a browser can offer as a link: a UNC
// path becomes file://server/share/..., an absolute local path file:///path.
// Anything else yields nothing rather than a link that goes somewhere else.
func folderURL(folder string) string {
	folder = filepath.ToSlash(folder)
	if rest, ok := strings.CutPrefix(folder, "//"); ok {
		host, path, found := strings.Cut(rest, "/")
		if !found || host == "" {
			return ""
		}
		u := url.URL{Scheme: "file", Host: host, Path: "/" + path}
		return u.String()
	}
	if !strings.HasPrefix(folder, "/") {
		return ""
	}
	u := url.URL{Scheme: "file", Path: folder}
	return u.String()
}

// manualFallback describes the hand-download path for one row, or nil when the
// family has none.
func (a *Agent) manualFallback(id ImageID) *ManualFallback {
	return ManualFallbackFor(id, a.store.ManualDir(id), a.store.ImagesDir(), a.opts.PoolNetworkPath)
}

// adoptManual publishes a hand-placed artifact as this identity's current
// generation and reports whether it did. It runs ahead of the resolver in every
// refresh: a file in the drop folder is an operator saying "the automated path
// cannot get this, here are the bytes", so re-running a resolve that just
// refused would spend a session to arrive at the same answer.
//
// Only a best-effort family is adopted. Everything else has a resolver that
// works, and a hand-placed copy of it would be replaced by the next scan anyway
// -- silently, which is the surprise this refuses to create.
func (a *Agent) adoptManual(ctx context.Context, id ImageID, p *Progress) (bool, error) {
	if !IsBestEffort(id.ImageKey) {
		return false, nil
	}
	path, info, ok := a.store.ManualCandidate(id, a.now())
	if !ok {
		return false, nil
	}

	p.SetPhase(PhaseAdopting)
	p.SetTotal(info.Size())
	sha, n, err := hashFile(ctx, path, p)
	if err != nil {
		return false, fmt.Errorf("manual drop %s: %w", path, err)
	}
	if n != info.Size() {
		// The settle delay is meant to have ruled this out; a file that still
		// grew while being read is one nobody should publish.
		return false, fmt.Errorf("manual drop %s: %d byte(s) when listed, %d when read", path, info.Size(), n)
	}

	name := filepath.Base(path)
	generation := GenerationName(name, sha)
	p.SetPhase(PhasePromoting)
	if err := a.store.PromoteStaging(id, path, generation); err != nil {
		return false, fmt.Errorf("manual drop %s: %w", path, err)
	}
	nowStr := a.now().UTC().Format(time.RFC3339)
	sc := Sidecar{
		ImageKey: id.ImageKey, HostType: id.HostType, Arch: id.Arch, Variant: id.Variant,
		ResolvedVariant:  id.Variant,
		UpstreamFilename: name,
		ByteCount:        n,
		SHA256:           sha,
		// The publisher hands out no checksum for media minted per session, and
		// the operator's copy carries none either, so the verdict says what it
		// always says for this family: nothing was proven.
		ChecksumVerdict: VerdictNone,
		// Where these bytes came from, as far as anything here knows: the page an
		// operator was sent to. Naming a signed URL would be a claim about a
		// download that this agent never made.
		SourceURL:      windows11SourceURL(id),
		DownloadedAt:   nowStr,
		LastVerifiedAt: nowStr,
		AgentVersion:   a.opts.AgentVersion,
	}
	if err := a.store.Commit(id, generation, sc); err != nil {
		return false, err
	}
	if _, err := a.store.Retain(id); err != nil {
		a.logf("retention for %s: %v", id, err)
	}
	a.audit("adopt", id, "ok", name)
	a.logf("adopted hand-placed %s for %s", name, id)
	return true, nil
}

// windows11SourceURL is the provenance an adopted artifact carries: the page it
// was fetched from by hand, for the family that has one.
func windows11SourceURL(id ImageID) string {
	if FamilyOf(id.ImageKey) != FamilyWindows11 {
		return ""
	}
	return windows11Page(id.Arch)
}

// hashFile reads a file once, hashing and counting as it goes, and tees into the
// flight's progress so a multi-gigabyte adoption is visible in the table rather
// than looking like a stalled row.
func hashFile(ctx context.Context, path string, p *Progress) (string, int64, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", 0, err
	}
	defer f.Close()
	h := sha256.New()
	n, err := io.Copy(io.MultiWriter(h, p), &ctxReader{ctx: ctx, r: f})
	if err != nil {
		return "", n, err
	}
	return hex.EncodeToString(h.Sum(nil)), n, nil
}

// ctxReader aborts a read when the flight is canceled. Hashing gigabytes off a
// share is not instant, and a delete or a daemon stop must not wait it out.
type ctxReader struct {
	ctx context.Context
	r   io.Reader
}

func (c *ctxReader) Read(p []byte) (int, error) {
	if err := c.ctx.Err(); err != nil {
		return 0, err
	}
	return c.r.Read(p)
}

// manualPass is the scan's half of the hand-download path: it starts an
// adoption for an identity whose drop folder holds a finished copy, and creates
// that folder for a family this agent cannot currently resolve. The folder is
// created rather than only named because the UI offers it as a link the moment
// the family breaks, and a link to a folder that does not exist reads as a typo.
//
// Both halves are best effort. A share that refuses the mkdir leaves an operator
// to create the folder by hand, which works just as well; a candidate that turns
// out to be unreadable fails inside its own flight, where the error belongs to
// one row instead of to the scan.
func (a *Agent) manualPass(hostTypes []string) int {
	started := 0
	for _, id := range BestEffortTargets(hostTypes) {
		if a.manualFallback(id) == nil {
			continue
		}
		if _, _, ok := a.store.ManualCandidate(id, a.now()); ok {
			if _, ok := a.startRefresh(id, false); ok {
				started++
			}
			continue
		}
		if a.familyUnavailable(id) == "" {
			continue
		}
		if err := os.MkdirAll(a.store.ManualDir(id), 0o755); err != nil {
			a.logf("could not create the manual drop folder %s: %v", a.store.ManualDir(id), err)
		}
	}
	return started
}
