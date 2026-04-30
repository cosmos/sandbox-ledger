package app

import (
	"testing"
	"time"

	cmtabcitypes "github.com/cometbft/cometbft/abci/types"
	"github.com/cosmos/cosmos-sdk/baseapp"
	dbm "github.com/cosmos/cosmos-db"
	gmptypes "github.com/cosmos/ibc-go/v11/modules/apps/27-gmp/types"
	ibctransfertypes "github.com/cosmos/ibc-go/v11/modules/apps/transfer/types"
	ibcexported "github.com/cosmos/ibc-go/v11/modules/core/exported"
	ibcattestations "github.com/cosmos/ibc-go/v11/modules/light-clients/attestations"
	ethcrypto "github.com/ethereum/go-ethereum/crypto"
	"github.com/stretchr/testify/require"

	"cosmossdk.io/log/v2"

	sdk "github.com/cosmos/cosmos-sdk/types"
	"github.com/cosmos/cosmos-sdk/types/module"
	simtestutil "github.com/cosmos/cosmos-sdk/testutil/sims"
)

const testChainID = "sandbox-test-1"

// newTestApp constructs a SandboxApp with an in-memory db. Returns just the
// app — use `initTestApp` if you need a context with initialized state.
func newTestApp(t *testing.T) *SandboxApp {
	t.Helper()
	return NewApp(
		log.NewNopLogger(),
		dbm.NewMemDB(),
		nil,
		true,
		simtestutil.NewAppOptionsWithFlagHome(t.TempDir()),
		baseapp.SetChainID(testChainID),
	)
}

// initTestApp returns an app whose state has been initialized. We construct
// with loadLatest=false so we can install a custom InitChainer (NewApp seals
// the base app once it's loaded). The custom InitChainer runs each module's
// InitGenesis directly instead of going through module.Manager.InitGenesis,
// which lets us skip the "validator set is empty after InitGenesis"
// assertion — POA validators are injected by bring-up scripts in
// production, not synthesized by DefaultGenesis.
func initTestApp(t *testing.T) (*SandboxApp, sdk.Context) {
	t.Helper()
	app := NewApp(
		log.NewNopLogger(),
		dbm.NewMemDB(),
		nil,
		false, // loadLatest = false — keeps the BaseApp unsealed so we can SetInitChainer below
		simtestutil.NewAppOptionsWithFlagHome(t.TempDir()),
		baseapp.SetChainID(testChainID),
	)

	app.SetInitChainer(func(ctx sdk.Context, _ *cmtabcitypes.RequestInitChain) (*cmtabcitypes.ResponseInitChain, error) {
		for _, name := range app.ModuleManager.OrderInitGenesis {
			m, ok := app.ModuleManager.Modules[name].(module.HasGenesis)
			if !ok {
				continue
			}
			m.InitGenesis(ctx, app.AppCodec(), m.DefaultGenesis(app.AppCodec()))
		}
		return &cmtabcitypes.ResponseInitChain{}, nil
	})

	require.NoError(t, app.LoadLatestVersion())
	_, err := app.InitChain(&cmtabcitypes.RequestInitChain{
		ChainId:         testChainID,
		ConsensusParams: simtestutil.DefaultConsensusParams,
	})
	require.NoError(t, err)

	ctx := app.NewContext(false).
		WithChainID(testChainID).
		WithBlockTime(time.Now()).
		WithBlockHeight(1)
	return app, ctx
}

func TestAppNewAndGenesis(t *testing.T) {
	app := newTestApp(t)

	require.NotNil(t, app.GMPKeeper, "GMPKeeper must be wired for IBC v2 GMP transfers")
	require.NotNil(t, app.IFTKeeper, "IFTKeeper must be wired to receive callbacks-v2")
	require.NotNil(t, app.TokenFactoryKeeper, "TokenFactoryKeeper must be wired")

	require.NotPanics(t, func() { app.DefaultGenesis() },
		"DefaultGenesis must not panic — guards module manager registration and genesis ordering")
}

func TestIBCv2Routes(t *testing.T) {
	app := newTestApp(t)

	routerV2 := app.IBCKeeper.ChannelKeeperV2.Router
	require.NotNil(t, routerV2)

	require.True(t, routerV2.HasRoute(ibctransfertypes.ModuleName),
		"transfer v2 route must be registered for IBC v2 fungible transfers")
	require.True(t, routerV2.HasRoute(gmptypes.PortID),
		"gmp v2 route must be registered for IBC v2 general message passing")
}

// TestAttestations_CreateClient creates a real attestations client through
// the full IBCKeeper.ClientKeeper.CreateClient path. Indirectly verifies:
//   - the attestations LightClientModule is registered as a client route,
//   - "attestations" is in the IBC `allowed_clients` params list,
//   - the module's Initialize() accepts a valid ClientState/ConsensusState.
func TestAttestations_CreateClient(t *testing.T) {
	app, ctx := initTestApp(t)

	// Generate a fresh attestor EOA. The address isn't verified at create
	// time, but Validate() requires hex format and uniqueness.
	priv, err := ethcrypto.GenerateKey()
	require.NoError(t, err)
	attestor := ethcrypto.PubkeyToAddress(priv.PublicKey).Hex()

	clientState := ibcattestations.NewClientState(
		[]string{attestor},
		1, // min required signatures
		1, // latest height
	)
	require.NoError(t, clientState.Validate())

	consensusState := &ibcattestations.ConsensusState{
		Timestamp: uint64(time.Now().UnixNano()),
	}

	clientID, err := app.IBCKeeper.ClientKeeper.CreateClient(
		ctx, ibcexported.Attestations,
		app.AppCodec().MustMarshal(clientState),
		app.AppCodec().MustMarshal(consensusState),
	)
	require.NoError(t, err)
	require.Contains(t, clientID, "attestations-",
		"created client ID must use the `attestations-N` format")

	// Round-trip: reading the route by client ID should succeed.
	route, err := app.IBCKeeper.ClientKeeper.Route(ctx, clientID)
	require.NoError(t, err)
	require.NotNil(t, route)
}

// TestAttestations_TendermintRejected confirms that 07-tendermint clients
// are no longer creatable on this chain — the attestations module replaced
// it as the supported counterparty light-client type.
func TestAttestations_TendermintRejected(t *testing.T) {
	app, ctx := initTestApp(t)

	// Even an empty/invalid byte payload should be rejected at the route
	// lookup stage with ErrRouteNotFound, before any unmarshal is attempted.
	_, err := app.IBCKeeper.ClientKeeper.CreateClient(
		ctx, ibcexported.Tendermint,
		[]byte{}, []byte{},
	)
	require.Error(t, err, "07-tendermint should not be a registered client type on this chain")
}

// TestAttestations_ClientStateValidation rejects malformed ClientStates at
// the light-client layer. Pure unit tests on the module's own checks; no
// app context required.
func TestAttestations_ClientStateValidation(t *testing.T) {
	cases := []struct {
		name        string
		state       *ibcattestations.ClientState
		expectError string
	}{
		{
			name:        "empty attestor set",
			state:       ibcattestations.NewClientState(nil, 1, 1),
			expectError: "attestor addresses cannot be empty",
		},
		{
			name:        "zero min signatures",
			state:       ibcattestations.NewClientState([]string{"0x0000000000000000000000000000000000000001"}, 0, 1),
			expectError: "min required sigs cannot be 0",
		},
		{
			name: "min signatures exceeds attestor count",
			state: ibcattestations.NewClientState(
				[]string{"0x0000000000000000000000000000000000000001"}, 2, 1,
			),
			expectError: "min required sigs cannot exceed number of attestors",
		},
		{
			name: "non-hex attestor address",
			state: ibcattestations.NewClientState(
				[]string{"not-a-hex-address"}, 1, 1,
			),
			expectError: "invalid attestor address format",
		},
		{
			name: "duplicate attestor address",
			state: ibcattestations.NewClientState(
				[]string{
					"0x0000000000000000000000000000000000000001",
					"0x0000000000000000000000000000000000000001",
				}, 1, 1,
			),
			expectError: "duplicate attestor address",
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			err := tc.state.Validate()
			require.Error(t, err)
			require.Contains(t, err.Error(), tc.expectError)
		})
	}
}
