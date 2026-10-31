// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
// GUID: 42f4f83d-f405-4484-a76b-becb20a96b1f

package poolstate

// The identity aliases map a retired hostId to the hostId that replaced it, so
// a host handed over to a new identity keeps its history: retired ids project
// onto the live one, and a retired id never regains a live row.

// CanonicalHostID follows the aliases from id to the identity that replaced it
// last; an id never retired is its own. The walk is bounded by the number of
// aliases, so a cycle in an unvalidated map cannot loop forever.
func (v *View) CanonicalHostID(id string) string {
	for i := 0; i < len(v.aliases); i++ {
		next := v.aliases[id]
		if next == "" {
			break
		}
		id = next
	}
	return id
}

// ReplacedBy is the identity id was handed over to, or "" when id is not
// retired.
func (v *View) ReplacedBy(id string) string { return v.aliases[id] }

// RetiredIDs returns the retired ids whose aliases lead to canonical, in no
// particular order; empty, not nil, when there are none.
func (v *View) RetiredIDs(canonical string) []string {
	ids := make([]string, 0)
	for old := range v.aliases {
		if v.CanonicalHostID(old) == canonical {
			ids = append(ids, old)
		}
	}
	return ids
}

// Aliases returns a copy of the aliases, retired id -> the id that replaced it.
func (v *View) Aliases() map[string]string {
	out := make(map[string]string, len(v.aliases))
	for old, next := range v.aliases {
		out[old] = next
	}
	return out
}

// SetAliases replaces the aliases with a map the caller no longer changes.
func (v *View) SetAliases(aliases map[string]string) { v.aliases = aliases }
