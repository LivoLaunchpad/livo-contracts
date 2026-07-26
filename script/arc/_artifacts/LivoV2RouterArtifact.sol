// SPDX-License-Identifier: MIT
pragma solidity =0.6.6;

// Compile-anchor for the vendored LivoUniswapV2Router02 (0.6.6, patched pair init-code-hash), mirroring
// V2RouterArtifact.sol for the stock router. `forge build` emits its artifact to out/ so the sparse
// `forge script` compile in DeployUniswapArc / DeployUniswapV2RouterArc / VerifyV2GraduationArc can
// resolve `deployCode("out/LivoUniswapV2Router02.sol/...")`.
import "script/arc/vendored/LivoUniswapV2Router02.sol";
