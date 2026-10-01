// LICENSEURI https://yuruna.link/license
// Copyright (c) 2026 by Alisson Sol et al.

package jsonbody

import (
	"errors"
	"strings"
	"testing"
)

func TestBoundaries(t *testing.T) {
	for _, c := range []struct {
		body  string
		limit int64
		empty bool
		want  error
	}{
		{"{}", 2, false, nil}, {"{} ", 2, false, ErrOversize}, {"{} junk", 20, false, ErrTrailing}, {"{} {}", 20, false, ErrTrailing}, {"", 20, true, nil}, {"  ", 20, true, nil}, {"", 20, false, ErrMalformed}, {"[]", 20, false, ErrMalformed}, {"{", 20, false, ErrMalformed},
	} {
		var dst struct{}
		err := Decode(strings.NewReader(c.body), &dst, c.limit, c.empty)
		if !errors.Is(err, c.want) {
			t.Errorf("%q: %v want %v", c.body, err, c.want)
		}
	}
}
