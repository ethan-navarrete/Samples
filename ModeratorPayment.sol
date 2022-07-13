// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "./interfaces/IPair.sol";
import "./interfaces/IApple.sol";

// *** Contract to pay moderators for community. Ensures a friday withdrawl no matter how long a mod waits to claim payment. ***

contract TESTModClaim is Ownable, ReentrancyGuard {

    using SafeERC20 for IERC20;
    using SafeMath for uint;

    IPair public PairInterface;
    IApple public AppleInterface;
    address public constant PairAddress = 0x0B18F91fF6850DB46c1e21888Ec1cAb889a5E635;
    address public constant AppleAddress = 0xF65Ae63D580EDe49589992b6E772b48E61EaDed2;
    address public BUSD;

    mapping(address => bool) public isChief;
    mapping(address => bool) public isLead;
    mapping(address => uint) public lastClaim; // a block.timestamp
    mapping(address => uint) public startTime; // the block.timestamp when member was made a chief or a lead

    uint constant accFactor = 1 * 10 ** 18;
    uint chiefMultiplier = 250;
    uint leadMultiplier = 150;
    bool public applePaymentsEnabledForChiefs;
    bool public BUSDPaymentsEnabledForChiefs;
    bool public applePaymentsEnabledForLeads;
    bool public BUSDPaymentsEnabledForLeads;

    event AppleClaimed(address _claimer, uint _amount);
    event BUSDClaimed(address _claimer, uint _amount);
    event ChiefAdded(address _newChief, uint _timestamp);
    event ChiefRemoved(address _removedChief, uint _timestamp);
    event LeadAdded(address _newLead, uint _timestamp);
    event LeadRemoved(address _removedLead, uint _timestamp);

    constructor() {
        PairInterface = IPair(PairAddress);
        AppleInterface = IApple(AppleAddress);
        applePaymentsEnabledForChiefs = true;
        applePaymentsEnabledForLeads = true;
        BUSD = 0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56;
    }

    modifier modCheck() {
        require(isChief[msg.sender] || isLead[msg.sender] , "Not a chief or lead");
        require(isChief[msg.sender] != isLead[msg.sender] , "Cannot be chief and lead simultaneously");
        _;
    }

    modifier paymentCheck {
        require(
            applePaymentsEnabledForChiefs || 
            applePaymentsEnabledForLeads || 
            BUSDPaymentsEnabledForChiefs || 
            BUSDPaymentsEnabledForLeads , 
            "Payments Disabled");

        if (applePaymentsEnabledForChiefs == BUSDPaymentsEnabledForChiefs) {
            require(!applePaymentsEnabledForChiefs && !applePaymentsEnabledForLeads , 
            "Chiefs: Apple and BUSD payments cannot be active simultaneously");
        }
        if (applePaymentsEnabledForLeads == BUSDPaymentsEnabledForLeads) {
            require(!applePaymentsEnabledForChiefs && !applePaymentsEnabledForLeads , 
            "Leads: Apple and BUSD payments cannot be active simultaneously");
        }
        _;
    } 

    modifier timeCheck() {
        require((block.timestamp.sub(startTime[msg.sender])).div(604800) >= 1 , "Must be a mod for 1 week");
        require(block.timestamp - lastClaim[msg.sender] >= 604800 , "Must wait 1 week between payments");
        _;
    }

    // ----- Payment Function

    function getPaid() external nonReentrant modCheck() paymentCheck timeCheck() {

        uint timeMultiple = (block.timestamp.sub(lastClaim[msg.sender])).div(604800);

        // chiefs and leads both get apple         
        if ( 
            applePaymentsEnabledForChiefs && 
            applePaymentsEnabledForLeads &&
            !BUSDPaymentsEnabledForChiefs &&
            !BUSDPaymentsEnabledForLeads) { 

            if (isChief[msg.sender]) {
                uint chiefPayment;
                (chiefPayment,) = calculateTokens();
                AppleInterface.mint(msg.sender, chiefPayment * timeMultiple);
                lastClaim[msg.sender] = lastClaim[msg.sender].add(604800 * timeMultiple);
                emit AppleClaimed(msg.sender, chiefPayment * timeMultiple);
            } else if (isLead[msg.sender]) {
                uint leadPayment;
                (,leadPayment) = calculateTokens();
                AppleInterface.mint(msg.sender, leadPayment * timeMultiple);
                lastClaim[msg.sender] = lastClaim[msg.sender].add(604800 * timeMultiple);
                emit AppleClaimed(msg.sender, leadPayment * timeMultiple);
            }

        // chiefs get BUSD, leads get apple
        } else if (
            BUSDPaymentsEnabledForChiefs && 
            applePaymentsEnabledForLeads &&
            !applePaymentsEnabledForChiefs &&
            !BUSDPaymentsEnabledForLeads) { 

            if (isChief[msg.sender]) {
                uint chiefPayment = chiefMultiplier * 10**18 * timeMultiple;
                require(IERC20(BUSD).balanceOf(address(this)) >= chiefPayment , "Amt exceeds contract BUSD");
                IERC20(BUSD).safeTransfer(msg.sender, chiefPayment);
                lastClaim[msg.sender] = lastClaim[msg.sender].add(604800 * timeMultiple);
                emit BUSDClaimed(msg.sender, chiefPayment);
            } else if (isLead[msg.sender]) {
                uint leadPayment;
                (,leadPayment) = calculateTokens();
                AppleInterface.mint(msg.sender, leadPayment * timeMultiple);
                lastClaim[msg.sender] = lastClaim[msg.sender].add(604800 * timeMultiple);
                emit AppleClaimed(msg.sender, leadPayment * timeMultiple);
            }

        // chiefs and leads get BUSD
        } else if (
            BUSDPaymentsEnabledForChiefs && 
            BUSDPaymentsEnabledForLeads &&
            !applePaymentsEnabledForChiefs &&
            !applePaymentsEnabledForLeads) { 

            if (isChief[msg.sender]) {
                uint chiefPayment = chiefMultiplier * 10**18 * timeMultiple;
                require(IERC20(BUSD).balanceOf(address(this)) >= chiefPayment , "Amt exceeds contract BUSD");
                IERC20(BUSD).safeTransfer(msg.sender, chiefPayment);
                lastClaim[msg.sender] = lastClaim[msg.sender].add(604800 * timeMultiple);
                emit BUSDClaimed(msg.sender, chiefPayment);
            } else if (isLead[msg.sender]) {
                uint leadPayment = leadMultiplier * 10**18 * timeMultiple;
                require(IERC20(BUSD).balanceOf(address(this)) >= leadPayment , "Amt exceeds contract BUSD");
                IERC20(BUSD).safeTransfer(msg.sender, leadPayment);
                lastClaim[msg.sender] = lastClaim[msg.sender].add(604800 * timeMultiple);
                emit BUSDClaimed(msg.sender, leadPayment);
            }

        // chiefs get apple, leads get BUSD
        } else if (
            applePaymentsEnabledForChiefs && 
            BUSDPaymentsEnabledForLeads &&
            !BUSDPaymentsEnabledForChiefs &&
            !applePaymentsEnabledForLeads) { 

            if (isChief[msg.sender]) {
                uint chiefPayment;
                (chiefPayment,) = calculateTokens();
                AppleInterface.mint(msg.sender, chiefPayment * timeMultiple);
                lastClaim[msg.sender] = lastClaim[msg.sender].add(604800 * timeMultiple);
                emit AppleClaimed(msg.sender, chiefPayment * timeMultiple);
            } else if (isLead[msg.sender]) {
                uint leadPayment = leadMultiplier * 10**18 * timeMultiple;
                require(IERC20(BUSD).balanceOf(address(this)) >= leadPayment , "Amt exceeds contract BUSD");
                IERC20(BUSD).safeTransfer(msg.sender, leadPayment);
                lastClaim[msg.sender] = lastClaim[msg.sender].add(604800 * timeMultiple);
                emit BUSDClaimed(msg.sender, leadPayment);
            }
        }
    }

    function calculateTokens() internal view returns (uint, uint) {

        uint BUSDReserve; // BUSD reserve in Pair Contract
        uint APPLEReserve; // Apple reserve in Pair Contract
        (BUSDReserve,APPLEReserve,,) = PairInterface.getReserves();
        uint baseQuote = (((10**18) * accFactor) / BUSDReserve) * (APPLEReserve / accFactor);

        uint chiefPay = chiefMultiplier * baseQuote;
        uint leadPay = leadMultiplier * baseQuote;
        return (chiefPay, leadPay);
    }

    // ----- Setters

    function setLead(address _member, bool _bool, uint _startTime) external onlyOwner {

        if (isChief[_member] && _bool) { // if member is a chief and is being downgraded to lead
            isLead[_member] = _bool;
            isChief[_member] = false;
            emit ChiefRemoved(_member, block.timestamp);
            emit LeadAdded(_member, block.timestamp);
            assert(!isChief[_member]);
        } else if (isLead[_member] && _bool) { // if they're already a lead
            revert("Member is already a lead"); 
        } else if (!isLead[_member] && _bool) { // if param is true and member is not a lead
            isLead[_member] = _bool;
            startTime[_member] = _startTime;
            lastClaim[_member] = _startTime;
            emit LeadAdded(_member, block.timestamp);
            assert(!isChief[_member]);
        } else if (isLead[_member] && !_bool) { // remove them as a lead
            isLead[_member] = false;
            emit LeadRemoved(_member, block.timestamp);
        } else if (!isLead[_member] && !_bool) {
            revert("Member is not currently a lead");
        }
    }

    function setChief(address _member, bool _bool, uint _startTime) external onlyOwner {

        if (isLead[_member] && _bool) { // if member is a lead and is being upgraded to chief
            isChief[_member] = _bool;
            isLead[_member] = false;
            emit LeadRemoved(_member, block.timestamp);
            emit ChiefAdded(_member, block.timestamp);
            assert(!isLead[_member]);
        } else if (isChief[_member] && _bool) { // if they're already a chief
            revert("Member is already a chief"); 
        } else if (!isChief[_member] && _bool) { // if param is true and member is not a chief
            isChief[_member] = _bool;
            startTime[_member] = _startTime;
            lastClaim[_member] = _startTime;
            emit ChiefAdded(_member, block.timestamp);
            assert(!isLead[_member]);
        } else if (isChief[_member] && !_bool) { // remove them as a chief
            isChief[_member] = false;
            emit ChiefRemoved(_member, block.timestamp);
        } else if (!isChief[_member] && !_bool) {
            revert("Member is not currently a chief");
        } 
    }

    function setStartTime(address _member, uint _startTime) external onlyOwner modCheck() {
        startTime[_member] = _startTime;
    }

    function setLastClaim(address _member, uint _startTime) external onlyOwner modCheck() {
        lastClaim[_member] = _startTime;
    }

    function enableBUSDPaymentsForChiefs() external onlyOwner {
        applePaymentsEnabledForChiefs = false;
        BUSDPaymentsEnabledForChiefs = true;
        assert(applePaymentsEnabledForChiefs != BUSDPaymentsEnabledForChiefs);
    }

    function enableApplePaymentsForChiefs() external onlyOwner {
        BUSDPaymentsEnabledForChiefs = false;
        applePaymentsEnabledForChiefs = true;
        assert(applePaymentsEnabledForChiefs != BUSDPaymentsEnabledForChiefs);
    }

    function enableBUSDPaymentsForLeads() external onlyOwner {
        applePaymentsEnabledForLeads = false;
        BUSDPaymentsEnabledForLeads = true;
        assert(applePaymentsEnabledForLeads != BUSDPaymentsEnabledForLeads);
    }

    function enableApplePaymentsForLeads() external onlyOwner {
        BUSDPaymentsEnabledForLeads = false;
        applePaymentsEnabledForLeads = true;
        assert(applePaymentsEnabledForLeads != BUSDPaymentsEnabledForLeads);
    }

    function disableAllPayments() external onlyOwner {
        BUSDPaymentsEnabledForChiefs = false;
        applePaymentsEnabledForChiefs = false;
        BUSDPaymentsEnabledForLeads = false;
        applePaymentsEnabledForLeads = false;
        assert(
            !applePaymentsEnabledForChiefs && 
            !BUSDPaymentsEnabledForChiefs &&
            !applePaymentsEnabledForLeads &&
            !BUSDPaymentsEnabledForLeads);
    }

    function updatePaymentMultipliers(uint _chiefMult, uint _leadMult) external onlyOwner {
        chiefMultiplier = _chiefMult;
        leadMultiplier = _leadMult;
    }

    function withdrawBUSD() external onlyOwner {
        uint bal = IERC20(BUSD).balanceOf(address(this));
        IERC20(BUSD).safeTransfer(msg.sender, bal);
    }

    function setBUSD(address _BUSD) external onlyOwner {
        BUSD = _BUSD;
    }
}
