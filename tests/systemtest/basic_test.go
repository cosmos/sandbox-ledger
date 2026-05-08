//go:build systemtest

package systemtest

import (
	"context"
	"crypto/ecdsa"
	"math/big"
	"testing"
	"time"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core/types"
	"github.com/ethereum/go-ethereum/crypto"
	"github.com/ethereum/go-ethereum/ethclient"
)

func dial(t *testing.T) *ethclient.Client {
	t.Helper()
	c, err := ethclient.Dial(JSONRPCURL)
	if err != nil {
		t.Fatalf("dial JSON-RPC: %v", err)
	}
	t.Cleanup(c.Close)
	return c
}

// TestEVMChainID asserts the running chain reports the configured EVM
// chain id. Catches drift between local-node.sh's --evm.evm-chain-id and
// what the binary actually exposes.
func TestEVMChainID(t *testing.T) {
	c := dial(t)
	cid, err := c.ChainID(t.Context())
	if err != nil {
		t.Fatalf("ChainID: %v", err)
	}
	if cid.Int64() != EVMChainID {
		t.Fatalf("EVM chain id = %d, want %d", cid.Int64(), EVMChainID)
	}
}

// TestChainProducesBlocks asserts the chain is alive — block height
// advances by at least 3 within 30s. With CometBFT's default ~1s block
// time this should land in 3-4s; the wide budget tolerates slow CI.
func TestChainProducesBlocks(t *testing.T) {
	c := dial(t)
	ctx := t.Context()

	start, err := c.BlockNumber(ctx)
	if err != nil {
		t.Fatalf("BlockNumber: %v", err)
	}
	t.Logf("starting at block %d", start)

	deadline := time.Now().Add(30 * time.Second)
	for time.Now().Before(deadline) {
		h, err := c.BlockNumber(ctx)
		if err != nil {
			t.Fatalf("BlockNumber poll: %v", err)
		}
		if h >= start+3 {
			t.Logf("advanced to block %d", h)
			return
		}
		time.Sleep(500 * time.Millisecond)
	}
	t.Fatal("chain did not advance 3 blocks within 30s")
}

// TestValidatorHasGenesisBalance asserts that the validator's EVM-derived
// address was funded in genesis with non-zero balance — the same address
// that signs blocks (POA validator) is also the gas payer for any tx the
// sandbox backend submits.
func TestValidatorHasGenesisBalance(t *testing.T) {
	c := dial(t)

	val, err := crypto.HexToECDSA(ValidatorPrivHex)
	if err != nil {
		t.Fatal(err)
	}
	addr := crypto.PubkeyToAddress(val.PublicKey)

	bal, err := c.BalanceAt(t.Context(), addr, nil)
	if err != nil {
		t.Fatalf("BalanceAt: %v", err)
	}
	if bal.Sign() <= 0 {
		t.Fatalf("validator %s has zero balance — genesis allocation broken", addr.Hex())
	}
	t.Logf("validator %s balance = %s %s", addr.Hex(), bal, NativeDenom)
}

// TestNativeEVMTransfer signs an EIP-1559 native-token transfer from the
// validator (genesis-funded) to user-1 (also genesis-funded — but we
// don't rely on user-1's prior balance) and asserts the recipient's
// balance increased by exactly the sent amount.
//
// This is the smallest end-to-end exercise of the EVM module: tx pool
// admit, block inclusion, state transition, balance read.
func TestNativeEVMTransfer(t *testing.T) {
	c := dial(t)
	ctx := t.Context()

	from, fromAddr := mustKey(t, ValidatorPrivHex)
	_, toAddr := mustKey(t, User2PrivHex)

	// Capture recipient's pre-balance so the assertion is delta-based and
	// doesn't depend on whether previous tests already credited them.
	preBal, err := c.BalanceAt(ctx, toAddr, nil)
	if err != nil {
		t.Fatalf("pre BalanceAt: %v", err)
	}

	nonce, err := c.PendingNonceAt(ctx, fromAddr)
	if err != nil {
		t.Fatalf("PendingNonceAt: %v", err)
	}
	gasTip, err := c.SuggestGasTipCap(ctx)
	if err != nil {
		t.Fatalf("SuggestGasTipCap: %v", err)
	}
	head, err := c.HeaderByNumber(ctx, nil)
	if err != nil {
		t.Fatalf("HeaderByNumber: %v", err)
	}
	gasFeeCap := new(big.Int).Add(gasTip, new(big.Int).Mul(head.BaseFee, big.NewInt(2)))
	amount := big.NewInt(1_000_000_000_000_000) // 0.001 token in 18-decimal units

	tx := types.NewTx(&types.DynamicFeeTx{
		ChainID:   big.NewInt(EVMChainID),
		Nonce:     nonce,
		GasTipCap: gasTip,
		GasFeeCap: gasFeeCap,
		Gas:       21_000,
		To:        &toAddr,
		Value:     amount,
	})
	signed, err := types.SignTx(tx, types.LatestSignerForChainID(big.NewInt(EVMChainID)), from)
	if err != nil {
		t.Fatalf("SignTx: %v", err)
	}
	if err := c.SendTransaction(ctx, signed); err != nil {
		t.Fatalf("SendTransaction: %v", err)
	}
	t.Logf("submitted tx %s", signed.Hash().Hex())

	receipt := waitForReceipt(t, c, signed.Hash(), 30*time.Second)
	if receipt.Status != 1 {
		t.Fatalf("tx reverted; status=%d", receipt.Status)
	}

	postBal, err := c.BalanceAt(ctx, toAddr, nil)
	if err != nil {
		t.Fatalf("post BalanceAt: %v", err)
	}
	delta := new(big.Int).Sub(postBal, preBal)
	if delta.Cmp(amount) != 0 {
		t.Fatalf("recipient delta = %s, want %s", delta, amount)
	}
}

func mustKey(t *testing.T, hex string) (*ecdsa.PrivateKey, common.Address) {
	t.Helper()
	k, err := crypto.HexToECDSA(hex)
	if err != nil {
		t.Fatal(err)
	}
	return k, crypto.PubkeyToAddress(k.PublicKey)
}

func waitForReceipt(t *testing.T, c *ethclient.Client, hash common.Hash, timeout time.Duration) *types.Receipt {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		ctx, cancel := context.WithTimeout(t.Context(), 2*time.Second)
		r, err := c.TransactionReceipt(ctx, hash)
		cancel()
		if err == nil {
			return r
		}
		time.Sleep(500 * time.Millisecond)
	}
	t.Fatalf("no receipt for %s after %s", hash.Hex(), timeout)
	return nil
}
