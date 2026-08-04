// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package imagestore

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"path"
	"regexp"
	"strconv"
	"strings"
)

// Families the agent resolves. Each one mirrors the PowerShell resolver that
// remains the host-side fallback, so resolver drift degrades agent freshness
// rather than correctness.
const (
	FamilyUbuntuISO      = "ubuntu-iso"
	FamilyUbuntuCloudImg = "ubuntu-cloud-image"
	FamilyAmazonLinux    = "amazon-linux-2023"
	FamilyWindows11      = "windows-11"
	FamilyVirtioWin      = "virtio-win"
)

// AllFamilies is every family the agent resolves. It exists so a family-keyed
// policy -- the signed-URL freshness exception below is the one that matters --
// can be stated against the whole set instead of only against the family that
// motivated it, and so a family added later cannot inherit that exception by
// accident.
var AllFamilies = []string{
	FamilyUbuntuISO, FamilyUbuntuCloudImg, FamilyAmazonLinux, FamilyWindows11, FamilyVirtioWin,
}

// Checksum publication shapes.
const (
	// ChecksumSHA256SUMS is a multi-line "<sha>  <filename>" manifest.
	ChecksumSHA256SUMS = "sha256sums"
	// ChecksumSidecar is a single-artifact "<sha>[  <filename>]" file.
	ChecksumSidecar = "sha256-sidecar"
)

// Resolved is one family resolution: where the bytes are and how to prove them.
type Resolved struct {
	Family           string
	UpstreamFilename string
	SourceURL        string
	ChecksumURL      string
	ChecksumFormat   string
	// ChecksumTarget is the filename to look up inside a SHA256SUMS manifest.
	ChecksumTarget string
	// Variant is the preference that actually resolved, which can differ from
	// the requested one when the fallback fired.
	Variant string
}

// codenames maps an image key to the Ubuntu release codename the host wrappers
// pass today. An unmapped key has no Ubuntu family.
var codenames = map[string]string{
	KeyUbuntuServer24:  "noble",
	KeyUbuntuServer26:  "resolute",
	KeyUbuntuExtension: "resolute",
}

// FamilyOf classifies an image key. An unknown key resolves to "" and the agent
// answers "absent" for it rather than inventing a URL.
func FamilyOf(imageKey string) string {
	switch imageKey {
	case KeyUbuntuServer24, KeyUbuntuServer26:
		return FamilyUbuntuISO
	case KeyUbuntuExtension:
		return FamilyUbuntuCloudImg
	case KeyAmazonLinux2023:
		return FamilyAmazonLinux
	case KeyWindows11:
		return FamilyWindows11
	case KeyVirtioWin:
		return FamilyVirtioWin
	default:
		return ""
	}
}

// IsBestEffort reports whether a family may simply not be servable by a given
// agent: it needs a tool the agent VM might not have (Fido), or it is an
// auxiliary artifact hosts can and do fetch themselves. Hosts read an absent
// best-effort family as "no agent for this image" and use their own path, so the
// flag is what lets an operator tell that apart from "not downloaded yet".
func IsBestEffort(imageKey string) bool {
	switch FamilyOf(imageKey) {
	case FamilyWindows11, FamilyVirtioWin:
		return true
	default:
		return false
	}
}

// ComparesSourceURL reports whether the freshness comparison may include the
// source URL for a family. Fido mints a NEW signed URL for the same ISO on every
// resolve, so a URL comparison there would differ on every scan and re-download
// ~5.5 GB forever; that family compares upstream filename plus Content-Length
// instead, both of which are stable across resolves. Every other family has a
// URL that changes only when the artifact does and must keep comparing it --
// which is why this answers per family and not per entry.
func ComparesSourceURL(family string) bool {
	return family != FamilyWindows11
}

// CodenameFor exposes the imageKey -> release codename map.
func CodenameFor(imageKey string) (string, bool) {
	c, ok := codenames[imageKey]
	return c, ok
}

// Supported reports whether the agent has a resolver for this identity. It is a
// statement about the identity alone: whether the resolver can actually run on
// THIS agent is a separate question, because a best-effort family depends on
// tooling the agent VM may not have.
func Supported(id ImageID) bool {
	family := FamilyOf(id.ImageKey)
	if family == "" {
		return false
	}
	// Only the Ubuntu ISO family has a daily preference; everything else is
	// stable-only, and a daily request for it would name a URL that does not
	// exist.
	if id.Variant == VariantDaily && family != FamilyUbuntuISO {
		return false
	}
	// The virtio-win bundle carries x86-64 drivers only. Answering an arm64
	// request with it would hand a Windows-on-ARM install drivers it cannot
	// load, and the failure would surface much later as an unbootable guest, so
	// the arch is refused outright.
	if family == FamilyVirtioWin && id.Arch != ArchAMD64 {
		return false
	}
	return true
}

// ubuntuURLs is the stable + daily URL pair for a codename and arch.
type ubuntuURLs struct {
	StableReleaseURL string
	StableISOPattern string
	DailyBaseURL     string
	DailyISOFileName string
}

// ubuntuManifest mirrors Get-UbuntuServerImageManifestUrl. releases.ubuntu.com
// is amd64-only, so arm64 stable comes from the cdimage release tree. The daily
// path always pins the codename: the codename-less ubuntu-server/daily-live path
// is rolling and 404s for a codename that has already shipped.
func ubuntuManifest(codename, arch string) ubuntuURLs {
	stable := "https://cdimage.ubuntu.com/releases/" + codename + "/release"
	if arch == ArchAMD64 {
		stable = "https://releases.ubuntu.com/" + codename
	}
	return ubuntuURLs{
		StableReleaseURL: stable,
		StableISOPattern: `ubuntu-[\d.]+-live-server-` + arch + `\.iso`,
		DailyBaseURL:     "https://cdimage.ubuntu.com/ubuntu-server/" + codename + "/daily-live/current",
		DailyISOFileName: codename + "-live-server-" + arch + ".iso",
	}
}

// al2023PlatformDir maps a host type + arch onto the AL2023 publisher's
// platform directory. Hyper-V takes the zipped VHDX; the two qemu-family hosts
// take the native qcow2.
func al2023PlatformDir(hostType, arch string) (dir, suffix string, ok bool) {
	switch hostType {
	case HostTypeHyperV:
		return "hyperv", ".zip", true
	case HostTypeKVM:
		if arch == ArchARM64 {
			return "kvm-arm64", ".qcow2", true
		}
		return "kvm", ".qcow2", true
	case HostTypeUTM:
		return "kvm-arm64", ".qcow2", true
	}
	return "", "", false
}

// Resolver turns an ImageID into a concrete origin URL. Its client MUST be the
// direct one: a resolution fetched through the caching proxy would pin the
// answer to whatever the cache was primed with.
type Resolver struct {
	Client *http.Client
	// Fido locates the interpreter and script the Windows 11 family needs. Its
	// zero value points at the standard install locations, which is also the
	// right production default.
	Fido FidoConfig
}

// NewResolver builds a Resolver over a direct HTTP client.
func NewResolver(client *http.Client) *Resolver { return &Resolver{Client: client} }

// Resolve dispatches to the family resolver for this identity.
func (r *Resolver) Resolve(ctx context.Context, id ImageID) (Resolved, error) {
	switch FamilyOf(id.ImageKey) {
	case FamilyUbuntuISO:
		return r.resolveUbuntuISO(ctx, id)
	case FamilyUbuntuCloudImg:
		return r.resolveUbuntuCloudImage(ctx, id)
	case FamilyAmazonLinux:
		return r.resolveAmazonLinux(ctx, id)
	case FamilyWindows11:
		return r.resolveWindows11(ctx, id)
	case FamilyVirtioWin:
		return r.resolveVirtioWin(id)
	default:
		return Resolved{}, fmt.Errorf("no resolver for imageKey %q", id.ImageKey)
	}
}

// resolveUbuntuISO keeps Resolve-UbuntuServerImage's preference-with-fallback
// semantics: the requested variant is tried first and the other one is the
// fallback, with the resolved outcome recorded so the sidecar tells the truth
// about which build the bytes came from.
func (r *Resolver) resolveUbuntuISO(ctx context.Context, id ImageID) (Resolved, error) {
	codename, ok := CodenameFor(id.ImageKey)
	if !ok {
		return Resolved{}, fmt.Errorf("no release codename for imageKey %q", id.ImageKey)
	}
	u := ubuntuManifest(codename, id.Arch)
	stable := func() (Resolved, error) { return r.ubuntuStable(ctx, u) }
	daily := func() (Resolved, error) { return r.ubuntuDaily(ctx, u) }

	first, second := stable, daily
	if id.Variant == VariantDaily {
		first, second = daily, stable
	}
	res, err := first()
	if err == nil {
		return res, nil
	}
	firstErr := err
	res, err = second()
	if err == nil {
		return res, nil
	}
	return Resolved{}, fmt.Errorf("ubuntu iso resolve failed (preferred: %v; fallback: %v)", firstErr, err)
}

func (r *Resolver) ubuntuStable(ctx context.Context, u ubuntuURLs) (Resolved, error) {
	body, err := r.getText(ctx, u.StableReleaseURL+"/")
	if err != nil {
		return Resolved{}, fmt.Errorf("stable index %s: %w", u.StableReleaseURL, err)
	}
	iso, err := PickLatestISO(body, u.StableISOPattern)
	if err != nil {
		return Resolved{}, fmt.Errorf("stable index %s: %w", u.StableReleaseURL, err)
	}
	return Resolved{
		Family:           FamilyUbuntuISO,
		UpstreamFilename: iso,
		SourceURL:        u.StableReleaseURL + "/" + iso,
		ChecksumURL:      u.StableReleaseURL + "/SHA256SUMS",
		ChecksumFormat:   ChecksumSHA256SUMS,
		ChecksumTarget:   iso,
		Variant:          VariantStable,
	}, nil
}

func (r *Resolver) ubuntuDaily(ctx context.Context, u ubuntuURLs) (Resolved, error) {
	url := u.DailyBaseURL + "/" + u.DailyISOFileName
	resp, err := r.head(ctx, url)
	if err != nil {
		return Resolved{}, fmt.Errorf("daily probe %s: %w", url, err)
	}
	resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return Resolved{}, fmt.Errorf("daily probe %s: HTTP %d", url, resp.StatusCode)
	}
	return Resolved{
		Family:           FamilyUbuntuISO,
		UpstreamFilename: u.DailyISOFileName,
		SourceURL:        url,
		ChecksumURL:      u.DailyBaseURL + "/SHA256SUMS",
		ChecksumFormat:   ChecksumSHA256SUMS,
		ChecksumTarget:   u.DailyISOFileName,
		Variant:          VariantDaily,
	}, nil
}

// resolveUbuntuCloudImage is a fixed URL -- the shared extension-service base
// image, one artifact per host type rather than one per service guest.
func (r *Resolver) resolveUbuntuCloudImage(ctx context.Context, id ImageID) (Resolved, error) {
	codename, ok := CodenameFor(id.ImageKey)
	if !ok {
		return Resolved{}, fmt.Errorf("no release codename for imageKey %q", id.ImageKey)
	}
	base := "https://cloud-images.ubuntu.com/" + codename + "/current"
	name := codename + "-server-cloudimg-" + id.Arch + ".img"
	return Resolved{
		Family:           FamilyUbuntuCloudImg,
		UpstreamFilename: name,
		SourceURL:        base + "/" + name,
		ChecksumURL:      base + "/SHA256SUMS",
		ChecksumFormat:   ChecksumSHA256SUMS,
		ChecksumTarget:   name,
		Variant:          VariantStable,
	}, nil
}

// resolveAmazonLinux scrapes the publisher's latest-release listing. The listing
// exposes exactly one artifact plus its .sha256 sidecar per release, so the
// first matching link is the release.
func (r *Resolver) resolveAmazonLinux(ctx context.Context, id ImageID) (Resolved, error) {
	dir, suffix, ok := al2023PlatformDir(id.HostType, id.Arch)
	if !ok {
		return Resolved{}, fmt.Errorf("no AL2023 platform directory for %s/%s", id.HostType, id.Arch)
	}
	base := "https://cdn.amazonlinux.com/al2023/os-images/latest/" + dir + "/"
	body, err := r.getText(ctx, base)
	if err != nil {
		return Resolved{}, fmt.Errorf("al2023 listing %s: %w", base, err)
	}
	artifact := FirstLinkWithSuffix(body, suffix)
	if artifact == "" {
		return Resolved{}, fmt.Errorf("no %s listed at %s", suffix, base)
	}
	res := Resolved{
		Family:           FamilyAmazonLinux,
		UpstreamFilename: path.Base(artifact),
		SourceURL:        base + artifact,
		Variant:          VariantStable,
	}
	if sum := FirstLinkWithSuffix(body, suffix+".sha256"); sum != "" {
		res.ChecksumURL = base + sum
		res.ChecksumFormat = ChecksumSidecar
		res.ChecksumTarget = res.UpstreamFilename
	}
	return res, nil
}

// virtioWinURL is the pinned versioned virtio-win archive. The convenience
// stable-virtio/ and latest-virtio/ paths 301-redirect to this same file through
// a chain that bounces https -> http -> https: Apache emits http:// Location
// headers and HSTS preload upgrades them back. Clients that refuse an https->http
// downgrade -- .NET HttpClient and the squid ssl-bump port every host download
// routes through -- cannot follow that chain, so the pinned archive URL, a
// single-hop 200 over https, is the only form that works for every consumer.
//
// To refresh: list .../direct-downloads/stable-virtio/ for the current
// virtio-win-<ver>.iso, then point this at
// .../archive-virtio/virtio-win-<ver>-1/virtio-win-<ver>.iso.
const virtioWinURL = "https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/archive-virtio/virtio-win-0.1.285-1/virtio-win-0.1.285.iso"

// resolveVirtioWin answers the pinned URL without touching the network: the
// artifact is one fixed versioned file, so there is no index to scrape and
// nothing to version-sort. The publisher offers no checksum sidecar beside it,
// which makes the verdict "none" -- the same trust the host path extends to it.
func (r *Resolver) resolveVirtioWin(id ImageID) (Resolved, error) {
	if id.Arch != ArchAMD64 {
		return Resolved{}, fmt.Errorf("virtio-win publishes x86-64 drivers only, so there is nothing to serve for %s", id.Arch)
	}
	return Resolved{
		Family:           FamilyVirtioWin,
		UpstreamFilename: path.Base(virtioWinURL),
		SourceURL:        virtioWinURL,
		Variant:          VariantStable,
	}, nil
}

// resolveWindows11 mints a download URL by running Fido, the same tool and the
// same parameters the host scripts use. The URL it returns is signed and
// short-lived, so it is only ever used immediately; what survives into the
// sidecar for later comparison is the filename and the byte count (see
// ComparesSourceURL).
//
// Every failure below is returned as an error and the agent turns it into
// "family unavailable", which is why nothing here retries or substitutes a
// guess: a wrong URL would be downloaded, checksummed against nothing and
// served to hosts as the Windows 11 ISO.
func (r *Resolver) resolveWindows11(ctx context.Context, id ImageID) (Resolved, error) {
	arch, ok := fidoArchFor(id.Arch)
	if !ok {
		return Resolved{}, fmt.Errorf("no Fido architecture for %q", id.Arch)
	}
	raw, err := r.Fido.ResolveURL(ctx, arch)
	if err != nil {
		return Resolved{}, err
	}
	name := filenameFromSignedURL(raw)
	if name == "" {
		return Resolved{}, fmt.Errorf("the URL Fido returned names no file")
	}
	// Microsoft publishes no checksum for the ISO behind the signed URL, so the
	// verdict is "none": the host path verifies size only, and the agent must not
	// claim more assurance than the publisher offers.
	return Resolved{
		Family:           FamilyWindows11,
		UpstreamFilename: name,
		SourceURL:        raw,
		Variant:          VariantStable,
	}, nil
}

func (r *Resolver) getText(ctx context.Context, url string) (string, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return "", err
	}
	resp, err := r.Client.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return "", fmt.Errorf("HTTP %d", resp.StatusCode)
	}
	// Index pages are small; the cap stops a misrouted response from a proxy
	// error page consuming memory.
	b, err := io.ReadAll(io.LimitReader(resp.Body, 8<<20))
	if err != nil {
		return "", err
	}
	return string(b), nil
}

func (r *Resolver) head(ctx context.Context, url string) (*http.Response, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodHead, url, nil)
	if err != nil {
		return nil, err
	}
	return r.Client.Do(req)
}

// versionInName pulls the dotted version out of an ISO filename.
var versionInName = regexp.MustCompile(`(\d+(?:\.\d+)+)`)

// hrefRE extracts the href targets from a directory listing.
var hrefRE = regexp.MustCompile(`(?i)href\s*=\s*["']([^"']+)["']`)

// PickLatestISO returns the highest-versioned ISO name matching pattern in a
// release index page. The sort is numeric per component, not lexical: as
// strings "24.04.2" sorts above "24.04.10", which would pick the older point
// release.
func PickLatestISO(page, pattern string) (string, error) {
	re, err := regexp.Compile(pattern)
	if err != nil {
		return "", err
	}
	found := re.FindAllString(page, -1)
	if len(found) == 0 {
		return "", fmt.Errorf("no ISO matching pattern %q", pattern)
	}
	best := found[0]
	for _, cand := range found[1:] {
		if compareVersionsIn(cand, best) > 0 {
			best = cand
		}
	}
	return best, nil
}

// compareVersionsIn compares the dotted versions embedded in two names.
func compareVersionsIn(a, b string) int {
	return compareDottedVersions(versionInName.FindString(a), versionInName.FindString(b))
}

func compareDottedVersions(a, b string) int {
	as, bs := strings.Split(a, "."), strings.Split(b, ".")
	n := len(as)
	if len(bs) > n {
		n = len(bs)
	}
	for i := 0; i < n; i++ {
		av, bv := 0, 0
		if i < len(as) {
			av, _ = strconv.Atoi(as[i])
		}
		if i < len(bs) {
			bv, _ = strconv.Atoi(bs[i])
		}
		if av != bv {
			if av > bv {
				return 1
			}
			return -1
		}
	}
	return 0
}

// FirstLinkWithSuffix returns the first href in a directory listing whose target
// ends with suffix, mirroring the AL2023 scripts' $html.Links selection.
func FirstLinkWithSuffix(page, suffix string) string {
	for _, m := range hrefRE.FindAllStringSubmatch(page, -1) {
		href := strings.TrimSpace(m[1])
		if strings.HasSuffix(href, suffix) {
			return href
		}
	}
	return ""
}

// ParseSHA256SUMS finds the hash for one filename in a SHA256SUMS manifest.
// The leading '*' the binary-mode format writes is stripped.
func ParseSHA256SUMS(body, filename string) string {
	for _, line := range strings.Split(body, "\n") {
		fields := strings.Fields(strings.TrimSpace(line))
		if len(fields) < 2 {
			continue
		}
		if strings.TrimPrefix(fields[len(fields)-1], "*") == filename {
			return strings.ToLower(fields[0])
		}
	}
	return ""
}

// ParseSHA256Sidecar reads a single-artifact .sha256 file, which publishers
// write either bare or in "<sha>  <filename>" form.
func ParseSHA256Sidecar(body string) string {
	for _, f := range strings.Fields(body) {
		if isHex64(f) {
			return strings.ToLower(f)
		}
	}
	return ""
}

func isHex64(s string) bool {
	if len(s) != 64 {
		return false
	}
	for _, c := range s {
		switch {
		case c >= '0' && c <= '9', c >= 'a' && c <= 'f', c >= 'A' && c <= 'F':
		default:
			return false
		}
	}
	return true
}
