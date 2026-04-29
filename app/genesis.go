package app

import (
	"encoding/json"

	evmtypes "github.com/cosmos/evm/x/vm/types"

	"github.com/cosmos/cosmos-sdk/codec"
	"github.com/cosmos/cosmos-sdk/types/module"
	"github.com/cosmos/cosmos-sdk/x/bank"
	banktypes "github.com/cosmos/cosmos-sdk/x/bank/types"
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

// EVMBankDenomMetadata returns bank denom metadata for the EVM coin.
//
// The EVM module's InitGenesis calls bank.GetDenomMetaData(EvmDenom) and panics
// if it isn't present. Cosmos-SDK's default bank genesis ships with an empty
// metadata list, so we inject an entry here to make `sandboxd init && start`
// boot without external genesis patching.
//
// Two denom units are required: bank validation requires the *base* unit to
// have exponent 0, while cosmos/evm derives decimals from the unit whose
// denom equals Display. Display is intentionally distinct from base so that
// LoadEvmCoinInfo computes decimals=18 (and treats EvmDenom as the extended
// 18-decimal denom).
func EVMBankDenomMetadata(evmDenom string) banktypes.Metadata {
	displayDenom := evmDenom + "-display"
	return banktypes.Metadata{
		Description: "Native 18-decimal denom metadata for the sandbox EVM chain",
		Base:        evmDenom,
		Display:     displayDenom,
		Name:        "Sandbox",
		Symbol:      "SBX",
		DenomUnits: []*banktypes.DenomUnit{
			{Denom: evmDenom, Exponent: 0},
			{Denom: displayDenom, Exponent: 18},
		},
	}
}

// bankBasicWithEVMDenomMetadata wraps the bank AppModuleBasic so that
// `sandboxd init` writes a genesis whose bank.denom_metadata already contains
// the EVM denom entry. The cosmos-sdk init command calls
// BasicManager.DefaultGenesis(), not App.DefaultGenesis(), so the metadata
// injection has to live at the BasicManager layer.
type bankBasicWithEVMDenomMetadata struct {
	bank.AppModuleBasic
}

// NewBankBasicWithEVMDenomMetadata returns a bank AppModuleBasic that
// appends EVMBankDenomMetadata to the default bank genesis state.
func NewBankBasicWithEVMDenomMetadata() module.AppModuleBasic {
	return bankBasicWithEVMDenomMetadata{}
}

// DefaultGenesis appends the EVM denom metadata to the bank module's default
// genesis. Uses the EVM module's default EvmDenom so the two stay consistent.
func (b bankBasicWithEVMDenomMetadata) DefaultGenesis(cdc codec.JSONCodec) json.RawMessage {
	raw := b.AppModuleBasic.DefaultGenesis(cdc)
	var gs banktypes.GenesisState
	cdc.MustUnmarshalJSON(raw, &gs)
	gs.DenomMetadata = append(gs.DenomMetadata, EVMBankDenomMetadata(evmtypes.DefaultParams().EvmDenom))
	return cdc.MustMarshalJSON(&gs)
}
