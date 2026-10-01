// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package sshsrv

import (
	"bytes"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/pem"
	"errors"
	"os"
	"path/filepath"
	"syscall"
	"testing"

	"golang.org/x/crypto/ssh"
)

func TestExclusiveHostKeyWriteNeverReplacesExistingBytes(t *testing.T) {
	path := filepath.Join(t.TempDir(), "host_key")
	original := []byte("existing identity")
	if err := os.WriteFile(path, original, 0600); err != nil {
		t.Fatal(err)
	}
	if err := writeHostKeyExclusive(path, []byte("new identity")); err == nil {
		t.Fatal("existing key was replaced")
	}
	got, err := os.ReadFile(path)
	if err != nil || string(got) != string(original) {
		t.Fatalf("key changed: %q, %v", got, err)
	}
}

func seedHostKey(t *testing.T, path string) (ssh.Signer, []byte) {
	t.Helper()
	_, key, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	block, err := ssh.MarshalPrivateKey(key, "test host key")
	if err != nil {
		t.Fatal(err)
	}
	data := pem.EncodeToMemory(block)
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, data, 0o600); err != nil {
		t.Fatal(err)
	}
	signer, err := ssh.ParsePrivateKey(data)
	if err != nil {
		t.Fatal(err)
	}
	return signer, data
}

func TestHostKeyUncertainShare(t *testing.T) {
	for _, statErr := range []error{syscall.EACCES, syscall.EIO} {
		for _, primaryPresent := range []bool{false, true} {
			for _, localState := range []string{"valid", "absent", "corrupt"} {
				name := statErr.Error() + "/" + localState
				if primaryPresent {
					name += "/primary-present"
				}
				t.Run(name, func(t *testing.T) {
					tmp := t.TempDir()
					primary := filepath.Join(tmp, "share", "key")
					fallback := filepath.Join(tmp, "local", "key")
					var primaryKey, localKey []byte
					var localSigner ssh.Signer
					if primaryPresent {
						_, primaryKey = seedHostKey(t, primary)
					}
					switch localState {
					case "valid":
						localSigner, localKey = seedHostKey(t, fallback)
					case "corrupt":
						localKey = []byte("not a private key")
						if err := os.MkdirAll(filepath.Dir(fallback), 0o700); err != nil {
							t.Fatal(err)
						}
						if err := os.WriteFile(fallback, localKey, 0o600); err != nil {
							t.Fatal(err)
						}
					}
					signer, err := loadOrGenerateHostKeyWithStat(primary, fallback, func(path string) (os.FileInfo, error) {
						return nil, &os.PathError{Op: "stat", Path: path, Err: statErr}
					})
					if localState == "valid" {
						if err != nil {
							t.Fatalf("existing local identity must permit offline startup: %v", err)
						}
						if !bytes.Equal(signer.PublicKey().Marshal(), localSigner.PublicKey().Marshal()) {
							t.Fatal("offline startup selected a different identity")
						}
					} else if !errors.Is(err, statErr) {
						t.Fatalf("uncertain primary without usable fallback must retain stat error, got %v", err)
					}
					for path, want := range map[string][]byte{primary: primaryKey, fallback: localKey} {
						got, err := os.ReadFile(path)
						if want == nil {
							if !errors.Is(err, os.ErrNotExist) {
								t.Fatalf("unavailable share caused key creation at %s: %v", path, err)
							}
						} else if err != nil || !bytes.Equal(got, want) {
							t.Fatalf("unavailable share changed key at %s: %v", path, err)
						}
					}
				})
			}
		}
	}
}

func TestHostKeyPresentPrimaryWins(t *testing.T) {
	tmp := t.TempDir()
	primary := filepath.Join(tmp, "share", "key")
	fallback := filepath.Join(tmp, "local", "key")
	want, _ := seedHostKey(t, primary)
	_, localKey := seedHostKey(t, fallback)
	got, err := loadOrGenerateHostKey(primary, fallback)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(got.PublicKey().Marshal(), want.PublicKey().Marshal()) {
		t.Fatal("local fallback displaced the durable primary identity")
	}
	if data, err := os.ReadFile(fallback); err != nil || !bytes.Equal(data, localKey) {
		t.Fatalf("local key changed: %v", err)
	}
}

func TestHostKeyRejectsDirectory(t *testing.T) {
	for _, localState := range []string{"absent", "valid"} {
		t.Run(localState, func(t *testing.T) {
			tmp := t.TempDir()
			primary := filepath.Join(tmp, "share", "key")
			fallback := filepath.Join(tmp, "local", "key")
			if err := os.MkdirAll(primary, 0o700); err != nil {
				t.Fatal(err)
			}
			if localState == "valid" {
				seedHostKey(t, fallback)
			}
			if _, err := loadOrGenerateHostKey(primary, fallback); err == nil {
				t.Fatal("directory primary must fail without generating or selecting another key")
			}
			if info, err := os.Stat(primary); err != nil || !info.IsDir() {
				t.Fatalf("directory primary changed: %v", err)
			}
			if localState == "absent" {
				if _, err := os.Stat(fallback); !errors.Is(err, os.ErrNotExist) {
					t.Fatalf("directory primary caused local identity creation: %v", err)
				}
			}
		})
	}
}

func TestHostKeySymlinks(t *testing.T) {
	for _, targetState := range []string{"valid", "absent"} {
		for _, localState := range []string{"absent", "valid"} {
			t.Run(targetState+"/"+localState, func(t *testing.T) {
				tmp := t.TempDir()
				primary := filepath.Join(tmp, "key-link")
				target := filepath.Join(tmp, "target")
				fallback := filepath.Join(tmp, "local", "key")
				var want ssh.Signer
				if targetState == "valid" {
					want, _ = seedHostKey(t, target)
				}
				if localState == "valid" {
					seedHostKey(t, fallback)
				}
				if err := os.Symlink(target, primary); err != nil {
					t.Skipf("symlink unavailable: %v", err)
				}
				got, err := loadOrGenerateHostKey(primary, fallback)
				if targetState == "valid" {
					if err != nil {
						t.Fatal(err)
					}
					if !bytes.Equal(got.PublicKey().Marshal(), want.PublicKey().Marshal()) {
						t.Fatal("valid symlink did not retain its target's identity")
					}
				} else {
					if err == nil {
						t.Fatal("dangling primary link must fail closed")
					}
					if _, err := os.Stat(target); !errors.Is(err, os.ErrNotExist) {
						t.Fatalf("dangling link's target was created: %v", err)
					}
				}
				if got, err := os.Readlink(primary); err != nil || got != target {
					t.Fatalf("primary symlink was changed: %v", err)
				}
				if localState == "absent" {
					if _, err := os.Stat(fallback); !errors.Is(err, os.ErrNotExist) {
						t.Fatalf("symlink primary caused local key creation: %v", err)
					}
				}
			})
		}
	}
}

func TestHostKeyConcurrentPublication(t *testing.T) {
	for _, localState := range []string{"absent", "valid"} {
		t.Run(localState, func(t *testing.T) {
			tmp := t.TempDir()
			primary := filepath.Join(tmp, "share", "key")
			type result struct {
				signer ssh.Signer
				err    error
			}
			const workers = 16
			results := make(chan result, workers)
			start := make(chan struct{})
			locals := make(map[string][]byte)
			for range workers {
				fallback := filepath.Join(t.TempDir(), "local", "key")
				var key []byte
				if localState == "valid" {
					_, key = seedHostKey(t, fallback)
				}
				locals[fallback] = key
				go func() {
					<-start
					signer, err := loadOrGenerateHostKey(primary, fallback)
					results <- result{signer, err}
				}()
			}
			close(start)
			var signers []ssh.Signer
			for range workers {
				r := <-results
				// A reader can see an incompletely published key and fail closed;
				// every successful startup must agree with the durable winner.
				if r.err == nil {
					signers = append(signers, r.signer)
				}
			}
			if len(signers) == 0 {
				t.Fatal("no startup published a usable key")
			}
			data, err := os.ReadFile(primary)
			if err != nil {
				t.Fatal(err)
			}
			winner, err := ssh.ParsePrivateKey(data)
			if err != nil {
				t.Fatal(err)
			}
			for _, signer := range signers {
				if !bytes.Equal(signer.PublicKey().Marshal(), winner.PublicKey().Marshal()) {
					t.Fatal("concurrent startup disagrees with the durable identity")
				}
			}
			for path, want := range locals {
				got, err := os.ReadFile(path)
				if want == nil {
					if !errors.Is(err, os.ErrNotExist) {
						t.Fatalf("concurrent publication created a local identity: %v", err)
					}
				} else if err != nil || !bytes.Equal(got, want) {
					t.Fatalf("concurrent publication changed a local identity: %v", err)
				}
			}
		})
	}
}

func TestHostKeyPromotionUsesPublishedWinner(t *testing.T) {
	for _, winnerState := range []string{"valid", "corrupt", "directory", "dangling"} {
		t.Run(winnerState, func(t *testing.T) {
			tmp := t.TempDir()
			primary := filepath.Join(tmp, "primary")
			fallback := filepath.Join(tmp, "local", "key")
			_, localKey := seedHostKey(t, fallback)
			var want ssh.Signer
			var primaryKey []byte
			switch winnerState {
			case "valid":
				want, primaryKey = seedHostKey(t, primary)
			case "corrupt":
				primaryKey = []byte("unusable published key")
				if err := os.WriteFile(primary, primaryKey, 0o600); err != nil {
					t.Fatal(err)
				}
			case "directory":
				if err := os.Mkdir(primary, 0o700); err != nil {
					t.Fatal(err)
				}
			case "dangling":
				if err := os.Symlink(filepath.Join(tmp, "missing"), primary); err != nil {
					t.Skipf("symlink unavailable: %v", err)
				}
			}
			got, err := promoteHostKey(primary, localKey)
			if winnerState == "valid" {
				if err != nil || got == nil {
					t.Fatalf("promotion did not return published winner: %v", err)
				}
				if !bytes.Equal(got.PublicKey().Marshal(), want.PublicKey().Marshal()) {
					t.Fatal("promotion selected the local identity over the published winner")
				}
			} else if err == nil {
				t.Fatal("unusable published identity must fail closed")
			}
			if primaryKey != nil {
				if got, err := os.ReadFile(primary); err != nil || !bytes.Equal(got, primaryKey) {
					t.Fatalf("published winner was overwritten: %v", err)
				}
			}
			if got, err := os.ReadFile(fallback); err != nil || !bytes.Equal(got, localKey) {
				t.Fatalf("local identity was changed: %v", err)
			}
		})
	}
}

func TestHostKeyFollowsConcurrentlyPublishedSymlink(t *testing.T) {
	tmp := t.TempDir()
	primary := filepath.Join(tmp, "primary")
	target := filepath.Join(tmp, "target")
	fallback := filepath.Join(tmp, "local", "key")
	want, _ := seedHostKey(t, target)
	got, err := loadOrGenerateHostKeyWithStat(primary, fallback, func(path string) (os.FileInfo, error) {
		if err := os.Symlink(target, path); err != nil {
			t.Skipf("symlink unavailable: %v", err)
		}
		return nil, &os.PathError{Op: "stat", Path: path, Err: os.ErrNotExist}
	})
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(got.PublicKey().Marshal(), want.PublicKey().Marshal()) {
		t.Fatal("concurrently published symlink did not retain its target identity")
	}
}

func TestHostKeyRejectsDevice(t *testing.T) {
	fi, err := os.Stat(os.DevNull)
	if err != nil || fi.Mode().IsRegular() {
		t.Skip("platform does not expose a nonregular null device")
	}
	fallback := filepath.Join(t.TempDir(), "local", "key")
	if _, err := loadOrGenerateHostKey(os.DevNull, fallback); err == nil {
		t.Fatal("nonregular device must not be opened as a host key")
	}
	if _, err := os.Stat(fallback); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("nonregular primary caused local identity creation: %v", err)
	}
}
