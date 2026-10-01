// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IQuiverConsumer} from "quiver/interfaces/IQuiverConsumer.sol";
import {QuiverStructs} from "quiver/libraries/QuiverStructs.sol";
import {
    ProviderNotRegistered,
    ProviderAlreadyRegistered,
    InvalidChainLength,
    ProviderChainExhausted,
    TooManyHashes,
    InsufficientFee,
    InsufficientAccruedFees,
    TransferFailed,
    NoSuchRequest,
    IncorrectUserRevelation,
    IncorrectProviderRevelation,
    RequestCallbackMismatch
} from "quiver/libraries/QuiverErrors.sol";

/// @notice Test-only keccak hash-chain helpers. `anchor(seed, len)` is the registered
///         commitment `keccak^len(seed)`; `revelation(seed, len, seq)` is the link the
///         provider reveals for 1-based sequence `seq` (walking backwards from the tip).
library MockQuiverHash {
    function hashChain(bytes32 seed, uint256 steps) internal pure returns (bytes32) {
        bytes32 h = seed;
        for (uint256 i = 0; i < steps; ++i) {
            h = keccak256(abi.encodePacked(h));
        }
        return h;
    }

    function anchor(bytes32 seed, uint64 len) internal pure returns (bytes32) {
        return hashChain(seed, len);
    }

    function revelation(bytes32 seed, uint64 len, uint64 seq) internal pure returns (bytes32) {
        require(seq <= len, "MockQuiverHash: seq out of range");
        return hashChain(seed, len - seq);
    }
}

/// @title  MockQuiverCoordinator
/// @notice A faithful-enough, test-owned stand-in for the live QuiverCoordinator on Robinhood
///         Chain (which has no public source / cannot be forked locally for unit tests).
///
/// @dev    Implements the semantics LotteryCore relies on:
///         - per-provider monotonic 1-based sequence numbers (getProviderSequenceNumber),
///         - fee quotes via getFee(provider) = providerFee + protocolFee,
///         - requestWithCallback (push) recording the user's commitment,
///         - revealWithCallback with real hash-chain verification — provider revelations are
///           checked by hashing them `seq - currentCommitmentSeq` times back to the provider's
///           current anchor, then the anchor is advanced to the revelation,
///         - a retry buffer (CallbackFailed) when the consumer callback reverts,
///         - retryCallback redelivery, pause (new requests blocked), fee accrual.
///
///         Test-only surfaces (clearly marked): seed-keyed provider registration so reveals
///         can be driven from the known seed; `setCallbackGas` to simulate a gas-capped
///         keeper; `setForcedRequestError` to simulate coordinator-side reverts
///         (Paused/ProviderChainExhausted/TooManyHashes/InsufficientFee); protocol-fee
///         control; `getConsumerSequence`/`reveal` convenience.
contract MockQuiverCoordinator {
    // ── Errors ─────────────────────────────────────────────────────────────
    error Paused();
    error ZeroAddress();
    error NotProviderOwner();
    error InvalidCallbackGas();

    struct ProviderRecord {
        address provider;
        bytes32 originalCommitment;
        bytes32 currentCommitment; // advanced forward as reveals land
        uint64 originalChainLength;
        uint64 currentCommitmentSequenceNumber; // last revealed seq (0 = none yet)
        uint64 sequenceNumber; // next seq to assign, 1-based, monotonic
        uint64 endSequenceNumber; // exclusive upper bound for assignable seqs
        uint64 maxNumHashes;
        uint128 feeInWei;
        uint128 accruedFeesInWei;
        bool registered;
        bytes32 seed; // TEST-ONLY: enables auto-reveal from the known seed
    }

    struct RequestRecord {
        address provider;
        uint64 sequenceNumber;
        bytes32 userCommitment; // keccak256(userRandomNumber)
        bytes32 providerCommitment; // anchor snapshot at request time (informational)
        address requester;
        bool isRequestWithCallback;
        bool revealed;
        bytes32 rawUserRandom; // TEST-ONLY: retained so auto-reveal can redeliver
    }

    struct FailedRecord {
        bytes32 randomNumber;
        address requester;
        bool exists;
    }

    // ── State ──────────────────────────────────────────────────────────────
    mapping(address => ProviderRecord) private _providers;
    mapping(address => mapping(uint64 => RequestRecord)) private _requests;
    mapping(address => mapping(uint64 => FailedRecord)) private _failedCallbacks;
    mapping(uint64 => address) public sequenceRequester; // TEST-ONLY: seq => requester (default provider space)

    bool public paused;
    uint128 public protocolFee;
    uint128 public accruedProtocolFees;

    uint256 public callbackGas; // TEST-ONLY: 0 = forward unrestricted
    bytes4 public forcedRequestError; // TEST-ONLY: 0x0 = none

    event RandomnessRequested(
        address indexed provider,
        address indexed requester,
        uint64 indexed sequenceNumber,
        bytes32 userContribution,
        uint32 numHashes,
        bool withCallback,
        bool useBlockhash
    );
    event RandomnessRevealed(
        address indexed provider,
        uint64 indexed sequenceNumber,
        address indexed requester,
        bytes32 randomNumber,
        bytes32 userRevelation,
        bytes32 providerRevelation
    );
    event CallbackSucceeded(
        address indexed provider, uint64 indexed sequenceNumber, address indexed requester, bytes32 randomNumber
    );
    event CallbackFailed(
        address indexed provider,
        uint64 indexed sequenceNumber,
        address indexed requester,
        bytes32 randomNumber,
        bytes reason
    );
    event ProtocolFeeUpdated(uint128 oldFeeInWei, uint128 newFeeInWei);
    event ProviderRegistered(
        address indexed provider, uint128 feeInWei, bytes32 commitment, uint64 chainLength, uint64 maxNumHashes
    );

    // ── Test-only registration & configuration ─────────────────────────────

    /// @notice TEST-ONLY. Register `provider` with a known seed so the mock can compute
    ///         revelations itself. Emulates `register()` + holding the chain secret.
    function registerProviderWithSeed(
        address provider,
        uint128 feeInWei,
        bytes32 seed,
        uint64 chainLength,
        uint64 maxNumHashes
    ) public returns (bytes32 commitment) {
        if (provider == address(0)) revert ZeroAddress();
        if (chainLength == 0) revert InvalidChainLength(chainLength);
        if (_providers[provider].registered) revert ProviderAlreadyRegistered(provider);
        commitment = MockQuiverHash.anchor(seed, chainLength);
        _providers[provider] = ProviderRecord({
            provider: provider,
            originalCommitment: commitment,
            currentCommitment: commitment,
            originalChainLength: chainLength,
            currentCommitmentSequenceNumber: 0,
            sequenceNumber: 1,
            endSequenceNumber: chainLength,
            maxNumHashes: maxNumHashes,
            feeInWei: feeInWei,
            accruedFeesInWei: 0,
            registered: true,
            seed: seed
        });
        emit ProviderRegistered(provider, feeInWei, commitment, chainLength, maxNumHashes);
    }

    /// @notice TEST-ONLY. Register a second provider (e.g. a fallback) — just seeds the
    ///         mapping with a distinct address.
    function registerSecondProvider(address provider, uint128 feeInWei, bytes32 seed, uint64 chainLength)
        external
        returns (bytes32 commitment)
    {
        return registerProviderWithSeed(provider, feeInWei, seed, chainLength, 32);
    }

    /// @notice TEST-ONLY. Forward-quote randomness from the default test provider.
    function setProtocolFee(uint128 newFee) external {
        emit ProtocolFeeUpdated(protocolFee, newFee);
        protocolFee = newFee;
    }

    /// @notice TEST-ONLY. Cap the gas forwarded to `quiverCallback` (keeper simulation).
    function setCallbackGas(uint256 gas) external {
        callbackGas = gas;
    }

    /// @notice TEST-ONLY. Force the next request(s) to revert with a 4-byte error selector.
    ///         Pass 0x0 to clear.
    function setForcedRequestError(bytes4 sel) external {
        forcedRequestError = sel;
    }

    /// @notice TEST-ONLY. Set the secret of an already-registered provider (rotation sim).
    function setProviderSecret(address provider, bytes32 seed, uint64 chainLength) external {
        ProviderRecord storage p = _providers[provider];
        if (!p.registered) revert ProviderNotRegistered(provider);
        bytes32 commitment = MockQuiverHash.anchor(seed, chainLength);
        p.originalCommitment = commitment;
        p.currentCommitment = commitment;
        p.originalChainLength = chainLength;
        p.endSequenceNumber = p.sequenceNumber + chainLength - 1;
        p.currentCommitmentSequenceNumber = p.sequenceNumber - 1;
        p.seed = seed;
    }

    // ── IQuiverCoordinator: provider management ────────────────────────────

    /// @notice Register `msg.sender` as a provider with an externally-computed commitment.
    ///         The mock cannot auto-reveal for such providers (no secret) — callers must
    ///         supply the provider revelation to {revealWithCallback}.
    function register(
        uint128 feeInWei,
        bytes32 commitment,
        bytes calldata,
        uint64 chainLength,
        uint64 maxNumHashes,
        bytes calldata
    ) external {
        if (chainLength == 0) revert InvalidChainLength(chainLength);
        if (_providers[msg.sender].registered) revert ProviderAlreadyRegistered(msg.sender);
        _providers[msg.sender] = ProviderRecord({
            provider: msg.sender,
            originalCommitment: commitment,
            currentCommitment: commitment,
            originalChainLength: chainLength,
            currentCommitmentSequenceNumber: 0,
            sequenceNumber: 1,
            endSequenceNumber: chainLength,
            maxNumHashes: maxNumHashes,
            feeInWei: feeInWei,
            accruedFeesInWei: 0,
            registered: true,
            seed: bytes32(0)
        });
        emit ProviderRegistered(msg.sender, feeInWei, commitment, chainLength, maxNumHashes);
    }

    function rotateCommitment(bytes32 newCommitment, bytes calldata, uint64 newChainLength, bytes calldata) external {
        ProviderRecord storage p = _providers[msg.sender];
        if (!p.registered) revert ProviderNotRegistered(msg.sender);
        p.originalCommitment = newCommitment;
        p.currentCommitment = newCommitment;
        p.originalChainLength = newChainLength;
        p.endSequenceNumber = p.sequenceNumber + newChainLength - 1;
        p.currentCommitmentSequenceNumber = p.sequenceNumber - 1;
        p.seed = bytes32(0);
    }

    function setProviderFee(uint128 newFeeInWei) external {
        ProviderRecord storage p = _providers[msg.sender];
        if (!p.registered) revert ProviderNotRegistered(msg.sender);
        p.feeInWei = newFeeInWei;
    }

    function setProviderFeeAsFeeManager(address provider, uint128 newFeeInWei) external {
        _providers[provider].feeInWei = newFeeInWei;
    }

    function setFeeManager(address) external {}

    function withdraw(uint128 amount) external {
        ProviderRecord storage p = _providers[msg.sender];
        if (amount > p.accruedFeesInWei) revert InsufficientAccruedFees(amount, p.accruedFeesInWei);
        p.accruedFeesInWei -= amount;
        (bool ok,) = msg.sender.call{value: amount}("");
        if (!ok) revert TransferFailed(msg.sender, amount);
    }

    function withdrawAsFeeManager(address, uint128) external {}

    // ── IQuiverCoordinator: randomness flow ────────────────────────────────

    function request(address provider, bytes32 userCommitment, bool useBlockhash)
        external
        payable
        returns (uint64 seq)
    {
        if (useBlockhash) revert("Mock: no blockhash support");
        seq = _assignSequence(provider);
        _requests[provider][seq] = RequestRecord({
            provider: provider,
            sequenceNumber: seq,
            userCommitment: userCommitment,
            providerCommitment: _providers[provider].currentCommitment,
            requester: msg.sender,
            isRequestWithCallback: false,
            revealed: false,
            rawUserRandom: bytes32(0)
        });
        emit RandomnessRequested(provider, msg.sender, seq, userCommitment, 1, false, false);
    }

    function requestWithCallback(address provider, bytes32 userRandomNumber) external payable returns (uint64 seq) {
        if (paused) revert Paused();
        _applyForcedRequestError();
        seq = _assignSequence(provider);
        _requests[provider][seq] = RequestRecord({
            provider: provider,
            sequenceNumber: seq,
            userCommitment: keccak256(abi.encodePacked(userRandomNumber)),
            providerCommitment: _providers[provider].currentCommitment,
            requester: msg.sender,
            isRequestWithCallback: true,
            revealed: false,
            rawUserRandom: userRandomNumber
        });
        emit RandomnessRequested(provider, msg.sender, seq, userRandomNumber, 1, true, false);
    }

    function reveal(address provider, uint64 seq, bytes32 userRevelation, bytes32 providerRevelation)
        external
        returns (bytes32 rnd)
    {
        RequestRecord storage req = _requests[provider][seq];
        if (req.requester == address(0)) revert NoSuchRequest(provider, seq);
        if (req.isRequestWithCallback) revert RequestCallbackMismatch(true);
        if (keccak256(abi.encodePacked(userRevelation)) != req.userCommitment) revert IncorrectUserRevelation();
        _verifyProviderRevelation(provider, seq, providerRevelation);
        req.revealed = true;
        rnd = _combine(userRevelation, providerRevelation);
        emit RandomnessRevealed(provider, seq, req.requester, rnd, userRevelation, providerRevelation);
    }

    /// @notice Push-flow reveal. The keeper normally calls this; in tests either this mock
    ///         computes the provider revelation from the stored seed (via {revealAuto}) or the
    ///         test supplies it here.
    function revealWithCallback(address provider, uint64 seq, bytes32 userRandomNumber, bytes32 providerRevelation)
        public
    {
        RequestRecord storage req = _requests[provider][seq];
        if (req.requester == address(0)) revert NoSuchRequest(provider, seq);
        if (!req.isRequestWithCallback) revert RequestCallbackMismatch(false);
        if (req.revealed) revert("Mock: already revealed");
        if (keccak256(abi.encodePacked(userRandomNumber)) != req.userCommitment) revert IncorrectUserRevelation();
        _verifyProviderRevelation(provider, seq, providerRevelation);
        req.revealed = true;
        bytes32 rnd = _combine(userRandomNumber, providerRevelation);
        emit RandomnessRevealed(provider, seq, req.requester, rnd, userRandomNumber, providerRevelation);
        _deliverCallback(provider, seq, req.requester, rnd);
    }

    /// @notice TEST-ONLY. Reveal the current request for `provider`/`seq`, computing the
    ///         provider revelation from the registered seed, and forward the callback.
    ///         Reverts if the provider has no stored seed (registered by commitment only).
    function revealAuto(address provider, uint64 seq, bytes32 userRandomNumber) external {
        ProviderRecord storage p = _providers[provider];
        if (p.seed == bytes32(0)) revert("Mock: provider has no stored seed");
        bytes32 provReveal = MockQuiverHash.revelation(p.seed, p.originalChainLength, seq);
        revealWithCallback(provider, seq, userRandomNumber, provReveal);
    }

    function retryCallback(address provider, uint64 seq) external {
        FailedRecord storage f = _failedCallbacks[provider][seq];
        if (!f.exists) revert("Mock: no failed callback");
        bytes32 rnd = f.randomNumber;
        address requester = f.requester;
        delete _failedCallbacks[provider][seq];
        _deliverCallback(provider, seq, requester, rnd);
    }

    // ── IQuiverCoordinator: protocol administration ────────────────────────

    function pause() external {
        paused = true;
    }

    function unpause() external {
        paused = false;
    }

    function withdrawProtocolFees(address to, uint128 amount) external {
        if (amount > accruedProtocolFees) revert InsufficientAccruedFees(amount, accruedProtocolFees);
        accruedProtocolFees -= amount;
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert TransferFailed(to, amount);
    }

    // ── IQuiverCoordinator: views ──────────────────────────────────────────

    function getFee(address provider) external view returns (uint128) {
        if (!_providers[provider].registered) revert ProviderNotRegistered(provider);
        return _providers[provider].feeInWei + protocolFee;
    }

    function getProtocolFee() external view returns (uint128) {
        return protocolFee;
    }

    function getAccruedProtocolFees() external view returns (uint128) {
        return accruedProtocolFees;
    }

    function getProviderInfo(address provider) external view returns (QuiverStructs.ProviderInfo memory info) {
        ProviderRecord storage p = _providers[provider];
        if (!p.registered) revert ProviderNotRegistered(provider);
        info.feeInWei = p.feeInWei;
        info.accruedFeesInWei = p.accruedFeesInWei;
        info.originalCommitment = p.originalCommitment;
        info.currentCommitment = p.currentCommitment;
        info.originalChainLength = p.originalChainLength;
        info.currentCommitmentSequenceNumber = p.currentCommitmentSequenceNumber;
        info.sequenceNumber = p.sequenceNumber;
        info.endSequenceNumber = p.endSequenceNumber;
        info.maxNumHashes = p.maxNumHashes;
    }

    function getProviderSequenceNumber(address provider) external view returns (uint64) {
        if (!_providers[provider].registered) revert ProviderNotRegistered(provider);
        return _providers[provider].sequenceNumber;
    }

    function getRequest(address provider, uint64 seq) external view returns (QuiverStructs.Request memory req) {
        RequestRecord storage r = _requests[provider][seq];
        req.provider = r.provider;
        req.sequenceNumber = r.sequenceNumber;
        req.userCommitment = r.userCommitment;
        req.providerCommitment = r.providerCommitment;
        req.requester = r.requester;
        req.isRequestWithCallback = r.isRequestWithCallback;
    }

    function getFailedCallback(address provider, uint64 seq) external view returns (bool exists, bytes32 randomNumber) {
        FailedRecord storage f = _failedCallbacks[provider][seq];
        return (f.exists, f.randomNumber);
    }

    function constructUserCommitment(bytes32 userRandomNumber) external pure returns (bytes32) {
        return keccak256(abi.encodePacked(userRandomNumber));
    }

    function combineRandomValues(bytes32 userRevelation, bytes32 providerRevelation, bytes32 blockHash)
        external
        pure
        returns (bytes32)
    {
        return _combine(userRevelation, providerRevelation);
    }

    // ── Internal ───────────────────────────────────────────────────────────

    function _combine(bytes32 userRevelation, bytes32 providerRevelation) private pure returns (bytes32) {
        return keccak256(abi.encode(userRevelation, providerRevelation));
    }

    function _assignSequence(address provider) private returns (uint64 seq) {
        ProviderRecord storage p = _providers[provider];
        if (!p.registered) revert ProviderNotRegistered(provider);
        if (p.sequenceNumber > p.endSequenceNumber) {
            revert ProviderChainExhausted(provider, p.endSequenceNumber);
        }
        uint256 totalFee = uint256(p.feeInWei) + uint256(protocolFee);
        if (msg.value < totalFee) revert InsufficientFee(msg.value, totalFee);
        seq = p.sequenceNumber;
        ++p.sequenceNumber;
        p.accruedFeesInWei += p.feeInWei;
        accruedProtocolFees += protocolFee;
        // return excess value to the caller (LotteryCore pays the exact quote, so none)
        uint256 refund = msg.value - totalFee;
        if (refund > 0) {
            (bool ok,) = msg.sender.call{value: refund}("");
            if (!ok) revert TransferFailed(msg.sender, refund);
        }
    }

    function _applyForcedRequestError() private view {
        bytes4 sel = forcedRequestError;
        if (sel == bytes4(0)) return;
        if (sel == 0xffffffff) revert("Mock: generic failure");
        assembly {
            let ptr := mload(0x40)
            mstore(ptr, sel)
            mstore(add(ptr, 0x04), 0)
            revert(ptr, 0x04)
        }
    }

    function _verifyProviderRevelation(address provider, uint64 seq, bytes32 providerRevelation) private {
        ProviderRecord storage p = _providers[provider];
        uint64 ccs = p.currentCommitmentSequenceNumber;
        if (seq <= ccs) revert("Mock: already-revealed-or-older seq");
        uint256 steps = uint256(seq) - uint256(ccs);
        if (steps > p.maxNumHashes) revert TooManyHashes(uint64(steps), p.maxNumHashes);
        bytes32 h = providerRevelation;
        for (uint256 i = 0; i < steps; ++i) {
            h = keccak256(abi.encodePacked(h));
        }
        if (h != p.currentCommitment) revert IncorrectProviderRevelation();
        p.currentCommitment = providerRevelation;
        p.currentCommitmentSequenceNumber = seq;
    }

    function _deliverCallback(address provider, uint64 seq, address requester, bytes32 rnd) private {
        uint256 gas = callbackGas;
        bool ok;
        bytes memory reason;
        if (gas != 0) {
            (ok, reason) = requester.call{gas: gas}(
                abi.encodeWithSelector(IQuiverConsumer.quiverCallback.selector, seq, provider, rnd)
            );
        } else {
            (ok, reason) =
                requester.call(abi.encodeWithSelector(IQuiverConsumer.quiverCallback.selector, seq, provider, rnd));
        }
        if (ok) {
            emit CallbackSucceeded(provider, seq, requester, rnd);
        } else {
            _failedCallbacks[provider][seq] = FailedRecord({randomNumber: rnd, requester: requester, exists: true});
            emit CallbackFailed(provider, seq, requester, rnd, reason);
        }
    }
}
