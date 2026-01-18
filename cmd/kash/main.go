package main

import (
	"crypto/sha256"
	"encoding/gob"
	"encoding/hex"
	"fmt"
	"os"
	"strings"

	"github.com/int128/kubelogin/pkg/oidc"
	"github.com/int128/kubelogin/pkg/tlsclientconfig"
	"github.com/int128/kubelogin/pkg/tokencache"
)

func computeChecksum(key tokencache.Key) (string, error) {
	s := sha256.New()
	e := gob.NewEncoder(s)
	if err := e.Encode(&key); err != nil {
		return "", fmt.Errorf("could not encode the key: %w", err)
	}
	h := hex.EncodeToString(s.Sum(nil))
	return h, nil
}

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintf(os.Stderr, "usage: kash <command>\n")
		os.Exit(1)
	}

	switch os.Args[1] {
	case "kubelogin":
		kubelogin()
	default:
		fmt.Fprintf(os.Stderr, "unknown command: %s\n", os.Args[1])
		os.Exit(1)
	}
}

func kubelogin() {
	key := tokencache.Key{
		Provider: oidc.Provider{
			IssuerURL:      os.Getenv("OIDC_ISS"),
			ClientID:       os.Getenv("OIDC_AZP"),
			ClientSecret:   "",
			ExtraScopes:    strings.Split(os.Getenv("OIDC_SCP"), ","),
			UseAccessToken: true,
		},
		TLSClientConfig: tlsclientconfig.Config{},
		Username:        "",
	}

	hash, err := computeChecksum(key)
	if err != nil {
		fmt.Fprintf(os.Stderr, "error: %v\n", err)
		os.Exit(1)
	}
	fmt.Print(hash)
}
