// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Base64.sol";

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address who) external view returns (uint256);
}

/**
 * Dukes Knickers Pub Quiz (Reusable Rounds) + Commit–Reveal + USDC entry/prize + ERC1155 NFTs
 *
 * Token IDs:
 *  - LOST token is static and ALWAYS tokenId = 0 (on-chain metadata)
 *  - WINNER tokenId = roundId (starts at 1 and increases each round)
 *
 * Metadata:
 *  - LOST: on-chain JSON (data:application/json;utf8,...) with fixed image
 *  - WINNER: on-chain JSON (data:application/json;utf8,...) with dynamic Round + Team Name attributes
 *            and fixed image
 *
 * NOTE (Stack Too Deep Fix):
 *  - commit verification hashes answers with: keccak256(abi.encode(answers))
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
    // Revel delays
    // ---------------------------

    uint256 public constant MIN_REVEAL_DELAY = 6 seconds;
    uint256 public constant MAX_REVEAL_DELAY = 1 hours;


    // ---------------------------
    // Token IDs
    // ---------------------------
    uint256 public constant LOST_TOKEN_ID = 0; // static loser/participant NFT
    uint256 public constant WINNER_BASE = 1;   // winner tokenId == roundId (rounds start at 1)

    // ---------------------------
    // NFT image URIs
    // ---------------------------
    // Winner token metadata uses this single image URI (owner can still change it).
    string public constant winnerImageUri =
        "https://upload.wikimedia.org/wikipedia/commons/thumb/8/80/Trophy.svg/640px-Trophy.svg.png";

    // Lost token uses a fixed image URI and fully on-chain JSON metadata.
    string public constant LOST_IMAGE_URI =
        "https://upload.wikimedia.org/wikipedia/commons/thumb/8/81/Andechser_Beer_-_Coaster_%28Germany%2C_2025%29.png/640px-Andechser_Beer_-_Coaster_%28Germany%2C_2025%29.png";

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
            winner: address(0),
            winnerTeamName: ""
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
        if (block.timestamp < uint256(c.commitTime) + MIN_REVEAL_DELAY) revert TooEarlyToReveal();

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

            // Winner tokenId starts at 1 and increases every round => tokenId == roundId
            uint256 winnerTokenId = r; // (equivalently: WINNER_BASE + (r - 1))
            _mint(msg.sender, winnerTokenId, 1, "");
            emit Revealed(r, msg.sender, true, winnerTokenId, c.teamName);
        } else {
            // Lost token is static tokenId=0
            _mint(msg.sender, LOST_TOKEN_ID, 1, "");
            emit Revealed(r, msg.sender, false, LOST_TOKEN_ID, c.teamName);
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

    function _isExpired(uint256 /* roundId */, uint64 commitTime)
        internal
        view
        returns (bool)
    {
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
    // Metadata (ERC1155 uri)
    // ============================================================
function uri(uint256 id) public view override returns (string memory) {
    // ------------------------------------------------------------
    // LOST token (tokenId = 0) — fully on-chain, Base64 encoded
    // ------------------------------------------------------------
    if (id == LOST_TOKEN_ID) {
        bytes memory json = abi.encodePacked(
            "{",
                "\"name\":\"Lost Quiz Stolen Drinks Coaster\",",
                "\"description\":\"Stolen from The Dukes Knickers Pub after losing the Pub Quiz.\",",
                "\"image\":\"", LOST_IMAGE_URI, "\",",
                "\"attributes\":[",
                    "{\"trait_type\":\"Result\",\"value\":\"Lost\"}",
                "]",
            "}"
        );

        return string(
            abi.encodePacked(
                "data:application/json;base64,",
                Base64.encode(json)
            )
        );
    }

    // ------------------------------------------------------------
    // WINNER tokens (tokenId == roundId, starting at 1)
    // Only valid AFTER the round has been won
    // ------------------------------------------------------------
    if (id >= WINNER_BASE && id <= currentRound) {
        Round storage round = rounds[id];

        // Token metadata only exists once the winner is known
        if (!round.won) revert InvalidTokenId();

        bytes memory json = abi.encodePacked(
            "{",
                "\"name\":\"The Dukes Knickers Pub Quiz Winner - ", round.winnerTeamName, "\",",
                "\"description\":\"Congratulations on winning The Dukes Knickers Pub Quiz.\",",
                "\"image\":\"", winnerImageUri, "\",",
                "\"attributes\":[",
                    "{\"trait_type\":\"Result\",\"value\":\"Winner\"},",
                    "{\"trait_type\":\"Round\",\"value\":\"", _toString(id), "\"},",
                    "{\"trait_type\":\"Team Name\",\"value\":\"", round.winnerTeamName, "\"}",
                "]",
            "}"
        );

        return string(
            abi.encodePacked(
                "data:application/json;base64,",
                Base64.encode(json)
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
