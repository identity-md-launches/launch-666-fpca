// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {CatRenderer} from "./CatRenderer.sol";

/// @title Cats Alive (Fren Pet)
/// @notice Unlimited free commemorative NFTs; live game data is an explicitly trusted reporter's snapshot.
/// @dev No proxy, royalties, mint cap, burn, payable entrypoint, external renderer or HTTP dependency.
contract CatsAlive is ERC721, Ownable2Step, Pausable, ReentrancyGuard {
    using Strings for uint256;

    // This bounds the game population rendered, never the FPCA mint supply.
    uint32 public constant MAX_CATS = 100_000;
    uint32 public immutable originalCats;
    uint64 public immutable originalMintTimestamp;
    uint32 public immutable maxReportAge;

    address public reporter;
    uint256 public totalSupply;
    uint32 public aliveCats;
    uint64 public observedAt;
    uint256 public reportedAt;
    bytes32 public sourceHash;

    error InvalidConfiguration();
    error UnauthorizedReporter();
    error InvalidReport();
    error RenunciationDisabled();

    event ReporterChanged(address indexed previousReporter, address indexed newReporter);
    event CountPublished(uint32 aliveCats, uint64 observedAt, bytes32 indexed sourceHash);
    // ERC-4906. A new report changes metadata for every already minted token.
    event BatchMetadataUpdate(uint256 _fromTokenId, uint256 _toTokenId);

    /// @param initialOwner Explicit administration beneficiary, never implicitly the deploying factory.
    /// @param initialReporter Account responsible for checking and publishing the Fren Pet API snapshot.
    /// @param originalCats_ Verified size of the original, closed game-cat cohort, NOT FPCA supply.
    /// @param originalMintTimestamp_ Verified UTC date of that original game mint, expressed as Unix seconds.
    /// @param maxReportAge_ Freshness threshold in seconds, from one minute through seven days.
    constructor(
        address initialOwner,
        address initialReporter,
        uint32 originalCats_,
        uint64 originalMintTimestamp_,
        uint32 maxReportAge_
    ) ERC721("FPCA", "FPCA") Ownable(initialOwner) {
        if (
            initialReporter == address(0) || originalCats_ == 0 || originalCats_ > MAX_CATS
                || originalMintTimestamp_ == 0 || originalMintTimestamp_ > block.timestamp
                || originalMintTimestamp_ >= 4_102_444_800 || maxReportAge_ < 60 || maxReportAge_ > 7 days
        ) revert InvalidConfiguration();
        reporter = initialReporter;
        originalCats = originalCats_;
        originalMintTimestamp = originalMintTimestamp_;
        maxReportAge = maxReportAge_;
        emit ReporterChanged(address(0), initialReporter);
    }

    /// @notice Mint one NFT to the caller for zero ETH; repeat freely. Gas is paid by the caller.
    function mint() external nonReentrant whenNotPaused returns (uint256 tokenId) {
        tokenId = ++totalSupply;
        _safeMint(msg.sender, tokenId);
    }

    /// @notice Only minting pauses. Existing tokens remain freely transferable.
    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function setReporter(address newReporter) external onlyOwner {
        if (newReporter == address(0)) revert InvalidConfiguration();
        address previousReporter = reporter;
        reporter = newReporter;
        emit ReporterChanged(previousReporter, newReporter);
    }

    /// @notice Publish a newer, recent source observation, including a hash of the archived source evidence.
    /// @dev The hash records provenance; it does not cryptographically verify the API's truthfulness.
    /// Counts can increase to accommodate corrections/revivals, but never exceed the original cohort.
    function publishCount(uint32 alive, uint64 observationTime, bytes32 evidenceHash) external {
        if (msg.sender != reporter) revert UnauthorizedReporter();
        if (
            alive > originalCats || observationTime <= observedAt || observationTime < originalMintTimestamp
                || observationTime > block.timestamp || block.timestamp - observationTime > maxReportAge
                || evidenceHash == bytes32(0)
        ) revert InvalidReport();
        aliveCats = alive;
        observedAt = observationTime;
        reportedAt = block.timestamp;
        sourceHash = evidenceHash;
        emit CountPublished(alive, observationTime, evidenceHash);
        if (totalSupply != 0) emit BatchMetadataUpdate(1, totalSupply);
    }

    function renounceOwnership() public view override onlyOwner {
        revert RenunciationDisabled();
    }

    function isStale() public view returns (bool) {
        return observedAt == 0 || block.timestamp > uint256(observedAt) + maxReportAge;
    }

    function reportStatus() public view returns (string memory) {
        if (observedAt == 0) return "unreported";
        return isStale() ? "stale" : "fresh";
    }

    function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
        return interfaceId == 0x49064906 || super.supportsInterface(interfaceId);
    }

    /// @notice Block-varying SVG fallback. Calls in the same block intentionally share a layout.
    function imageSVG(uint256 tokenId) public view returns (string memory) {
        _requireOwned(tokenId);
        return CatRenderer.svg(
            tokenId,
            aliveCats,
            observedAt,
            reportStatus(),
            keccak256(abi.encode(block.chainid, address(this), block.number, block.timestamp))
        );
    }

    /// @notice Embedded HTML randomizes locally and tries the API, retaining the report if unavailable.
    function animationHTML(uint256 tokenId) public view returns (string memory) {
        _requireOwned(tokenId);
        return CatRenderer.html(tokenId, aliveCats, observedAt, maxReportAge, originalCats, originalMintTimestamp);
    }

    function originalMintStatement() public view returns (string memory) {
        return string.concat(
            uint256(originalCats).toString(),
            " cats were originally minted on ",
            CatRenderer.date(originalMintTimestamp),
            " as a one-time mint. No new cats will ever be minted. This refers to the original Fren Pet game cats; FPCA minting is unlimited."
        );
    }

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId);
        string memory json = string.concat(
            '{"name":"Cats Alive (Fren Pet) #',
            tokenId.toString(),
            '","description":"An unlimited free FPCA collectible tracking the original Fren Pet cats on Base. '
            "Metadata and SVG use the latest authorized onchain report. The interactive artwork tries current API data. "
            'Open the interactive artwork for a new layout. Read status and observed_at for freshness.",'
            '"external_url":"https://pet.game","original_mint":"',
            originalMintStatement(),
            '"',
            _reportFields(),
            ',"attributes":[{"trait_type":"Mint number","value":',
            tokenId.toString(),
            '}],"image":"data:image/svg+xml;base64,',
            Base64.encode(bytes(imageSVG(tokenId))),
            '","animation_url":"data:text/html;base64,',
            Base64.encode(bytes(animationHTML(tokenId))),
            '"}'
        );
        return string.concat("data:application/json;base64,", Base64.encode(bytes(json)));
    }

    function _reportFields() private view returns (string memory) {
        return string.concat(
            ',"alive_cats":',
            observedAt == 0 ? "null" : uint256(aliveCats).toString(),
            ',"status":"',
            reportStatus(),
            '","observed_at":',
            uint256(observedAt).toString(),
            ',"reported_at":',
            reportedAt.toString(),
            ',"max_report_age":',
            uint256(maxReportAge).toString(),
            ',"source_hash":"',
            Strings.toHexString(uint256(sourceHash), 32),
            '","source":"https://api.pet.game","original_cats":',
            uint256(originalCats).toString(),
            ',"original_mint_timestamp":',
            uint256(originalMintTimestamp).toString()
        );
    }
}
