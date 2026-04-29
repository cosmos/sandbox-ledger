package testutil

import (
	"sync"

	sdk "github.com/cosmos/cosmos-sdk/types"
	"github.com/cosmos/evm/crypto/hd"
	evmconfig "github.com/cosmos/evm/evmd/config"
)

var once sync.Once

// SafeSetAddressPrefixes configures the SDK config bech32 prefixes for tests
// using the same EVM-aware setup as cmd/sandboxd/main.go.
//
// Wrapped in sync.Once because sdk.Config is a process-global singleton that
// panics on Seal() if called twice — so multiple test packages running in the
// same binary must share a single initialization.
func SafeSetAddressPrefixes() {
	once.Do(func() {
		cfg := sdk.GetConfig()
		evmconfig.SetBech32Prefixes(cfg)
		cfg.SetCoinType(hd.Bip44CoinType)
		cfg.SetPurpose(sdk.Purpose)
		cfg.SetFullFundraiserPath(hd.BIP44HDPath) //nolint:staticcheck
		cfg.Seal()
	})
}
