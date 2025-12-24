// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// OpenZeppelin
import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

interface IERC20 {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/**
 * Virtual Pub (ERC1155) with USDC-priced items, per-item sale pause, burnable tokens, supply tracking,
 * off-chain URIs, and buyer bans.
 *
 * Changes requested:
 *  - owner = deployer (msg.sender)
 *  - treasury = deployer (msg.sender)
 *  - base URI is set *after* deployment via setBaseUri()
 *
 * Initial items:
 *  - Beer (id=1), Red Wine (id=2), Pork Scratchings (id=3) at $1 (assumes 6-decimal USDC => 1_000_000)
 */
contract DukesBar is ERC1155, Ownable {
    using Strings for uint256;

    // ---- Errors ----
    error NotForSale();
    error UnknownItem();
    error Banned();
    error BadAmount();
    error USDCTransferFailed();
    error ZeroAddress();
    error AlreadyExists();
    error BaseUriNotSet();

    // ---- Constants: initial token IDs ----
    uint256 public constant BEER = 1;
    uint256 public constant RED_WINE = 2;
    uint256 public constant PORK_SCRATCHINGS = 3;

    struct Item {
        bool exists;
        bool paused;
        uint96 price;   // USDC smallest units (typically 6 decimals)
        string name;
    }

    IERC20 public immutable usdc;
    address public treasury;

    // Off-chain metadata base URI like "ipfs://CID/" or "https://example.com/metadata/"
    // uri(id) => baseUri + id + ".json"
    string private baseUri;
    bool public baseUriSet;

    mapping(uint256 => Item) public items;
    mapping(uint256 => uint256) private _totalSupply;
    mapping(address => bool) public banned;

    uint256 public nextItemId = 4;

    // ---- Events ----
    event ItemCreated(uint256 indexed id, string name, uint256 price, bool paused);
    event ItemPriceUpdated(uint256 indexed id, uint256 oldPrice, uint256 newPrice);
    event ItemPausedUpdated(uint256 indexed id, bool paused);
    event BaseUriUpdated(string newBaseUri);
    event TreasuryUpdated(address indexed newTreasury);
    event BannedUpdated(address indexed user, bool banned);

    constructor(address usdc_) ERC1155("") Ownable(msg.sender) {
        if (usdc_ == address(0)) revert ZeroAddress();

        usdc = IERC20(usdc_);
        treasury = msg.sender; // deployer is treasury
        // baseUri intentionally NOT set here (set after deploy)

        // Initial items at $1 (assuming 6-decimal USDC)
        _createItem(BEER, "Beer", 1_000_000, false);
        _createItem(RED_WINE, "Red Wine", 1_000_000, false);
        _createItem(PORK_SCRATCHINGS, "Pork Scratchings", 1_000_000, false);
    }

    // -----------------------
    // Metadata (off-chain)
    // -----------------------
    function setBaseUri(string calldata newBaseUri) external onlyOwner {
        baseUri = newBaseUri;
        baseUriSet = true;
        emit BaseUriUpdated(newBaseUri);
    }

    function uri(uint256 id) public view override returns (string memory) {
        if (!items[id].exists) revert UnknownItem();
        if (!baseUriSet) revert BaseUriNotSet();
        return string.concat(baseUri, id.toString(), ".json");
    }

    // -----------------------
    // Admin controls
    // -----------------------
    function setTreasury(address newTreasury) external onlyOwner {
        if (newTreasury == address(0)) revert ZeroAddress();
        treasury = newTreasury;
        emit TreasuryUpdated(newTreasury);
    }

    function setBanned(address user, bool isBanned) external onlyOwner {
        banned[user] = isBanned;
        emit BannedUpdated(user, isBanned);
    }

    function setItemPrice(uint256 id, uint96 newPrice) external onlyOwner {
        if (!items[id].exists) revert UnknownItem();
        uint256 old = items[id].price;
        items[id].price = newPrice;
        emit ItemPriceUpdated(id, old, newPrice);
    }

    function setItemPaused(uint256 id, bool paused_) external onlyOwner {
        if (!items[id].exists) revert UnknownItem();
        items[id].paused = paused_;
        emit ItemPausedUpdated(id, paused_);
    }

    /// Add new items (auto-incrementing id).
    function createNewItem(string calldata name, uint96 price, bool paused_)
        external
        onlyOwner
        returns (uint256 id)
    {
        id = nextItemId++;
        _createItem(id, name, price, paused_);
    }

    /// Add an item with an explicit id (optional).
    function createItemWithId(uint256 id, string calldata name, uint96 price, bool paused_) external onlyOwner {
        if (id == 0) revert UnknownItem();
        if (items[id].exists) revert AlreadyExists();
        if (id >= nextItemId) nextItemId = id + 1;
        _createItem(id, name, price, paused_);
    }

    function _createItem(uint256 id, string memory name, uint96 price, bool paused_) internal {
        if (items[id].exists) revert AlreadyExists();
        items[id] = Item({exists: true, paused: paused_, price: price, name: name});
        emit ItemCreated(id, name, price, paused_);
    }

    // -----------------------
    // Purchasing / Minting
    // -----------------------
    function buy(uint256 id, uint256 amount) external {
        if (banned[msg.sender]) revert Banned();
        if (!items[id].exists) revert UnknownItem();
        if (items[id].paused) revert NotForSale();
        if (amount == 0) revert BadAmount();

        uint256 cost = uint256(items[id].price) * amount;
        bool ok = usdc.transferFrom(msg.sender, treasury, cost);
        if (!ok) revert USDCTransferFailed();

        _mint(msg.sender, id, amount, "");
        _totalSupply[id] += amount;
    }

    function buyBatch(uint256[] calldata ids, uint256[] calldata amounts) external {
        if (banned[msg.sender]) revert Banned();
        uint256 n = ids.length;
        if (n == 0 || n != amounts.length) revert BadAmount();

        uint256 totalCost = 0;
        for (uint256 i = 0; i < n; i++) {
            uint256 id = ids[i];
            uint256 amt = amounts[i];
            if (amt == 0) revert BadAmount();
            if (!items[id].exists) revert UnknownItem();
            if (items[id].paused) revert NotForSale();
            totalCost += uint256(items[id].price) * amt;
        }

        bool ok = usdc.transferFrom(msg.sender, treasury, totalCost);
        if (!ok) revert USDCTransferFailed();

        _mintBatch(msg.sender, ids, amounts, "");

        for (uint256 i = 0; i < n; i++) {
            _totalSupply[ids[i]] += amounts[i];
        }
    }

    // -----------------------
    // Burnable
    // -----------------------
    function burn(address from, uint256 id, uint256 amount) external {
        if (from != msg.sender && !isApprovedForAll(from, msg.sender)) revert("NOT_AUTHORIZED");
        _burn(from, id, amount);
        _totalSupply[id] -= amount;
    }

    function burnBatch(address from, uint256[] calldata ids, uint256[] calldata amounts) external {
        if (from != msg.sender && !isApprovedForAll(from, msg.sender)) revert("NOT_AUTHORIZED");
        _burnBatch(from, ids, amounts);
        for (uint256 i = 0; i < ids.length; i++) {
            _totalSupply[ids[i]] -= amounts[i];
        }
    }

    // -----------------------
    // Supply tracking / views
    // -----------------------
    function totalSupply(uint256 id) external view returns (uint256) {
        if (!items[id].exists) revert UnknownItem();
        return _totalSupply[id];
    }

    function itemInfo(uint256 id)
        external
        view
        returns (string memory name, uint256 price, bool paused, uint256 supply)
    {
        if (!items[id].exists) revert UnknownItem();
        Item storage it = items[id];
        return (it.name, it.price, it.paused, _totalSupply[id]);
    }
}

