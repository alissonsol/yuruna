// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package meta

import (
	"strings"

	"golang.org/x/text/cases"
	"golang.org/x/text/unicode/norm"
)

// ComparisonKey is a transient search/order key. Stored names and artifact IDs
// keep their original bytes; canonically equivalent names remain separate
// records. Case folding is locale-independent and accents remain significant.
func ComparisonKey(value string) string {
	return norm.NFC.String(cases.Fold().String(norm.NFC.String(value)))
}

func ContainsName(value, query string) bool {
	return strings.Contains(ComparisonKey(value), ComparisonKey(query))
}
