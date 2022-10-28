// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract POWV is ERC20, Ownable {
    mapping(address => bool) public isExcludedFromFee;
    mapping(address => bool) public isMinter;
    mapping(address => bool) public powvPair;

    uint256 public constant MAX_SUPPLY = 5000000 * 1e18;
    uint256 public BUY_FEE = 0;
    uint256 public SELL_FEE = 300; //burn fee

    event FeeUpdated(address indexed _user, bool _feeType, uint256 _fee);
    event ToggleV2Pair(address indexed _user, address indexed _pair, bool _flag);
    event AddressExcluded(address indexed _user, address indexed _account, bool _flag);

    constructor(uint256 _initialSupply) ERC20("Power Vault", "POWVTEST") {
        require(_initialSupply <= MAX_SUPPLY, "POWV: _initialSupply should be less then _maxSupply");

        isExcludedFromFee[owner()] = true;
        isExcludedFromFee[address(this)] = true;
        isMinter[msg.sender] = true;
        if (_initialSupply > 0) {
            _mint(_msgSender(), _initialSupply);
        }
    }

    modifier hasMinterRole() {
        require(isMinter[_msgSender()], "POWV: Permission Denied!!!");
        _;
    }

    /************************************************************************/

    function _transfer(
        address sender,
        address recipient,
        uint256 amount
    ) internal override {
        uint256 fee;

        if (powvPair[sender]) {
            fee = BUY_FEE;
        } else if (powvPair[recipient]) {
            fee = SELL_FEE;
        }

        if (
            (isExcludedFromFee[sender] || isExcludedFromFee[recipient]) || (!powvPair[sender] && !powvPair[recipient])
        ) {
            //no normal transfer fee. only sell fee
            fee = 0;
        }

        uint256 feeAmount = (amount * fee) / 10000;

        if (feeAmount > 0) {
            _burn(sender, feeAmount);
        }
        super._transfer(sender, recipient, amount - feeAmount);
    }

    function mint(address _user, uint256 _amount) external hasMinterRole {
        require(totalSupply() + _amount <= MAX_SUPPLY, "POWV: No more Minting is allowed!!!");
        _mint(_user, _amount);
    }

    function grantRole(address _account, bool _allow) public onlyOwner {
        isMinter[_account] = _allow;
    }

    function enableV2PairFee(address _account, bool _flag) external onlyOwner {
        powvPair[_account] = _flag;
        emit ToggleV2Pair(_msgSender(), _account, _flag);
    }

    function updateFee(bool feeType, uint256 fee) external onlyOwner {
        require(fee <= 1000, "POWV: Fee cannot be more then 10%");

        if (feeType) {
            // TRUE == BUY FEE
            BUY_FEE = fee;
        } else {
            // FALSE == SELL FEE
            SELL_FEE = fee;
        }

        emit FeeUpdated(_msgSender(), feeType, fee);
    }
}
