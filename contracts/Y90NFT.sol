// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Royalty.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Votes.sol";
import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Counters.sol";

interface IYield90 {
    function burnFromCirculating(uint256 amount, address burner, uint256 tokenId) external;
    function balanceOf(address account) external view returns (uint256);
    function getCirculatingBurnLimit() external pure returns (uint256);
    function totalBurnt() external view returns (uint256);
    function getRemainingBurnCapacity() external view returns (uint256);
    function registerGovernanceNFT(uint256 tokenId, uint256 voteWeight) external;
}

contract Y90NFT is ERC721, ERC721Enumerable, ERC721Votes, ERC721Royalty, ERC721URIStorage, Ownable, ReentrancyGuard {
    using Counters for Counters.Counter;    
    IYield90 public yield90;
    Counters.Counter private _tokenIdCounter;
    struct BurnNFT {
        uint256 burnAmount;
        uint256 mintPrice;
        bool used;
    }
    struct BurnRecord {
        uint256 totalBurnt;
        uint256 lastBurnTime;
        uint256 burnCount;
    }
    mapping(uint256 => BurnNFT) public burnNFTs;
    mapping(address => BurnRecord) public burnRecords;
    mapping(uint256 => uint256) public burnPower;
    address public royaltyRecipient;
    string private _baseTokenURI;
    uint96 public constant ROYALTY_BASIS_POINTS = 1000;
    uint256 public constant YIELD90_INIT_DEX_CEX_SUPPLY = 2_000_000_000 * 10**18;
    event BurnNFTMinted(uint256 indexed tokenId, uint256 burnAmount, uint256 mintPrice, uint256 burnPower);
    event BurnNFTUsed(uint256 indexed tokenId, address indexed burner, uint256 amount);
    event Y90Yield90Updated(address indexed newYield90);
    constructor(address _yield90, address multisig) ERC721("Y90NFT", "Y90NFT") EIP712("Y90NFT", "1") {
        require(_yield90 != address(0), "Invalid Yield90 address.");
        require(multisig != address(0), "Invalid multisig");
        _transferOwnership(multisig);

        yield90 = IYield90(_yield90);
        royaltyRecipient = multisig;
        _setDefaultRoyalty(royaltyRecipient, ROYALTY_BASIS_POINTS);
    }

    function tokenURI(uint256 tokenId) public view override(ERC721, ERC721URIStorage) returns (string memory) {
        require(_exists(tokenId), "NFT does not exist");
        string memory base = _baseTokenURI;
        require(bytes(base).length > 0, "Base URI not set");
        if (bytes(base)[bytes(base).length - 1] != bytes1("/")) {
            base = string(abi.encodePacked(base, "/"));
        }
        return string(abi.encodePacked(
            base,
            Strings.toString(tokenId),
            burnNFTs[tokenId].used ? "-used.json" : ".json"
        ));
    }

    function setRoyaltyRecipient(address newRecipient) external onlyOwner {
        require(newRecipient != address(0), "Invalid recipient");
        royaltyRecipient = newRecipient;
        _setDefaultRoyalty(royaltyRecipient, ROYALTY_BASIS_POINTS);
    }

    function mintBurnNFT(address to, uint256 burnPercentage, uint256 mintPrice) external onlyOwner {
        require(burnPercentage >= 1 && burnPercentage <= 15, "Burn power must be 1-15%");
        _tokenIdCounter.increment();
        uint256 tokenId = _tokenIdCounter.current();
        uint256 burnAmount = (YIELD90_INIT_DEX_CEX_SUPPLY * burnPercentage) / 100;
        uint256 remainingCapacity = yield90.getRemainingBurnCapacity();
        require(burnAmount <= remainingCapacity, "Not enough remaining burn capacity");
        yield90.registerGovernanceNFT(tokenId, burnPercentage);
        _safeMint(to, tokenId);
        burnNFTs[tokenId] = BurnNFT({
            burnAmount: burnAmount,
            used: false,
            mintPrice: mintPrice
        });
        burnPower[tokenId] = burnPercentage;
        emit BurnNFTMinted(tokenId, burnAmount, mintPrice, burnPercentage);
    }

    function mintNFT(address recipient, string memory uri, uint256 power) external onlyOwner  returns (uint256){
        require(power >= 1 && power <= 15, "Invalid burn power");
        _tokenIdCounter.increment();
        uint256 newItemId = _tokenIdCounter.current();
        _mint(recipient, newItemId);
        _setTokenURI(newItemId, uri);
        burnPower[newItemId] = power;
        uint256 burnAmount = (YIELD90_INIT_DEX_CEX_SUPPLY * power) / 100;
        burnNFTs[newItemId] = BurnNFT({burnAmount: burnAmount,  used: false, mintPrice: 0 });
        yield90.registerGovernanceNFT(newItemId, power);
        return newItemId;
    }
 
    function useBurnNFT(uint256 tokenId) external payable nonReentrant {
        require(!burnNFTs[tokenId].used, "NFT Already used");
        require(ownerOf(tokenId) == msg.sender, "Invalid NFT owner!");
        if (burnNFTs[tokenId].mintPrice > 0) {
            require(msg.value >= burnNFTs[tokenId].mintPrice, "Insufficient payment.");
            (bool sent,) = payable(royaltyRecipient).call{value: msg.value}("");
            require(sent, "Payment failed");
        }
        uint256 burnAmount = burnNFTs[tokenId].burnAmount;
        require(burnAmount <= yield90.getRemainingBurnCapacity(), "Exceeds burn capacity"); 
        burnNFTs[tokenId].used = true; 
        yield90.burnFromCirculating(burnAmount, msg.sender, tokenId);
        emit BurnNFTUsed(tokenId, msg.sender, burnAmount);
    }

    function getBurnCapacity(address owner, uint256 tokenId) public view returns (uint256) {
        require(ownerOf(tokenId) == owner, "Not NFT owner");
        require(!burnNFTs[tokenId].used, "NFT already used");
        return burnNFTs[tokenId].burnAmount;
    }
 
    function isBurnVerified(uint256 tokenId) external view returns (bool) {
        require(_exists(tokenId), "NFT does not exist");
        return !burnNFTs[tokenId].used;
    }
 
    function markAsUsed(uint256 tokenId) external onlyOwner {
        require(_exists(tokenId), "NFT does not exist");
        require(!burnNFTs[tokenId].used, "Already used");
        burnNFTs[tokenId].used = true;
    }

    modifier onlyYield90() {
        require(msg.sender == address(yield90), "Only Yield90");
        _;
    }
 
    function verifyBurnCompletion(address burnInitiator, uint256 amount) external onlyYield90 returns (bool) {
        BurnRecord storage record = burnRecords[burnInitiator];
        record.totalBurnt += amount;
        record.lastBurnTime = block.timestamp;
        record.burnCount++;
        return true;
    }
 
    function setYield90(address _newYield90) external onlyOwner {
        require(_newYield90 != address(0), "Invalid address");
        yield90 = IYield90(_newYield90);
        emit Y90Yield90Updated(_newYield90);
    }
 
    function withdraw() external onlyOwner {
        payable(owner()).transfer(address(this).balance);
    }
 
    function _beforeTokenTransfer(address from, address to, uint256 tokenId, uint256 batchSize) internal override(ERC721, ERC721Enumerable) {
        super._beforeTokenTransfer(from, to, tokenId, batchSize);
    }

    function _afterTokenTransfer(address from, address to, uint256 tokenId, uint256 batchSize) internal override(ERC721, ERC721Votes) {
        super._afterTokenTransfer(from, to, tokenId, batchSize);
    }

    function _burn(uint256 tokenId) internal override(ERC721, ERC721Royalty, ERC721URIStorage) {
        super._burn(tokenId);
    }

    function _baseURI() internal view override returns (string memory) {
        return _baseTokenURI;
    }

    function setBaseURI(string memory baseURI) external onlyOwner {
        _baseTokenURI = baseURI;
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC721, ERC721Enumerable, ERC721Royalty, ERC721URIStorage) returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}