// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package hostinfo

import (
	"errors"
	"net"
	"testing"
)

func TestIPLinesFiltersAndGroupsLiveAddresses(t *testing.T) {
	interfaces := func() ([]net.Interface, error) {
		return []net.Interface{
			{Index: 1, Flags: net.FlagUp},
			{Index: 2, Flags: net.FlagUp},
			{Index: 3},
			{Index: 4, Flags: net.FlagUp | net.FlagLoopback},
			{Index: 5, Flags: net.FlagUp},
		}, nil
	}
	addresses := func(iface net.Interface) ([]net.Addr, error) {
		switch iface.Index {
		case 1:
			return []net.Addr{
				&net.IPNet{IP: net.ParseIP("192.0.2.2")},
				&net.IPAddr{IP: net.ParseIP("2001:db8::2")},
				&net.IPAddr{IP: net.ParseIP("127.0.0.1")},
				&net.IPAddr{IP: net.ParseIP("::1")},
				&net.IPAddr{IP: net.ParseIP("169.254.1.1")},
				&net.IPAddr{IP: net.ParseIP("fe80::1")},
				&net.IPAddr{IP: net.ParseIP("ff02::1")},
				&net.IPAddr{},
				&net.UnixAddr{Name: "irrelevant", Net: "unix"},
			}, nil
		case 2:
			return []net.Addr{
				&net.IPAddr{IP: net.ParseIP("192.0.2.1")},
				&net.IPAddr{IP: net.ParseIP("::ffff:192.0.2.2")},
				&net.IPNet{IP: net.ParseIP("2001:db8::1")},
				&net.IPAddr{IP: net.ParseIP("2001:db8::2")},
			}, nil
		case 5:
			return nil, errors.New("interface disappeared")
		default:
			t.Errorf("enumerated inactive/loopback interface %d", iface.Index)
			return nil, nil
		}
	}
	if got, want := ipLines(interfaces, addresses), "192.0.2.1,192.0.2.2\n2001:db8::1,2001:db8::2"; got != want {
		t.Fatalf("IP lines = %q, want %q", got, want)
	}
}

func TestIPLinesEnumerationFailureAndEmpty(t *testing.T) {
	for _, err := range []error{nil, errors.New("enumeration unavailable")} {
		got := ipLines(func() ([]net.Interface, error) { return nil, err }, func(net.Interface) ([]net.Addr, error) {
			t.Fatal("enumerated addresses without an interface")
			return nil, nil
		})
		if got != "" {
			t.Fatalf("empty/failed enumeration = %q", got)
		}
	}
}

func TestIPLinesReadsCurrentAddresses(t *testing.T) {
	interfaces := func() ([]net.Interface, error) { return []net.Interface{{Flags: net.FlagUp}}, nil }
	address := "192.0.2.1"
	addresses := func(net.Interface) ([]net.Addr, error) {
		return []net.Addr{&net.IPAddr{IP: net.ParseIP(address)}}, nil
	}
	if got := ipLines(interfaces, addresses); got != address {
		t.Fatalf("first address = %q", got)
	}
	address = "192.0.2.2"
	if got := ipLines(interfaces, addresses); got != address {
		t.Fatalf("changed address = %q", got)
	}
}

func TestCommaJoinUnique(t *testing.T) {
	cases := []struct {
		in   []string
		want string
	}{
		{nil, ""},
		{[]string{}, ""},
		{[]string{"10.0.0.2", "10.0.0.1", "10.0.0.2"}, "10.0.0.1,10.0.0.2"},
		{[]string{"192.168.7.15"}, "192.168.7.15"},
	}
	for _, c := range cases {
		if got := commaJoinUnique(c.in); got != c.want {
			t.Fatalf("commaJoinUnique(%v) = %q, want %q", c.in, got, c.want)
		}
	}
}
