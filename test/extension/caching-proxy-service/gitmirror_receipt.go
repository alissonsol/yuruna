// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package main

import (
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"errors"
	"os"
)

type mirrorSigner struct {
	key   *rsa.PrivateKey
	keyID string
}

func loadMirrorSigner(path string) (*mirrorSigner, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, errors.New("signing-key-absent")
	}
	block, rest := pem.Decode(b)
	if block == nil || len(rest) != 0 {
		return nil, errors.New("signing-key-invalid")
	}
	var key *rsa.PrivateKey
	if block.Type == "RSA PRIVATE KEY" {
		key, err = x509.ParsePKCS1PrivateKey(block.Bytes)
	} else {
		var parsed any
		parsed, err = x509.ParsePKCS8PrivateKey(block.Bytes)
		if err == nil {
			key, _ = parsed.(*rsa.PrivateKey)
		}
	}
	if err != nil || key == nil || key.N.BitLen() < 3072 || key.Validate() != nil {
		return nil, errors.New("signing-key-invalid")
	}
	return newMirrorSigner(key), nil
}

func newMirrorSigner(key *rsa.PrivateKey) *mirrorSigner {
	der, _ := x509.MarshalPKIXPublicKey(&key.PublicKey)
	digest := sha256.Sum256(der)
	return &mirrorSigner{key: key, keyID: hex.EncodeToString(digest[:])}
}

func (s *mirrorSigner) sign(receipt mirrorReceipt) (mirrorEnvelope, error) {
	if s == nil {
		return mirrorEnvelope{}, errors.New("signing-key-absent")
	}
	receipt.SchemaVersion = mirrorAPIVersion
	receipt.KeyID = s.keyID
	payload, err := json.Marshal(receipt)
	if err != nil {
		return mirrorEnvelope{}, err
	}
	return s.signBytes(payload)
}

func (s *mirrorSigner) signBytes(payload []byte) (mirrorEnvelope, error) {
	digest := sha256.Sum256(payload)
	signature, err := rsa.SignPKCS1v15(rand.Reader, s.key, crypto.SHA256, digest[:])
	if err != nil {
		return mirrorEnvelope{}, err
	}
	return mirrorEnvelope{KeyID: s.keyID, Payload: base64.StdEncoding.EncodeToString(payload), Signature: base64.StdEncoding.EncodeToString(signature)}, nil
}
