// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./libs/IUniswapV2Router02.sol";

contract Thunderpot is Ownable, Pausable {
    using SafeERC20 for IERC20;
    struct UserInfo {
        uint lockUntil;
        uint amount;
        uint point;
        uint rewardDebt; //usdc debt
        uint lastwithdraw;
        uint[] pids;
    }
    struct PoolInfo {
        uint point;
        uint startTime;
        uint endTime;
        uint tokenPerSec; //X10^18
        uint accPerShare;
        IERC20 token;
        uint lastRewardTime;
        address router;
        bool disable; //in case of error
    }
    struct UsdcPool {
        //usdcPerSec everyweek
        uint newRepo;
        uint currentRepo;
        uint week;
        uint[] wkUnit; //weekly usdcPerSec. 4week cycle
        uint usdcPerTime; //*1e18
        uint endtime;
        uint accUsdcPerShare;
        uint lastRewardTime;
    }

    /**Variables */

    mapping(address => UserInfo) public userInfo;
    PoolInfo[] public poolInfo;
    mapping(address => address[]) public paths; //token to POWV path
    mapping(address => string) public uri; //token=>logo file uri
    mapping(uint => mapping(address => uint)) public pooldebt;
    UsdcPool public usdcPool;
    IERC20 public immutable POWV;
    IERC20 public constant USDC = IERC20(0x11bbB41B3E8baf7f75773DB7428d5AcEe25FEC75);
    IERC20 public constant WETH = IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    address public constant router = 0x633e494C22D163F798b25b0264b92Ac612645731;
    uint public constant period = 86400 * 7;
    uint8 public constant MAXLOCK = 12; //months
    uint8 public constant MINLOCK = 1;
    uint8 public constant MAXMULTIPLE = 4;
    uint public totalAmount;
    uint public totalPoint;
    uint public totalpayout;

    constructor(IERC20 _POWV, address[] memory _usdcToPOWVpath) {
        POWV = IERC20(_POWV);
        paths[address(USDC)] = _usdcToPOWVpath;
        usdcPool.wkUnit = [0, 0, 0, 0];
        WETH.approve(router, type(uint).max);
        USDC.approve(router, type(uint).max);
    }

    /** Viewer functions  */
    function userinfo(address _user) external view returns (UserInfo memory) {
        //to query userInfo with dynamic array type
        return userInfo[_user];
    }

    function getUsdcPool() external view returns (UsdcPool memory) {
        return usdcPool;
    }

    function poolLength() external view returns (uint) {
        return poolInfo.length;
    }

    function livepoolIndex() external view returns (uint[] memory, uint) {
        uint[] memory index = new uint[](poolInfo.length);
        uint cnt;
        for (uint i = 0; i < poolInfo.length; i++) {
            if (poolInfo[i].endTime > block.timestamp) {
                index[cnt++] = i;
            }
        }
        return (index, cnt);
    }

    function pendingReward(uint _pid, address _user) public view returns (uint256) {
        PoolInfo memory pool = poolInfo[_pid];
        uint256 _accUsdcPerShare = pool.accPerShare;
        if (block.timestamp <= pool.startTime) {
            return 0;
        }
        if (block.timestamp > pool.lastRewardTime && pool.point != 0) {
            uint multiplier;
            if (block.timestamp > pool.endTime) {
                multiplier = pool.endTime - (pool.lastRewardTime);
            } else {
                multiplier = block.timestamp - (pool.lastRewardTime);
            }
            uint256 Reward = multiplier * (pool.tokenPerSec);
            _accUsdcPerShare = _accUsdcPerShare + ((Reward * 1e12) / pool.point);
        }
        return ((userInfo[_user].point * _accUsdcPerShare) / 1e12 - pooldebt[_pid][_user]) / 1e18;
    }

    /** aggregated viewer function to query all the pending rewards for the user */
    function pendingrewards(address _user) external view returns (uint[] memory) {
        uint[] memory pids = userInfo[_user].pids;
        uint[] memory rewards = new uint[](pids.length);
        for (uint i = 0; i < pids.length; i++) {
            rewards[i] = pendingReward(pids[i], _user);
        }
        return rewards;
    }

    function pendingUsdc(address _user) external view returns (uint256) {
        UserInfo memory user = userInfo[_user];
        uint256 _accUsdcPerShare = usdcPool.accUsdcPerShare;
        if (block.timestamp > usdcPool.lastRewardTime && totalAmount != 0) {
            uint256 multiplier = block.timestamp - usdcPool.lastRewardTime;
            uint256 UsdcReward = multiplier * usdcPool.usdcPerTime;
            _accUsdcPerShare = _accUsdcPerShare + ((UsdcReward * 1e12) / totalAmount);
        }
        return ((user.point * _accUsdcPerShare) / 1e12 - user.rewardDebt) / 1e18;
    }

    /**EXTERNAL FUNCTIONS */
    function deposit(uint256 _amount, uint _lock) external whenNotPaused {
        require(_lock <= MAXLOCK && _lock >= MINLOCK, "incorrect lock time");
        UserInfo storage user = userInfo[msg.sender];
        _updateUser();
        uint addedPoint;
        if (_amount > 0) {
            uint before = POWV.balanceOf(address(this));
            POWV.safeTransferFrom(address(msg.sender), address(this), _amount);
            _amount = POWV.balanceOf(address(this)) - before;
            user.amount += _amount;
            totalAmount += _amount;
            addedPoint = (_amount * _lock * MAXMULTIPLE) / MAXLOCK;
            user.point += addedPoint;
            totalPoint += addedPoint;
            uint lockuntil = block.timestamp + _lock * (30 days);
            user.lockUntil = lockuntil > user.lockUntil ? lockuntil : user.lockUntil;
        }

        for (uint i = 0; i < user.pids.length; i++) {
            uint _pid = user.pids[i];
            PoolInfo storage pool = poolInfo[_pid];
            if (pool.disable) {
                continue;
            }
            pool.point += addedPoint;
            pooldebt[_pid][msg.sender] = (user.point * pool.accPerShare) / 1e12;
        }
        user.rewardDebt = (user.point * usdcPool.accUsdcPerShare) / 1e12;
        checkend();
    }

    function withdraw() external {
        UserInfo storage user = userInfo[msg.sender];
        require(user.lockUntil < block.timestamp, "still locked");
        _updateUser();
        POWV.transfer(msg.sender, user.amount);
        uint removedPoint = user.point;
        totalAmount -= user.amount;
        totalPoint -= removedPoint;
        user.amount = 0;
        user.point = 0;
        user.lockUntil = 0;
        for (uint i = 0; i < user.pids.length; i++) {
            uint _pid = user.pids[i];
            PoolInfo storage pool = poolInfo[_pid];
            if (pool.disable) {
                continue;
            }
            pool.point -= removedPoint;
            pooldebt[_pid][msg.sender] = 0;
        }
        user.rewardDebt = 0;
        checkend();
    }

    function enroll(uint _pid) external {
        require(_pid < poolInfo.length && poolInfo[_pid].endTime > block.timestamp, "wrong pid");
        PoolInfo storage pool = poolInfo[_pid];
        require(pool.disable == false, "disabled pool");
        UserInfo storage user = userInfo[msg.sender];
        for (uint i = 0; i < user.pids.length; i++) {
            require(user.pids[i] != _pid, "duplicated pid");
        }
        updatePool(_pid);
        pool.point += user.point;
        user.pids.push(_pid);
        pooldebt[_pid][msg.sender] = (user.point * poolInfo[_pid].accPerShare) / 1e12;
    }

    function claimInPOWV() external {
        UserInfo storage user = userInfo[msg.sender];
        require(user.amount > 0);
        updateUsdcPool();
        uint before = POWV.balanceOf(address(this));
        //tokens=>POWV
        for (uint i = 0; i < user.pids.length; i++) {
            uint _pid = user.pids[i];
            PoolInfo memory pool = poolInfo[_pid];
            updatePool(_pid);
            uint pendingR = (user.point * pool.accPerShare) / 1e12 - pooldebt[_pid][msg.sender];
            pendingR /= 1e18;
            if (pool.disable) {
                if (pendingR > 0) {
                    pool.token.safeTransfer(msg.sender, pendingR);
                }
            } else {
                _safeSwap(pool.router, paths[address(pool.token)], pendingR);
            }
        }

        //USDC=>POWV
        uint256 pending = (user.point * usdcPool.accUsdcPerShare) / 1e12 - user.rewardDebt;
        pending /= 1e18;
        _safeSwap(router, paths[address(USDC)], pending);
        uint bal = POWV.balanceOf(address(this)) - before;
        POWV.transfer(msg.sender, bal);
        user.rewardDebt = (user.point * (usdcPool.accUsdcPerShare)) / (1e12);
        for (uint i = 0; i < user.pids.length; i++) {
            uint _pid = user.pids[i];
            pooldebt[_pid][msg.sender] = (user.point * poolInfo[_pid].accPerShare) / (1e12);
        }
        checkend();
    }

    /**INTERNAL FUNCTIONS */

    function _updateUser() internal {
        UserInfo memory user = userInfo[msg.sender];
        updateUsdcPool();
        for (uint i = 0; i < user.pids.length; i++) {
            uint _pid = user.pids[i];
            PoolInfo memory pool = poolInfo[_pid];
            if (pool.disable) {
                continue;
            }
            updatePool(_pid);
            uint pending = (user.point * pool.accPerShare) / 1e12 - pooldebt[_pid][msg.sender];
            pending = pending / (1e18);
            if (pending > 0) {
                pool.token.safeTransfer(msg.sender, pending);
            }
        }
        if (user.point > 0) {
            uint256 pending = (user.point * usdcPool.accUsdcPerShare) / 1e12 - user.rewardDebt;
            pending = pending / 1e18;
            if (pending > 0) {
                safeUsdcTransfer(msg.sender, pending);
            }
        }
    }

    function updateUsdcPool() internal {
        if (block.timestamp <= usdcPool.lastRewardTime) {
            return;
        }
        if (totalPoint == 0) {
            usdcPool.lastRewardTime = block.timestamp;
            return;
        }
        uint256 usdcReward = (block.timestamp - usdcPool.lastRewardTime) * usdcPool.usdcPerTime;
        usdcPool.accUsdcPerShare += (usdcReward * 1e12) / totalPoint;
        usdcPool.lastRewardTime = block.timestamp;
    }

    function updatePool(uint _pid) internal {
        PoolInfo storage pool = poolInfo[_pid];
        if (pool.lastRewardTime >= pool.endTime || block.timestamp <= pool.lastRewardTime) {
            return;
        }
        if (totalPoint == 0 || pool.point == 0) {
            pool.lastRewardTime = block.timestamp;
            return;
        }
        uint multiplier;
        if (block.timestamp > pool.endTime) {
            multiplier = pool.endTime - pool.lastRewardTime;
        } else {
            multiplier = block.timestamp - pool.lastRewardTime;
        }
        uint256 Reward = multiplier * pool.tokenPerSec;
        pool.accPerShare = pool.accPerShare + ((Reward * 1e12) / pool.point);
        pool.lastRewardTime = block.timestamp > pool.endTime ? pool.endTime : block.timestamp;
    }

    function checkend() internal {
        //already updated pool above.
        deletepids();
        if (usdcPool.endtime <= block.timestamp) {
            usdcPool.endtime = block.timestamp + period;
            usdcPool.currentRepo = (usdcPool.newRepo * 9999) / 10000; //in case of error by over-paying
            usdcPool.newRepo = 0;
            if (usdcPool.week == 3) {
                usdcPool.usdcPerTime -= usdcPool.wkUnit[0];
                usdcPool.week = 0;
                usdcPool.wkUnit[0] = (usdcPool.currentRepo * 1e18) / (period * 4);
                usdcPool.usdcPerTime += usdcPool.wkUnit[0];
            } else {
                uint week = usdcPool.week;
                usdcPool.usdcPerTime = usdcPool.usdcPerTime - usdcPool.wkUnit[week + 1];
                usdcPool.week++;
                usdcPool.wkUnit[week + 1] = (usdcPool.currentRepo * 1e18) / (period * 4);
                usdcPool.usdcPerTime += usdcPool.wkUnit[week + 1];
            }
        }
    }

    function deletepids() internal {
        UserInfo storage user = userInfo[msg.sender];
        for (uint i = 0; i < user.pids.length; i++) {
            if (poolInfo[user.pids[i]].endTime <= block.timestamp) {
                user.pids[i] = user.pids[user.pids.length - 1];
                user.pids.pop();
                deletepids();
                break;
            }
        }
    }

    function _safeSwap(
        address _router,
        address[] memory _path,
        uint256 _amountIn
    ) internal {
        if (_amountIn > 0) {
            IUniswapV2Router02(_router).swapExactTokensForTokensSupportingFeeOnTransferTokens(
                _amountIn,
                0,
                _path,
                address(this),
                block.timestamp
            );
        }
    }

    function safeUsdcTransfer(address _to, uint256 _amount) internal {
        uint256 balance = USDC.balanceOf(address(this));
        if (_amount > balance) {
            USDC.safeTransfer(_to, balance);
        } else {
            USDC.safeTransfer(_to, _amount);
        }
    }

    /*governance functions*/

    function addRepo(uint _amount) external {
        //open for donations
        USDC.transferFrom(msg.sender, address(this), _amount);
        usdcPool.newRepo += _amount;
        totalpayout += _amount;
    }

    function addpool(
        uint _amount,
        uint _startTime,
        uint _endTime,
        IERC20 _token,
        address _router,
        address[] memory _path
    ) external onlyOwner {
        require(_startTime > block.timestamp && _endTime > _startTime, "wrong time");
        require(_token.balanceOf(address(this)) >= _amount, "insufficient rewards");
        poolInfo.push(
            PoolInfo({
                point: 0,
                startTime: _startTime,
                endTime: _endTime,
                tokenPerSec: (_amount * (1e18)) / (_endTime - _startTime), //X10^18
                accPerShare: 0,
                token: _token,
                lastRewardTime: _startTime,
                router: _router,
                disable: false //in case of error
            })
        );
        paths[address(_token)] = _path;
        _token.approve(_router, type(uint).max);
    }

    function start() external onlyOwner {
        usdcPool.endtime = block.timestamp + period;
        usdcPool.currentRepo = usdcPool.newRepo;
        usdcPool.usdcPerTime = (usdcPool.currentRepo * 1e18) / (period * 4);
        usdcPool.wkUnit[0] = usdcPool.usdcPerTime;
        usdcPool.newRepo = 0;
    }

    function stopPool(uint _pid, bool stop) external onlyOwner {
        poolInfo[_pid].disable = stop; //toggle
    }

    function setURI(address _token, string memory _uri) external onlyOwner {
        uri[_token] = _uri;
    }

    function recoverToken(address _token, uint _bal) external onlyOwner {
        require(_token != address(POWV), "can't remove POWV");
        IERC20(_token).transfer(msg.sender, _bal);
    }
}
