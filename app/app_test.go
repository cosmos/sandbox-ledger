package app

import (
	"testing"

	dbm "github.com/cosmos/cosmos-db"
	gmptypes "github.com/cosmos/ibc-go/v11/modules/apps/27-gmp/types"
	ibctransfertypes "github.com/cosmos/ibc-go/v11/modules/apps/transfer/types"
	"github.com/stretchr/testify/require"

	"cosmossdk.io/log/v2"

	simtestutil "github.com/cosmos/cosmos-sdk/testutil/sims"
)

func TestAppNewAndGenesis(t *testing.T) {
	app := NewApp(
		log.NewNopLogger(),
		dbm.NewMemDB(),
		nil,
		true,
		simtestutil.NewAppOptionsWithFlagHome(t.TempDir()),
	)

	require.NotNil(t, app.GMPKeeper, "GMPKeeper must be wired for IBC v2 GMP transfers")
	require.NotNil(t, app.IFTKeeper, "IFTKeeper must be wired to receive callbacks-v2")
	require.NotNil(t, app.TokenFactoryKeeper, "TokenFactoryKeeper must be wired")

	require.NotPanics(t, func() { app.DefaultGenesis() },
		"DefaultGenesis must not panic — guards module manager registration and genesis ordering")
}

func TestIBCv2Routes(t *testing.T) {
	app := NewApp(
		log.NewNopLogger(),
		dbm.NewMemDB(),
		nil,
		true,
		simtestutil.NewAppOptionsWithFlagHome(t.TempDir()),
	)

	routerV2 := app.IBCKeeper.ChannelKeeperV2.Router
	require.NotNil(t, routerV2)

	require.True(t, routerV2.HasRoute(ibctransfertypes.ModuleName),
		"transfer v2 route must be registered for IBC v2 fungible transfers")
	require.True(t, routerV2.HasRoute(gmptypes.PortID),
		"gmp v2 route must be registered for IBC v2 general message passing")
}
