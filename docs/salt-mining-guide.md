# Salt Mining Guide: Computing Valid Token Addresses

## Overview

The Livo factories deploy tokens using `Clones.cloneDeterministic()` (CREATE2 under the hood). The factory enforces that every token address must end in `0x1110` (last 2 bytes). The frontend/backend must pre-compute a valid `salt` before calling `createToken()`.

## How CREATE2 Addresses Work

The deployed address is deterministic, computed as:

```
address = keccak256(0xff ++ deployer ++ salt ++ keccak256(initcode))[12:]
```

Three factors control the final address:

| Factor | Value | Variable? |
|--------|-------|-----------|
| `deployer` | Factory contract address | Fixed per factory |
| `salt` | `bytes32` passed to `createToken()` | User-controlled |
| `initcode` | ERC-1167 minimal proxy bytecode (depends on `TOKEN_IMPLEMENTATION`) | Fixed per factory |

Since `deployer` and `initcode` are fixed for a given factory deployment, **the only variable is `salt`**.

## The Initcode

The ERC-1167 minimal proxy initcode is 55 bytes, deterministic given the implementation address:

```
0x3d602d80600a3d3981f3363d3d373d3d3d363d73
  <20-byte TOKEN_IMPLEMENTATION address>
0x5af43d82803e903d91602b57fd5bf3
```

This is the bytecode that CREATE2 hashes. It comes directly from [OpenZeppelin's Clones.sol](https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/proxy/Clones.sol).

### Example: `LivoFactory (V2)` on Sepolia

Using `LivoFactory (V2)` at `0x4b092C01952d8e87bd0eAEdc28737d0154619e8C` with `TOKEN_IMPLEMENTATION` (`LivoToken`) at `0xDF1F1EfFb7733fA17090aFE2A86034CED186DeEa`:

```
initcode (55 bytes):
  3d602d80600a3d3981f3363d3d373d3d3d363d73   ← ERC-1167 prefix (20 bytes, fixed)
  DF1F1EfFb7733fA17090aFE2A86034CED186DeEa   ← TOKEN_IMPLEMENTATION address (20 bytes)
  5af43d82803e903d91602b57fd5bf3               ← ERC-1167 suffix (15 bytes, fixed)

initcodeHash = keccak256(initcode)
```

Then the CREATE2 address is derived from:

```
keccak256(
  0xff                                                               ← fixed prefix (1 byte)
  4b092C01952d8e87bd0eAEdc28737d0154619e8C                           ← deployer: LivoFactory V2 (20 bytes)
  <salt>                                                             ← the bytes32 salt you're brute-forcing (32 bytes)
  keccak256(3d...73 DF1F...DeEa 5af4...5bf3)                        ← initcodeHash (32 bytes)
)[12:]                                                               ← take last 20 bytes = address
```

For `LivoFactoryTaxToken (V4)` at `0x5ba05f2326e73D46d66bf80aF43a768CEd2e4a5d`, the same logic applies but using `LivoTaxableTokenUniV4` (`0x167a40f0C706381D5Ead24802c49cfD408B75aDd`) as the implementation — which produces a **different `initcodeHash`**.

## The Constraint

Both `LivoFactoryBase` and `LivoFactoryTaxToken` enforce:

```solidity
require(uint16(uint160(token)) == 0x1110, InvalidTokenAddress());
```

This means the last 2 bytes of the token address must be `0x1110`. Statistically, **1 in 65,536 salts** will produce a valid address, so brute-forcing is near-instant.

## Implementation (TypeScript with viem)

```typescript
import { getCreate2Address, keccak256, concat, toHex, pad } from "viem";

// These are fixed per factory deployment — read from your config/env
const FACTORY_ADDRESS = "0x...";
const TOKEN_IMPLEMENTATION = "0x...";

// Compute initcode hash once (constant for a given factory)
const initcode = concat([
  "0x3d602d80600a3d3981f3363d3d373d3d3d363d73",
  TOKEN_IMPLEMENTATION as `0x${string}`,
  "0x5af43d82803e903d91602b57fd5bf3",
]);
const INITCODE_HASH = keccak256(initcode);

/**
 * Finds a salt that produces a token address ending in 0x1110.
 * Typically completes in < 100ms (brute-forces ~65k iterations on average).
 */
function findValidSalt(): { salt: `0x${string}`; tokenAddress: string } {
  for (let i = 0n; ; i++) {
    const salt = pad(toHex(i), { size: 32 });

    const addr = getCreate2Address({
      from: FACTORY_ADDRESS as `0x${string}`,
      salt,
      bytecodeHash: INITCODE_HASH,
    });

    if (addr.toLowerCase().endsWith("1110")) {
      return { salt, tokenAddress: addr };
    }
  }
}
```

## Implementation (TypeScript with ethers v6)

```typescript
import { ethers } from "ethers";

const FACTORY_ADDRESS = "0x...";
const TOKEN_IMPLEMENTATION = "0x...";

const initcode = ethers.concat([
  "0x3d602d80600a3d3981f3363d3d373d3d3d363d73",
  TOKEN_IMPLEMENTATION,
  "0x5af43d82803e903d91602b57fd5bf3",
]);
const INITCODE_HASH = ethers.keccak256(initcode);

function findValidSalt(): { salt: string; tokenAddress: string } {
  for (let i = 0n; ; i++) {
    const salt = ethers.zeroPadValue(ethers.toBeHex(i), 32);
    const addr = ethers.getCreate2Address(FACTORY_ADDRESS, salt, INITCODE_HASH);

    if (addr.toLowerCase().endsWith("1110")) {
      return { salt, tokenAddress: addr };
    }
  }
}
```

## Important Notes

- **`INITCODE_HASH` is constant** for a given factory — compute it once at startup, not per call.
- **Different factories have different `TOKEN_IMPLEMENTATION` addresses**, so the initcode hash differs between `LivoFactoryBase` and `LivoFactoryTaxToken`. Make sure you use the right implementation address for the factory you're calling.
- **Salt uniqueness**: each salt can only be used once per factory. If a salt has already been used (token deployed), `create2` will revert. If you need to handle retries, start iterating from a random offset.
- **On-chain verification**: you can call `Clones.predictDeterministicAddress(implementation, salt, factory)` via a static call to double-check your off-chain computation before submitting.
