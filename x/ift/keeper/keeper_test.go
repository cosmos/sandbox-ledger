package keeper_test

import (
	"fmt"
	"testing"
	"time"

	dbm "github.com/cosmos/cosmos-db"
	"github.com/cosmos/sandbox-ledger/app"
	"github.com/cosmos/sandbox-ledger/testutil"
	ifttypes "github.com/cosmos/sandbox-ledger/x/ift/types"
	"github.com/stretchr/testify/require"

	"cosmossdk.io/collections"
	"cosmossdk.io/log/v2"
	"cosmossdk.io/math"

	"github.com/cosmos/cosmos-sdk/baseapp"
	"github.com/cosmos/cosmos-sdk/runtime"
	simtestutil "github.com/cosmos/cosmos-sdk/testutil/sims"
	sdk "github.com/cosmos/cosmos-sdk/types"
	"github.com/cosmos/cosmos-sdk/types/module"
	authtypes "github.com/cosmos/cosmos-sdk/x/auth/types"
	consensusparamkeeper "github.com/cosmos/cosmos-sdk/x/consensus/keeper"
	consensusparamtypes "github.com/cosmos/cosmos-sdk/x/consensus/types"
	govtypes "github.com/cosmos/cosmos-sdk/x/gov/types"

	cmtabcitypes "github.com/cometbft/cometbft/abci/types"
	cmtproto "github.com/cometbft/cometbft/proto/tendermint/types"
	cmttypes "github.com/cometbft/cometbft/types"

	clienttypes "github.com/cosmos/ibc-go/v11/modules/core/02-client/types"
	clientv2types "github.com/cosmos/ibc-go/v11/modules/core/02-client/v2/types"
	commitmenttypes "github.com/cosmos/ibc-go/v11/modules/core/23-commitment/types"
	ibcexported "github.com/cosmos/ibc-go/v11/modules/core/exported"
	ibctm "github.com/cosmos/ibc-go/v11/modules/light-clients/07-tendermint"
	ibctesting "github.com/cosmos/ibc-go/v11/testing"
)

const (
	// Test addresses
	adminAddr   = "cosmos1nsh9vj9znccakn6xwlhlwx92acdt79yeqrkz4y"
	userAddrA   = "cosmos1uu635yk0hz3cvrypnryrggltrjq7975jrmeg97"
	userAddrB   = "cosmos1y6xz2ggfc0pcsmyjlekh0j9pxh6hk87yfwcjct"
	invalidAddr = "invalid"

	// Test denoms
	testDenom  = "testtoken"
	testDenom2 = "testtoken2"

	// Remote contract addresses (EVM)
	remoteIFTAddrA = "0x1111111111111111111111111111111111111111"
	remoteIFTAddrB = "0x2222222222222222222222222222222222222222"

	// Remote Solana addresses (valid base58 encoded 32-byte public keys)
	solanaIFTProgramID = "BPFLoaderUpgradeab1e11111111111111111111111"
	solanaGMPProgramID = "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA"
	solanaMintPubkey   = "So11111111111111111111111111111111111111112"
	solanaReceiverAddr = "11111111111111111111111111111111"
)

func setupIntegrationApp(tb testing.TB) (*app.SandboxApp, sdk.Context) {
	tb.Helper()
	testutil.SafeSetAddressPrefixes()

	db := dbm.NewMemDB()
	wfapp := app.NewApp(log.NewNopLogger(), db, nil, false, simtestutil.NewAppOptionsWithFlagHome(tb.TempDir()), baseapp.SetChainID("wf-chain-id"))
	wfapp.SetInitChainer(func(ctx sdk.Context, _ *cmtabcitypes.RequestInitChain) (*cmtabcitypes.ResponseInitChain, error) {
		for _, mod := range wfapp.ModuleManager.OrderInitGenesis {
			if m, ok := wfapp.ModuleManager.Modules[mod].(module.HasGenesis); ok {
				m.InitGenesis(ctx, wfapp.AppCodec(), m.DefaultGenesis(wfapp.AppCodec()))
			}
		}
		return &cmtabcitypes.ResponseInitChain{}, nil
	})

	consensusParamsKeeper := consensusparamkeeper.NewKeeper(wfapp.AppCodec(), runtime.NewKVStoreService(wfapp.GetKey(consensusparamtypes.StoreKey)), authtypes.NewModuleAddress("gov").String(), runtime.EventService{})
	wfapp.SetParamStore(consensusParamsKeeper.ParamsStore)

	if err := wfapp.LoadLatestVersion(); err != nil {
		panic(fmt.Errorf("failed to load application version from store: %w", err))
	}

	_, err := wfapp.InitChain(&cmtabcitypes.RequestInitChain{ChainId: "wf-chain-id", ConsensusParams: simtestutil.DefaultConsensusParams})
	require.NoError(tb, err)

	ctx := wfapp.NewContext(false)
	ctx = ctx.WithBlockHeader(cmtproto.Header{ChainID: "wf-chain-id", Time: time.Now(), Height: 1})

	// Set IFT params with admin as authority
	require.NoError(tb, wfapp.IFTKeeper.ParamsStore.Set(ctx, ifttypes.Params{
		Authority: authtypes.NewModuleAddress(govtypes.ModuleName).String(),
	}))

	return wfapp, ctx
}

func createIBCClient(tb testing.TB, ctx sdk.Context, wfapp *app.SandboxApp) string {
	tb.Helper()

	trustingPeriod := time.Hour * 24 * 7 * 2
	ubdPeriod := time.Hour * 24 * 7 * 3
	maxClockDrift := time.Second * 10
	testClientHeight := clienttypes.Height{
		RevisionNumber: 0,
		RevisionHeight: 1,
	}
	privVal := cmttypes.NewMockPV()
	pubKey, err := privVal.GetPubKey()
	require.NoError(tb, err)

	validator := cmttypes.NewValidator(pubKey, 1)
	valSet := cmttypes.NewValidatorSet([]*cmttypes.Validator{validator})
	valSetHash := valSet.Hash()

	tmClientState := ibctm.NewClientState("test-chain-id", ibctm.DefaultTrustLevel, trustingPeriod, ubdPeriod, maxClockDrift, testClientHeight, commitmenttypes.GetSDKSpecs(), ibctesting.UpgradePath)
	tmConsensusState := ibctm.NewConsensusState(time.Now(), commitmenttypes.NewMerkleRoot(make([]byte, 32)), valSetHash)
	clientState := wfapp.AppCodec().MustMarshal(tmClientState)
	consensusState := wfapp.AppCodec().MustMarshal(tmConsensusState)

	clientID, err := wfapp.IBCKeeper.ClientKeeper.CreateClient(ctx, ibcexported.Tendermint, clientState, consensusState)
	require.NoError(tb, err)

	wfapp.IBCKeeper.ClientV2Keeper.SetClientCounterparty(ctx, clientID, clientv2types.CounterpartyInfo{ClientId: clientID})
	wfapp.IBCKeeper.ChannelKeeperV2.SetNextSequenceSend(ctx, clientID, 1)

	return clientID
}

//nolint:unparam // creator kept for test flexibility
func createTokenFactoryDenom(tb testing.TB, ctx sdk.Context, wfapp *app.SandboxApp, creator, denom string) {
	tb.Helper()
	err := wfapp.TokenFactoryKeeper.CreateDenom(ctx, creator, denom)
	require.NoError(tb, err)
}

//nolint:unparam // denom kept for test flexibility
func mintTokens(tb testing.TB, ctx sdk.Context, wfapp *app.SandboxApp, denom string, amount math.Int, to sdk.AccAddress) {
	tb.Helper()
	err := wfapp.TokenFactoryKeeper.MintTo(ctx, denom, amount, to)
	require.NoError(tb, err)
}

// TestKeeper_SetGetIFTBridge tests basic bridge storage operations
func TestKeeper_SetGetIFTBridge(t *testing.T) {
	wfapp, ctx := setupIntegrationApp(t)

	clientID := createIBCClient(t, ctx, wfapp)

	bridge := ifttypes.IFTBridge{
		ClientId:               clientID,
		CounterpartyIftAddress: remoteIFTAddrA,
		IftSendCallConstructor: ifttypes.ConstructorEVM,
	}

	// Set bridge
	err := wfapp.IFTKeeper.IFTBridgeStore.Set(ctx, collections.Join(testDenom, clientID), bridge)
	require.NoError(t, err)

	// Get bridge
	gotBridge, err := wfapp.IFTKeeper.IFTBridgeStore.Get(ctx, collections.Join(testDenom, clientID))
	require.NoError(t, err)
	require.Equal(t, bridge.ClientId, gotBridge.ClientId)
	require.Equal(t, bridge.CounterpartyIftAddress, gotBridge.CounterpartyIftAddress)
	require.Equal(t, bridge.IftSendCallConstructor, gotBridge.IftSendCallConstructor)

	// Has bridge
	exists, err := wfapp.IFTKeeper.IFTBridgeStore.Has(ctx, collections.Join(testDenom, clientID))
	require.NoError(t, err)
	require.True(t, exists)

	// Remove bridge
	err = wfapp.IFTKeeper.IFTBridgeStore.Remove(ctx, collections.Join(testDenom, clientID))
	require.NoError(t, err)

	// Verify removed
	exists, err = wfapp.IFTKeeper.IFTBridgeStore.Has(ctx, collections.Join(testDenom, clientID))
	require.NoError(t, err)
	require.False(t, exists)
}

// TestKeeper_SetGetPendingTransfer tests pending transfer storage operations
func TestKeeper_SetGetPendingTransfer(t *testing.T) {
	wfapp, ctx := setupIntegrationApp(t)

	clientID := createIBCClient(t, ctx, wfapp)
	sequence := uint64(1)

	pending := ifttypes.PendingTransfer{
		Denom:    testDenom,
		ClientId: clientID,
		Sequence: sequence,
		Sender:   userAddrA,
		Amount:   math.NewInt(1000000),
	}

	// Set pending transfer
	err := wfapp.IFTKeeper.SetPendingTransfer(ctx, clientID, sequence, pending)
	require.NoError(t, err)

	// Get pending transfer
	gotPending, err := wfapp.IFTKeeper.PendingTransferStore.Get(ctx, collections.Join(clientID, sequence))
	require.NoError(t, err)
	require.Equal(t, pending.Denom, gotPending.Denom)
	require.Equal(t, pending.ClientId, gotPending.ClientId)
	require.Equal(t, pending.Sequence, gotPending.Sequence)
	require.Equal(t, pending.Sender, gotPending.Sender)
	require.True(t, pending.Amount.Equal(gotPending.Amount))

	// Has pending transfer
	exists, err := wfapp.IFTKeeper.PendingTransferStore.Has(ctx, collections.Join(clientID, sequence))
	require.NoError(t, err)
	require.True(t, exists)

	// Remove pending transfer
	err = wfapp.IFTKeeper.RemovePendingTransfer(ctx, clientID, sequence)
	require.NoError(t, err)

	// Verify removed
	exists, err = wfapp.IFTKeeper.PendingTransferStore.Has(ctx, collections.Join(clientID, sequence))
	require.NoError(t, err)
	require.False(t, exists)
}

// TestKeeper_Params tests params storage
func TestKeeper_Params(t *testing.T) {
	wfapp, ctx := setupIntegrationApp(t)

	params := ifttypes.Params{
		Authority: adminAddr,
	}

	// Set params
	err := wfapp.IFTKeeper.ParamsStore.Set(ctx, params)
	require.NoError(t, err)

	// Get params
	gotParams, err := wfapp.IFTKeeper.ParamsStore.Get(ctx)
	require.NoError(t, err)
	require.Equal(t, params.Authority, gotParams.Authority)
}

// TestKeeper_HasPendingTransfersForBridge tests the pending transfer check for bridge removal
func TestKeeper_HasPendingTransfersForBridge(t *testing.T) {
	wfapp, ctx := setupIntegrationApp(t)

	clientID1 := createIBCClient(t, ctx, wfapp)
	clientID2 := createIBCClient(t, ctx, wfapp)

	// Initially no pending transfers
	hasPending, err := wfapp.IFTKeeper.HasPendingTransfersForBridge(ctx, testDenom, clientID1)
	require.NoError(t, err)
	require.False(t, hasPending, "should have no pending transfers initially")

	// Add a pending transfer for (testDenom, clientID1)
	pending1 := ifttypes.PendingTransfer{
		Denom:    testDenom,
		ClientId: clientID1,
		Sequence: 1,
		Sender:   userAddrA,
		Amount:   math.NewInt(1000000),
	}
	err = wfapp.IFTKeeper.SetPendingTransfer(ctx, clientID1, 1, pending1)
	require.NoError(t, err)

	// Now should have pending transfers for (testDenom, clientID1)
	hasPending, err = wfapp.IFTKeeper.HasPendingTransfersForBridge(ctx, testDenom, clientID1)
	require.NoError(t, err)
	require.True(t, hasPending, "should have pending transfers after adding one")

	// Different client should not have pending transfers
	hasPending, err = wfapp.IFTKeeper.HasPendingTransfersForBridge(ctx, testDenom, clientID2)
	require.NoError(t, err)
	require.False(t, hasPending, "different client should have no pending transfers")

	// Different denom should not have pending transfers
	hasPending, err = wfapp.IFTKeeper.HasPendingTransfersForBridge(ctx, testDenom2, clientID1)
	require.NoError(t, err)
	require.False(t, hasPending, "different denom should have no pending transfers")

	// Add multiple pending transfers for same bridge
	pending2 := ifttypes.PendingTransfer{
		Denom:    testDenom,
		ClientId: clientID1,
		Sequence: 2,
		Sender:   userAddrB,
		Amount:   math.NewInt(2000000),
	}
	err = wfapp.IFTKeeper.SetPendingTransfer(ctx, clientID1, 2, pending2)
	require.NoError(t, err)

	// Still should have pending transfers
	hasPending, err = wfapp.IFTKeeper.HasPendingTransfersForBridge(ctx, testDenom, clientID1)
	require.NoError(t, err)
	require.True(t, hasPending, "should have pending transfers with multiple entries")

	// Remove first pending transfer
	err = wfapp.IFTKeeper.RemovePendingTransfer(ctx, clientID1, 1)
	require.NoError(t, err)

	// Should still have pending (second one exists)
	hasPending, err = wfapp.IFTKeeper.HasPendingTransfersForBridge(ctx, testDenom, clientID1)
	require.NoError(t, err)
	require.True(t, hasPending, "should still have pending after removing one")

	// Remove second pending transfer
	err = wfapp.IFTKeeper.RemovePendingTransfer(ctx, clientID1, 2)
	require.NoError(t, err)

	// Now should have no pending transfers
	hasPending, err = wfapp.IFTKeeper.HasPendingTransfersForBridge(ctx, testDenom, clientID1)
	require.NoError(t, err)
	require.False(t, hasPending, "should have no pending transfers after removing all")
}

// TestKeeper_GetPendingTransferByClientSequence tests the O(1) index lookup
func TestKeeper_GetPendingTransferByClientSequence(t *testing.T) {
	wfapp, ctx := setupIntegrationApp(t)

	clientID := createIBCClient(t, ctx, wfapp)

	// Initially not found
	_, found, err := wfapp.IFTKeeper.GetPendingTransferByClientSequence(ctx, clientID, 1)
	require.NoError(t, err)
	require.False(t, found, "should not find non-existent transfer")

	// Add pending transfer
	pending := ifttypes.PendingTransfer{
		Denom:    testDenom,
		ClientId: clientID,
		Sequence: 1,
		Sender:   userAddrA,
		Amount:   math.NewInt(1000000),
	}
	err = wfapp.IFTKeeper.SetPendingTransfer(ctx, clientID, 1, pending)
	require.NoError(t, err)

	// Now should find it via index
	gotPending, found, err := wfapp.IFTKeeper.GetPendingTransferByClientSequence(ctx, clientID, 1)
	require.NoError(t, err)
	require.True(t, found, "should find transfer via index")
	require.Equal(t, testDenom, gotPending.Denom)
	require.Equal(t, clientID, gotPending.ClientId)
	require.Equal(t, uint64(1), gotPending.Sequence)
	require.Equal(t, userAddrA, gotPending.Sender)

	// Different sequence should not be found
	_, found, err = wfapp.IFTKeeper.GetPendingTransferByClientSequence(ctx, clientID, 999)
	require.NoError(t, err)
	require.False(t, found, "should not find different sequence")

	// Remove and verify index is also cleaned up
	err = wfapp.IFTKeeper.RemovePendingTransfer(ctx, clientID, 1)
	require.NoError(t, err)

	_, found, err = wfapp.IFTKeeper.GetPendingTransferByClientSequence(ctx, clientID, 1)
	require.NoError(t, err)
	require.False(t, found, "should not find after removal")
}
