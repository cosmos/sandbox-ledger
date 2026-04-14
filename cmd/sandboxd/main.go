package main

import (
	"fmt"
	"os"

	clienthelpers "cosmossdk.io/client/v2/helpers"
	svrcmd "github.com/cosmos/cosmos-sdk/server/cmd"
	sdk "github.com/cosmos/cosmos-sdk/types"
	"github.com/cosmos/evm/crypto/hd"
	evmconfig "github.com/cosmos/evm/evmd/config"

	"github.com/cosmos/sandbox-ledger/app"
)

const Bech32Prefix = "cosmos"

func main() {
	setupSDKConfig()

	defaultNodeHome, err := clienthelpers.GetNodeHomeDirectory(".sandboxd")
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}

	rootCmd := app.NewRootCmd(defaultNodeHome)
	if err := svrcmd.Execute(rootCmd, "sandboxd", defaultNodeHome); err != nil {
		fmt.Fprintln(rootCmd.OutOrStderr(), err)
		os.Exit(1)
	}
}

func setupSDKConfig() {
	cfg := sdk.GetConfig()
	evmconfig.SetBech32Prefixes(cfg)
	cfg.SetCoinType(hd.Bip44CoinType)
	cfg.SetPurpose(sdk.Purpose)
	cfg.SetFullFundraiserPath(hd.BIP44HDPath) //nolint:staticcheck
	cfg.Seal()
}
