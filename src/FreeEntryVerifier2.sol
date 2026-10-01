// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

/// @title  FreeEntryVerifier2
/// @notice EIP-712 signature verifier for free raffle entries.
///         Validates backend-signed free entry claims and prevents double-claiming.
/// @dev    Abstract — must be inherited by a contract that provides owner-gated
///         access control (e.g. RaffleManager5 via ConfirmedOwner).
///         Fixes vs FreeEntryVerifier:
///           1. verifyAndClaim is internal (prevents front-running griefing)
///           2. verifierOwner removed — single ownership via child's owner()
///           3. setTrustedSigner is internal _setTrustedSigner — child exposes with access control
abstract contract FreeEntryVerifier2 is EIP712("LotteryCore", "1") {
    using ECDSA for bytes32;

    // ── State ────────────────────────────────────────────────────────────
    address public trustedSigner;

    /// @notice Tracks which users have already claimed free entry per raffle.
    mapping(uint256 => mapping(address => bool)) public freeEntryClaimed;

    // ── Errors ───────────────────────────────────────────────────────────
    error InvalidSigner();
    error AlreadyClaimed();

    // ── Events ───────────────────────────────────────────────────────────
    event FreeEntryClaimed(uint256 raffleId, address user, address signer);
    event TrustedSignerUpdated(address oldSigner, address newSigner);

    // ── Type hash (matches backend) ──────────────────────────────────────
    bytes32 private constant FREE_ENTRY_TYPEHASH = keccak256("FreeEntry(uint256 raffleId,address user)");

    // ── Constructor ──────────────────────────────────────────────────────
    constructor(address _trustedSigner) {
        require(_trustedSigner != address(0), "Invalid signer");
        trustedSigner = _trustedSigner;
    }

    // ── Admin (internal — child must expose with access control) ─────────
    function _setTrustedSigner(address _newSigner) internal {
        require(_newSigner != address(0), "Invalid signer");
        emit TrustedSignerUpdated(trustedSigner, _newSigner);
        trustedSigner = _newSigner;
    }

    // ── Core verification logic ──────────────────────────────────────────
    /// @notice Verify EIP-712 signature and record free entry claim.
    /// @dev    Internal — only callable from enterFreeRaffle in the child contract.
    ///         External callers cannot burn signatures without entering the raffle.
    function verifyAndClaim(uint256 raffleId, address user, bytes calldata signature) internal returns (bool success) {
        if (freeEntryClaimed[raffleId][user]) revert AlreadyClaimed();

        bytes32 structHash = keccak256(abi.encode(FREE_ENTRY_TYPEHASH, raffleId, user));
        bytes32 digest = _hashTypedDataV4(structHash);

        address recovered = digest.recover(signature);
        if (recovered != trustedSigner) revert InvalidSigner();

        freeEntryClaimed[raffleId][user] = true;

        emit FreeEntryClaimed(raffleId, user, trustedSigner);
        return true;
    }

    // ── Views ────────────────────────────────────────────────────────────
    function computeDigest(uint256 raffleId, address user) external view returns (bytes32) {
        bytes32 structHash = keccak256(abi.encode(FREE_ENTRY_TYPEHASH, raffleId, user));
        return _hashTypedDataV4(structHash);
    }

    function recoverSigner(uint256 raffleId, address user, bytes calldata signature) external view returns (address) {
        bytes32 structHash = keccak256(abi.encode(FREE_ENTRY_TYPEHASH, raffleId, user));
        bytes32 digest = _hashTypedDataV4(structHash);
        return digest.recover(signature);
    }

    function isSignatureEligible(uint256 raffleId, address user, bytes calldata signature)
        external
        view
        returns (bool)
    {
        if (freeEntryClaimed[raffleId][user]) return false;

        bytes32 structHash = keccak256(abi.encode(FREE_ENTRY_TYPEHASH, raffleId, user));
        bytes32 digest = _hashTypedDataV4(structHash);
        address recovered = digest.recover(signature);
        return recovered == trustedSigner;
    }
}
