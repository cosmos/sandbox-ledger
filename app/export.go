package app

import (
	"encoding/json"

	tmproto "github.com/cometbft/cometbft/proto/tendermint/types"

	servertypes "github.com/cosmos/cosmos-sdk/server/types"
)

func (app *SandboxApp) ExportAppStateAndValidators(
	forZeroHeight bool,
	_ []string,
	modulesToExport []string,
) (servertypes.ExportedApp, error) {
	ctx := app.NewContextLegacy(true, tmproto.Header{Height: app.LastBlockHeight()})

	height := app.LastBlockHeight() + 1
	if forZeroHeight {
		height = 0
	}

	genState, err := app.ModuleManager.ExportGenesisForModules(ctx, app.appCodec, modulesToExport)
	if err != nil {
		return servertypes.ExportedApp{}, err
	}

	appState, err := json.MarshalIndent(genState, "", "  ")
	if err != nil {
		return servertypes.ExportedApp{}, err
	}

	return servertypes.ExportedApp{
		AppState:        appState,
		Height:          height,
		ConsensusParams: app.GetConsensusParams(ctx),
	}, nil
}
