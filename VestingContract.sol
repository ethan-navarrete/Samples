// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

/*********
A smart contract developed from scratch that grants users the ability to withdraw 10% of their alloted token balance every week. Two other tokens,
denoted as "Token1" and "Token2" are reward tokens that are also distributed propotionally based on a user's weighted balance. Wait times here are arbitrary
and adjustable as needed.
*********/

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

contract VestingContract is Ownable, ReentrancyGuard {

    using SafeERC20 for IERC20;
    using SafeMath for uint256;
    
    struct Allotment {
        uint256 allotedToken0;
        uint256 claimedToken0;
        uint256 claimedToken1;
        uint256 claimedToken2;
    }

    mapping(address => Allotment) public Allotments;

    address public Token0;
    address public Token2;
    address public Token1;

    uint256 public immutable startTime; // beginning of 30 day vesting window (unix timestamp)
    uint256 public immutable totalAllotments; // sum of every holder's Allotment.total (Token0 tokens)
    uint256 public claimableToken1;
    uint256 public claimableToken2;
    uint256 constant accuracyFactor = 1 * 10**18;
    
    event TokensClaimed(address _holder, uint256 _amountToken0, uint256 _amountToken1, uint256 _amountToken2);
    event Token0Funded(address _depositor, uint256 _amount, uint256 _timestamp);
    event Token1Funded(address _depositor, uint256 _amount, uint256 _timestamp);
    event Token2Funded(address _depositor, uint256 _amount, uint256 _timestamp);
    event Token0Removed(address _withdrawer, uint256 _amount, uint256 _timestamp);
    event Token1Removed(address _withdrawer,uint256 _amount, uint256 _timestamp);
    event Token2Removed(address _withdrawer, uint256 _amount, uint256 _timestamp);

   
    constructor(address _Token0, address _Token1, address _Token2) {
        startTime = block.timestamp;
        Token0 = _Token0;
        Token1 = _Token1;
        Token2 = _Token2;
        totalAllotments = 10000000000000000000000;
    }

    // @dev: disallows contracts from entering
    modifier notContract() {
        require(!_isContract(msg.sender), "Contract not allowed");
        require(msg.sender == tx.origin, "Proxy contract not allowed");
        _;
    }

    // ------------------ Getter Fxns ----------------------

    function getToken0Allotment(address _address) public view returns (uint256) {
        return Allotments[_address].allotedToken0;
    }

    function getClaimed(address _address) public view returns (uint256, uint256, uint256) {
        return 
            (Allotments[_address].claimedToken0,
             Allotments[_address].claimedToken1,
             Allotments[_address].claimedToken2);
    }

    function getElapsedTime() public view returns (uint256) {
        return block.timestamp.sub(startTime);
    }

    function getContractToken1() public view returns (uint256) {
        return IERC20(Token1).balanceOf(address(this));
    }

    function getContractToken2() public view returns (uint256) {
        return IERC20(Token2).balanceOf(address(this));
    }

    // ----------------- Setter Fxns -----------------------

    function setToken0(address _Token0) public onlyOwner {Token0 = _Token0;}

    function setToken1(address _Token1) public onlyOwner {Token1 = _Token1;}

    function setToken2(address _Token2) public onlyOwner {Token2 = _Token2;}

    function setAllotment(address _address, uint256 _allotment) public onlyOwner {
        Allotments[_address].allotedToken0 = _allotment;
    }

    // ----------------- Contract Funding/Removal Fxns -------------

    function fundToken0(uint256 _amountToken0) external onlyOwner {
        IERC20(Token0).transferFrom(address(msg.sender), address(this), _amountToken0);
        emit Token0Funded(msg.sender, _amountToken0, block.timestamp);
    }

    function fundToken1(uint256 _amountToken1) external onlyOwner {
        IERC20(Token1).transferFrom(address(msg.sender), address(this), _amountToken1);
        claimableToken1 = claimableToken1.add(_amountToken1);
        emit Token1Funded(msg.sender, _amountToken1, block.timestamp);
    }

    function fundToken2(uint256 _amountToken2) external onlyOwner {
        IERC20(Token2).transferFrom(address(msg.sender), address(this), _amountToken2);
        claimableToken2 = claimableToken2.add(_amountToken2);
        emit Token2Funded(msg.sender, _amountToken2, block.timestamp);
    }

    function removeToken0(uint256 _amountToken0) external onlyOwner {
        require(getElapsedTime() < 30 days || getElapsedTime() > 180 days , "Cannot withdraw Token0 during the vesting period!");
        require(_amountToken0 <= IERC20(Token0).balanceOf(address(this)), "Amount exceeds contract Token0 balance!");
        IERC20(Token0).transfer(address(msg.sender), _amountToken0);
        emit Token0Removed(msg.sender, _amountToken0, block.timestamp);
    }

    function removeToken1(uint256 _amountToken1) external onlyOwner {
        require(getElapsedTime() > 180 days , "Can only remove Token1 after vesting period!");
        require(_amountToken1 <= IERC20(Token1).balanceOf(address(this)), "Amount exceeds contract Token1 balance!");
        IERC20(Token1).transfer(address(msg.sender), _amountToken1);
        claimableToken1 = claimableToken1.sub(_amountToken1);
        emit Token1Removed(msg.sender, _amountToken1, block.timestamp);
    }

    function removeToken2(uint256 _amountToken2) external onlyOwner {
        require(getElapsedTime() > 180 days , "Can only remove Token2 after vesting period!");
        require(_amountToken2 <= IERC20(Token2).balanceOf(address(this)), "Amount exceeds contract Token2 balance!");
        IERC20(Token2).transfer(address(msg.sender), _amountToken2);
        claimableToken2 = claimableToken2.sub(_amountToken2);
        emit Token2Removed(msg.sender, _amountToken2, block.timestamp);
    }

    // ----------------- Withdraw Fxn ----------------------

    function claimTokens() external nonReentrant notContract() {
        require(getElapsedTime() > 10 days , "You have not waited the 10-day cliff period!");
        uint256 original = Allotments[msg.sender].allotedToken0; // initial allotment
        uint256 withdrawn = Allotments[msg.sender].claimedToken0; // amount user has claimed
        uint256 available = original.sub(withdrawn); // amount left that can be claimed
        uint256 tenPercent = (original.mul((1 * 10**18))).div(10 * 10**18); // 10% of user's original allotment;

        uint256 weightedAllotment = (original.mul(accuracyFactor)).div(totalAllotments);
        uint256 withdrawableToken1 = ((weightedAllotment.mul(claimableToken1)).div(accuracyFactor)).sub(Allotments[msg.sender].claimedToken1);
        uint256 withdrawableToken2 = ((weightedAllotment.mul(claimableToken2)).div(accuracyFactor)).sub(Allotments[msg.sender].claimedToken2);

        uint256 withdrawableToken0;

        if (getElapsedTime() >= 19 days) {
            withdrawableToken0 = available;
            checkThenTransfer(withdrawableToken0, withdrawableToken1, withdrawableToken2, available);

        } else if (getElapsedTime() >= 18 days && getElapsedTime() < 19 days) {
            withdrawableToken0 = (9 * tenPercent).sub(withdrawn);
            checkThenTransfer(withdrawableToken0, withdrawableToken1, withdrawableToken2, available);

        } else if (getElapsedTime() >= 17 days && getElapsedTime() < 18 days) {
            withdrawableToken0 = (8 * tenPercent).sub(withdrawn);
            checkThenTransfer(withdrawableToken0, withdrawableToken1, withdrawableToken2, available);

        } else if (getElapsedTime() >= 16 days && getElapsedTime() < 17 days) {
            withdrawableToken0 = (7 * tenPercent).sub(withdrawn);
            checkThenTransfer(withdrawableToken0, withdrawableToken1, withdrawableToken2, available);

        } else if (getElapsedTime() >= 15 days && getElapsedTime() < 16 days) {
            withdrawableToken0 = (6 * tenPercent).sub(withdrawn);
            checkThenTransfer(withdrawableToken0, withdrawableToken1, withdrawableToken2, available);

        } else if (getElapsedTime() >= 14 days && getElapsedTime() < 15 days) {
            withdrawableToken0 = (5 * tenPercent).sub(withdrawn);
            checkThenTransfer(withdrawableToken0, withdrawableToken1, withdrawableToken2, available);

        } else if (getElapsedTime() >= 13 days && getElapsedTime() < 14 days) {
            withdrawableToken0 = (4 * tenPercent).sub(withdrawn);
            checkThenTransfer(withdrawableToken0, withdrawableToken1, withdrawableToken2, available);

        } else if (getElapsedTime() >= 12 days && getElapsedTime() < 13 days) {
            withdrawableToken0 = (3 * tenPercent).sub(withdrawn);
            checkThenTransfer(withdrawableToken0, withdrawableToken1, withdrawableToken2, available);

        } else if (getElapsedTime() >= 11 days && getElapsedTime() < 12 days) {
            withdrawableToken0 = (2 * tenPercent).sub(withdrawn);
            checkThenTransfer(withdrawableToken0, withdrawableToken1, withdrawableToken2, available);

        } else if (getElapsedTime() >= 10 days && getElapsedTime() < 11 days) {
            withdrawableToken0 = tenPercent.sub(withdrawn);
            checkThenTransfer(withdrawableToken0, withdrawableToken1, withdrawableToken2, available);

        } else {
            withdrawableToken0 = 0;
        }
    }

    // ------------------------ Internal Helper/Transfer Fxns ------

    function checkThenTransfer(uint256 _withdrawableToken0, uint256 _withdrawableToken1, uint256 _withdrawableToken2, uint256 _available) internal {
        require(_withdrawableToken0 <= _available && _withdrawableToken0 <= IERC20(Token0).balanceOf(address(this)) , 
            "You have already claimed for this period, or you have claimed your total Token0 allotment!");
        require(_withdrawableToken1 <= getContractToken1() && _withdrawableToken2 <= getContractToken2() ,
            "Token2 or Token1 transfer exceeds contract balance!");

        if (_withdrawableToken0 > 0) {
            IERC20(Token0).safeTransfer(msg.sender, _withdrawableToken0);
            Allotments[msg.sender].claimedToken0 = Allotments[msg.sender].claimedToken0.add(_withdrawableToken0);
        }
        if (_withdrawableToken1 > 0) {
            IERC20(Token1).safeTransfer(msg.sender, _withdrawableToken1);
            Allotments[msg.sender].claimedToken1 = Allotments[msg.sender].claimedToken1.add(_withdrawableToken1);
        }
        if (_withdrawableToken2 > 0) {
            IERC20(Token2).safeTransfer(msg.sender, _withdrawableToken2);
            Allotments[msg.sender].claimedToken2 = Allotments[msg.sender].claimedToken2.add(_withdrawableToken2);
        }

        emit TokensClaimed(msg.sender, _withdrawableToken0, _withdrawableToken1, _withdrawableToken2);
    }

    function _isContract(address _addr) internal view returns (bool) {
        uint256 size;
        assembly {
            size := extcodesize(_addr)
        }
        return size > 0;
    }

    // ----------------------- View Function To Calculate Withdraw Amt. -----

    function calculateWithdrawableAmounts(address _address) external view returns (uint256, uint256, uint256) {
        require(getElapsedTime() > 10 days , "You have not waited the 10-day cliff period! Your withdrawable amounts are 0.");
        uint256 original = Allotments[_address].allotedToken0; // initial allotment
        uint256 withdrawn = Allotments[_address].claimedToken0; // amount user has claimed
        uint256 available = original.sub(withdrawn); // amount left that can be claimed
        uint256 tenPercent = (original.mul((1 * 10**18))).div(10 * 10**18); // 10% of user's original allotment;

        uint256 weightedAllotment = (original.mul(accuracyFactor)).div(totalAllotments);
        uint256 withdrawableToken1 = ((weightedAllotment.mul(claimableToken1)).div(accuracyFactor)).sub(Allotments[_address].claimedToken1);
        uint256 withdrawableToken2 = ((weightedAllotment.mul(claimableToken2)).div(accuracyFactor)).sub(Allotments[_address].claimedToken2);

        uint256 withdrawableToken0;

        if (getElapsedTime() >= 19 days) {withdrawableToken0 = available;
        } else if (getElapsedTime() >= 18 days && getElapsedTime() < 19 days) {withdrawableToken0 = (9 * tenPercent).sub(withdrawn);
        } else if (getElapsedTime() >= 17 days && getElapsedTime() < 18 days) {withdrawableToken0 = (8 * tenPercent).sub(withdrawn);
        } else if (getElapsedTime() >= 16 days && getElapsedTime() < 17 days) {withdrawableToken0 = (7 * tenPercent).sub(withdrawn);
        } else if (getElapsedTime() >= 15 days && getElapsedTime() < 16 days) {withdrawableToken0 = (6 * tenPercent).sub(withdrawn);
        } else if (getElapsedTime() >= 14 days && getElapsedTime() < 15 days) {withdrawableToken0 = (5 * tenPercent).sub(withdrawn);
        } else if (getElapsedTime() >= 13 days && getElapsedTime() < 14 days) {withdrawableToken0 = (4 * tenPercent).sub(withdrawn);
        } else if (getElapsedTime() >= 12 days && getElapsedTime() < 13 days) {withdrawableToken0 = (3 * tenPercent).sub(withdrawn);
        } else if (getElapsedTime() >= 11 days && getElapsedTime() < 12 days) {withdrawableToken0 = (2 * tenPercent).sub(withdrawn);
        } else if (getElapsedTime() >= 10 days && getElapsedTime() < 11 days) {withdrawableToken0 = tenPercent.sub(withdrawn);
        } else {withdrawableToken0 = 0;}

        return (withdrawableToken0, withdrawableToken1, withdrawableToken2);
    }    
}
