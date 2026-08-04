// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package imagestore

import (
	"context"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
)

// Fixture bodies, trimmed to the shapes the resolvers actually parse.

const ubuntuReleaseIndexFixture = `<!DOCTYPE html>
<html><head><title>Ubuntu 26.04 LTS (Resolute Raccoon)</title></head><body>
<table>
<tr><td><a href="ubuntu-26.04-live-server-amd64.iso">ubuntu-26.04-live-server-amd64.iso</a></td><td>3.0G</td></tr>
<tr><td><a href="ubuntu-26.04.2-live-server-amd64.iso">ubuntu-26.04.2-live-server-amd64.iso</a></td><td>3.1G</td></tr>
<tr><td><a href="ubuntu-26.04.10-live-server-amd64.iso">ubuntu-26.04.10-live-server-amd64.iso</a></td><td>3.2G</td></tr>
<tr><td><a href="ubuntu-26.04.10-live-server-arm64.iso">ubuntu-26.04.10-live-server-arm64.iso</a></td><td>3.2G</td></tr>
<tr><td><a href="SHA256SUMS">SHA256SUMS</a></td><td>1.2K</td></tr>
</table></body></html>`

const al2023ListingFixture = `<html><head><title>Index of al2023/os-images/latest/kvm/</title></head><body>
<h1>Index</h1>
<ul>
<li><a href="../">Parent Directory</a></li>
<li><a href="al2023-kvm-2023.10.20260715.0-kernel-6.12-x86_64.xfs.gpt.qcow2">al2023-kvm-2023.10.20260715.0-kernel-6.12-x86_64.xfs.gpt.qcow2</a></li>
<li><a href="al2023-kvm-2023.10.20260715.0-kernel-6.12-x86_64.xfs.gpt.qcow2.sha256">al2023-kvm-...qcow2.sha256</a></li>
</ul></body></html>`

const al2023HypervListingFixture = `<html><body>
<a href="../">Parent Directory</a>
<a href="al2023-hyperv-2023.10.20260715.0-kernel-6.12-x86_64.xfs.gpt.vhdx.zip">image</a>
<a href="al2023-hyperv-2023.10.20260715.0-kernel-6.12-x86_64.xfs.gpt.vhdx.zip.sha256">checksum</a>
</body></html>`

const sha256sumsFixture = `d0d0d0d0000000000000000000000000000000000000000000000000000000ff *ubuntu-26.04.10-live-server-amd64.iso
aaaaaaaa000000000000000000000000000000000000000000000000000000ff *ubuntu-26.04.2-live-server-amd64.iso
` + "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef  resolute-server-cloudimg-amd64.img\n"

func TestPickLatestISOSortsNumericallyNotLexically(t *testing.T) {
	got, err := PickLatestISO(ubuntuReleaseIndexFixture, `ubuntu-[\d.]+-live-server-amd64\.iso`)
	if err != nil {
		t.Fatalf("PickLatestISO: %v", err)
	}
	// As strings "26.04.2" sorts above "26.04.10"; a lexical sort would pick the
	// older point release.
	if got != "ubuntu-26.04.10-live-server-amd64.iso" {
		t.Fatalf("PickLatestISO = %q, want ubuntu-26.04.10-live-server-amd64.iso", got)
	}
}

func TestPickLatestISOIsArchScoped(t *testing.T) {
	got, err := PickLatestISO(ubuntuReleaseIndexFixture, `ubuntu-[\d.]+-live-server-arm64\.iso`)
	if err != nil {
		t.Fatalf("PickLatestISO: %v", err)
	}
	if got != "ubuntu-26.04.10-live-server-arm64.iso" {
		t.Fatalf("PickLatestISO = %q, want the arm64 ISO", got)
	}
	if _, err := PickLatestISO("<html>nothing here</html>", `ubuntu-[\d.]+-live-server-amd64\.iso`); err == nil {
		t.Error("an index with no matching ISO must be an error, not an empty name")
	}
}

func TestFirstLinkWithSuffixDistinguishesArtifactFromChecksum(t *testing.T) {
	artifact := FirstLinkWithSuffix(al2023ListingFixture, ".qcow2")
	if artifact != "al2023-kvm-2023.10.20260715.0-kernel-6.12-x86_64.xfs.gpt.qcow2" {
		t.Fatalf("artifact link = %q", artifact)
	}
	sum := FirstLinkWithSuffix(al2023ListingFixture, ".qcow2.sha256")
	if !strings.HasSuffix(sum, ".qcow2.sha256") {
		t.Fatalf("checksum link = %q", sum)
	}
	if FirstLinkWithSuffix(al2023ListingFixture, ".zip") != "" {
		t.Error("a suffix that is not listed must resolve to nothing")
	}
}

func TestParseSHA256SUMSStripsBinaryMarker(t *testing.T) {
	got := ParseSHA256SUMS(sha256sumsFixture, "ubuntu-26.04.10-live-server-amd64.iso")
	if got != "d0d0d0d0000000000000000000000000000000000000000000000000000000ff" {
		t.Fatalf("ParseSHA256SUMS = %q", got)
	}
	got = ParseSHA256SUMS(sha256sumsFixture, "resolute-server-cloudimg-amd64.img")
	if got != "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" {
		t.Fatalf("ParseSHA256SUMS (two-space form) = %q", got)
	}
	if ParseSHA256SUMS(sha256sumsFixture, "not-listed.iso") != "" {
		t.Error("an unlisted filename must yield no hash, so the verdict can be 'unpublished'")
	}
}

func TestParseSHA256SidecarAcceptsBareAndNamedForms(t *testing.T) {
	const h = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
	if got := ParseSHA256Sidecar(h + "\n"); got != h {
		t.Fatalf("bare form = %q", got)
	}
	if got := ParseSHA256Sidecar(h + "  al2023-kvm.qcow2\n"); got != h {
		t.Fatalf("named form = %q", got)
	}
	if ParseSHA256Sidecar("not a hash at all\n") != "" {
		t.Error("a body with no 64-hex token must yield nothing")
	}
}

// rewriteTransport sends every request to a test server while preserving the
// original URL, so a resolver's real publisher URLs can be asserted verbatim.
type rewriteTransport struct {
	base    *url.URL
	seen    []string
	wrapped http.RoundTripper
}

func (rt *rewriteTransport) RoundTrip(r *http.Request) (*http.Response, error) {
	rt.seen = append(rt.seen, r.Method+" "+r.URL.String())
	clone := r.Clone(r.Context())
	clone.URL.Scheme = rt.base.Scheme
	clone.URL.Host = rt.base.Host
	clone.Host = ""
	return rt.wrapped.RoundTrip(clone)
}

func newFixtureResolver(t *testing.T, handler http.HandlerFunc) (*Resolver, *rewriteTransport) {
	t.Helper()
	srv := httptest.NewServer(handler)
	t.Cleanup(srv.Close)
	base, err := url.Parse(srv.URL)
	if err != nil {
		t.Fatal(err)
	}
	rt := &rewriteTransport{base: base, wrapped: http.DefaultTransport}
	return NewResolver(&http.Client{Transport: rt}), rt
}

func TestResolveUbuntuISOStableUsesReleasesForAmd64(t *testing.T) {
	r, rt := newFixtureResolver(t, func(w http.ResponseWriter, req *http.Request) {
		_, _ = w.Write([]byte(ubuntuReleaseIndexFixture))
	})
	got, err := r.Resolve(context.Background(), ImageID{
		HostType: HostTypeKVM, ImageKey: KeyUbuntuServer26, Arch: ArchAMD64, Variant: VariantStable})
	if err != nil {
		t.Fatalf("Resolve: %v", err)
	}
	if want := "GET https://releases.ubuntu.com/resolute/"; rt.seen[0] != want {
		t.Fatalf("first request = %q, want %q", rt.seen[0], want)
	}
	if got.SourceURL != "https://releases.ubuntu.com/resolute/ubuntu-26.04.10-live-server-amd64.iso" {
		t.Fatalf("SourceURL = %q", got.SourceURL)
	}
	if got.ChecksumURL != "https://releases.ubuntu.com/resolute/SHA256SUMS" || got.ChecksumFormat != ChecksumSHA256SUMS {
		t.Fatalf("checksum = %q (%s)", got.ChecksumURL, got.ChecksumFormat)
	}
	if got.Variant != VariantStable {
		t.Fatalf("Variant = %q, want stable", got.Variant)
	}
}

func TestResolveUbuntuISOStableUsesCdimageForArm64(t *testing.T) {
	r, rt := newFixtureResolver(t, func(w http.ResponseWriter, req *http.Request) {
		_, _ = w.Write([]byte(ubuntuReleaseIndexFixture))
	})
	got, err := r.Resolve(context.Background(), ImageID{
		HostType: HostTypeUTM, ImageKey: KeyUbuntuServer24, Arch: ArchARM64, Variant: VariantStable})
	if err != nil {
		t.Fatalf("Resolve: %v", err)
	}
	if want := "GET https://cdimage.ubuntu.com/releases/noble/release/"; rt.seen[0] != want {
		t.Fatalf("first request = %q, want %q", rt.seen[0], want)
	}
	if got.UpstreamFilename != "ubuntu-26.04.10-live-server-arm64.iso" {
		t.Fatalf("UpstreamFilename = %q", got.UpstreamFilename)
	}
}

func TestResolveUbuntuISODailyHeadProbesTheCodenamePinnedPath(t *testing.T) {
	r, rt := newFixtureResolver(t, func(w http.ResponseWriter, req *http.Request) {
		if req.Method == http.MethodHead {
			w.WriteHeader(http.StatusOK)
			return
		}
		_, _ = w.Write([]byte(ubuntuReleaseIndexFixture))
	})
	got, err := r.Resolve(context.Background(), ImageID{
		HostType: HostTypeKVM, ImageKey: KeyUbuntuServer26, Arch: ArchAMD64, Variant: VariantDaily})
	if err != nil {
		t.Fatalf("Resolve: %v", err)
	}
	want := "HEAD https://cdimage.ubuntu.com/ubuntu-server/resolute/daily-live/current/resolute-live-server-amd64.iso"
	if rt.seen[0] != want {
		t.Fatalf("first request = %q, want %q", rt.seen[0], want)
	}
	if got.Variant != VariantDaily || got.UpstreamFilename != "resolute-live-server-amd64.iso" {
		t.Fatalf("resolved = %+v", got)
	}
}

func TestResolveUbuntuISOFallsBackWhenThePreferenceFails(t *testing.T) {
	r, _ := newFixtureResolver(t, func(w http.ResponseWriter, req *http.Request) {
		if req.Method == http.MethodHead {
			w.WriteHeader(http.StatusNotFound)
			return
		}
		_, _ = w.Write([]byte(ubuntuReleaseIndexFixture))
	})
	got, err := r.Resolve(context.Background(), ImageID{
		HostType: HostTypeKVM, ImageKey: KeyUbuntuServer26, Arch: ArchAMD64, Variant: VariantDaily})
	if err != nil {
		t.Fatalf("Resolve: %v", err)
	}
	if got.Variant != VariantStable {
		t.Fatalf("a failed daily probe must fall back to stable; got variant %q", got.Variant)
	}
}

func TestResolveExtensionCloudImageIsAFixedURL(t *testing.T) {
	r, _ := newFixtureResolver(t, func(w http.ResponseWriter, req *http.Request) { w.WriteHeader(http.StatusOK) })
	got, err := r.Resolve(context.Background(), ImageID{
		HostType: HostTypeHyperV, ImageKey: KeyUbuntuExtension, Arch: ArchAMD64, Variant: VariantStable})
	if err != nil {
		t.Fatalf("Resolve: %v", err)
	}
	if got.SourceURL != "https://cloud-images.ubuntu.com/resolute/current/resolute-server-cloudimg-amd64.img" {
		t.Fatalf("SourceURL = %q", got.SourceURL)
	}
	if got.ChecksumURL != "https://cloud-images.ubuntu.com/resolute/current/SHA256SUMS" {
		t.Fatalf("ChecksumURL = %q", got.ChecksumURL)
	}
}

func TestResolveAmazonLinuxPicksArtifactAndSidecarPerPlatform(t *testing.T) {
	cases := []struct {
		id       ImageID
		listing  string
		wantPath string
		wantFile string
	}{
		{
			id:       ImageID{HostType: HostTypeKVM, ImageKey: KeyAmazonLinux2023, Arch: ArchAMD64, Variant: VariantStable},
			listing:  al2023ListingFixture,
			wantPath: "https://cdn.amazonlinux.com/al2023/os-images/latest/kvm/",
			wantFile: "al2023-kvm-2023.10.20260715.0-kernel-6.12-x86_64.xfs.gpt.qcow2",
		},
		{
			id:       ImageID{HostType: HostTypeUTM, ImageKey: KeyAmazonLinux2023, Arch: ArchARM64, Variant: VariantStable},
			listing:  al2023ListingFixture,
			wantPath: "https://cdn.amazonlinux.com/al2023/os-images/latest/kvm-arm64/",
			wantFile: "al2023-kvm-2023.10.20260715.0-kernel-6.12-x86_64.xfs.gpt.qcow2",
		},
		{
			id:       ImageID{HostType: HostTypeHyperV, ImageKey: KeyAmazonLinux2023, Arch: ArchAMD64, Variant: VariantStable},
			listing:  al2023HypervListingFixture,
			wantPath: "https://cdn.amazonlinux.com/al2023/os-images/latest/hyperv/",
			wantFile: "al2023-hyperv-2023.10.20260715.0-kernel-6.12-x86_64.xfs.gpt.vhdx.zip",
		},
	}
	for _, tc := range cases {
		listing := tc.listing
		r, rt := newFixtureResolver(t, func(w http.ResponseWriter, req *http.Request) {
			_, _ = w.Write([]byte(listing))
		})
		got, err := r.Resolve(context.Background(), tc.id)
		if err != nil {
			t.Fatalf("%s: Resolve: %v", tc.id, err)
		}
		if rt.seen[0] != "GET "+tc.wantPath {
			t.Errorf("%s: listing request = %q, want %q", tc.id, rt.seen[0], "GET "+tc.wantPath)
		}
		if got.SourceURL != tc.wantPath+tc.wantFile {
			t.Errorf("%s: SourceURL = %q, want %q", tc.id, got.SourceURL, tc.wantPath+tc.wantFile)
		}
		if got.ChecksumURL != tc.wantPath+tc.wantFile+".sha256" || got.ChecksumFormat != ChecksumSidecar {
			t.Errorf("%s: checksum = %q (%s)", tc.id, got.ChecksumURL, got.ChecksumFormat)
		}
	}
}

func TestSupportedRejectsUnknownKeysAndDailyForNonISOFamilies(t *testing.T) {
	if Supported(ImageID{HostType: HostTypeKVM, ImageKey: "guest.no.such.family", Arch: ArchAMD64, Variant: VariantStable}) {
		t.Error("a family with no resolver must not be reported as supported")
	}
	if Supported(ImageID{HostType: HostTypeKVM, ImageKey: KeyUbuntuExtension, Arch: ArchAMD64, Variant: VariantDaily}) {
		t.Error("only the Ubuntu ISO family has a daily preference")
	}
	if !Supported(ImageID{HostType: HostTypeKVM, ImageKey: KeyUbuntuServer26, Arch: ArchAMD64, Variant: VariantDaily}) {
		t.Error("the Ubuntu ISO family must accept the daily preference")
	}
}

func TestCodenameMapMatchesTheHostWrappers(t *testing.T) {
	for key, want := range map[string]string{
		KeyUbuntuServer24:  "noble",
		KeyUbuntuServer26:  "resolute",
		KeyUbuntuExtension: "resolute",
	} {
		got, ok := CodenameFor(key)
		if !ok || got != want {
			t.Errorf("CodenameFor(%q) = %q ok=%v, want %q", key, got, ok, want)
		}
	}
	if _, ok := CodenameFor(KeyAmazonLinux2023); ok {
		t.Error("a non-Ubuntu key must have no release codename")
	}
}
