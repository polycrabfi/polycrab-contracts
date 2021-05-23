// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import {IERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import {ICrabToken} from "./interfaces/ICrabToken.sol";
import {IStrategy} from "./interfaces/IStrategy.sol";

contract MasterChefStorage {
        // Info of each user.
    struct UserInfo {
        uint256 amount;         // How many LP tokens the user has provided.
        uint256 rewardDebt;     // Reward debt. See explanation below.
        //
        // We do some fancy math here. Basically, any point in time, the amount of CRAB
        // entitled to a user but is pending to be distributed is:
        //
        //   pending reward = (user.amount * pool.accCrabPerShare) - user.rewardDebt
        //
        // Whenever a user deposits or withdraws LP tokens to a pool. Here's what happens:
        //   1. The pool's `accCrabPerShare` (and `lastRewardBlock`) gets updated.
        //   2. User receives the pending reward sent to his/her address.
        //   3. User's `amount` gets updated.
        //   4. User's `rewardDebt` gets updated.
    }

    // Info of each pool.
    struct PoolInfo {
        IERC20Upgradeable lpToken;// Address of LP token contract.
        uint256 allocPoint;       // How many allocation points assigned to this pool. CRAB to distribute per block.
        uint256 lastRewardBlock;  // Last block number that CRAB distribution occurs.
        uint256 accCrabPerShare;  // Accumulated CRAB per share, times 1e12. See below.
        uint16 depositFeeBP;      // Deposit fee in basis points
        uint256 totalSharesSupply;// Total shares of the pool.
        IStrategy strategy;       // Strategy for the vault.
        IStrategy nextStrategy;   // Latest strategy to upgrade to.
        uint256 nextStrategyTimestamp;  // When the new strategy can be added.
        uint256 underlyingUnit;   // Unit of the vault underlying for calculations.
    }

    // The CRAB TOKEN!
    ICrabToken public crab;
    // Dev address.
    address public devaddr;
    // CRAB tokens created per block.
    uint256 public crabPerBlock;
    // Bonus muliplier for early CRAB farmers.
    uint256 public constant BONUS_MULTIPLIER = 1;
    // Deposit Fee address
    address public feeAddress;
    // Info of each pool.
    PoolInfo[] public poolInfo;
    // Info of each user that stakes LP tokens.
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;
    // Total allocation points. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint = 0;
    // The block number when CRAB farming starts.
    uint256 public startBlock;
    // Delay for switching strategies on vaults.
    uint256 public constant STRATEGY_SWITCH_DELAY = 12 hours;
    // Tokens that cannot be transferred out by `inCaseTokensGetStuck`
    mapping(address => bool) public unsalvageableTokens;
}