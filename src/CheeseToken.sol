// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ICheeseToken} from "./interfaces/ICheeseToken.sol";
import {SqueekIssuance} from "./libraries/SqueekIssuance.sol";

/// @title CheeseToken ($CHEESE)
/// @notice 18-decimal ERC-20 with a 2,100,000,000 CHEESE lifetime cap that mirrors SQK's supply model:
///         a 210,000,000 premint (63M team / 63M treasury / 84M liquidity, the verified SQK split) minted
///         in the constructor, and a 1,890,000,000 mining allowance that only the immutable emission
///         authority (CheeseEmissionController) can mint, block by verified Squeek block.
/// @dev No owner. Nothing in this contract is administrable after deployment: the emission authority is
///      fixed at construction and no other address can ever mint. Burns lower totalSupply but never
///      reopen the cap, because the cap bounds totalMinted (as SqueekToken does).
contract CheeseToken is ERC20, ERC20Permit, ICheeseToken {
    uint256 public constant MAX_SUPPLY = SqueekIssuance.SUPPLY_CAP;
    uint256 public constant PREMINT = SqueekIssuance.PREMINT;
    uint256 public constant MINING_ALLOWANCE = SqueekIssuance.ALLOWANCE;

    /// @notice The only address that may mint after construction.
    address public immutable emissionAuthority;

    uint256 public totalMinted;
    uint256 public totalBurned;

    event Preminted(
        address indexed teamRecipient, address indexed treasuryRecipient, address indexed liquidityRecipient
    );
    event EmissionMinted(address indexed to, uint256 amount, uint256 totalMinted);

    error ZeroAddress();
    error UnauthorizedMinter(address caller);
    error ExceedsMaxSupply(uint256 requested, uint256 remaining);

    /// @param teamRecipient_ receives the 63,000,000 CHEESE team premint
    /// @param treasuryRecipient_ receives the 63,000,000 CHEESE treasury premint
    /// @param liquidityRecipient_ receives the 84,000,000 CHEESE liquidity premint
    /// @param emissionAuthority_ the CheeseEmissionController; the only minter, forever
    constructor(
        address teamRecipient_,
        address treasuryRecipient_,
        address liquidityRecipient_,
        address emissionAuthority_
    ) ERC20("CHEESE", "CHEESE") ERC20Permit("CHEESE") {
        if (
            teamRecipient_ == address(0) || treasuryRecipient_ == address(0) || liquidityRecipient_ == address(0)
                || emissionAuthority_ == address(0)
        ) revert ZeroAddress();
        emissionAuthority = emissionAuthority_;
        _mint(teamRecipient_, SqueekIssuance.PREMINT_TEAM);
        _mint(treasuryRecipient_, SqueekIssuance.PREMINT_TREASURY);
        _mint(liquidityRecipient_, SqueekIssuance.PREMINT_LIQUIDITY);
        totalMinted = PREMINT;
        emit Preminted(teamRecipient_, treasuryRecipient_, liquidityRecipient_);
    }

    /// @notice The premint, fixed at construction (SqueekToken.totalPreminted analogue).
    function totalPreminted() external pure returns (uint256) {
        return PREMINT;
    }

    /// @notice Mints CHEESE mining emission. Only the emission authority may call; the lifetime cap bounds
    ///         totalMinted, so burned tokens never reopen it.
    function mintEmission(address to, uint256 amount) external {
        if (msg.sender != emissionAuthority) revert UnauthorizedMinter(msg.sender);
        if (to == address(0)) revert ZeroAddress();
        uint256 remaining = MAX_SUPPLY - totalMinted;
        if (amount > remaining) revert ExceedsMaxSupply(amount, remaining);
        totalMinted += amount;
        _mint(to, amount);
        emit EmissionMinted(to, amount, totalMinted);
    }

    /// @notice Burns the caller's CHEESE. Lowers totalSupply, never the minted total the cap bounds.
    function burn(uint256 amount) external {
        totalBurned += amount;
        _burn(msg.sender, amount);
    }
}
