pragma solidity 0.6.12;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./interfaces/IRewardPool.sol";
import "./interfaces/IUniswapV2Router02.sol";
import "./lib/Governable.sol";

contract FeeRewardForwarder is Governable {
  using SafeMath for uint256;
  using SafeERC20 for IERC20;

  mapping (address => mapping (address => address[])) public routes;

  // The targeted reward token to convert everything to
  address public targetToken;
  address public profitSharingPool;

  address public router;

  event TokenPoolSet(address token, address pool);

  constructor(address _storage, address _router) public Governable(_storage) {
    require(_router != address(0), "FeeRewardForwarder: Router not defined");
    router = _router;
  }

  /*
  *   Set the pool that will receive the reward token
  *   based on the address of the reward Token
  */
  function setTokenPool(address _pool) public onlyGovernance {
    targetToken = IRewardPool(_pool).rewardToken();
    profitSharingPool = _pool;
    emit TokenPoolSet(targetToken, _pool);
  }

  /**
  * Sets the path for swapping tokens to the to address
  * The to address is not validated to match the targetToken,
  * so that we could first update the paths, and then,
  * set the new target
  */
  function setConversionPath(address from, address to, address[] memory _route)
  public onlyGovernance {
    require(from == _route[0],
      "FeeRewardForwarder: The first token of the route must be the from token");
    require(to == _route[_route.length - 1],
      "FeeRewardForwarder: The last token of the route must be the to token");
    routes[from][to] = _route;
  }

  // Transfers the funds from the msg.sender to the pool
  // under normal circumstances, msg.sender is the strategy
  function poolNotifyFixedTarget(address _token, uint256 _amount) external {
    if (targetToken == address(0)) {
      return; // a No-op if target pool is not set yet
    }
    if (_token == targetToken) {
      // This is already the right token
      IERC20(_token).safeTransferFrom(msg.sender, profitSharingPool, _amount);
      IRewardPool(profitSharingPool).notifyRewardAmount(_amount);
    } else {
      // We need to convert
      if (routes[_token][targetToken].length > 1) {
        IERC20(_token).safeTransferFrom(msg.sender, address(this), _amount);
        uint256 balanceToSwap = IERC20(_token).balanceOf(address(this));

        IERC20(_token).safeApprove(router, 0);
        IERC20(_token).safeApprove(router, balanceToSwap);

        IUniswapV2Router02(router).swapExactTokensForTokens(
          balanceToSwap,
          1, // We will accept any amount
          routes[_token][targetToken],
          address(this),
          block.timestamp
        );
        // Now we can send this token forward
        uint256 convertedRewardAmount = IERC20(targetToken).balanceOf(address(this));
        IERC20(targetToken).safeTransfer(profitSharingPool, convertedRewardAmount);
        IRewardPool(profitSharingPool).notifyRewardAmount(convertedRewardAmount);
      }
      // Else the route does not exist for this token
      // do not take any fees - leave them in the controller
    }
  }

}