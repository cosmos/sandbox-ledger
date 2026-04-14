package app

import (
	errorsmod "cosmossdk.io/errors"

	cosmosante "github.com/cosmos/evm/ante/cosmos"
	evmante "github.com/cosmos/evm/ante/evm"
	evmantelib "github.com/cosmos/evm/ante"
	antetypes "github.com/cosmos/evm/ante/types"
	evmtypes "github.com/cosmos/evm/x/vm/types"
	ibcante "github.com/cosmos/ibc-go/v11/modules/core/ante"

	poatypes "github.com/cosmos/cosmos-sdk/enterprise/poa/x/poa/types"
	errortypes "github.com/cosmos/cosmos-sdk/types/errors"
	"github.com/cosmos/gogoproto/proto"

	sdk "github.com/cosmos/cosmos-sdk/types"
	"github.com/cosmos/cosmos-sdk/x/auth/ante"
	sdkvesting "github.com/cosmos/cosmos-sdk/x/auth/vesting/types"
)

// NewPOAEVMAnteHandler routes EVM and Cosmos SDK transactions to the
// appropriate sub-handler. Cosmos SDK transactions use a DeductFeeDecorator
// that sends fees to the POA module account.
func NewPOAEVMAnteHandler(options evmantelib.HandlerOptions) sdk.AnteHandler {
	extensionOptionsEthereumTx := "/" + proto.MessageName(&evmtypes.ExtensionOptionsEthereumTx{})
	extensionOptionsDynamicFeeTx := "/" + proto.MessageName(&antetypes.ExtensionOptionDynamicFeeTx{})

	return func(ctx sdk.Context, tx sdk.Tx, sim bool) (sdk.Context, error) {
		var anteHandler sdk.AnteHandler

		txWithExtensions, ok := tx.(ante.HasExtensionOptionsTx)
		if ok {
			opts := txWithExtensions.GetExtensionOptions()
			if len(opts) > 0 {
				switch typeURL := opts[0].GetTypeUrl(); typeURL {
				case extensionOptionsEthereumTx:
					anteHandler = newEVMAnteHandler(ctx, options)
				case extensionOptionsDynamicFeeTx:
					anteHandler = newPOACosmosAnteHandler(ctx, options)
				default:
					return ctx, errorsmod.Wrapf(
						errortypes.ErrUnknownExtensionOptions,
						"rejecting tx with unsupported extension option: %s", typeURL,
					)
				}
				return anteHandler(ctx, tx, sim)
			}
		}

		switch tx.(type) {
		case sdk.Tx:
			anteHandler = newPOACosmosAnteHandler(ctx, options)
		default:
			return ctx, errorsmod.Wrapf(errortypes.ErrUnknownRequest, "invalid transaction type: %T", tx)
		}
		return anteHandler(ctx, tx, sim)
	}
}

// newEVMAnteHandler handles EVM (MsgEthereumTx) transactions.
func newEVMAnteHandler(ctx sdk.Context, options evmantelib.HandlerOptions) sdk.AnteHandler {
	evmParams := options.EvmKeeper.GetParams(ctx)
	feemarketParams := options.FeeMarketKeeper.GetParams(ctx)
	return sdk.ChainAnteDecorators(
		evmante.NewEVMMonoDecorator(
			options.AccountKeeper,
			options.FeeMarketKeeper,
			options.EvmKeeper,
			options.MaxTxGasWanted,
			&evmParams,
			&feemarketParams,
		),
		evmantelib.NewTxListenerDecorator(options.PendingTxListener),
	)
}

// newPOACosmosAnteHandler handles standard Cosmos SDK transactions with
// fees routed to the POA module account.
func newPOACosmosAnteHandler(ctx sdk.Context, options evmantelib.HandlerOptions) sdk.AnteHandler {
	feemarketParams := options.FeeMarketKeeper.GetParams(ctx)
	var txFeeChecker ante.TxFeeChecker
	if options.DynamicFeeChecker {
		txFeeChecker = evmante.NewDynamicFeeChecker(&feemarketParams)
	}

	return sdk.ChainAnteDecorators(
		cosmosante.NewRejectMessagesDecorator(),
		cosmosante.NewAuthzLimiterDecorator(
			sdk.MsgTypeURL(&evmtypes.MsgEthereumTx{}),
			sdk.MsgTypeURL(&sdkvesting.MsgCreateVestingAccount{}),
		),
		ante.NewSetUpContextDecorator(),
		ante.NewExtensionOptionsDecorator(options.ExtensionOptionChecker),
		ante.NewValidateBasicDecorator(),
		ante.NewTxTimeoutHeightDecorator(),
		ante.NewValidateMemoDecorator(options.AccountKeeper),
		cosmosante.NewMinGasPriceDecorator(&feemarketParams),
		ante.NewConsumeGasForTxSizeDecorator(options.AccountKeeper),
		ante.NewDeductFeeDecorator(options.AccountKeeper, options.BankKeeper, options.FeegrantKeeper, txFeeChecker).
			WithFeeRecipientModule(poatypes.ModuleName),
		ante.NewSetPubKeyDecorator(options.AccountKeeper),
		ante.NewValidateSigCountDecorator(options.AccountKeeper),
		ante.NewSigGasConsumeDecorator(options.AccountKeeper, options.SigGasConsumer),
		ante.NewSigVerificationDecorator(options.AccountKeeper, options.SignModeHandler),
		ante.NewIncrementSequenceDecorator(options.AccountKeeper),
		ibcante.NewRedundantRelayDecorator(options.IBCKeeper),
	)
}
