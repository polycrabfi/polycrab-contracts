// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import {MathUpgradeable} from "@openzeppelin/contracts-upgradeable/math/MathUpgradeable.sol";
import {SafeMathUpgradeable} from "@openzeppelin/contracts-upgradeable/math/SafeMathUpgradeable.sol";
import {IERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {SafeERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/SafeERC20Upgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/Initializable.sol";

import {IFeeDistributor} from "./interfaces/IFeeDistributor.sol";
import {ICrabToken} from "./interfaces/ICrabToken.sol";
import {IStrategy} from "./interfaces/IStrategy.sol";
import {MasterChefStorage} from "./MasterChefStorage.sol";

// MasterChef is the farming and yield optimizing contract for CRAB. It can mint new
// CRAB tokens and also act as a vault to optimize yields for stakers in the smart contract.
//
// Note that it's ownable and the owner wields tremendous power. The ownership
// will be transferred to a governance smart contract once CRAB is sufficiently
// distributed and the community can show to govern itself.
//
// Have fun reading it. Hopefully it's bug-free. God bless.
contract MasterChef is Initializable, OwnableUpgradeable, ReentrancyGuardUpgradeable, MasterChefStorage {
    using SafeMathUpgradeable for uint256;
    using SafeERC20Upgradeable for IERC20Upgradeable;

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event SetFeeAddress(address indexed user, address indexed newAddress);
    event SetDevAddress(address indexed user, address indexed newAddress);
    event UpdateEmissionRate(address indexed user, uint256 crabPerBlock);
    event StrategyChangeQueued(uint256 indexed pid, address indexed strategy);
    event StrategyUpdated(uint256 indexed pid, address indexed strategy);

    constructor() public { }

    function initialize(
        ICrabToken _crab,
        address _devaddr,
        address _feeAddress,
        uint256 _crabPerBlock,
        uint256 _startBlock
    ) public initializer {
        __Ownable_init();
        __ReentrancyGuard_init();

        crab = _crab;
        devaddr = _devaddr;
        feeAddress = _feeAddress;
        crabPerBlock = _crabPerBlock;
        startBlock = _startBlock;

        unsalvageableTokens[address(crab)] = true;
    }

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    mapping(IERC20Upgradeable => bool) public poolExistence;
    modifier nonDuplicated(IERC20Upgradeable _lpToken) {
        require(poolExistence[_lpToken] == false, "nonDuplicated: duplicated");
        _;
    }

    /// @notice Adds a new pool to the MasterChef contract.
    /// @param _allocPoint Reward allocation point of the pool.
    /// @param _lpToken Underlying token of the pool.
    /// @param _depositFeeBP Deposit tax percentage in basis points.
    /// @param _strategy Strategy of the pool.
    /// @param _withUpdate Should massUpdatePools be called.
    function add(uint256 _allocPoint, IERC20Upgradeable _lpToken, uint16 _depositFeeBP, IStrategy _strategy, bool _withUpdate) public onlyOwner nonDuplicated(_lpToken) {
        require(_depositFeeBP <= 10000, "MasterChef: Invalid deposit fee basis points");
        if (_withUpdate) {
            massUpdatePools();
        }
        uint256 lastRewardBlock = block.number > startBlock ? block.number : startBlock;
        totalAllocPoint = totalAllocPoint.add(_allocPoint);
        poolExistence[_lpToken] = true;
        unsalvageableTokens[address(_lpToken)] = true;
        uint256 unit = 10 ** uint256(ERC20Upgradeable(address(_lpToken)).decimals());
        poolInfo.push(PoolInfo({
            lpToken: _lpToken,
            allocPoint: _allocPoint,
            lastRewardBlock: lastRewardBlock,
            accCrabPerShare: 0,
            depositFeeBP: _depositFeeBP,
            totalSharesSupply: 0,
            strategy: _strategy,
            nextStrategy: IStrategy(address(0)),
            nextStrategyTimestamp: 0,
            underlyingUnit: unit
        }));
    }

    /// @notice Allows for updating information on the specified pool.
    /// @param _pid Pool to update.
    /// @param _allocPoint Allocation point for CRAB rewards.
    /// @param _depositFeeBP Deposit fee of the pool.
    function set(uint256 _pid, uint256 _allocPoint, uint16 _depositFeeBP, bool _withUpdate) public onlyOwner {
        require(_depositFeeBP <= 10000, "MasterChef: Invalid deposit fee basis points");
        if (_withUpdate) {
            massUpdatePools();
        }
        totalAllocPoint = totalAllocPoint.sub(poolInfo[_pid].allocPoint).add(_allocPoint);
        poolInfo[_pid].allocPoint = _allocPoint;
        poolInfo[_pid].depositFeeBP = _depositFeeBP;
    }

    /// @notice Queues a strategy update to the pool.
    /// @param _pid Pool to update the strategy of.
    /// @param _strategy The next strategy of the pool.
    function queueStrategyUpdate(
        uint256 _pid, 
        IStrategy _strategy
    ) public onlyOwner {
        PoolInfo storage pool = poolInfo[_pid];
        pool.nextStrategy = _strategy;
        pool.nextStrategyTimestamp = block.timestamp.add(STRATEGY_SWITCH_DELAY);
        emit StrategyChangeQueued(_pid, address(_strategy));
    }

    /// @notice Finalizes strategy update.
    /// @param _pid Pool to finalize the strategy upgrade of.
    /// @param _strategy The new strategy of the pool.
    function setStrategy(
        uint256 _pid, 
        IStrategy _strategy
    ) public onlyOwner {
        PoolInfo storage pool = poolInfo[_pid];
        require(block.timestamp >= pool.nextStrategyTimestamp, "MasterChef: Timelock has not passed yet");
        require(_strategy == pool.nextStrategy, "MasterChef: _strategy is not pool's next strategy");
        pool.strategy.withdrawAll();
        pool.strategy = _strategy;
        if(address(pool.strategy) != address(0)) {
            pool.lpToken.safeTransfer(address(pool.strategy), pool.lpToken.balanceOf(address(this)));
            pool.strategy.invest();
        }
        emit StrategyUpdated(_pid, address(_strategy));
    }

    /// @notice Reward multiplier over a given time.
    /// @param _from The block for rewards from.
    /// @param _to The block for rewards to.
    function getMultiplier(uint256 _from, uint256 _to) public pure returns (uint256) {
        return _to.sub(_from).mul(BONUS_MULTIPLIER);
    }

    /// @notice View function to view pending CRAB tokens on the frontend.
    /// @param _pid ID of the pool.
    /// @param _user User to view the rewards of.
    function pendingCrab(uint256 _pid, address _user) external view returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accCrabPerShare = pool.accCrabPerShare;
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (block.number > pool.lastRewardBlock && lpSupply != 0) {
            uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
            uint256 crabReward = multiplier.mul(crabPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
            accCrabPerShare = accCrabPerShare.add(crabReward.mul(1e12).div(lpSupply));
        }
        return user.amount.mul(accCrabPerShare).div(1e12).sub(user.rewardDebt);
    }

    /// @notice Gets the value of the user's stake in the specified pool.
    /// @param _pid Pool to get the value of.
    /// @param _user User to get the stake of.
    function valueOfStakeForUser(
        uint256 _pid, 
        address _user
    ) external view returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        if(pool.totalSharesSupply == 0) {
            return 0;
        }
        return underlyingBalanceWithInvestment(_pid)
            .mul(user.amount)
            .div(pool.totalSharesSupply);
    }

    /// @notice Updates the reward variables of all pools.
    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    /// @notice Updates the reward variables of the specified pool.
    /// @param _pid Pool to update.
    function updatePool(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.number <= pool.lastRewardBlock) {
            return;
        }
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (lpSupply == 0 || pool.allocPoint == 0) {
            pool.lastRewardBlock = block.number;
            return;
        }
        uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
        uint256 crabReward = multiplier.mul(crabPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
        crab.mint(devaddr, crabReward.div(10));
        crab.mint(address(this), crabReward);
        pool.accCrabPerShare = pool.accCrabPerShare.add(crabReward.mul(1e12).div(lpSupply));
        pool.lastRewardBlock = block.number;
    }

    /// @notice Deposit tokens into the Masterchef contract.
    /// @param _pid ID of the pool to deposit in.
    /// @param _amount Amount to deposit into the pool.
    function deposit(uint256 _pid, uint256 _amount) public {
        _deposit(_pid, msg.sender, msg.sender, _amount);
    }

    /// @notice Deposit tokens into the MasterChef for someone else.
    /// @param _pid ID of the pool to deposit in.
    /// @param _to Address to receive the deposit.
    /// @param _amount Amount of tokens to deposit.
    function depositFor(uint256 _pid, address _to, uint256 _amount) public {
        _deposit(_pid, msg.sender, _to, _amount);
    }
 
    /// @notice Internal function to handle deposits.
    /// @param _pid Pool for the deposit to go to.
    /// @param _from Address to transfer the pool tokens from.
    /// @param _to Address to credit with the deposit from `_from`.
    /// @param _amount The amount to transfer from `_from`.
    function _deposit(uint256 _pid, address _from, address _to, uint256 _amount) internal nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_to];
        updatePool(_pid);
        if (user.amount > 0) {
            uint256 pending = user.amount.mul(pool.accCrabPerShare).div(1e12).sub(user.rewardDebt);
            if (pending > 0) {
                _safeCrabTransfer(_to, pending);
            }
        }
        if (_amount > 0) {
            pool.lpToken.safeTransferFrom(address(_from), address(this), _amount);
            if (pool.depositFeeBP > 0) {
                uint256 depositFee = _amount.mul(pool.depositFeeBP).div(10000);
                pool.lpToken.safeTransfer(feeAddress, depositFee);
                uint256 amountAfterFee = _amount.sub(depositFee);
                uint256 sharesForUser = pool.totalSharesSupply == 0
                    ? amountAfterFee
                    : amountAfterFee.mul(pool.totalSharesSupply).div(underlyingBalanceWithInvestment(_pid));
                pool.totalSharesSupply = pool.totalSharesSupply.add(sharesForUser);
                user.amount = user.amount.add(sharesForUser);
                if(address(pool.strategy) != address(0)) {
                    pool.lpToken.safeTransfer(address(pool.strategy), pool.lpToken.balanceOf(address(this)));
                    pool.strategy.invest();
                }
            } else {
                uint256 sharesForUser = pool.totalSharesSupply == 0
                    ? _amount
                    : _amount.mul(pool.totalSharesSupply).div(underlyingBalanceWithInvestment(_pid));
                pool.totalSharesSupply = pool.totalSharesSupply.add(sharesForUser);
                user.amount = user.amount.add(sharesForUser);
                if(address(pool.strategy) != address(0)) {
                    pool.lpToken.safeTransfer(address(pool.strategy), pool.lpToken.balanceOf(address(this)));
                    pool.strategy.invest();
                }
            }
        }
        user.rewardDebt = user.amount.mul(pool.accCrabPerShare).div(1e12);
        emit Deposit(msg.sender, _pid, _amount);
    }

    /// @notice Withdraw LP tokens from MasterChef contract.
    /// @param _pid ID of the pool to withdraw from.
    /// @param _amount Amount to withdraw.
    function withdraw(uint256 _pid, uint256 _amount) public nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        require(user.amount >= _amount, "MasterChef: Cannot withdraw more than deposited amount");
        updatePool(_pid);
        uint256 pending = user.amount.mul(pool.accCrabPerShare).div(1e12).sub(user.rewardDebt);
        if (pending > 0) {
            _safeCrabTransfer(msg.sender, pending);
        }
        if (_amount > 0) {
            user.amount = user.amount.sub(_amount);
            uint256 amountToWithdraw = underlyingBalanceWithInvestment(_pid).mul(_amount).div(pool.totalSharesSupply);
            if(amountToWithdraw > pool.lpToken.balanceOf(address(this))) {
                if(_amount == pool.totalSharesSupply) {
                    pool.strategy.withdrawAll();
                } else {
                    uint256 missing = amountToWithdraw.sub(pool.lpToken.balanceOf(address(this)));
                    pool.strategy.withdraw(missing);
                }

                amountToWithdraw = MathUpgradeable.min(underlyingBalanceWithInvestment(_pid)
                    .mul(_amount)
                    .div(pool.totalSharesSupply), pool.lpToken.balanceOf(address(this)));

            }
            pool.lpToken.safeTransfer(address(msg.sender), amountToWithdraw);
        }
        pool.totalSharesSupply = pool.totalSharesSupply.sub(_amount);
        user.rewardDebt = user.amount.mul(pool.accCrabPerShare).div(1e12);
        emit Withdraw(msg.sender, _pid, _amount);
    }

    /// @notice Withdraw without caring about rewards. EMERGENCY ONLY.
    /// @param _pid ID of the pool to withdraw from.
    function emergencyWithdraw(uint256 _pid) public nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        uint256 amount = user.amount;
        user.amount = 0;
        user.rewardDebt = 0;
        uint256 amountToWithdraw = underlyingBalanceWithInvestment(_pid).mul(amount).div(pool.totalSharesSupply);
        if(amountToWithdraw > pool.lpToken.balanceOf(address(this))) {
            if(amount == pool.totalSharesSupply) {
                pool.strategy.withdrawAll();
            } else {
                uint256 missing = amountToWithdraw.sub(pool.lpToken.balanceOf(address(this)));
                pool.strategy.withdraw(missing);
            }
            amountToWithdraw = MathUpgradeable.min(underlyingBalanceWithInvestment(_pid)
                .mul(amount)
                .div(pool.totalSharesSupply), pool.lpToken.balanceOf(address(this)));
            }
        pool.totalSharesSupply = pool.totalSharesSupply.sub(amount);
        pool.lpToken.safeTransfer(address(msg.sender), amountToWithdraw);
        emit EmergencyWithdraw(msg.sender, _pid, amountToWithdraw);
    }

    /// @notice Safe transfer function for CRAB.
    function _safeCrabTransfer(address _to, uint256 _amount) internal {
        uint256 crabBal = crab.balanceOf(address(this));
        bool transferSuccess = false;
        if (_amount > crabBal) {
            transferSuccess = crab.transfer(_to, crabBal);
        } else {
            transferSuccess = crab.transfer(_to, _amount);
        }
        require(transferSuccess, "MasterChef: Transfer failed");
    }

    /// @notice Allows the dev address to update the devshare address.
    /// @param _devaddr New dev address.
    function dev(address _devaddr) public {
        require(msg.sender == devaddr, "MasterChef: Caller not devaddr");
        devaddr = _devaddr;
        emit SetDevAddress(msg.sender, _devaddr);
    }

    /// @notice Sets the address that receives deposit fees.
    /// @param _feeAddress Address that receives the fees.
    function setFeeDistributor(address _feeAddress) public onlyOwner {
        feeAddress = _feeAddress;
        emit SetFeeAddress(msg.sender, _feeAddress);
    }

    /// @notice Sets the emission rate of CRAB tokens.
    /// @param _crabPerBlock CRAB tokens to emit per block.
    function updateEmissionRate(uint256 _crabPerBlock) public onlyOwner {
        crabPerBlock = _crabPerBlock;
        emit UpdateEmissionRate(msg.sender, _crabPerBlock);
    }

    /// @notice Allows for recovering tokens from the contract, excluding vault tokens.
    /// @param _token To recover.
    /// @param _amount Amount of tokens to recover.
    function inCaseTokensGetStuck(address _token, uint256 _amount)
        public
        onlyOwner
    {
        require(!unsalvageableTokens[_token], "MasterChef: Token unsalvageable");
        IERC20Upgradeable(_token).safeTransfer(msg.sender, _amount);
    }

    /// @notice Distributes deposit fees from the specified pool.
    /// @param _pid Pool to distribute from.
    function distributeFees(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        IFeeDistributor(feeAddress).distribute(address(pool.lpToken));
    }

    /// @notice Gets how much is staked and invested in the strategy of the specified pool.
    /// @param _pid Pool to get the information of.
    function underlyingBalanceWithInvestment(
        uint256 _pid
    ) public view returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        if(address(pool.strategy) == address(0)) {
            return pool.lpToken.balanceOf(address(this));
        }
        return pool.lpToken.balanceOf(address(this)).add(pool.strategy.investedUnderlyingBalance());
    }
}