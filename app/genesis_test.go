package app

import (
	"slices"
	"testing"

	evmtypes "github.com/cosmos/evm/x/vm/types"
)

// The chain deliberately omits the staking, distribution, slashing,
// vesting, and ICS20 precompiles because their backing modules aren't
// included (POA replaces staking; the others have no module). If any of
// those were activated, txs touching them would compile-call a missing
// keeper at runtime — silent, hard-to-debug failures. Pin the negative
// invariant here so a future evm.evmd upgrade that adds a default
// precompile doesn't sneak past.
func TestActivePrecompiles_Inclusions(t *testing.T) {
	want := []string{
		evmtypes.P256PrecompileAddress,
		evmtypes.Bech32PrecompileAddress,
		evmtypes.BankPrecompileAddress,
		evmtypes.GovPrecompileAddress,
		evmtypes.ICS02PrecompileAddress,
	}
	for _, addr := range want {
		if !slices.Contains(ActivePrecompiles, addr) {
			t.Errorf("ActivePrecompiles missing %s", addr)
		}
	}
}

func TestActivePrecompiles_Exclusions(t *testing.T) {
	excluded := map[string]string{
		evmtypes.StakingPrecompileAddress:      "Staking (POA replaces staking)",
		evmtypes.DistributionPrecompileAddress: "Distribution (no module)",
		evmtypes.SlashingPrecompileAddress:     "Slashing (no module)",
		evmtypes.VestingPrecompileAddress:      "Vesting (no module)",
		evmtypes.ICS20PrecompileAddress:        "ICS20 (no module)",
	}
	for addr, why := range excluded {
		if slices.Contains(ActivePrecompiles, addr) {
			t.Errorf("ActivePrecompiles unexpectedly contains %s (%s)", addr, why)
		}
	}
}

func TestNewEVMGenesisState_AppliesActivePrecompiles(t *testing.T) {
	gen := NewEVMGenesisState()
	if gen == nil {
		t.Fatal("NewEVMGenesisState returned nil")
	}
	got := gen.Params.ActiveStaticPrecompiles
	if len(got) != len(ActivePrecompiles) {
		t.Fatalf("got %d active precompiles, want %d", len(got), len(ActivePrecompiles))
	}
	for _, want := range ActivePrecompiles {
		if !slices.Contains(got, want) {
			t.Errorf("genesis ActiveStaticPrecompiles missing %s", want)
		}
	}
}

func TestNewEVMGenesisState_PreinstallsCarriedThrough(t *testing.T) {
	// Preinstalls (deterministic deployments like Create2 deployer) come
	// from the upstream evm package. Our wrapper must not drop them.
	gen := NewEVMGenesisState()
	if len(gen.Preinstalls) == 0 {
		t.Fatal("expected non-empty Preinstalls; the wrapper dropped them")
	}
	if len(gen.Preinstalls) != len(evmtypes.DefaultPreinstalls) {
		t.Errorf("Preinstalls count = %d, want %d", len(gen.Preinstalls), len(evmtypes.DefaultPreinstalls))
	}
}
