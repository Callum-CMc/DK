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
 * Dukes Knickers Pub Quiz (Reusable Rounds) + Commit–Reveal + USDC entry/prize + ERC1155 NFTs
 *
 * Size-optimized + STATIC Winner token metadata:
 *  - Off-chain metadata: uri() returns static URIs (no Base64, no on-chain JSON building)
 *  - Team name is NOT stored on-chain (only emitted in events). Reveal takes teamName as input.
 *  - Team name validation reduced to length-only (prevents grief without heavy bytecode).
 *  - Winner token ID is STATIC (WINNER_TOKEN_ID = 1) regardless of round.
 *
 * Token IDs:
 *  - LOST token is static tokenId = 0
 *  - WINNER token is static tokenId = 1
 */
contract DukesKnickersQuiz is ERC1155, Ownable, ReentrancyGuard {
    // ---------------------------
    // Custom errors
    // ---------------------------
    error ZeroAddress();
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
    // Reveal delays
    // ---------------------------
    uint256 public constant MIN_REVEAL_DELAY = 5 seconds;
    uint256 public constant MAX_REVEAL_DELAY = 1 hours;

    // ---------------------------
    // Token IDs
    // ---------------------------
    uint256 public constant LOST_TOKEN_ID = 0;   // static loser/participant NFT
    uint256 public constant WINNER_TOKEN_ID = 1; // static winner NFT

    // ---------------------------
    // Off-chain metadata URIs (STATIC)
    // ---------------------------
    string public lostUri;   // uri(0)
    string public winnerUri; // uri(1)

    event UrisSet(string lostUri, string winnerUri);

    function setUris(string calldata lostUri_, string calldata winnerUri_) external onlyOwner {
        lostUri = lostUri_;
        winnerUri = winnerUri_;
        emit UrisSet(lostUri_, winnerUri_);
    }

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
        uint256 entryFee;
        uint256 prizeAmount;
        bytes32 answerSalt;
        bytes32[10] correctAnswerHashes;

        uint256 prizeFunded;
        bool won;
        bool cancelled;
        address winner;
    }

    uint256 public currentRound; // 0 means no round yet
    mapping(uint256 => Round) public rounds;

    // ---------------------------
    // Commit storage (per round, per player)
    // ---------------------------
    struct CommitInfo {
        bytes32 commitHash;
        uint64 commitTime;
        bool revealed;
    }

    mapping(uint256 => mapping(address => CommitInfo)) public commits;

    // Track players per round for owner cancellation (enables iteration)
    mapping(uint256 => address[]) private _roundPlayers;
    mapping(uint256 => mapping(address => bool)) private _isRoundPlayer;

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

    event RoundCancelled(uint256 indexed roundId, uint256 playersAffected);

    event RoundAnswersUpdated(uint256 indexed roundId);
    event PrizeFunded(uint256 indexed roundId, address indexed from, uint256 amount);
    event PrizePaid(uint256 indexed roundId, address indexed to, uint256 amount);

    // Team name is kept only in events (not stored).
    event WinnerDeclared(uint256 indexed roundId, address indexed winner, string teamName);
    event Committed(uint256 indexed roundId, address indexed player, bytes32 indexed commitHash, string teamName);
    event Revealed(uint256 indexed roundId, address indexed player, bool correct, uint256 tokenId);

    event BanSet(address indexed who, bool bannedStatus);

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

    // ============================================================
    // Owner: round lifecycle
    // ============================================================

    function startNewRound(
        uint256 entryFee_,
        uint256 prizeAmount_,
        bytes32 answerSalt_,
        bytes32[10] calldata correctAnswerHashes_
    ) external onlyOwner {
        if (answerSalt_ == bytes32(0)) revert CommitMismatch();

        currentRound += 1;
        uint256 r = currentRound;

        rounds[r] = Round({
            entryFee: entryFee_,
            prizeAmount: prizeAmount_,
            answerSalt: answerSalt_,
            correctAnswerHashes: correctAnswerHashes_,
            prizeFunded: 0,
            won: false,
            cancelled: false,
            winner: address(0)
        });

        emit RoundStarted(r, entryFee_, prizeAmount_, MIN_REVEAL_DELAY, MAX_REVEAL_DELAY);
    }

    function setCurrentRoundAnswers(bytes32[10] calldata newHashes) external onlyOwner {
        uint256 r = currentRound;
        if (r == 0) revert NoActiveRound();
        if (rounds[r].won) revert RoundAlreadyWon();
        rounds[r].correctAnswerHashes = newHashes;
        emit RoundAnswersUpdated(r);
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
    // View: current round status
    // ============================================================

    function getCurrentRoundStatus()
        external
        view
        returns (
            uint256 roundNumber,
            uint256 entryFee,
            uint256 prizeAmount,
            uint256 prizeFunded,
            bool isActive,
            bool isPrizeFunded,
            bool isCompleted,
            address winner
        )
    {
        roundNumber = currentRound;
        if (roundNumber == 0) {
            return (0, 0, 0, 0, false, false, false, address(0));
        }

        Round storage round = rounds[roundNumber];
        entryFee = round.entryFee;
        prizeAmount = round.prizeAmount;
        prizeFunded = round.prizeFunded;

        isCompleted = round.won;
        isActive = !round.won;
        isPrizeFunded = (prizeFunded >= prizeAmount);

        winner = round.winner;
    }

    // ============================================================
    // Player: commit–reveal
    // ============================================================

    function commit(bytes32 commitHash, string calldata teamName) external nonReentrant notBanned {
        uint256 r = currentRound;
        if (r == 0) revert NoActiveRound();
        if (rounds[r].won) revert RoundAlreadyWon();
        if (commitHash == bytes32(0)) revert CommitMismatch();

        // length-only cap (size-optimized)
        uint256 tnLen = bytes(teamName).length;
        if (tnLen == 0 || tnLen > 32) revert InvalidTeamName();

        CommitInfo storage c = commits[r][msg.sender];

        if (c.commitHash != bytes32(0) && !c.revealed) {
            if (!_isExpired(c.commitTime)) revert ActiveCommitExists();
        }

        uint256 fee = rounds[r].entryFee;
        if (!usdc.transferFrom(msg.sender, address(this), fee)) revert UsdcTransferFromFailed();

        commits[r][msg.sender] = CommitInfo({
            commitHash: commitHash,
            commitTime: uint64(block.timestamp),
            revealed: false
        });

        // Track participants for owner-cancel (unique per round)
        if (!_isRoundPlayer[r][msg.sender]) {
            _isRoundPlayer[r][msg.sender] = true;
            _roundPlayers[r].push(msg.sender);
        }

        emit Committed(r, msg.sender, commitHash, teamName);
    }

    function cancelCurrentRound() external onlyOwner nonReentrant {
        uint256 r = currentRound;
        if (r == 0) revert NoActiveRound();

        Round storage round = rounds[r];
        if (round.won) revert RoundAlreadyWon();

        // Treat as completed round but with no winner
        round.won = true;
        round.cancelled = true;
        round.winner = address(0);

        address[] storage players = _roundPlayers[r];
        uint256 affected;

        for (uint256 i = 0; i < players.length; i++) {
            address p = players[i];
            CommitInfo storage c = commits[r][p];

            // Mint LOST NFT to anyone who committed and hasn't already resolved their commit
            if (c.commitHash != bytes32(0) && !c.revealed) {
                c.revealed = true; // prevent later reveal
                _mint(p, LOST_TOKEN_ID, 1, "");
                affected++;
            }
        }

        emit RoundCancelled(r, affected);
    }

    function roundPlayers(
        uint256 roundId,
        uint256 start,
        uint256 count
    ) external view returns (address[] memory players) {
        address[] storage all = _roundPlayers[roundId];
        uint256 total = all.length;

        if (start >= total) {
            return new address[](0);
        }

        uint256 end = start + count;
        if (end > total) {
            end = total;
        }

        uint256 size = end - start;
        players = new address[](size);

        for (uint256 i = 0; i < size; i++) {
            players[i] = all[start + i];
        }
    }

    function reveal(string[10] calldata answers, bytes32 userSalt, string calldata teamName)
        external
        nonReentrant
        notBanned
    {
        uint256 r = currentRound;
        if (r == 0) revert NoActiveRound();

        Round storage round = rounds[r];
        if (round.won) revert RoundAlreadyWon();

        CommitInfo storage c = commits[r][msg.sender];
        if (c.commitHash == bytes32(0)) revert NoCommit();
        if (c.revealed) revert AlreadyRevealed();
        if (_isExpired(c.commitTime)) revert CommitExpired();
        if (block.timestamp < uint256(c.commitTime) + MIN_REVEAL_DELAY) revert TooEarlyToReveal();

        // Verify commit (team name provided at reveal; not stored)
        bytes32 teamHash = keccak256(bytes(teamName));
        bytes32 answersHash = keccak256(abi.encode(answers));
        bytes32 recomputed = keccak256(abi.encodePacked(msg.sender, teamHash, answersHash, userSalt));
        if (recomputed != c.commitHash) revert CommitMismatch();

        c.revealed = true;

        bool isCorrect = _checkAnswers(r, answers);

        if (isCorrect) {
            if (round.prizeFunded < round.prizeAmount) revert PrizeNotFunded();

            round.won = true;
            round.winner = msg.sender;

            emit WinnerDeclared(r, msg.sender, teamName);

            round.prizeFunded -= round.prizeAmount;
            if (!usdc.transfer(msg.sender, round.prizeAmount)) revert UsdcTransferFailed();
            emit PrizePaid(r, msg.sender, round.prizeAmount);

            _mint(msg.sender, WINNER_TOKEN_ID, 1, "");
            emit Revealed(r, msg.sender, true, WINNER_TOKEN_ID);
        } else {
            _mint(msg.sender, LOST_TOKEN_ID, 1, "");
            emit Revealed(r, msg.sender, false, LOST_TOKEN_ID);
        }
    }

    function clearExpiredCommit(uint256 roundId, address player) external {
        if (roundId == 0 || roundId > currentRound) revert BadRoundId();

        CommitInfo storage c = commits[roundId][player];
        if (c.commitHash == bytes32(0)) revert NoCommit();
        if (c.revealed) revert AlreadyRevealed();
        if (!_isExpired(c.commitTime)) revert CommitExpired(); // reused: means "not expired yet"

        delete commits[roundId][player];
    }

    function _isExpired(uint64 commitTime) internal view returns (bool) {
        return block.timestamp > uint256(commitTime) + MAX_REVEAL_DELAY;
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
    // Metadata (ERC1155 uri) - STATIC OFF-CHAIN
    // ============================================================

    function uri(uint256 id) public view override returns (string memory) {
        if (id == LOST_TOKEN_ID) return lostUri;
        if (id == WINNER_TOKEN_ID) return winnerUri;
        revert InvalidTokenId();
    }
}
