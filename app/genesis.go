package app

import (
	"encoding/json"

	evmtypes "github.com/cosmos/evm/x/vm/types"
)

// GenesisState defines the genesis state of the application.
type GenesisState map[string]json.RawMessage

// ActivePrecompiles returns the precompile addresses that are active on this
// chain. Staking, distribution, slashing, vesting, and ICS20 precompiles are
// excluded because their backing modules are not included.
var ActivePrecompiles = []string{
	evmtypes.P256PrecompileAddress,
	evmtypes.Bech32PrecompileAddress,
	evmtypes.BankPrecompileAddress,
	evmtypes.GovPrecompileAddress,
	evmtypes.ICS02PrecompileAddress,
}

// NewEVMGenesisState returns the default EVM genesis with only the precompiles
// supported by this chain enabled.
func NewEVMGenesisState() *evmtypes.GenesisState {
	gen := evmtypes.DefaultGenesisState()
	gen.Params.ActiveStaticPrecompiles = ActivePrecompiles
	gen.Preinstalls = evmtypes.DefaultPreinstalls
	return gen
}
