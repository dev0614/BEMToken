//SPDX-License-Identifier:MIT

pragma solidity ^0.8.19;
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "./lib/ABDKMath64x64.sol";
import "forge-std/console.sol";

//Error
error BMS__InsufficientStake();
error BMS__InvalidDuration();
error BMS_InsufficientBalance();
error BMS__StakeFailed();
error BMS__WithdrawFailed();
error BMS__NoRewardsAvailable();
error BMS__InvalidStaker();
error BMS__StakingPeriodNotOver();
error BMS__NoStakeAvailable();
error BMS__StakingInactive();
error BMS__AlreadyPaused();
error BMS__StakingAlreadyActive();
error BMS__StakingPeriodOverTryWithdrawal();
error BMS__StakeExitFailed();

contract BemStaking is AccessControl {
    IERC20 public immutable tokenAddress;
    uint256 public totalSupply;
    uint256 public immutable i_rewardRate;
    bool public isActive = true;

    uint64 public MIN_DURATION = 3 * 30 days;
    uint64 public MAX_DURATION = 2 * 365 days;
    bytes32 public constant STAKER_ADMIN = keccak256("STAKER_ADMIN");
    struct StakeInfo {
        uint256 stakeAmount;
        uint64 duration;
        uint256 stakeBegan;
    }

    //Mapping
    mapping(address => uint32) public stakeCounts;
    mapping(address => mapping(uint32 => StakeInfo)) public stakerInfo;
    mapping(address => bool) public isStaker;

    //Event
    event TokenStaked(
        address staker,
        uint256 amount,
        uint64 stakeBegan,
        uint64 duration,
        uint32 _counter,
        StakeInfo stakeInfo
    );
    event StakeYieldRedeemed(address staker, uint256 rewards, uint32 index);
    event StakerExited(address staker, uint _amount, StakeInfo stakeInfo);

    //Modifier
    modifier hasStake() {
        if (!isStaker[msg.sender]) revert BMS__InvalidStaker();
        _;
    }
    modifier stakingIsActive() {
        if (!isActive) revert BMS__StakingInactive();
        _;
    }

    constructor(IERC20 _token, address stakerAdmin, uint256 rewardRate) {
        tokenAddress = _token;
        i_rewardRate = rewardRate;
        _grantRole(STAKER_ADMIN, stakerAdmin);
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    function stake(uint256 _amount, uint64 _duration) public stakingIsActive {
        if (_amount == 0) revert BMS__InsufficientStake();
        if (_duration < MIN_DURATION || _duration > MAX_DURATION)
            revert BMS__InvalidDuration();
        if (tokenAddress.balanceOf(msg.sender) < _amount)
            revert BMS_InsufficientBalance();

        uint32 stakeCount = stakeCounts[msg.sender];
        StakeInfo memory stakeInfo = StakeInfo(
            _amount,
            _duration,
            block.timestamp
        );
        console.log("stakeBegan:", stakeInfo.stakeBegan);
        stakerInfo[msg.sender][stakeCount] = stakeInfo;
        stakeCounts[msg.sender] = stakeCount + 1;
        stakeCount++;
        if (!tokenAddress.transferFrom(msg.sender, address(this), _amount))
            revert BMS__StakeFailed();
        totalSupply += _amount;
        isStaker[msg.sender] = true;

        emit TokenStaked(
            msg.sender,
            _amount,
            uint64(block.timestamp),
            _duration,
            stakeCount,
            stakeInfo
        );
    }

    function exit() external hasStake {
        uint32 index = stakeCounts[msg.sender];
        StakeInfo memory exitInfo = stakerInfo[msg.sender][index];
        if (exitInfo.stakeAmount > 0) revert BMS__NoStakeAvailable();
        if (block.timestamp > exitInfo.duration)
            revert BMS__StakingPeriodOverTryWithdrawal();

        uint256 exitAmount = exitInfo.stakeAmount;
        exitInfo.stakeAmount = 0;
        // exitInfo.duration = 0;
        // exitInfo.stakeBegan = 0;
        exitInfo = StakeInfo(0, 0, 0);
        if (!tokenAddress.transferFrom(address(this), msg.sender, exitAmount))
            revert BMS__StakeExitFailed();
        emit StakerExited(msg.sender, exitAmount, exitInfo);
    }

    function withdraw() public hasStake {
        uint32 index = stakeCounts[msg.sender];
        StakeInfo memory currentStaker = stakerInfo[msg.sender][index];
        if (block.timestamp - currentStaker.stakeBegan < currentStaker.duration)
            revert BMS__StakingPeriodNotOver();

        uint256 rewards = _getStakeRewards();
        if (rewards <= 0) revert BMS__NoRewardsAvailable();
        currentStaker.stakeBegan = uint64(block.timestamp);
        if (!tokenAddress.transferFrom(msg.sender, address(this), rewards))
            revert BMS__WithdrawFailed();

        emit StakeYieldRedeemed(msg.sender, rewards, index);
    }

    function pauseStaking() public onlyRole(STAKER_ADMIN) returns (bool) {
        if (!isActive) revert BMS__AlreadyPaused();
        isActive = false;
        return isActive;
    }

    function restartStaking() public onlyRole(STAKER_ADMIN) returns (bool) {
        if (isActive) revert BMS__StakingAlreadyActive();
        isActive = false;
        return isActive;
    }

    function grantStakeAdminRole(
        address admin
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _grantRole(STAKER_ADMIN, admin);
    }

    function revokeStakeAdminRole(
        address _admin
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _grantRole(STAKER_ADMIN, _admin);
    }

    function _getStakeRewards() internal view returns (uint256) {
        uint32 index = stakeCounts[msg.sender];
        StakeInfo memory thisStake = stakerInfo[msg.sender][index];
        if (block.timestamp < (thisStake.stakeBegan + thisStake.duration)) {
            return 0;
        }
        uint256 stakingDuration = uint64(block.timestamp) -
            thisStake.stakeBegan;
        if (stakingDuration > 0 && i_rewardRate > 0) {
            int128 compoundingFactor = ABDKMath64x64.pow(
                ABDKMath64x64.add(
                    ABDKMath64x64.fromUInt(1),
                    ABDKMath64x64.div(
                        ABDKMath64x64.fromUInt(i_rewardRate),
                        ABDKMath64x64.fromUInt(365)
                    )
                ),
                stakingDuration / 1 days
            );
            return
                ABDKMath64x64.mulu(compoundingFactor, thisStake.stakeAmount) -
                thisStake.stakeAmount;
        }
        return 0;
    }
}
