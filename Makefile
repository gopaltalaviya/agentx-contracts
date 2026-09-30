.PHONY: help install build test test-ci coverage snapshot snapshot-check fmt lint drift export \
        deploy deploy-local deploy-testnet deploy-mainnet verify-erc8004 publish clean

# Network alias from foundry.toml [rpc_endpoints]. One deploy target,
# parameterised — not one target per network that drifts apart.
NETWORK ?= monad_testnet

help:
	@echo "AGENTX contracts"
	@echo ""
	@echo "  make install          install deps (forge-std, openzeppelin)"
	@echo "  make build            compile"
	@echo "  make test             run tests"
	@echo "  make test-ci          tests with CI profile (10k fuzz runs)"
	@echo "  make coverage         coverage summary"
	@echo "  make snapshot         gas snapshot"
	@echo "  make fmt              format"
	@echo "  make verify-erc8004   probe the ERC-8004 registries on both networks"
	@echo "  make drift            deployed params vs config/params.<chainId>.json"
	@echo "  make export           ABIs + config -> export/ for @agentx/contracts"
	@echo ""
	@echo "  make deploy-local     -> anvil"
	@echo "  make deploy-testnet   -> Monad testnet (10143)"
	@echo "  make deploy-mainnet   -> Monad mainnet (143), requires confirmation"

# The libraries are git submodules pinned to exact commits (forge-std v1.9.4,
# OpenZeppelin v5.0.2). `forge install --no-git` ignored those pins.
install:
	git submodule update --init --recursive

build:
	forge build

test:
	forge test -vvv

test-ci:
	FOUNDRY_PROFILE=ci forge test -vvv

# --ir-minimum is REQUIRED, not a preference.
#
# forge coverage turns viaIR off for accurate line mapping, and this project
# cannot compile without it — ERC-8004's 11-argument NewFeedback event blows
# the stack. Without this flag the command fails with "Stack too deep", which
# is what it had been doing here and in CI.
coverage:
	forge coverage --ir-minimum --report summary --report lcov
	node scripts/check-coverage.mjs lcov.info

# Deterministic tests only: fuzz and invariant gas varies with the seed.
SNAPSHOT_FILTER = --no-match-test "testFuzz|invariant" --no-match-path "test/invariant/*"

snapshot:
	forge snapshot $(SNAPSHOT_FILTER)

snapshot-check:
	forge snapshot --check $(SNAPSHOT_FILTER)

fmt:
	forge fmt

lint:
	forge fmt --check
	npx --yes solhint@5.0.5 "src/**/*.sol"
	slither . --config-file slither.config.json --fail-medium

secrets:
	node scripts/check-no-secrets.mjs

verify-erc8004:
	node scripts/verify-erc8004.mjs

drift:
	node scripts/check-param-drift.mjs $(NETWORK)

export:
	node scripts/export-abis.mjs

# Verification is opt-in (VERIFY=1). Explorer verifiers reject or rate-limit
# often, and a failed verify must not look like a failed deploy — the
# contracts are already on-chain by then. Verify afterwards with `make verify`.
VERIFY_FLAG := $(if $(VERIFY),--verify,)

deploy:
	forge script script/Deploy.s.sol:Deploy --rpc-url $(NETWORK) --broadcast $(VERIFY_FLAG) -vvv
	node scripts/write-deployment.mjs $(NETWORK)

verify:
	forge script script/Deploy.s.sol:Deploy --rpc-url $(NETWORK) --verify --resume

deploy-local:
	$(MAKE) deploy NETWORK=anvil

deploy-testnet:
	$(MAKE) deploy NETWORK=monad_testnet

# A wrong NETWORK is one character away from a real-money mistake.
deploy-mainnet:
	@echo "*** MAINNET DEPLOY (Monad, chain 143) ***"
	@echo "Type the chain id to confirm:"
	@read -r c; [ "$$c" = "143" ] || { echo "aborted"; exit 1; }
	$(MAKE) deploy NETWORK=monad

publish:
	$(MAKE) export
	cd export && npm version patch && npm publish

clean:
	forge clean
	rm -rf export
