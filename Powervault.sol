// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "./libs/IUNIWChef.sol";
import "./libs/IUniswapV2Router02.sol";

//customed to save gas just for UNIW MasterChef
/**TODO 
thunderpot add
*/
interface IThunderpot {
    function addRepo(uint _amount) external;
}

contract Powervault is Pausable {
    using SafeERC20 for IERC20;
    struct UserInfo {
        uint shares;
        uint rewardDebt;
        uint punkId; //default is 0 and can't accept id 0.
        uint lockUntil;
    }
    struct InitAdds {
        address govAddress;
        address wantAddress;
        address token0Address;
        address token1Address;
        address rewardsAddress;
        address thunderpot;
    }
    struct Setting {
        uint256 entranceFeeFactor;
        uint256 withdrawFeeFactor;
        uint256 slippageFactor;
        uint256 potFee;
        uint compoundFee;
        uint burnFee;
        uint lockPeriod;
        uint reducedLockPeriod;
    }
    bool public isSingleAssetDeposit; //single stake:token0==wantAddress,token1=address(0)
    bool public emergencyWithdrew;

    uint256 public pid; // pid of pool in farmContractAddress
    address public wantAddress;
    address public token0Address;
    address public token1Address;
    address public thunderpot;
    address public constant farmContractAddress = 0xC07707C7AC7E383CE344C090F915F0a083764C94; // address of farm, eg, PCS, Thugs etc.
    address public constant earnedAddress = 0x2a0cf46ECaaEAD92487577e9b737Ec63B0208a33;
    address public constant UNIWPUNK = 0xe48B4261dCD213603bb4a6b85E200C54510CAf50;
    // address public constant farmContractAddress = 0x85E6a6832239e8b25f87ADDEfD6A565a9FE7E9eD; // DEMO
    // address public constant earnedAddress = 0x50ad6F378AB77842a74B2a2Ae5B18cBF7f4ABE21; //DEMO
    // address public constant UNIWPUNK = 0x43F60c89a232eA6718C491E72829AA3145d78026; //DEMO

    address public constant deadAddress = 0x000000000000000000000000000000000000dEaD;

    address public constant uniRouterAddress = 0x633e494C22D163F798b25b0264b92Ac612645731; // uniswap, pancakeswap etc
    address public constant USDC = 0x11bbB41B3E8baf7f75773DB7428d5AcEe25FEC75;
    address public govAddress;

    uint256 public lastEarnTime = 0;
    uint256 public wantLockedTotal = 0;
    uint256 public sharesTotal = 0;

    uint256 public potFee = 400;
    uint256 public constant potFeeMax = 10000;
    uint256 public constant potFeeUL = 1000;

    uint256 public compounderFee = 50;
    uint256 public constant compounderFeeMax = 10000;
    uint256 public constant compounderFeeUL = 100;

    uint256 public burnFee = 50;
    uint256 public constant burnFeeMax = 10000;
    uint256 public constant burnFeeUL = 100;

    uint256 public lplock = 7 days;
    uint256 public reducedlock = 3 days; //locktime with punk

    address public rewardsAddress;

    uint256 public entranceFeeFactor = 9990; // < 0.1% - goes back to pool to prevents front-running
    uint256 public constant entranceFeeFactorMax = 10000;
    uint256 public constant entranceFeeFactorLL = 9950; // 0.5% is the max entrance fee settable. LL = lowerlimit

    uint256 public withdrawFeeFactor = 9990; // 0.1% withdraw fee - goes back to pool to prevent front-running
    uint256 public constant withdrawFeeFactorMax = 10000;
    uint256 public constant withdrawFeeFactorLL = 9950; // 0.5% is the max entrance fee settable. LL = lowerlimit

    uint256 public slippageFactor = 950; // 5% default slippage tolerance
    uint256 public constant slippageFactorUL = 995;

    address[] public earnedToToken0Path;
    address[] public earnedToToken1Path;
    address[] public earnedToUSDCPath;
    address[] public token0ToEarnedPath;
    address[] public token1ToEarnedPath;
    mapping(address => UserInfo) public userInfo;

    event Deposited(address indexed _user, uint _wantAmt, uint _shareAdded);
    event Withdrawn(address indexed _user, uint _wantAmt, uint _shareRemoved);
    event Swapskipped(uint _amount);
    event SetGov(address _govAddress);
    event SetRewardsAddress(address _rewardsAddress);

    modifier onlyAllowGov() {
        require(msg.sender == govAddress, "!gov");
        _;
    }

    constructor(
        InitAdds memory _addresses,
        uint256 _pid,
        bool _isSingleAssetDeposit,
        address[] memory _earnedToToken0Path,
        address[] memory _earnedToToken1Path,
        address[] memory _earnedToUSDCPath,
        address[] memory _token0ToEarnedPath,
        address[] memory _token1ToEarnedPath
    ) {
        govAddress = _addresses.govAddress;
        wantAddress = _addresses.wantAddress;
        token0Address = _addresses.token0Address;
        token1Address = _addresses.token1Address;
        rewardsAddress = _addresses.rewardsAddress;
        thunderpot = _addresses.thunderpot;
        pid = _pid;
        isSingleAssetDeposit = _isSingleAssetDeposit;
        earnedToToken0Path = _earnedToToken0Path;
        earnedToToken1Path = _earnedToToken1Path;
        earnedToUSDCPath = _earnedToUSDCPath;
        token0ToEarnedPath = _token0ToEarnedPath;
        token1ToEarnedPath = _token1ToEarnedPath;
        IERC20(USDC).approve(_addresses.thunderpot, type(uint).max);
        IERC20(wantAddress).approve(farmContractAddress, type(uint).max);
        IERC20(earnedAddress).approve(uniRouterAddress, type(uint).max);
        IERC20(token0Address).approve(uniRouterAddress, type(uint).max);
        if (!_isSingleAssetDeposit) {
            IERC20(token1Address).approve(uniRouterAddress, type(uint).max);
        }
    }

    function pendingWant(address _user) external view virtual returns (uint) {
        if (sharesTotal == 0) {
            return 0;
        }
        return (userInfo[_user].shares * wantLockedTotal) / sharesTotal;
    }

    // Receives new deposits from user
    function deposit(uint256 _wantAmt) external virtual whenNotPaused {
        UserInfo storage user = userInfo[msg.sender];
        IERC20(wantAddress).safeTransferFrom(address(msg.sender), address(this), _wantAmt);
        //considering deposit fee
        (uint _prev, ) = IUNIWChef(farmContractAddress).userInfo(pid, address(this));
        _farm();
        (uint _after, ) = IUNIWChef(farmContractAddress).userInfo(pid, address(this));
        uint sharesAdded = _after - _prev;
        if (wantLockedTotal > 0 && sharesTotal > 0) {
            sharesAdded = (sharesAdded * sharesTotal * entranceFeeFactor) / wantLockedTotal / entranceFeeFactorMax;
        }
        wantLockedTotal = _after;
        sharesTotal += sharesAdded;
        user.shares += sharesAdded;
        uint lockperiod = user.punkId != 0 ? lplock : reducedlock;
        user.lockUntil = block.timestamp + lockperiod;
        emit Deposited(msg.sender, _wantAmt, sharesAdded);
    }

    function _farm() internal virtual {
        uint256 wantAmt = IERC20(wantAddress).balanceOf(address(this));
        IUNIWChef(farmContractAddress).deposit(pid, wantAmt, rewardsAddress);
    }

    function _unfarm(uint256 _wantAmt) internal virtual {
        IUNIWChef(farmContractAddress).withdraw(pid, _wantAmt);
    }

    function withdraw(uint256 _wantAmt) external virtual {
        UserInfo storage user = userInfo[msg.sender];
        require(user.lockUntil < block.timestamp, "unlock time not reached");
        uint256 sharesRemoved = (_wantAmt * (sharesTotal)) / (wantLockedTotal);

        require(sharesRemoved <= user.shares, "bad withdrawal");

        if (sharesRemoved > sharesTotal) {
            sharesRemoved = sharesTotal;
        }
        sharesTotal = sharesTotal - sharesRemoved;
        user.shares -= sharesRemoved;
        if (withdrawFeeFactor < withdrawFeeFactorMax) {
            _wantAmt = (_wantAmt * withdrawFeeFactor) / withdrawFeeFactorMax;
        }

        if (!emergencyWithdrew) {
            _unfarm(_wantAmt);
        }

        uint256 wantAmt = IERC20(wantAddress).balanceOf(address(this));
        if (_wantAmt > wantAmt) {
            _wantAmt = wantAmt;
        }

        if (wantLockedTotal < _wantAmt) {
            _wantAmt = wantLockedTotal;
        }

        wantLockedTotal = wantLockedTotal - _wantAmt;

        IERC20(wantAddress).safeTransfer(msg.sender, _wantAmt);
        emit Withdrawn(msg.sender, _wantAmt, sharesRemoved);
    }

    function depositPunk(uint _id) external virtual {
        UserInfo storage user = userInfo[msg.sender];
        require(user.punkId == 0, "already deposited");
        require(_id != 0, "can't accept id 0");
        IERC721(UNIWPUNK).transferFrom(msg.sender, address(this), _id);
        user.punkId = _id;
    }

    function withdrawpunk() external virtual {
        UserInfo storage user = userInfo[msg.sender];
        require(user.punkId != 0, "nothing to withdraw");
        require(user.lockUntil < block.timestamp, "unlock time not reached");
        IERC721(UNIWPUNK).transferFrom(address(this), msg.sender, user.punkId);
        user.punkId = 0;
    }

    // 1. Harvest farm tokens
    // 2. Converts farm tokens into want tokens
    // 3. Deposits want tokens

    function earn() public virtual whenNotPaused {
        // Harvest farm tokens
        _unfarm(0);

        // Converts farm tokens into want tokens
        uint256 earnedAmt = IERC20(earnedAddress).balanceOf(address(this));

        if (earnedAmt == 0) {
            lastEarnTime = block.timestamp;
            _farm();
            return;
        }

        earnedAmt = distributeFees(earnedAmt);

        if (isSingleAssetDeposit) {
            if (earnedAddress != token0Address) {
                _safeSwap(uniRouterAddress, earnedAmt, slippageFactor, earnedToToken0Path);
            }
        } else {
            if (earnedAddress != token0Address) {
                // Swap half earned to token0
                _safeSwap(uniRouterAddress, earnedAmt / (2), slippageFactor, earnedToToken0Path);
            }

            if (earnedAddress != token1Address) {
                // Swap half earned to token1
                _safeSwap(uniRouterAddress, earnedAmt / (2), slippageFactor, earnedToToken1Path);
            }

            // Get want tokens, ie. add liquidity
            uint256 token0Amt = IERC20(token0Address).balanceOf(address(this));
            uint256 token1Amt = IERC20(token1Address).balanceOf(address(this));
            if (token0Amt > 0 && token1Amt > 0) {
                IUniswapV2Router02(uniRouterAddress).addLiquidity(
                    token0Address,
                    token1Address,
                    token0Amt,
                    token1Amt,
                    0,
                    0,
                    address(this),
                    block.timestamp
                );
            }
        }
        lastEarnTime = block.timestamp;
        _farm();
    }

    function distributeFees(uint256 _earnedAmt) internal virtual returns (uint256) {
        if (potFee > 0) {
            uint256 fee = (_earnedAmt * potFee) / potFeeMax;
            uint before = IERC20(USDC).balanceOf(address(this));
            _safeSwap(uniRouterAddress, fee, slippageFactor, earnedToUSDCPath);
            IThunderpot(thunderpot).addRepo(IERC20(USDC).balanceOf(address(this)) - before);
            _earnedAmt -= fee;
        }
        if (compounderFee > 0) {
            uint256 fee = (_earnedAmt * compounderFee) / compounderFeeMax;
            IERC20(earnedAddress).transfer(rewardsAddress, fee);
            _earnedAmt -= fee;
        }
        if (burnFee > 0) {
            uint256 fee = (_earnedAmt * compounderFee) / compounderFeeMax;
            IERC20(earnedAddress).transfer(deadAddress, fee);
            _earnedAmt -= fee;
        }
        return _earnedAmt;
    }

    function convertDustToEarned() external virtual whenNotPaused {
        // Converts dust tokens into earned tokens, which will be reinvested on the next earn().

        // Converts token0 dust (if any) to earned tokens
        uint256 token0Amt = IERC20(token0Address).balanceOf(address(this));
        if (token0Address != earnedAddress && token0Amt > 0) {
            // Swap all dust tokens to earned tokens
            _safeSwap(uniRouterAddress, token0Amt, slippageFactor, token0ToEarnedPath);
        }

        // Converts token1 dust (if any) to earned tokens
        uint256 token1Amt = IERC20(token1Address).balanceOf(address(this));
        if (token1Address != earnedAddress && token1Amt > 0) {
            // Swap all dust tokens to earned tokens
            _safeSwap(uniRouterAddress, token1Amt, slippageFactor, token1ToEarnedPath);
        }
    }

    function pause() external virtual onlyAllowGov {
        _pause();
    }

    function unpause() external virtual onlyAllowGov {
        _unpause();
    }

    function setSettings(Setting memory config) external virtual onlyAllowGov {
        require(config.entranceFeeFactor >= entranceFeeFactorLL, "config.entranceFeeFactor too low");
        require(config.entranceFeeFactor <= entranceFeeFactorMax, "config.entranceFeeFactor too high");
        entranceFeeFactor = config.entranceFeeFactor;

        require(config.withdrawFeeFactor >= withdrawFeeFactorLL, "config.withdrawFeeFactor too low");
        require(config.withdrawFeeFactor <= withdrawFeeFactorMax, "config.withdrawFeeFactor too high");
        withdrawFeeFactor = config.withdrawFeeFactor;

        require(
            config.potFee <= potFeeUL && config.compoundFee <= compounderFeeUL && config.burnFee <= burnFeeUL,
            "config.potFee too high"
        );
        potFee = config.potFee;
        compounderFee = config.compoundFee;
        burnFee = config.burnFee;

        lplock = config.lockPeriod;
        reducedlock = config.reducedLockPeriod;

        require(config.slippageFactor <= slippageFactorUL, "config.slippageFactor too high");
        slippageFactor = config.slippageFactor;
    }

    function depositBoostNFT(address _nft, uint256 _tokenId) external virtual onlyAllowGov {
        require(_nft != address(0), "Invalid NFT");
        IERC721(_nft).approve(farmContractAddress, _tokenId);
        IUNIWChef(farmContractAddress).depositNFT(_nft, _tokenId, pid);
    }

    function withdrawBoostNFT(address _nft) external virtual onlyAllowGov {
        (, uint _id) = IUNIWChef(farmContractAddress).getStakedNFTDetails(address(this), pid);
        IUNIWChef(farmContractAddress).withdrawNFT(pid);
        IERC721(_nft).transferFrom(address(this), msg.sender, _id);
    }

    function setGov(address _govAddress) external virtual onlyAllowGov {
        govAddress = _govAddress;
        emit SetGov(_govAddress);
    }

    function setRewardsAddress(address _rewardsAddress) external virtual onlyAllowGov {
        rewardsAddress = _rewardsAddress;
        emit SetRewardsAddress(_rewardsAddress);
    }

    function setPot(address _thunder) external virtual onlyAllowGov {
        thunderpot = _thunder;
    }

    function inCaseTokensGetStuck(
        address _token,
        uint256 _amount,
        address _to
    ) external virtual onlyAllowGov {
        require(_token != earnedAddress, "!safe");
        require(_token != wantAddress, "!safe");
        IERC20(_token).safeTransfer(_to, _amount);
    }

    function emergencyUnfarm(uint256 _pid) external virtual onlyAllowGov {
        IUNIWChef(farmContractAddress).emergencyWithdraw(_pid);
        emergencyWithdrew = true;
        _pause();
    }

    function _safeSwap(
        address _uniRouterAddress,
        uint256 _amountIn,
        uint256 _slippageFactor,
        address[] memory _path
    ) internal virtual {
        uint256[] memory amounts = IUniswapV2Router02(_uniRouterAddress).getAmountsOut(_amountIn, _path);
        uint256 amountOut = amounts[amounts.length - (1)];
        if (amountOut == 0) {
            emit Swapskipped(_amountIn);
            return;
        }
        IUniswapV2Router02(_uniRouterAddress).swapExactTokensForTokensSupportingFeeOnTransferTokens(
            _amountIn,
            (amountOut * _slippageFactor) / 1000,
            _path,
            address(this),
            block.timestamp
        );
    }

    // receive() external payable {}

    // fallback() external payable {}
}
