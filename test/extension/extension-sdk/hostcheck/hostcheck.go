// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
// GUID: 42206907-a87e-40b9-b67d-97120249115e

// Package hostcheck refuses a request whose Host header names a host the
// service does not answer to. A page on another site can make its own name
// resolve to the service's address (DNS rebinding); the browser then treats
// the service as that site, so the cross-origin check passes the page's
// requests, and only the name they carry tells them apart.
//
// Every IP-literal Host is served: a rebound request always names the other
// site, and a service is also reached at addresses it cannot know, such as a
// port forward on the machine that hosts its VM. So are localhost, the
// machine's own host name and its first label, and the names an operator
// configured. Anything else is answered 421 Misdirected Request before the
// wrapped handler runs.
package hostcheck

import (
	"encoding/json"
	"net"
	"net/http"
	"net/netip"
	"os"
	"strings"
	"sync"

	"yuruna.com/test/extension/extension-sdk/i18n"
	"yuruna.com/test/extension/extension-sdk/internal/catalog"
)

const (
	// refusalCode is the catalog key of the 421 answer.
	refusalCode = "auth.host_not_served"
	// settingName is the configuration key the refusal tells an operator to
	// add a name to; the names reach the service through its VM's seed.
	settingName = "vmStart.serviceHostNames"
)

// Options configures a Check.
type Options struct {
	// Language and AllowPseudoLocale use the same authority as the service pages.
	Language          string
	AllowPseudoLocale bool

	// Names are the names the service answers to besides its addresses, its
	// host name and localhost: the ones hosts and browsers reach it by. Each is
	// compared the way ParseNames normalizes it.
	Names []string

	// hostname replaces os.Hostname, so a test can name the machine.
	hostname func() (string, error)
}

// Check holds the names a service answers to.
type Check struct {
	locale *i18n.Negotiator
	names  map[string]bool
}

// New builds a Check. The machine's host name is read once, here.
func New(opts Options) *Check {
	names := map[string]bool{"localhost": true}
	for _, name := range opts.Names {
		if name = normalize(name); name != "" {
			names[name] = true
		}
	}
	hostname := opts.hostname
	if hostname == nil {
		hostname = os.Hostname
	}
	if own, err := hostname(); err == nil {
		if own = normalize(own); own != "" {
			names[own] = true
			if label, _, dotted := strings.Cut(own, "."); dotted && label != "" {
				names[label] = true
			}
		}
	}
	return &Check{
		locale: &i18n.Negotiator{Manifest: i18n.DefaultManifest(), Available: messages().Locales(), ConfigLanguage: opts.Language, AllowPseudo: opts.AllowPseudoLocale},
		names:  names,
	}
}

// Allowed reports whether host, a Host header value with or without a port,
// names this service. An empty value passes: no browser sends one.
func (c *Check) Allowed(host string) bool {
	name := normalize(host)
	if name == "" {
		return true
	}
	if _, err := netip.ParseAddr(name); err == nil {
		return true
	}
	return c.names[name]
}

// Handler refuses a request that names a host this service does not answer to
// and passes every other request to next. A loopback peer is not exempt, since
// a rebound name can resolve to 127.0.0.1 as well; but a loopback peer is also
// the reverse proxy on the service's own machine, which forwards the browser's
// Host and appends it to X-Forwarded-Host, so every name in that header is
// judged too. From any other peer that header is the client's own text and is
// not read.
func (c *Check) Handler(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if name, refused := c.refusedName(r); refused {
			c.refuse(w, r, name)
			return
		}
		next.ServeHTTP(w, r)
	})
}

func (c *Check) refusedName(r *http.Request) (string, bool) {
	if !c.Allowed(r.Host) {
		return r.Host, true
	}
	if fromLoopback(r) {
		for _, header := range r.Header.Values("X-Forwarded-Host") {
			for _, value := range strings.Split(header, ",") {
				if value = strings.TrimSpace(value); !c.Allowed(value) {
					return value, true
				}
			}
		}
	}
	return "", false
}

func (c *Check) refuse(w http.ResponseWriter, r *http.Request, name string) {
	locale := c.locale.Resolve(r)
	i18n.Apply(w.Header(), locale)
	text := messages().Render(refusalCode, map[string]any{"host": name, "setting": settingName}, locale.ResolvedTag)
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(http.StatusMisdirectedRequest)
	_ = json.NewEncoder(w).Encode(map[string]any{"ok": false, "error": text, "code": refusalCode})
}

// ParseNames splits a comma-separated list into names: each trimmed,
// lower-cased and stripped of a port and of one trailing dot, with empty
// entries left out.
func ParseNames(list string) []string {
	var names []string
	for _, entry := range strings.Split(list, ",") {
		if name := normalize(entry); name != "" {
			names = append(names, name)
		}
	}
	return names
}

// normalize reduces a Host value to the name it carries: no port, no brackets
// around an IPv6 literal, lower case, and no trailing dot (an absolute name is
// the same host).
func normalize(host string) string {
	host = strings.TrimSpace(host)
	if name, _, err := net.SplitHostPort(host); err == nil {
		host = name
	} else if strings.HasPrefix(host, "[") && strings.HasSuffix(host, "]") {
		host = host[1 : len(host)-1]
	}
	return strings.TrimSuffix(strings.ToLower(host), ".")
}

func fromLoopback(r *http.Request) bool {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		host = r.RemoteAddr
	}
	addr, err := netip.ParseAddr(host)
	return err == nil && addr.Unmap().IsLoopback()
}

var (
	messagesOnce    sync.Once
	messagesCatalog *i18n.Catalog
)

// messages is the SDK's compiled catalog, the one labgate's refusals render from.
func messages() *i18n.Catalog {
	messagesOnce.Do(func() {
		messagesCatalog = i18n.NewCatalog(nil)
		for tag, domains := range catalog.Catalogs {
			for domain, data := range domains {
				if err := messagesCatalog.Register(tag, domain, data); err != nil {
					panic(err)
				}
			}
		}
	})
	return messagesCatalog
}
