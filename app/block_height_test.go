package app

import (
	"bytes"
	"context"
	"os"
	"path/filepath"
	"testing"

	cmtcfg "github.com/cometbft/cometbft/config"
	cmtcrypto "github.com/cometbft/cometbft/crypto"
	cmtstoreproto "github.com/cometbft/cometbft/proto/tendermint/store"
	cmtstore "github.com/cometbft/cometbft/store"
	cmttypes "github.com/cometbft/cometbft/types"
	"github.com/spf13/cobra"
	"github.com/spf13/viper"
	"github.com/stretchr/testify/require"

	"cosmossdk.io/log/v2"

	"github.com/cosmos/cosmos-sdk/client"
	"github.com/cosmos/cosmos-sdk/client/flags"
	sdkserver "github.com/cosmos/cosmos-sdk/server"
)

// newBlockHeightTestCmd builds the offline block-height command pointed at a
// fresh node home with a server context attached. The returned buffer captures
// stdout writes from cmd.Println and the client context's PrintProto.
func newBlockHeightTestCmd(t *testing.T) (*cobra.Command, *bytes.Buffer, *cmtcfg.Config) {
	t.Helper()

	home := t.TempDir()
	cfg := cmtcfg.DefaultConfig()
	cfg.SetRoot(home)
	require.NoError(t, os.MkdirAll(cfg.DBDir(), 0o700))
	require.NoError(t, os.MkdirAll(filepath.Dir(cfg.GenesisFile()), 0o700))

	cmd := queryBlockHeightCmd()
	cmd.SilenceUsage = true
	cmd.SilenceErrors = true

	buf := &bytes.Buffer{}
	cmd.SetOut(buf)
	cmd.SetErr(buf)

	serverCtx := sdkserver.NewContext(viper.New(), cfg, log.NewNopLogger())
	ctx := context.WithValue(context.Background(), sdkserver.ServerContextKey, serverCtx)
	cmd.SetContext(ctx)

	return cmd, buf, cfg
}

// seedBlockStoreHeight writes a BlockStoreState directly so the command sees a
// non-zero latest height without needing a real saved block.
func seedBlockStoreHeight(t *testing.T, cfg *cmtcfg.Config, base, height int64) {
	t.Helper()
	db, err := cmtcfg.DefaultDBProvider(&cmtcfg.DBContext{ID: "blockstore", Config: cfg})
	require.NoError(t, err)
	defer func() { require.NoError(t, db.Close()) }()

	batch := db.NewBatch()
	defer func() { require.NoError(t, batch.Close()) }()
	cmtstore.SaveBlockStoreStateBatch(&cmtstoreproto.BlockStoreState{Base: base, Height: height}, batch)
	require.NoError(t, batch.WriteSync())
}

// saveTestBlock writes a minimal block at the given height through the real
// BlockStore.SaveBlock path so LoadBlock can read it back. Only fields needed
// to satisfy ValidateBasic on read are populated.
func saveTestBlock(t *testing.T, cfg *cmtcfg.Config, height int64) {
	t.Helper()
	db, err := cmtcfg.DefaultDBProvider(&cmtcfg.DBContext{ID: "blockstore", Config: cfg})
	require.NoError(t, err)
	defer func() { require.NoError(t, db.Close()) }()

	bs := cmtstore.NewBlockStore(db)

	block := cmttypes.MakeBlock(height, nil, &cmttypes.Commit{}, nil)
	block.ChainID = testChainID
	block.ProposerAddress = bytes.Repeat([]byte{0x01}, cmtcrypto.AddressSize)

	parts, err := block.MakePartSet(cmttypes.BlockPartSizeBytes)
	require.NoError(t, err)

	bs.SaveBlock(block, parts, &cmttypes.Commit{Height: height})
}

func TestQueryBlockHeight_EmptyBlockstore(t *testing.T) {
	cmd, buf, _ := newBlockHeightTestCmd(t)

	require.NoError(t, cmd.Execute())
	require.Equal(t, "0\n", buf.String(),
		"empty blockstore should print height 0")
}

func TestQueryBlockHeight_PrePopulatedState(t *testing.T) {
	cmd, buf, cfg := newBlockHeightTestCmd(t)
	seedBlockStoreHeight(t, cfg, 1, 42)

	require.NoError(t, cmd.Execute())
	require.Equal(t, "42\n", buf.String(),
		"command should report the persisted height from blockstore.db")
}

func TestQueryBlockHeight_FullEmptyStoreErrors(t *testing.T) {
	cmd, buf, _ := newBlockHeightTestCmd(t)
	cmd.SetArgs([]string{"--full"})

	err := cmd.Execute()
	require.Error(t, err)
	require.Contains(t, err.Error(), "blockstore is empty")
	require.Equal(t, "0\n", buf.String(),
		"the height line is printed before --full attempts to load the block")
}

func TestQueryBlockHeight_FullPrintsBlock(t *testing.T) {
	cmd, buf, cfg := newBlockHeightTestCmd(t)
	saveTestBlock(t, cfg, 1)

	// PrintProto needs a Codec on the client context, and we route its
	// output to the same buffer that captures cmd.Println so we can assert
	// against a single stream.
	app := newTestApp(t)
	clientCtx := client.Context{}.
		WithCodec(app.AppCodec()).
		WithOutputFormat(flags.OutputFormatJSON).
		WithOutput(buf)
	require.NoError(t, client.SetCmdClientContext(cmd, clientCtx))

	cmd.SetArgs([]string{"--full"})
	require.NoError(t, cmd.Execute())

	out := buf.String()
	require.Contains(t, out, "1\n", "height line precedes the block JSON")
	require.Contains(t, out, `"height":"1"`,
		"--full should append the block proto encoded as JSON")
	require.Contains(t, out, `"chain_id":"`+testChainID+`"`,
		"block JSON should reflect the saved block's chain ID")
}
