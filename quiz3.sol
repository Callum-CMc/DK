// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address who) external view returns (uint256);
}

/**
 * Pub Quiz (Reusable Rounds) + Commit–Reveal + USDC entry/prize + ERC1155 NFTs
 *
 * Token IDs:
 *  - LOST_BASE   + roundId = LOST for that round
 *  - WINNER_BASE + roundId = WINNER for that round
 *
 * Metadata:
 *  - LOST: off-chain JSON via `lostBaseUri` (static metadata; no on-chain dynamic attributes)
 *  - WINNER: on-chain JSON (data:application/json;utf8,...) with dynamic Round + Team Name attributes
 *            and an off-chain image URL (`winnerImageUri`)
 *
 * NOTE (Stack Too Deep Fix):
 *  - commit verification hashes answers with: keccak256(abi.encode(answers))
 *    (NOT abi.encodePacked(answers[0]...answers[9])).
 */
contract PubQuiz3 is ERC1155, Ownable, ReentrancyGuard {
    // ---------------------------
    // Custom errors
    // ---------------------------
    error ZeroAddress();
    error BadRevealWindow();
    error AmountZero();
    error UsdcTransferFromFailed();
    error UsdcTransferFailed();
    error InvalidTeamName();

    error NoActiveRound();
    error RoundAlreadyWon();
    error PrizeNotFunded();

    error ActiveCommitExists();
    error NoCommit();
    error AlreadyRevealed();
    error CommitExpired();
    error TooEarlyToReveal();
    error CommitMismatch();

    error InvalidTokenId();
    error BadRoundId();

    error Banned();

    // ---------------------------
    // Token ID bases
    // ---------------------------
    uint256 public constant WINNER_BASE = 1_000_000;
    uint256 public constant LOST_BASE   = 2_000_000;

    // ---------------------------
    // Off-chain metadata config
    // ---------------------------
    // LOST token metadata: `${lostBaseUri}${roundId}.json`
    string public lostBaseUri;

    // WINNER token metadata uses this single off-chain image URI.
    string public winnerImageUri;

    // ---------------------------
    // USDC
    // ---------------------------
    IERC20 public immutable usdc;

    // ---------------------------
    // Ban list
    // ---------------------------
    mapping(address => bool) public banned;

    modifier notBanned() {
        if (banned[msg.sender]) revert Banned();
        _;
    }

    // ---------------------------
    // Round state
    // ---------------------------
    struct Round {
        uint256 entryFee;         // e.g. 1_000_000 for 1 USDC
        uint256 prizeAmount;      // e.g. 25_000_000 for 25 USDC
        uint256 minRevealDelay;   // seconds
        uint256 maxRevealDelay;   // seconds
        bytes32 answerSalt;
        bytes32[10] correctAnswerHashes;

        uint256 prizeFunded;
        bool won;
        address winner;
        string winnerTeamName;
    }

    uint256 public currentRound; // 0 means no active round yet
    mapping(uint256 => Round) public rounds;

    // ---------------------------
    // Commit storage (per round, per player)
    // ---------------------------
    struct CommitInfo {
        bytes32 commitHash;
        uint64 commitTime;
        bool revealed;
        string teamName;
    }

    mapping(uint256 => mapping(address => CommitInfo)) public commits;

    // ---------------------------
    // Events
    // ---------------------------
    event RoundStarted(
        uint256 indexed roundId,
        uint256 entryFee,
        uint256 prizeAmount,
        uint256 minRevealDelay,
        uint256 maxRevealDelay
    );

    event RoundAnswersUpdated(uint256 indexed roundId);
    event PrizeFunded(uint256 indexed roundId, address indexed from, uint256 amount);
    event PrizePaid(uint256 indexed roundId, address indexed to, uint256 amount);

    event Committed(uint256 indexed roundId, address indexed player, bytes32 indexed commitHash, string teamName);
    event Revealed(uint256 indexed roundId, address indexed player, bool correct, uint256 tokenId, string teamName);

    event BanSet(address indexed who, bool banned);
    event LostBaseUriSet(string newUri);
    event WinnerImageUriSet(string newUri);

    // ---------------------------
    // Constructor
    // ---------------------------
    constructor(address usdcAddress) ERC1155("") Ownable(msg.sender) {
        if (usdcAddress == address(0)) revert ZeroAddress();
        usdc = IERC20(usdcAddress);
    }

    // ============================================================
    // Owner: admin controls
    // ============================================================

    function setBanned(address who, bool isBanned) external onlyOwner {
        banned[who] = isBanned;
        emit BanSet(who, isBanned);
    }

    /// Example: "https://example.com/quiz/lost/" -> uri(lostTokenId) = ".../1.json"
    function setLostBaseUri(string calldata newUri) external onlyOwner {
        lostBaseUri = newUri;
        emit LostBaseUriSet(newUri);
    }

    /// Example: "https://example.com/quiz/winner.png"
    function setWinnerImageUri(string calldata newUri) external onlyOwner {
        winnerImageUri = newUri;
        emit WinnerImageUriSet(newUri);
    }

    // ============================================================
    // Owner: round lifecycle
    // ============================================================

    function startNewRound(
        uint256 entryFee_,
        uint256 prizeAmount_,
        bytes32 answerSalt_,
        bytes32[10] calldata correctAnswerHashes_,
        uint256 minRevealDelaySeconds,
        uint256 maxRevealDelaySeconds
    ) external onlyOwner {
        if (maxRevealDelaySeconds <= minRevealDelaySeconds) revert BadRevealWindow();
        if (answerSalt_ == bytes32(0)) revert CommitMismatch();

        currentRound += 1;
        uint256 r = currentRound;

        rounds[r] = Round({
            entryFee: entryFee_,
            prizeAmount: prizeAmount_,
            minRevealDelay: minRevealDelaySeconds,
            maxRevealDelay: maxRevealDelaySeconds,
            answerSalt: answerSalt_,
            correctAnswerHashes: correctAnswerHashes_,
            prizeFunded: 0,
            won: false,
            winner: address(0),
            winnerTeamName: ""
        });

        emit RoundStarted(r, entryFee_, prizeAmount_, minRevealDelaySeconds, maxRevealDelaySeconds);
    }

    function setCurrentRoundAnswers(bytes32[10] calldata newHashes) external onlyOwner {
        uint256 r = currentRound;
        if (r == 0) revert NoActiveRound();
        if (rounds[r].won) revert RoundAlreadyWon();
        rounds[r].correctAnswerHashes = newHashes;
        emit RoundAnswersUpdated(r);
    }

    function setCurrentRoundConfig(
        uint256 newEntryFee,
        uint256 newPrizeAmount,
        uint256 newMinDelay,
        uint256 newMaxDelay
    ) external onlyOwner {
        uint256 r = currentRound;
        if (r == 0) revert NoActiveRound();
        if (rounds[r].won) revert RoundAlreadyWon();
        if (newMaxDelay <= newMinDelay) revert BadRevealWindow();

        rounds[r].entryFee = newEntryFee;
        rounds[r].prizeAmount = newPrizeAmount;
        rounds[r].minRevealDelay = newMinDelay;
        rounds[r].maxRevealDelay = newMaxDelay;
    }

    function fundPrize(uint256 roundId, uint256 amount) external onlyOwner nonReentrant {
        if (roundId == 0 || roundId > currentRound) revert BadRoundId();
        if (amount == 0) revert AmountZero();

        if (!usdc.transferFrom(msg.sender, address(this), amount)) revert UsdcTransferFromFailed();
        rounds[roundId].prizeFunded += amount;

        emit PrizeFunded(roundId, msg.sender, amount);
    }

    function withdrawUSDC(address to, uint256 amount) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        if (!usdc.transfer(to, amount)) revert UsdcTransferFailed();
    }

    // ============================================================
    // Player: commit–reveal
    // ============================================================

    function commit(bytes32 commitHash, string calldata teamName) external nonReentrant notBanned {
        uint256 r = currentRound;
        if (r == 0) revert NoActiveRound();
        if (rounds[r].won) revert RoundAlreadyWon();
        if (commitHash == bytes32(0)) revert CommitMismatch();
        if (!_isValidTeamName(teamName)) revert InvalidTeamName();

        CommitInfo storage c = commits[r][msg.sender];

        if (c.commitHash != bytes32(0) && !c.revealed) {
            if (!_isExpired(r, c.commitTime)) revert ActiveCommitExists();
        }

        uint256 fee = rounds[r].entryFee;
        if (!usdc.transferFrom(msg.sender, address(this), fee)) revert UsdcTransferFromFailed();

        commits[r][msg.sender] = CommitInfo({
            commitHash: commitHash,
            commitTime: uint64(block.timestamp),
            revealed: false,
            teamName: teamName
        });

        emit Committed(r, msg.sender, commitHash, teamName);
    }

    function reveal(string[10] calldata answers, bytes32 userSalt) external nonReentrant notBanned {
        uint256 r = currentRound;
        if (r == 0) revert NoActiveRound();

        Round storage round = rounds[r];
        if (round.won) revert RoundAlreadyWon();

        CommitInfo storage c = commits[r][msg.sender];
        if (c.commitHash == bytes32(0)) revert NoCommit();
        if (c.revealed) revert AlreadyRevealed();
        if (_isExpired(r, c.commitTime)) revert CommitExpired();
        if (block.timestamp < uint256(c.commitTime) + round.minRevealDelay) revert TooEarlyToReveal();

        // Commit verification:
        // teamHash = keccak256(teamName)
        // answersHash = keccak256(abi.encode(answers))  <-- stack-safe fix
        bytes32 teamHash = keccak256(bytes(c.teamName));
        bytes32 answersHash = keccak256(abi.encode(answers));
        bytes32 recomputed = keccak256(abi.encodePacked(msg.sender, teamHash, answersHash, userSalt));
        if (recomputed != c.commitHash) revert CommitMismatch();

        c.revealed = true;

        bool isCorrect = _checkAnswers(r, answers);

        if (isCorrect) {
            if (round.prizeFunded < round.prizeAmount) revert PrizeNotFunded();

            round.won = true;
            round.winner = msg.sender;
            round.winnerTeamName = c.teamName;

            round.prizeFunded -= round.prizeAmount;

            if (!usdc.transfer(msg.sender, round.prizeAmount)) revert UsdcTransferFailed();
            emit PrizePaid(r, msg.sender, round.prizeAmount);

            uint256 winnerTokenId = WINNER_BASE + r;
            _mint(msg.sender, winnerTokenId, 1, "");
            emit Revealed(r, msg.sender, true, winnerTokenId, c.teamName);
        } else {
            uint256 lostTokenId = LOST_BASE + r;
            _mint(msg.sender, lostTokenId, 1, "");
            emit Revealed(r, msg.sender, false, lostTokenId, c.teamName);
        }
    }

    function clearExpiredCommit(uint256 roundId, address player) external {
        if (roundId == 0 || roundId > currentRound) revert BadRoundId();

        CommitInfo storage c = commits[roundId][player];
        if (c.commitHash == bytes32(0)) revert NoCommit();
        if (c.revealed) revert AlreadyRevealed();
        if (!_isExpired(roundId, c.commitTime)) revert CommitExpired(); // reused: means "not expired yet"

        delete commits[roundId][player];
    }

    function _isExpired(uint256 roundId, uint64 commitTime) internal view returns (bool) {
        Round storage round = rounds[roundId];
        return block.timestamp > uint256(commitTime) + round.maxRevealDelay;
    }

    // ============================================================
    // Frontend helper
    // ============================================================

    function getCommitStatus(uint256 roundId, address player)
        external
        view
        returns (
            bool hasCommit,
            bool revealed,
            bool expired,
            uint64 commitTime,
            string memory teamName,
            bytes32 commitHash
        )
    {
        if (roundId == 0 || roundId > currentRound) revert BadRoundId();

        CommitInfo storage c = commits[roundId][player];

        commitHash = c.commitHash;
        hasCommit = (commitHash != bytes32(0));

        revealed = c.revealed;
        commitTime = c.commitTime;
        teamName = c.teamName;

        expired = hasCommit && _isExpired(roundId, commitTime);
    }

    // ============================================================
    // Answer checking
    // ============================================================

    function _checkAnswers(uint256 roundId, string[10] calldata answers) internal view returns (bool) {
        Round storage round = rounds[roundId];
        for (uint256 i = 0; i < 10; i++) {
            bytes32 h = keccak256(abi.encodePacked(round.answerSalt, answers[i]));
            if (h != round.correctAnswerHashes[i]) return false;
        }
        return true;
    }

    // ============================================================
    // Metadata (ERC1155 uri)
    // ============================================================

    function uri(uint256 id) public view override returns (string memory) {
        // LOST tokens: off-chain JSON (static)
        if (id >= LOST_BASE && id < LOST_BASE + currentRound + 1) {
            uint256 roundId = id - LOST_BASE;
            if (roundId == 0 || roundId > currentRound) revert InvalidTokenId();
            return string(abi.encodePacked(lostBaseUri, _toString(roundId), ".json"));
        }

        // WINNER tokens: on-chain JSON with dynamic Round + Team Name
        if (id >= WINNER_BASE && id < WINNER_BASE + currentRound + 1) {
            uint256 roundId = id - WINNER_BASE;
            if (roundId == 0 || roundId > currentRound) revert InvalidTokenId();

            Round storage round = rounds[roundId];

            if (!round.won) {
                return "data:application/json;utf8,{\"name\":\"Winner TBD\"}";
            }

            // JSON has NO trailing commas.
            return string(
                abi.encodePacked(
                    "data:application/json;utf8,",
                    "{",
                        "\"name\":\"Quiz Winner - ", round.winnerTeamName, "\",",
                        "\"description\":\"Winner NFT for the first correct reveal.\",",
                        "\"image\":\"", winnerImageUri, "\",",
                        "\"attributes\":[",
                            "{\"trait_type\":\"Result\",\"value\":\"Winner\"},",
                            "{\"trait_type\":\"Round\",\"value\":\"", _toString(roundId), "\"},",
                            "{\"trait_type\":\"Team Name\",\"value\":\"", round.winnerTeamName, "\"}",
                        "]",
                    "}"
                )
            );
        }

        revert InvalidTokenId();
    }

    // ============================================================
    // Tiny uint->string (avoid importing Strings)
    // ============================================================

    function _toString(uint256 x) internal pure returns (string memory) {
        if (x == 0) return "0";
        uint256 temp = x;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (x != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(x % 10)));
            x /= 10;
        }
        return string(buffer);
    }

    // ============================================================
    // Team name validation
    // ============================================================

    function _isValidTeamName(string calldata s) internal pure returns (bool) {
        bytes calldata b = bytes(s);
        uint256 len = b.length;
        if (len == 0 || len > 32) return false;

        for (uint256 i = 0; i < len; i++) {
            bytes1 c = b[i];
            bool ok =
                (c >= 0x30 && c <= 0x39) || // 0-9
                (c >= 0x41 && c <= 0x5A) || // A-Z
                (c >= 0x61 && c <= 0x7A) || // a-z
                (c == 0x20) ||              // space
                (c == 0x5F) ||              // _
                (c == 0x2E) ||              // .
                (c == 0x2D);                // -
            if (!ok) return false;
        }
        return true;
    }
}

