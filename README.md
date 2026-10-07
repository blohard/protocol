# blohard protocol

Contracts and spec for blohard, a message board whose posts live on chain.

Messages are small on-chain records: an author, a parent for replies, a timestamp and the hash of
the content, which lives off chain and is checked against that hash by every reader. Authors decide
who may reply through pluggable reply gates, can delete their own messages and remove direct
replies to them, and can have someone else pay their gas by signing.

You can try it at [blohard.social](https://blohard.social), which runs the reference client and
host on Base and Base Sepolia.

**[SPEC.md](SPEC.md)** is the specification: the `Board` contract's rules, reply gates, and the
content format every client and host agrees on.

## Contracts

| contract | what it does |
|---|---|
| [`Board`](src/Board.sol) | the core: posting, replies, reply gates, deletion and removal, signed writes. Immutable and ownerless |
| [`IBoard`](src/IBoard.sol) | its interface, events and errors |
| [`IReplyGate`](src/IReplyGate.sol) | the interface every reply gate implements |
| [`ListRegistry`](src/ListRegistry.sol) | named address lists, each written only by its owner |
| [`AuthorBlocklistGate`](src/ListGates.sol) | one shared gate that refuses repliers on the parent author's `blocked` list |
| [`BlocklistGate`](src/ListGates.sol) | a gate over one fixed list |
| [`ClosedReplyGate`](src/ClosedReplyGate.sol) | "no new replies" |

## Deployments

[`deployments.json`](deployments.json) has the live addresses and the block at which the Board was
deployed on each chain.

| | Base (8453) | Base Sepolia (84532) |
|---|---|---|
| `Board` | `0xca3E637985f1866b92e56fCf82Bae7cbf479c7Bf` | same |
| `ListRegistry` | `0x0aE4C0c4e9D17816C79AE140A6E3466ffC14b791` | same |
| `AuthorBlocklistGate` | `0x4A3206b83a43094F6E32d39f3D7a24B667fb86a8` | same |
| `ClosedReplyGate` | `0x82f6C7E5f9E64C7083162aBC22D71d8d394164AA` | `0x82f6C7E5f9E64C7083162aBC22D71d8d394164AA` |

Every contract is deployed with CREATE2 through the deterministic deployer proxy and a fixed salt,
so one version of the code has one address on every chain (SPEC.md §9). The compiler version and
settings are pinned in `foundry.toml`, and the bytecode carries no metadata hash, so an address
depends only on the source. A test checks every address in `deployments.json` against the code in
this repository: changing a contract moves its address, and the test fails until the file and the
deployment are updated together.

## Build and test

You need [Foundry](https://getfoundry.sh).

```sh
git clone --recurse-submodules https://github.com/blohard/protocol.git
cd protocol
forge build
forge test
```

The build treats compiler and lint warnings as errors. `forge fmt` keeps the formatting.

## Deploy

Each script finds the CREATE2 address first and reports an existing deployment instead of
repeating it, so running one again is harmless. Without `--broadcast` nothing is sent: a script
simulates the deployment and prints the address.

```sh
forge script script/Deploy.s.sol --rpc-url $RPC --broadcast --private-key $DEPLOYER_KEY
forge script script/DeployLists.s.sol --rpc-url $RPC --broadcast --private-key $DEPLOYER_KEY
BOARD=0x… REGISTRY=0x… forge script script/DeployGates.s.sol --rpc-url $RPC --broadcast --private-key $DEPLOYER_KEY
forge script script/DeployClosedGate.s.sol --rpc-url $RPC --broadcast --private-key $DEPLOYER_KEY
```

`DeployGates` deploys an `AuthorBlocklistGate` for the list named by `LIST_NAME`, `blocked` by
default.

## Keeping a list

A list in the `ListRegistry` belongs to the account that writes it, and its id is the keccak256
hash of its name. Foundry's `cast` is enough to keep one:

```sh
LIST=$(cast keccak blocked)

# add or remove addresses; $YOU must be the account that signs
cast send $REGISTRY "add(address,bytes32,address[])" $YOU $LIST "[0x…,0x…]" \
    --rpc-url $RPC --private-key $KEY
cast send $REGISTRY "remove(address,bytes32,address[])" $YOU $LIST "[0x…]" \
    --rpc-url $RPC --private-key $KEY

# is an address on the list?
cast call $REGISTRY "contains(address,bytes32,address)(bool)" $YOU $LIST 0x… --rpc-url $RPC
```

## License

[MIT](LICENSE)
