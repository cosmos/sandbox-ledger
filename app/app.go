package app

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"

	goruntime "runtime"

	"github.com/spf13/cast"

	"github.com/cosmos/cosmos-sdk/baseapp/txnrunner"
	"github.com/ethereum/go-ethereum/common"

	_ "github.com/ethereum/go-ethereum/eth/tracers/js"
	_ "github.com/ethereum/go-ethereum/eth/tracers/native"

	abci "github.com/cometbft/cometbft/abci/types"
	cmtcfg "github.com/cometbft/cometbft/config"
	cmtcli "github.com/cometbft/cometbft/libs/cli"

	dbm "github.com/cosmos/cosmos-db"
	evmante "github.com/cosmos/evm/ante"
	antetypes "github.com/cosmos/evm/ante/types"
	evmencoding "github.com/cosmos/evm/encoding"
	evmaddress "github.com/cosmos/evm/encoding/address"
	evmconfig "github.com/cosmos/evm/evmd/config"
	evmmempool "github.com/cosmos/evm/mempool"
	precompiletypes "github.com/cosmos/evm/precompiles/types"
	cosmosevmserver "github.com/cosmos/evm/server"
	srvflags "github.com/cosmos/evm/server/flags"
	"github.com/cosmos/evm/utils"
	cosmosevmcmd "github.com/cosmos/evm/client"
	evmdebug "github.com/cosmos/evm/client/debug"
	"github.com/cosmos/evm/crypto/hd"
	"github.com/cosmos/evm/x/erc20"
	erc20keeper "github.com/cosmos/evm/x/erc20/keeper"
	erc20types "github.com/cosmos/evm/x/erc20/types"
	erc20v2 "github.com/cosmos/evm/x/erc20/v2"
	"github.com/cosmos/evm/x/feemarket"
	feemarketkeeper "github.com/cosmos/evm/x/feemarket/keeper"
	feemarkettypes "github.com/cosmos/evm/x/feemarket/types"
	ibccallbackskeeper "github.com/cosmos/evm/x/ibc/callbacks/keeper"
	"github.com/cosmos/evm/x/vm"
	evmkeeper "github.com/cosmos/evm/x/vm/keeper"
	evmtypes "github.com/cosmos/evm/x/vm/types"
	"github.com/cosmos/gogoproto/proto"

	ibccallbacks "github.com/cosmos/ibc-go/v11/modules/apps/callbacks"
	transfer "github.com/cosmos/ibc-go/v11/modules/apps/transfer"
	transferkeeper "github.com/cosmos/ibc-go/v11/modules/apps/transfer/keeper"
	ibctransfertypes "github.com/cosmos/ibc-go/v11/modules/apps/transfer/types"
	transferv2 "github.com/cosmos/ibc-go/v11/modules/apps/transfer/v2"
	ibc "github.com/cosmos/ibc-go/v11/modules/core"
	porttypes "github.com/cosmos/ibc-go/v11/modules/core/05-port/types"
	ibcapi "github.com/cosmos/ibc-go/v11/modules/core/api"
	ibcexported "github.com/cosmos/ibc-go/v11/modules/core/exported"
	ibckeeper "github.com/cosmos/ibc-go/v11/modules/core/keeper"
	ibctm "github.com/cosmos/ibc-go/v11/modules/light-clients/07-tendermint"

	autocliv1 "cosmossdk.io/api/cosmos/autocli/v1"
	"cosmossdk.io/client/v2/autocli"
	"cosmossdk.io/core/address"
	"cosmossdk.io/core/appmodule"
	"cosmossdk.io/log/v2"
	confixcmd "cosmossdk.io/tools/confix/cmd"
	storetypes "github.com/cosmos/cosmos-sdk/store/v2/types"

	"github.com/cosmos/cosmos-sdk/baseapp"
	"github.com/cosmos/cosmos-sdk/client"
	clientcfg "github.com/cosmos/cosmos-sdk/client/config"
	"github.com/cosmos/cosmos-sdk/client/flags"
	"github.com/cosmos/cosmos-sdk/client/grpc/cmtservice"
	"github.com/cosmos/cosmos-sdk/client/grpc/node"
	"github.com/cosmos/cosmos-sdk/client/pruning"
	"github.com/cosmos/cosmos-sdk/client/rpc"
	"github.com/cosmos/cosmos-sdk/client/snapshot"
	"github.com/cosmos/cosmos-sdk/codec"
	"github.com/cosmos/cosmos-sdk/codec/types"
	"github.com/cosmos/cosmos-sdk/enterprise/poa/x/poa"
	poakeeper "github.com/cosmos/cosmos-sdk/enterprise/poa/x/poa/keeper"
	poatypes "github.com/cosmos/cosmos-sdk/enterprise/poa/x/poa/types"
	"github.com/cosmos/cosmos-sdk/runtime"
	runtimeservices "github.com/cosmos/cosmos-sdk/runtime/services"
	sdkserver "github.com/cosmos/cosmos-sdk/server"
	"github.com/cosmos/cosmos-sdk/server/api"
	"github.com/cosmos/cosmos-sdk/server/config"
	servertypes "github.com/cosmos/cosmos-sdk/server/types"
	simtestutil "github.com/cosmos/cosmos-sdk/testutil/sims"
	sdk "github.com/cosmos/cosmos-sdk/types"
	sdkmempool "github.com/cosmos/cosmos-sdk/types/mempool"
	"github.com/cosmos/cosmos-sdk/types/module"
	sdktestutil "github.com/cosmos/cosmos-sdk/types/module/testutil"
	"github.com/cosmos/cosmos-sdk/types/msgservice"
	signingtypes "github.com/cosmos/cosmos-sdk/types/tx/signing"
	"github.com/cosmos/cosmos-sdk/version"
	"github.com/cosmos/cosmos-sdk/x/auth"
	authcmd "github.com/cosmos/cosmos-sdk/x/auth/client/cli"
	authkeeper "github.com/cosmos/cosmos-sdk/x/auth/keeper"
	"github.com/cosmos/cosmos-sdk/x/auth/posthandler"
	authsims "github.com/cosmos/cosmos-sdk/x/auth/simulation"
	authtx "github.com/cosmos/cosmos-sdk/x/auth/tx"
	txmodule "github.com/cosmos/cosmos-sdk/x/auth/tx/config"
	authtypes "github.com/cosmos/cosmos-sdk/x/auth/types"
	"github.com/cosmos/cosmos-sdk/x/bank"
	bankkeeper "github.com/cosmos/cosmos-sdk/x/bank/keeper"
	banktypes "github.com/cosmos/cosmos-sdk/x/bank/types"
	"github.com/cosmos/cosmos-sdk/x/consensus"
	consensusparamkeeper "github.com/cosmos/cosmos-sdk/x/consensus/keeper"
	consensusparamtypes "github.com/cosmos/cosmos-sdk/x/consensus/types"
	"github.com/cosmos/cosmos-sdk/x/genutil"
	genutilcli "github.com/cosmos/cosmos-sdk/x/genutil/client/cli"
	genutiltypes "github.com/cosmos/cosmos-sdk/x/genutil/types"
	"github.com/cosmos/cosmos-sdk/x/gov"
	govkeeper "github.com/cosmos/cosmos-sdk/x/gov/keeper"
	govtypes "github.com/cosmos/cosmos-sdk/x/gov/types"
	stakingtypes "github.com/cosmos/cosmos-sdk/x/staking/types"
	"github.com/cosmos/cosmos-sdk/x/upgrade"
	upgradekeeper "github.com/cosmos/cosmos-sdk/x/upgrade/keeper"
	upgradetypes "github.com/cosmos/cosmos-sdk/x/upgrade/types"
	"github.com/spf13/cobra"
	"github.com/spf13/viper"
)

func init() {
	sdk.DefaultPowerReduction = utils.AttoPowerReduction
}

const appName = "sandboxd"

// maccPerms are the module account permissions for this chain.
var maccPerms = map[string][]string{
	authtypes.FeeCollectorName: nil,
	govtypes.ModuleName:        {authtypes.Burner},
	poatypes.ModuleName:        nil,
	ibctransfertypes.ModuleName: {authtypes.Minter, authtypes.Burner},
	evmtypes.ModuleName:        {authtypes.Minter, authtypes.Burner},
	feemarkettypes.ModuleName:  nil,
	erc20types.ModuleName:      {authtypes.Minter, authtypes.Burner},
}

// ----------------------------------------------------------------------------
// poaStakingKeeper satisfies the EVM and ERC-20 StakingKeeper interfaces
// without the staking module. Only BondDenom and ValidatorAddressCodec are
// meaningful; the remaining methods return errors, which the EVM handles
// gracefully (e.g. BLOCKHASH returns 0, coinbase returns the zero address).
// ----------------------------------------------------------------------------

type poaStakingKeeper struct {
	denom     string
	addrCodec address.Codec
}

func (k poaStakingKeeper) GetHistoricalInfo(_ context.Context, _ int64) (stakingtypes.HistoricalInfo, error) {
	return stakingtypes.HistoricalInfo{}, stakingtypes.ErrNoHistoricalInfo
}
func (k poaStakingKeeper) GetValidatorByConsAddr(_ context.Context, _ sdk.ConsAddress) (stakingtypes.Validator, error) {
	return stakingtypes.Validator{}, stakingtypes.ErrNoValidatorFound
}
func (k poaStakingKeeper) ValidatorAddressCodec() address.Codec { return k.addrCodec }
func (k poaStakingKeeper) BondDenom(_ context.Context) (string, error) {
	return k.denom, nil
}

// SandboxApp is the main application type.
type SandboxApp struct {
	*baseapp.BaseApp

	legacyAmino       *codec.LegacyAmino
	appCodec          codec.Codec
	interfaceRegistry types.InterfaceRegistry
	txConfig          client.TxConfig

	pendingTxListeners []evmante.PendingTxListener

	keys  map[string]*storetypes.KVStoreKey
	oKeys map[string]*storetypes.ObjectStoreKey

	// keepers
	AccountKeeper         authkeeper.AccountKeeper
	BankKeeper            bankkeeper.Keeper
	ConsensusParamsKeeper consensusparamkeeper.Keeper
	GovKeeper             *govkeeper.Keeper
	UpgradeKeeper         *upgradekeeper.Keeper
	POAKeeper             *poakeeper.Keeper

	// IBC keepers
	IBCKeeper      *ibckeeper.Keeper
	TransferKeeper *transferkeeper.Keeper
	CallbackKeeper ibccallbackskeeper.ContractKeeper

	// Cosmos EVM keepers
	FeeMarketKeeper feemarketkeeper.Keeper
	EVMKeeper       *evmkeeper.Keeper
	Erc20Keeper     erc20keeper.Keeper
	EVMMempool      sdkmempool.ExtMempool

	ModuleManager      *module.Manager
	BasicModuleManager module.BasicManager
	configurator       module.Configurator
}

func NewApp(
	logger log.Logger,
	db dbm.DB,
	traceStore io.Writer,
	loadLatest bool,
	appOpts servertypes.AppOptions,
	baseAppOptions ...func(*baseapp.BaseApp),
) *SandboxApp {
	evmChainID := cast.ToUint64(appOpts.Get(srvflags.EVMChainID))
	encodingConfig := evmencoding.MakeConfig(evmChainID)

	appCodec := encodingConfig.Codec
	legacyAmino := encodingConfig.Amino
	interfaceRegistry := encodingConfig.InterfaceRegistry
	txConfig := encodingConfig.TxConfig

	baseAppOptions = append(baseAppOptions, baseapp.SetOptimisticExecution())

	bApp := baseapp.NewBaseApp(appName, logger, db, txConfig.TxDecoder(), baseAppOptions...)
	bApp.SetVersion(version.Version)
	bApp.SetInterfaceRegistry(interfaceRegistry)
	bApp.SetTxEncoder(txConfig.TxEncoder())

	keys := storetypes.NewKVStoreKeys(
		authtypes.StoreKey, banktypes.StoreKey,
		consensusparamtypes.StoreKey, govtypes.StoreKey,
		upgradetypes.StoreKey, poatypes.StoreKey,
		// IBC
		ibcexported.StoreKey, ibctransfertypes.StoreKey,
		// EVM
		evmtypes.StoreKey, feemarkettypes.StoreKey, erc20types.StoreKey,
	)
	oKeys := storetypes.NewObjectStoreKeys(banktypes.ObjectStoreKey, evmtypes.ObjectKey)
	transientKeys := storetypes.NewTransientStoreKeys(poatypes.TransientStoreKey)

	var nonTransientKeys []storetypes.StoreKey
	for _, k := range keys {
		nonTransientKeys = append(nonTransientKeys, k)
	}
	for _, k := range oKeys {
		nonTransientKeys = append(nonTransientKeys, k)
	}

	bApp.SetBlockSTMTxRunner(txnrunner.NewSTMRunner(
		txConfig.TxDecoder(),
		nonTransientKeys,
		min(goruntime.GOMAXPROCS(0), goruntime.NumCPU()),
		true,
		func(ms storetypes.MultiStore) string { return sdk.DefaultBondDenom },
	))
	bApp.SetDisableBlockGasMeter(true)

	if err := bApp.RegisterStreamingServices(appOpts, keys); err != nil {
		fmt.Printf("failed to load state streaming: %s", err)
		os.Exit(1)
	}

	app := &SandboxApp{
		BaseApp:           bApp,
		legacyAmino:       legacyAmino,
		appCodec:          appCodec,
		txConfig:          txConfig,
		interfaceRegistry: interfaceRegistry,
		keys:              keys,
		oKeys:             oKeys,
	}

	authAddr := authtypes.NewModuleAddress(govtypes.ModuleName).String()

	// Consensus
	app.ConsensusParamsKeeper = consensusparamkeeper.NewKeeper(
		appCodec,
		runtime.NewKVStoreService(keys[consensusparamtypes.StoreKey]),
		authAddr,
		runtime.EventService{},
	)
	bApp.SetParamStore(app.ConsensusParamsKeeper.ParamsStore)

	// Auth
	app.AccountKeeper = authkeeper.NewAccountKeeper(
		appCodec,
		runtime.NewKVStoreService(keys[authtypes.StoreKey]),
		authtypes.ProtoBaseAccount,
		maccPerms,
		evmaddress.NewEvmCodec(sdk.GetConfig().GetBech32AccountAddrPrefix()),
		sdk.GetConfig().GetBech32AccountAddrPrefix(),
		authAddr,
	)

	// Bank
	app.BankKeeper = bankkeeper.NewBaseKeeper(
		appCodec,
		runtime.NewKVStoreService(keys[banktypes.StoreKey]),
		app.AccountKeeper,
		blockedAddresses(),
		authAddr,
		logger,
	)
	app.BankKeeper = app.BankKeeper.WithObjStoreKey(oKeys[banktypes.ObjectStoreKey])

	// Sign mode textual
	enabledSignModes := append(authtx.DefaultSignModes, signingtypes.SignMode_SIGN_MODE_TEXTUAL) //nolint:gocritic
	txConfigOpts := authtx.ConfigOptions{
		EnabledSignModes:           enabledSignModes,
		TextualCoinMetadataQueryFn: txmodule.NewBankKeeperCoinMetadataQueryFn(app.BankKeeper),
	}
	txConfig, err := authtx.NewTxConfigWithOptions(appCodec, txConfigOpts)
	if err != nil {
		panic(err)
	}
	app.txConfig = txConfig

	// POA
	app.POAKeeper = poakeeper.NewKeeper(
		appCodec,
		runtime.NewKVStoreService(keys[poatypes.StoreKey]),
		runtime.NewTransientStoreService(transientKeys[poatypes.TransientStoreKey]),
		app.AccountKeeper,
		app.BankKeeper,
	)

	// Gov (with POA voting power)
	govConfig := govtypes.DefaultConfig()
	app.GovKeeper = govkeeper.NewKeeper(
		appCodec,
		runtime.NewKVStoreService(keys[govtypes.StoreKey]),
		app.AccountKeeper,
		app.BankKeeper,
		nil, // no staking keeper
		app.MsgServiceRouter(),
		govConfig,
		authAddr,
		poakeeper.NewPOACalculateVoteResultsAndVotingPowerFn(*app.POAKeeper),
	)
	app.GovKeeper.SetHooks(govtypes.NewMultiGovHooks(app.POAKeeper.NewGovHooks()))

	// Upgrade
	skipUpgradeHeights := map[int64]bool{}
	for _, h := range cast.ToIntSlice(appOpts.Get(sdkserver.FlagUnsafeSkipUpgrades)) {
		skipUpgradeHeights[int64(h)] = true
	}
	homePath := cast.ToString(appOpts.Get(flags.FlagHome))
	app.UpgradeKeeper = upgradekeeper.NewKeeper(
		skipUpgradeHeights,
		runtime.NewKVStoreService(keys[upgradetypes.StoreKey]),
		appCodec,
		homePath,
		app.BaseApp,
		authAddr,
	)

	// IBC
	app.IBCKeeper = ibckeeper.NewKeeper(
		appCodec,
		runtime.NewKVStoreService(keys[ibcexported.StoreKey]),
		app.UpgradeKeeper,
		authAddr,
	)

	// Fee Market
	app.FeeMarketKeeper = feemarketkeeper.NewKeeper(
		appCodec,
		authtypes.NewModuleAddress(govtypes.ModuleName),
		keys[feemarkettypes.StoreKey],
	)

	// IBC Transfer
	app.TransferKeeper = transferkeeper.NewKeeper(
		appCodec,
		evmaddress.NewEvmCodec(sdk.GetConfig().GetBech32AccountAddrPrefix()),
		runtime.NewKVStoreService(keys[ibctransfertypes.StoreKey]),
		app.IBCKeeper.ChannelKeeper,
		app.MsgServiceRouter(),
		app.AccountKeeper,
		app.BankKeeper,
		authAddr,
	)

	// EVM staking adapter (satisfies EVM interface without staking module)
	stakingAdapter := poaStakingKeeper{
		denom:     sdk.DefaultBondDenom,
		addrCodec: evmaddress.NewEvmCodec(sdk.GetConfig().GetBech32ValidatorAddrPrefix()),
	}

	// EVM
	tracer := cast.ToString(appOpts.Get(srvflags.EVMTracer))
	app.EVMKeeper = evmkeeper.NewKeeper(
		appCodec, keys[evmtypes.StoreKey], oKeys[evmtypes.ObjectKey], nonTransientKeys,
		authtypes.NewModuleAddress(govtypes.ModuleName),
		app.AccountKeeper,
		app.BankKeeper,
		stakingAdapter,
		app.FeeMarketKeeper,
		&app.ConsensusParamsKeeper,
		&app.Erc20Keeper,
		evmChainID,
		tracer,
	).WithStaticPrecompiles(
		precompiletypes.NewStaticPrecompiles().
			WithPraguePrecompiles().
			WithP256Precompile().
			WithBech32Precompile().
			WithICS02Precompile(appCodec, app.IBCKeeper.ClientKeeper).
			WithBankPrecompile(app.BankKeeper, &app.Erc20Keeper).
			WithGovPrecompile(*app.GovKeeper, app.BankKeeper, appCodec),
	)
	app.EVMKeeper.EnableVirtualFeeCollection()

	// ERC-20
	app.Erc20Keeper = erc20keeper.NewKeeper(
		keys[erc20types.StoreKey],
		appCodec,
		authtypes.NewModuleAddress(govtypes.ModuleName),
		app.AccountKeeper,
		app.BankKeeper,
		app.EVMKeeper,
		stakingAdapter,
		app.TransferKeeper,
	)

	// ---- IBC transfer stack ----
	var transferStack porttypes.IBCModule
	transferStack = transfer.NewIBCModule(app.TransferKeeper)
	maxCallbackGas := uint64(1_000_000)
	transferStack = erc20.NewIBCMiddleware(app.Erc20Keeper, transferStack)
	app.CallbackKeeper = ibccallbackskeeper.NewKeeper(app.AccountKeeper, app.EVMKeeper, app.Erc20Keeper)
	callbacksMiddleware := ibccallbacks.NewIBCMiddleware(app.CallbackKeeper, maxCallbackGas)
	callbacksMiddleware.SetICS4Wrapper(app.IBCKeeper.ChannelKeeper)
	callbacksMiddleware.SetUnderlyingApplication(transferStack)
	transferStack = callbacksMiddleware

	var transferStackV2 ibcapi.IBCModule
	transferStackV2 = transferv2.NewIBCModule(app.TransferKeeper)
	transferStackV2 = erc20v2.NewIBCMiddleware(transferStackV2, app.Erc20Keeper)

	ibcRouter := porttypes.NewRouter()
	ibcRouter.AddRoute(ibctransfertypes.ModuleName, transferStack)
	ibcRouterV2 := ibcapi.NewRouter()
	ibcRouterV2.AddRoute(ibctransfertypes.ModuleName, transferStackV2)

	app.IBCKeeper.SetRouter(ibcRouter)
	app.IBCKeeper.SetRouterV2(ibcRouterV2)

	clientKeeper := app.IBCKeeper.ClientKeeper
	storeProvider := app.IBCKeeper.ClientKeeper.GetStoreProvider()
	tmLightClientModule := ibctm.NewLightClientModule(appCodec, storeProvider)
	clientKeeper.AddRoute(ibctm.ModuleName, &tmLightClientModule)

	transferModule := transfer.NewAppModule(app.TransferKeeper)

	// ---- Module Manager ----
	app.ModuleManager = module.NewManager(
		genutil.NewAppModule(app.AccountKeeper, nil, app, txConfig),
		auth.NewAppModule(appCodec, app.AccountKeeper, authsims.RandomGenesisAccounts, nil),
		bank.NewAppModule(appCodec, app.BankKeeper, app.AccountKeeper, nil),
		consensus.NewAppModule(appCodec, app.ConsensusParamsKeeper),
		gov.NewAppModule(appCodec, app.GovKeeper, app.AccountKeeper, app.BankKeeper, nil),
		upgrade.NewAppModule(app.UpgradeKeeper, app.AccountKeeper.AddressCodec()),
		poa.NewAppModule(appCodec, app.POAKeeper, poa.WithSecp256k1Support()),
		// IBC
		ibc.NewAppModule(app.IBCKeeper),
		ibctm.NewAppModule(tmLightClientModule),
		transferModule,
		// EVM
		vm.NewAppModule(app.EVMKeeper, app.AccountKeeper, app.BankKeeper, app.AccountKeeper.AddressCodec()),
		feemarket.NewAppModule(app.FeeMarketKeeper),
		erc20.NewAppModule(app.Erc20Keeper, app.AccountKeeper),
	)

	app.BasicModuleManager = module.NewBasicManagerFromManager(
		app.ModuleManager,
		map[string]module.AppModuleBasic{
			genutiltypes.ModuleName:     genutil.NewAppModuleBasic(genutiltypes.DefaultMessageValidator),
			govtypes.ModuleName:         gov.NewAppModuleBasic(nil),
			ibctransfertypes.ModuleName: transfer.AppModuleBasic{},
		},
	)
	app.BasicModuleManager.RegisterLegacyAminoCodec(legacyAmino)
	app.BasicModuleManager.RegisterInterfaces(interfaceRegistry)

	// ---- Module ordering ----
	app.ModuleManager.SetOrderPreBlockers(
		upgradetypes.ModuleName,
		authtypes.ModuleName,
		evmtypes.ModuleName,
	)
	app.ModuleManager.SetOrderBeginBlockers(
		genutiltypes.ModuleName,
		poatypes.ModuleName,
		ibcexported.ModuleName, ibctransfertypes.ModuleName,
		erc20types.ModuleName, feemarkettypes.ModuleName,
		evmtypes.ModuleName,
		banktypes.ModuleName, govtypes.ModuleName,
		consensusparamtypes.ModuleName,
	)
	app.ModuleManager.SetOrderEndBlockers(
		genutiltypes.ModuleName,
		govtypes.ModuleName,
		poatypes.ModuleName,
		banktypes.ModuleName,
		authtypes.ModuleName,
		evmtypes.ModuleName, erc20types.ModuleName, feemarkettypes.ModuleName,
		ibcexported.ModuleName, ibctransfertypes.ModuleName,
		upgradetypes.ModuleName, consensusparamtypes.ModuleName,
	)

	genesisModuleOrder := []string{
		authtypes.ModuleName, banktypes.ModuleName,
		govtypes.ModuleName, poatypes.ModuleName,
		ibcexported.ModuleName,
		evmtypes.ModuleName, feemarkettypes.ModuleName, erc20types.ModuleName,
		ibctransfertypes.ModuleName,
		genutiltypes.ModuleName, upgradetypes.ModuleName,
		consensusparamtypes.ModuleName,
	}
	app.ModuleManager.SetOrderInitGenesis(genesisModuleOrder...)
	app.ModuleManager.SetOrderExportGenesis(genesisModuleOrder...)

	app.configurator = module.NewConfigurator(appCodec, app.MsgServiceRouter(), app.GRPCQueryRouter())
	if err := app.ModuleManager.RegisterServices(app.configurator); err != nil {
		panic(err)
	}

	autocliv1.RegisterQueryServer(app.GRPCQueryRouter(), runtimeservices.NewAutoCLIQueryService(app.ModuleManager.Modules))

	// ---- Mount stores, set handlers ----
	app.MountKVStores(keys)
	app.MountObjectStores(oKeys)
	app.MountTransientStores(transientKeys)

	maxGasWanted := cast.ToUint64(appOpts.Get(srvflags.EVMMaxTxGasWanted))

	app.SetInitChainer(app.InitChainer)
	app.SetPreBlocker(app.PreBlocker)
	app.SetBeginBlocker(app.BeginBlocker)
	app.SetEndBlocker(app.EndBlocker)
	app.setAnteHandler(app.txConfig, maxGasWanted)
	app.setPostHandler()

	// EVM mempool
	if err := app.configureEVMMempool(appOpts, logger); err != nil {
		panic(fmt.Sprintf("failed to configure EVM mempool: %s", err.Error()))
	}

	// Proto annotations
	protoFiles, err := proto.MergedRegistry()
	if err != nil {
		panic(err)
	}
	if err := msgservice.ValidateProtoAnnotations(protoFiles); err != nil {
		fmt.Fprintln(os.Stderr, err.Error())
	}

	if loadLatest {
		if err := app.LoadLatestVersion(); err != nil {
			logger.Error("error on loading last version", "err", err)
			os.Exit(1)
		}
	}

	return app
}

// ---------- ABCI ----------

func (app *SandboxApp) PreBlocker(ctx sdk.Context, _ *abci.RequestFinalizeBlock) (*sdk.ResponsePreBlock, error) {
	return app.ModuleManager.PreBlock(ctx)
}
func (app *SandboxApp) BeginBlocker(ctx sdk.Context) (sdk.BeginBlock, error) {
	return app.ModuleManager.BeginBlock(ctx)
}
func (app *SandboxApp) EndBlocker(ctx sdk.Context) (sdk.EndBlock, error) {
	return app.ModuleManager.EndBlock(ctx)
}
func (app *SandboxApp) InitChainer(ctx sdk.Context, req *abci.RequestInitChain) (*abci.ResponseInitChain, error) {
	var genesisState GenesisState
	if err := json.Unmarshal(req.AppStateBytes, &genesisState); err != nil {
		panic(err)
	}
	if err := app.UpgradeKeeper.SetModuleVersionMap(ctx, app.ModuleManager.GetVersionMap()); err != nil {
		panic(err)
	}
	return app.ModuleManager.InitGenesis(ctx, app.appCodec, genesisState)
}

func (app *SandboxApp) Configurator() module.Configurator { return app.configurator }
func (app *SandboxApp) Name() string                      { return app.BaseApp.Name() }
func (app *SandboxApp) LegacyAmino() *codec.LegacyAmino   { return app.legacyAmino }
func (app *SandboxApp) AppCodec() codec.Codec              { return app.appCodec }
func (app *SandboxApp) InterfaceRegistry() types.InterfaceRegistry {
	return app.interfaceRegistry
}
func (app *SandboxApp) TxConfig() client.TxConfig  { return app.txConfig }
func (app *SandboxApp) LoadHeight(h int64) error    { return app.LoadVersion(h) }
func (app *SandboxApp) GetKey(s string) *storetypes.KVStoreKey { return app.keys[s] }
func (app *SandboxApp) GetMempool() sdkmempool.ExtMempool       { return app.EVMMempool }
func (app *SandboxApp) GetAnteHandler() sdk.AnteHandler          { return app.BaseApp.AnteHandler() }

func (app *SandboxApp) DefaultGenesis() map[string]json.RawMessage {
	genesis := app.BasicModuleManager.DefaultGenesis(app.appCodec)
	evmGenState := NewEVMGenesisState()
	genesis[evmtypes.ModuleName] = app.appCodec.MustMarshalJSON(evmGenState)
	return genesis
}

// ---------- handlers ----------

func (app *SandboxApp) setAnteHandler(txConfig client.TxConfig, maxGasWanted uint64) {
	options := evmante.HandlerOptions{
		Cdc:                    app.appCodec,
		AccountKeeper:          app.AccountKeeper,
		BankKeeper:             app.BankKeeper,
		ExtensionOptionChecker: antetypes.HasDynamicFeeExtensionOption,
		EvmKeeper:              app.EVMKeeper,
		IBCKeeper:              app.IBCKeeper,
		FeeMarketKeeper:        app.FeeMarketKeeper,
		SignModeHandler:        txConfig.SignModeHandler(),
		SigGasConsumer:         evmante.SigVerificationGasConsumer,
		MaxTxGasWanted:         maxGasWanted,
		DynamicFeeChecker:      true,
		PendingTxListener:      app.onPendingTx,
	}
	if err := options.Validate(); err != nil {
		panic(err)
	}
	app.SetAnteHandler(evmante.NewAnteHandler(options))
}

func (app *SandboxApp) onPendingTx(hash common.Hash) {
	for _, l := range app.pendingTxListeners {
		l(hash)
	}
}

func (app *SandboxApp) RegisterPendingTxListener(l func(common.Hash)) {
	app.pendingTxListeners = append(app.pendingTxListeners, l)
}

func (app *SandboxApp) setPostHandler() {
	postHandler, err := posthandler.NewPostHandler(posthandler.HandlerOptions{})
	if err != nil {
		panic(err)
	}
	app.SetPostHandler(postHandler)
}

// ---------- EVM mempool (simplified: default non-exclusive mode) ----------

func (app *SandboxApp) configureEVMMempool(appOpts servertypes.AppOptions, logger log.Logger) error {
	if evmtypes.GetChainConfig() == nil {
		return nil
	}
	cosmosPoolMaxTx := cosmosevmserver.GetCosmosPoolMaxTx(appOpts, logger)
	if cosmosPoolMaxTx < 0 {
		return nil
	}

	evmMempool := evmmempool.NewExperimentalEVMMempool(
		app.CreateQueryContext,
		logger,
		app.EVMKeeper,
		app.FeeMarketKeeper,
		app.txConfig,
		&evmmempool.EVMMempoolConfig{
			AnteHandler:      app.BaseApp.AnteHandler(),
			LegacyPoolConfig: cosmosevmserver.GetLegacyPoolConfig(appOpts, logger),
			BlockGasLimit:    cosmosevmserver.GetBlockGasLimit(appOpts, logger),
			MinTip:           cosmosevmserver.GetMinTip(appOpts, logger),
		},
		cosmosPoolMaxTx,
	)

	app.SetCheckTxHandler(evmmempool.NewCheckTxHandler(evmMempool))
	abciProposalHandler := baseapp.NewDefaultProposalHandler(evmMempool, app)
	abciProposalHandler.SetSignerExtractionAdapter(
		evmmempool.NewEthSignerExtractionAdapter(sdkmempool.NewDefaultSignerExtractionAdapter()),
	)
	app.SetPrepareProposal(abciProposalHandler.PrepareProposalHandler())
	app.EVMMempool = evmMempool
	app.SetMempool(evmMempool)
	return nil
}

// ---------- gRPC/REST registration ----------

func (app *SandboxApp) RegisterAPIRoutes(apiSvr *api.Server, apiConfig config.APIConfig) {
	clientCtx := apiSvr.ClientCtx
	authtx.RegisterGRPCGatewayRoutes(clientCtx, apiSvr.GRPCGatewayRouter)
	cmtservice.RegisterGRPCGatewayRoutes(clientCtx, apiSvr.GRPCGatewayRouter)
	node.RegisterGRPCGatewayRoutes(clientCtx, apiSvr.GRPCGatewayRouter)
	app.BasicModuleManager.RegisterGRPCGatewayRoutes(clientCtx, apiSvr.GRPCGatewayRouter)
	if err := sdkserver.RegisterSwaggerAPI(apiSvr.ClientCtx, apiSvr.Router, apiConfig.Swagger); err != nil {
		panic(err)
	}
}
func (app *SandboxApp) RegisterTxService(clientCtx client.Context) {
	authtx.RegisterTxService(app.GRPCQueryRouter(), clientCtx, app.Simulate, app.interfaceRegistry)
}
func (app *SandboxApp) RegisterTendermintService(clientCtx client.Context) {
	cmtservice.RegisterTendermintService(clientCtx, app.GRPCQueryRouter(), app.interfaceRegistry, app.Query)
}
func (app *SandboxApp) RegisterNodeService(clientCtx client.Context, cfg config.Config) {
	node.RegisterNodeService(clientCtx, app.GRPCQueryRouter(), cfg, func() int64 {
		return app.CommitMultiStore().EarliestVersion()
	})
}

func (app *SandboxApp) AutoCliOpts() autocli.AppOptions {
	modules := make(map[string]appmodule.AppModule)
	for _, m := range app.ModuleManager.Modules {
		if mn, ok := m.(module.HasName); ok {
			if am, ok := mn.(appmodule.AppModule); ok {
				modules[mn.Name()] = am
			}
		}
	}
	return autocli.AppOptions{
		Modules:               modules,
		ModuleOptions:         runtimeservices.ExtractAutoCLIOptions(app.ModuleManager.Modules),
		AddressCodec:          evmaddress.NewEvmCodec(sdk.GetConfig().GetBech32AccountAddrPrefix()),
		ValidatorAddressCodec: evmaddress.NewEvmCodec(sdk.GetConfig().GetBech32ValidatorAddrPrefix()),
		ConsensusAddressCodec: evmaddress.NewEvmCodec(sdk.GetConfig().GetBech32ConsensusAddrPrefix()),
	}
}

func (app *SandboxApp) Close() error {
	var err error
	if m, ok := app.EVMMempool.(*evmmempool.ExperimentalEVMMempool); ok && m != nil {
		err = m.Close()
	}
	return errors.Join(err, app.BaseApp.Close())
}

// ---------- helpers ----------

func blockedAddresses() map[string]bool {
	blocked := make(map[string]bool)
	for acc := range maccPerms {
		blocked[authtypes.NewModuleAddress(acc).String()] = true
	}
	return blocked
}

// =====================================================================
// Root command (placed here to keep the cmd/ package thin)
// =====================================================================

func NewRootCmd(defaultNodeHome string) *cobra.Command {
	tempApp := NewApp(log.NewNopLogger(), dbm.NewMemDB(), nil, true, simtestutil.EmptyAppOptions{})

	encodingConfig := sdktestutil.TestEncodingConfig{
		InterfaceRegistry: tempApp.InterfaceRegistry(),
		Codec:             tempApp.AppCodec(),
		TxConfig:          tempApp.TxConfig(),
		Amino:             tempApp.LegacyAmino(),
	}
	initClientCtx := client.Context{}.
		WithCodec(encodingConfig.Codec).
		WithInterfaceRegistry(encodingConfig.InterfaceRegistry).
		WithTxConfig(encodingConfig.TxConfig).
		WithLegacyAmino(encodingConfig.Amino).
		WithInput(os.Stdin).
		WithAccountRetriever(authtypes.AccountRetriever{}).
		WithBroadcastMode(flags.FlagBroadcastMode).
		WithHomeDir(defaultNodeHome).
		WithViper("").
		WithKeyringOptions(hd.EthSecp256k1Option()).
		WithLedgerHasProtobuf(true)

	rootCmd := &cobra.Command{
		Use:   appName,
		Short: "Sandbox POA+EVM chain",
		PersistentPreRunE: func(cmd *cobra.Command, _ []string) error {
			cmd.SetOut(cmd.OutOrStdout())
			cmd.SetErr(cmd.ErrOrStderr())

			initClientCtx = initClientCtx.WithCmdContext(cmd.Context())
			initClientCtx, err := client.ReadPersistentCommandFlags(initClientCtx, cmd.Flags())
			if err != nil {
				return err
			}
			initClientCtx, err = clientcfg.ReadFromClientConfig(initClientCtx)
			if err != nil {
				return err
			}
			if !initClientCtx.Offline {
				enabledSignModes := append(authtx.DefaultSignModes, signingtypes.SignMode_SIGN_MODE_TEXTUAL) //nolint:gocritic
				txCfgOpts := authtx.ConfigOptions{
					EnabledSignModes:           enabledSignModes,
					TextualCoinMetadataQueryFn: txmodule.NewGRPCCoinMetadataQueryFn(initClientCtx),
				}
				txCfg, err := authtx.NewTxConfigWithOptions(initClientCtx.Codec, txCfgOpts)
				if err != nil {
					return err
				}
				initClientCtx = initClientCtx.WithTxConfig(txCfg)
			}
			if err := client.SetCmdClientContextHandler(initClientCtx, cmd); err != nil {
				return err
			}

			customAppTemplate, customAppConfig := evmconfig.InitAppConfig(evmtypes.DefaultEVMExtendedDenom, evmtypes.DefaultEVMChainID)
			customTMConfig := initCometConfig()
			return sdkserver.InterceptConfigsPreRunHandler(cmd, customAppTemplate, customAppConfig, customTMConfig)
		},
	}

	initRootCmd(rootCmd, tempApp, defaultNodeHome)

	autoCliOpts := tempApp.AutoCliOpts()
	initClientCtx, _ = clientcfg.ReadFromClientConfig(initClientCtx)
	autoCliOpts.ClientCtx = initClientCtx
	if err := autoCliOpts.EnhanceRootCommand(rootCmd); err != nil {
		panic(err)
	}

	return rootCmd
}

func initCometConfig() *cmtcfg.Config { return cmtcfg.DefaultConfig() }

func initRootCmd(rootCmd *cobra.Command, sandboxApp *SandboxApp, defaultNodeHome string) {
	cfg := sdk.GetConfig()
	cfg.Seal()

	sdkAppCreator := servertypes.AppCreator(func(l log.Logger, d dbm.DB, ao servertypes.AppOptions) servertypes.Application {
		return NewApp(l, d, nil, true, ao)
	})
	rootCmd.AddCommand(
		genutilcli.InitCmd(sandboxApp.BasicModuleManager, defaultNodeHome),
		genutilcli.Commands(sandboxApp.TxConfig(), sandboxApp.BasicModuleManager, defaultNodeHome),
		cmtcli.NewCompletionCmd(rootCmd, true),
		evmdebug.Cmd(),
		confixcmd.ConfigCommand(),
		pruning.Cmd(sdkAppCreator, defaultNodeHome),
		snapshot.Cmd(sdkAppCreator),
	)

	cosmosevmserver.AddCommands(
		rootCmd,
		cosmosevmserver.NewDefaultStartOptions(newApp, defaultNodeHome),
		appExport,
		func(_ *cobra.Command) {},
	)

	rootCmd.AddCommand(
		cosmosevmcmd.KeyCommands(defaultNodeHome, true),
		sdkserver.StatusCommand(),
		queryCommand(),
		txCommand(),
	)

	var err error
	_, err = srvflags.AddTxFlags(rootCmd)
	if err != nil {
		panic(err)
	}
}

func queryCommand() *cobra.Command {
	cmd := &cobra.Command{
		Use:                        "query",
		Aliases:                    []string{"q"},
		Short:                      "Querying subcommands",
		DisableFlagParsing:         false,
		SuggestionsMinimumDistance: 2,
		RunE:                       client.ValidateCmd,
	}
	cmd.AddCommand(
		rpc.QueryEventForTxCmd(),
		rpc.ValidatorCommand(),
		authcmd.QueryTxsByEventsCmd(),
		authcmd.QueryTxCmd(),
		sdkserver.QueryBlockCmd(),
		sdkserver.QueryBlockResultsCmd(),
	)
	cmd.PersistentFlags().String(flags.FlagChainID, "", "The network chain ID")
	return cmd
}

func txCommand() *cobra.Command {
	cmd := &cobra.Command{
		Use:                        "tx",
		Short:                      "Transactions subcommands",
		DisableFlagParsing:         false,
		SuggestionsMinimumDistance: 2,
		RunE:                       client.ValidateCmd,
	}
	cmd.AddCommand(
		authcmd.GetSignCommand(),
		authcmd.GetSignBatchCommand(),
		authcmd.GetMultiSignCommand(),
		authcmd.GetMultiSignBatchCmd(),
		authcmd.GetValidateSignaturesCommand(),
		authcmd.GetBroadcastCommand(),
		authcmd.GetEncodeCommand(),
		authcmd.GetDecodeCommand(),
		authcmd.GetSimulateCmd(),
	)
	cmd.PersistentFlags().String(flags.FlagChainID, "", "The network chain ID")
	return cmd
}

// newApp creates the application for the server start command.
func newApp(
	logger log.Logger,
	db dbm.DB,
	appOpts servertypes.AppOptions,
) cosmosevmserver.Application {
	return NewApp(logger, db, nil, true, appOpts)
}

// appExport creates a new app and exports state.
func appExport(
	logger log.Logger,
	db dbm.DB,
	height int64,
	forZeroHeight bool,
	jailAllowedAddrs []string,
	appOpts servertypes.AppOptions,
	modulesToExport []string,
) (servertypes.ExportedApp, error) {
	viperAppOpts, ok := appOpts.(*viper.Viper)
	if !ok {
		return servertypes.ExportedApp{}, errors.New("appOpts is not viper.Viper")
	}
	viperAppOpts.Set(sdkserver.FlagInvCheckPeriod, 1)
	appOpts = viperAppOpts

	var a *SandboxApp
	if height != -1 {
		a = NewApp(logger, db, nil, false, appOpts)
		if err := a.LoadHeight(height); err != nil {
			return servertypes.ExportedApp{}, err
		}
	} else {
		a = NewApp(logger, db, nil, true, appOpts)
	}
	return a.ExportAppStateAndValidators(forZeroHeight, jailAllowedAddrs, modulesToExport)
}

