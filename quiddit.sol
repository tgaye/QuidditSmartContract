// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
// We need IERC20 to talk to the WETH contract
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract QuidditPlatform is ERC721, Ownable, ReentrancyGuard {
    using Strings for uint256;
    
    uint256 private _tokenIdCounter;
    uint256 public creditExchangeRate = 0.001 ether;
    address public treasuryWallet;
    
    // NEW: The address of the WETH token on your chain
    IERC20 public immutable weth; 
    
    // ============ ORIGINAL FEATURES ============
    
    // Track credit purchases (spending tracked off-chain)
    mapping(address => uint256) public creditDeposits;
    
    // NFT metadata
    mapping(uint256 => string) public tokenAnimationUrls;
    mapping(uint256 => address) public tokenCreators; 
    mapping(uint256 => uint256) public tokenDropIds; 
    
    // Drop tracking
    uint256 public currentDropId;
    
    // State backup
    uint256 public lastSnapshotTimestamp;
    string public lastSnapshotReference;
    
    // ============ EVENTS ============
    
    event CreditsPurchased(address indexed buyer, uint256 credits, uint256 ethPaid);
    event CreditExchangeRateUpdated(uint256 newRate);
    event NFTMinted(
        uint256 indexed tokenId,
        address indexed auctionWinner,
        address indexed originalArtist,
        string animationUrl,
        uint256 dropId
    );
    event DropAnnounced(uint256 indexed dropId, uint256 timestamp);
    event StateSnapshot(
        uint256 indexed timestamp,
        uint256 blockNumber,
        string storageReference,
        bytes32 contentHash,
        string description
    );

    // Replaced internal ledger events with a single settlement event
    event WethAuctionSettled(uint256 indexed tokenId, address indexed winner, uint256 price);
    
    // Pass the WETH address in the constructor (e.g., Mainnet WETH or Goerli WETH)
    constructor(address _treasuryWallet, address _wethAddress) 
        ERC721("Quiddit Creation", "QUIDDIT") 
        Ownable(msg.sender) 
    {
        require(_treasuryWallet != address(0), "Invalid treasury");
        require(_wethAddress != address(0), "Invalid WETH address");
        
        treasuryWallet = _treasuryWallet;
        weth = IERC20(_wethAddress);
        currentDropId = 1;
    }

    // ============ NEW FEATURE: WETH SETTLEMENT ============

    /**
     * @dev SETTLEMENT for WETH Auctions.
     * Replaces the old "Exchange Balance" logic.
     * * Pre-requisite: User must have called weth.approve(address(this), amount)
     */
    function finalizeWethAuction(
        address winner,
        uint256 finalPrice,
        address artist,
        string calldata animationUrl,
        uint256 dropId
    ) external onlyOwner nonReentrant {
        // 1. PULL FUNDS
        // We attempt to transfer WETH from the winner to the treasury.
        // If the user revoked approval OR moved their funds, this line REVERTS.
        // This provides the exact same "Troll Protection" as the previous contract.
        bool success = weth.transferFrom(winner, treasuryWallet, finalPrice);
        require(success, "WETH transfer failed: Insufficient Balance or Allowance");

        // 2. Mint using your existing logic
        mintToAuctionWinner(winner, artist, animationUrl, dropId);

        emit WethAuctionSettled(_tokenIdCounter - 1, winner, finalPrice);
    }
    
    // ============ ORIGINAL CREDIT SYSTEM (UNCHANGED) ============
    
    // Note: Buying credits still uses native ETH because it's an instant purchase.
    // You could switch this to WETH too, but native ETH is usually easier for "Top Ups".
    function buyCredits(uint256 credits) external payable nonReentrant {
        require(credits > 0, "Must buy at least 1 credit");
        uint256 cost = credits * creditExchangeRate;
        require(msg.value == cost, "Incorrect payment amount");
        
        creditDeposits[msg.sender] += credits;
        
        (bool success, ) = treasuryWallet.call{value: msg.value}("");
        require(success, "Treasury payment failed");
        
        emit CreditsPurchased(msg.sender, credits, msg.value);
    }
    
    function setCreditExchangeRate(uint256 newRate) external onlyOwner {
        creditExchangeRate = newRate;
        emit CreditExchangeRateUpdated(newRate);
    }
    
    // ============ DROP MANAGEMENT (PRESERVED) ============
    
    function announceNewDrop() external onlyOwner {
        emit DropAnnounced(currentDropId, block.timestamp);
        currentDropId++;
    }
    
    function mintToAuctionWinner(
        address auctionWinner,
        address originalArtist,
        string calldata animationUrl,
        uint256 dropId
    ) public onlyOwner returns (uint256) {
        uint256 tokenId = _tokenIdCounter++;
        
        tokenCreators[tokenId] = originalArtist;
        tokenAnimationUrls[tokenId] = animationUrl;
        tokenDropIds[tokenId] = dropId;
        
        _safeMint(auctionWinner, tokenId);
        
        emit NFTMinted(tokenId, auctionWinner, originalArtist, animationUrl, dropId);
        
        return tokenId;
    }
    
    function batchMintToAuctionWinners(
        address[] calldata auctionWinners,
        address[] calldata originalArtists,
        string[] calldata animationUrls,
        uint256 dropId
    ) external onlyOwner {
        require(
            auctionWinners.length == originalArtists.length &&
            auctionWinners.length == animationUrls.length,
            "Array length mismatch"
        );
        
        for (uint256 i = 0; i < auctionWinners.length; i++) {
            mintToAuctionWinner(
                auctionWinners[i],
                originalArtists[i],
                animationUrls[i],
                dropId
            );
        }
    }
    
    // ============ BACKUP SYSTEM (PRESERVED) ============
    
    function recordStateSnapshot(
        string calldata storageReference,
        bytes32 contentHash,
        string calldata description
    ) external onlyOwner {
        require(bytes(storageReference).length > 0, "Storage reference required");
        lastSnapshotTimestamp = block.timestamp;
        lastSnapshotReference = storageReference;
        emit StateSnapshot(
            block.timestamp,
            block.number,
            storageReference,
            contentHash,
            description
        );
    }
    
    function recordSnapshot(string calldata ipfsHash) external onlyOwner {
        require(bytes(ipfsHash).length > 0, "IPFS hash required");
        lastSnapshotTimestamp = block.timestamp;
        lastSnapshotReference = ipfsHash;
        emit StateSnapshot(
            block.timestamp,
            block.number,
            ipfsHash,
            bytes32(0),
            "snapshot"
        );
    }
    
    // ============ VIEW FUNCTIONS ============
    
    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId);
        return string(
            abi.encodePacked(
                "https://quiddit.ai/metadata/",
                tokenId.toString(),
                ".json"
            )
        );
    }
    
    function getLastSnapshot() external view returns (
        uint256 timestamp,
        string memory snapshotReference
    ) {
        return (lastSnapshotTimestamp, lastSnapshotReference);
    }
    
    function totalSupply() external view returns (uint256) {
        return _tokenIdCounter;
    }
    
    // ============ ADMIN ============
    
    function setTreasuryWallet(address newTreasury) external onlyOwner {
        require(newTreasury != address(0), "Invalid address");
        treasuryWallet = newTreasury;
    }
    
    // Function to withdraw ETH if anyone accidentally sends it directly
    function emergencyWithdraw() external onlyOwner nonReentrant {
        uint256 balance = address(this).balance;
        (bool success, ) = treasuryWallet.call{value: balance}("");
        require(success, "Withdrawal failed");
    }
    
    receive() external payable {}
}