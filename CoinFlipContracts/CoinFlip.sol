// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./interfaces/ICoinFlipRNG.sol";
import "./interfaces/IApple.sol";

// contract that allows users to bet on a coin flip. RNG contract must be deployed first. 

contract CoinFlip is Ownable, ReentrancyGuard {

    using SafeERC20 for IERC20;

    //----- Interfaces/Addresses -----

    ICoinFlipRNG public CoinFlipRNG;
    IApple public AppleInterface;
    address public CoinFlipRNGAddress;
    address public Apple;
    address public devWallet;

    //----- Mappings -----------------

    mapping(address => mapping(uint256 => Bet)) public Bets; // keeps track of each players bet for each sessionId
    mapping(address => mapping(uint256 => bool)) public HasBet; // keeps track of whether or not a user has bet in a certain session #
    mapping(address => mapping(uint256 => bool)) public HasClaimed; // keeps track of users and whether or not they have claimed reward for a session
    mapping(address => mapping(uint256 => bool)) public HasBeenRefunded; // keeps track of whether or not a user has been refunded for a particular session
    mapping(address => mapping(uint256 => uint256)) public PlayerRewardPerSession; // keeps track of player rewards per session
    mapping(address => mapping(uint256 => uint256)) public PlayerRefundPerSession; // keeps track of player refunds per session
    mapping(address => uint256) public TotalRewards; // a user's total collected payouts (lifetime)
    mapping(uint256 => Session) public _sessions; // mapping for session id to unlock corresponding session params
    mapping(address => bool) public Operators; // contract operators 
    mapping(address => uint256[]) public EnteredSessions; // list of session ID's that a particular address has bet in
   

    //----- Lottery State Variables ---------------

    uint256 public maxDuration;
    uint256 public minDuration;
    uint256 public constant maxDevFee = 1000; // 10%
    uint256 public currentSessionId;
    uint256 constant accuracyFactor = 1 * 10**18;
    bool public autoBurnEnabled; // automatic burn fxn variable when devFee is collected
    bool public autoStartSessionEnabled; // automatic bool to determine whether or not new sessions start automatically when closeSession is called

    //----- Default Parameters for Session -------

    uint256 public defaultLength; // in SECONDS
    uint256 public defaultMaxBet; 
    uint256 public defaultMinBet; // > 0
    uint256 public defaultDevFee; // 200: 2%

    // status for betting sessions
    enum Status {
        Closed,
        Open,
        Standby,
        Voided,
        Claimable
    }

    // player bet
    struct Bet {
        address player;
        uint256 amount; 
        uint8 choice; // (0) heads or (1) tails;
    }
    
    // params for each bet session
    struct Session {
        Status status;
        uint256 sessionId;
        uint256 startTime;
        uint256 endTime;
        uint256 minBet;
        uint256 maxBet;
        uint256 headsCount;
        uint256 tailsCount;
        uint256 headsApple;
        uint256 tailsApple;
        uint256 injectedApple;
        uint256 collectedApple;
        uint256 appleForDisbursal;
        uint256 totalPayouts;
        uint256 totalRefunds;
        uint256 devFee;
        uint256 flipResult;
    }

    //----- Events --------------

    event SessionOpened(
        uint256 indexed sessionId,
        uint256 startTime,
        uint256 endTime,
        uint256 minBet,
        uint256 maxBet
    );

    event BetPlaced(
        address indexed player, 
        uint256 indexed sessionId, 
        uint256 amount,
        uint8 choice
    );

    event SessionClosed(
        uint256 indexed sessionId, 
        uint256 endTime,
        uint256 headsCount,
        uint256 tailsCount,
        uint256 headsApple,
        uint256 tailsApple,
        uint256 injectedApple,
        uint256 collectedApple
    );

    event SessionVoided(
        uint256 indexed sessionId,
        uint256 endTime,
        uint256 headsCount,
        uint256 tailsCount,
        uint256 headsApple,
        uint256 tailsApple,
        uint256 injectedApple,
        uint256 collectedApple
    );

    event CoinFlipped(
        uint256 indexed sessionId,
        uint256 flipResult
    );

    event RewardClaimed(
        address indexed player,
        uint256 indexed sessionId,
        uint256 amount
    );

    event RefundClaimed(
        address indexed player,
        uint256 indexed sessionId,
        uint256 amount
    );

    event ManualInjection(
        uint256 indexed sessionId,
        uint256 amount
    );

    event AutoInjection(
        uint256 indexed sessionId,
        uint256 amount
    );

    event AppleBurned(
        uint256 indexed sessionId,
        uint256 amount
    );

    constructor(
        address _Apple, 
        address _RNG, 
        address _devWallet, 
        uint256 _defaultLength, 
        uint256 _defaultMaxBet, 
        uint256 _defaultMinBet, 
        uint256 _defaultDevFee) {
            Apple = _Apple;
            AppleInterface = IApple(_Apple);
            CoinFlipRNGAddress = _RNG;
            CoinFlipRNG = ICoinFlipRNG(_RNG);
            devWallet = _devWallet;
            defaultLength = _defaultLength;
            defaultMinBet = _defaultMinBet;
            defaultMaxBet = _defaultMaxBet;
            defaultDevFee = _defaultDevFee;
    }

    //---------------------------- MODIFIERS-------------------------

    modifier notOwner() {
        require(msg.sender != owner() , "Owner not allowed!");
        _;
    }

    // @dev: disallows contracts from entering
    modifier notContract() {
        require(!_isContract(msg.sender), "Contract not allowed");
        require(msg.sender == tx.origin, "Proxy contract not allowed");
        _;
    }

    modifier onlyOwnerOrOperator() {
        require(msg.sender == owner() || Operators[msg.sender] , "Not owner or operator!");
        _;
    }

    // @dev: returns the size of the code of an address. If >0, address is a contract. 
    function _isContract(address _addr) internal view returns (bool) {
        uint256 size;
        assembly {
            size := extcodesize(_addr)
        }
        return size > 0;
    }

    // ------------------- Setters/Getters ------------------------

    function setDefaultParams(uint256 _defaultLength, uint256 _defaultMaxBet, uint256 _defaultMinBet, uint256 _defaultDevFee) external onlyOwner {
        require(
        currentSessionId == 0 || 
        _sessions[currentSessionId].status == Status.Closed || 
        _sessions[currentSessionId].status == Status.Claimable, 
        "The session must be closed or claimable to update values!");
        require(_defaultLength >= minDuration && _defaultLength <= maxDuration , "Not within max/min time duration");
        require(_defaultMinBet > 0 , "Minimum bet must be > 0");
        require(_defaultDevFee <= maxDevFee , "Cannot exceed maxDevFee!");
        defaultLength = _defaultLength;
        defaultMaxBet = _defaultMaxBet;
        defaultMinBet = _defaultMinBet;
        defaultDevFee = _defaultDevFee;
    }

    // dev: set the address of the RNG contract interface
    function setRNGAddress(address _address) external onlyOwner {
        require(
        currentSessionId == 0 || 
        _sessions[currentSessionId].status == Status.Closed || 
        _sessions[currentSessionId].status == Status.Claimable, 
        "The session must be closed or claimable to update values!");
        CoinFlipRNGAddress = _address;
        CoinFlipRNG = ICoinFlipRNG(_address);
    }

    function setApple(address _address) external onlyOwner {
        require(
        currentSessionId == 0 || 
        _sessions[currentSessionId].status == Status.Closed || 
        _sessions[currentSessionId].status == Status.Claimable, 
        "The session must be closed or claimable to update values!");
        Apple = _address;
        AppleInterface = IApple(_address);
    }

    function setDevWallet(address _address) external onlyOwner {
        require(
        currentSessionId == 0 || 
        _sessions[currentSessionId].status == Status.Closed || 
        _sessions[currentSessionId].status == Status.Claimable, 
        "The session must be closed or claimable to update values!");
        devWallet = _address;
    }

    function setMaxMinDuration(uint256 _max, uint256 _min) external onlyOwner {
        require(
        currentSessionId == 0 || 
        _sessions[currentSessionId].status == Status.Closed || 
        _sessions[currentSessionId].status == Status.Claimable, 
        "The session must be closed or claimable to update values!");
        maxDuration = _max;
        minDuration = _min;
    }

    function setAutoBurn(bool _bool) external onlyOwner {
        require(
        currentSessionId == 0 || 
        _sessions[currentSessionId].status == Status.Closed || 
        _sessions[currentSessionId].status == Status.Claimable, 
        "The session must be closed or claimable to update values!");
        autoBurnEnabled = _bool;
    }

    function setAutoSessionStart(bool _bool) external onlyOwner {
        require(
        currentSessionId == 0 || 
        _sessions[currentSessionId].status == Status.Closed || 
        _sessions[currentSessionId].status == Status.Claimable, 
        "The session must be closed or claimable to update values!");
        autoStartSessionEnabled = _bool;
    }
    
    function viewSessionById(uint256 _sessionId) external view returns (Session memory) {
        return _sessions[_sessionId];
    }

    function getAppleBalance() external view returns (uint256) {
        return IERC20(Apple).balanceOf(address(this));
    }

    function setOperator(address _operator, bool _bool) external onlyOwner {
        Operators[_operator] = _bool;
    }

    function getEnteredSessionsLength(address _better) external view returns (uint256) {
        return EnteredSessions[_better].length;
    }

    function getBetHistory(address _better, uint256 _sessionId) external view returns 
    (uint256, uint256, uint256, uint256, uint256, uint256, uint256, uint256) {
        return (Bets[_better][_sessionId].amount, 
                Bets[_better][_sessionId].choice,
                _sessions[_sessionId].startTime,
                _sessions[_sessionId].endTime,
                _sessions[_sessionId].headsApple,
                _sessions[_sessionId].tailsApple,
                _sessions[_sessionId].devFee,
                _sessions[_sessionId].flipResult);
    }

    // ------------------- Coin Flip Functions ----------------------

    // @dev: generates a random number in the VRF contract. must be called before flipCoin() 
    // cannot be called unless the session.status is OPEN, impossible to place a bet after random number is chosen for that session.
    function generateRandomNumber() internal {
        CoinFlipRNG.requestRandomWords();
    }

    // @dev: return 1 or 0
    function flipCoin() internal returns (uint256) {
        uint256 result = CoinFlipRNG.flipCoin();
        _sessions[currentSessionId].status = Status.Standby;
        if (result == 0) {
            _sessions[currentSessionId].flipResult = 0;
        } else {
            _sessions[currentSessionId].flipResult = 1;
        }
        return result;
    }

    // ------------------ Injection Functions --------------------

    function autoInject(uint256 _sessionId, uint256 _amount) internal {
        IERC20(Apple).safeTransferFrom(devWallet, address(this), _amount);
        _sessions[_sessionId].injectedApple += _amount;
        emit AutoInjection(_sessionId, _amount);
    }

    function injectFunds(uint256 _sessionId, uint256 _amount) external onlyOwner {
        IERC20(Apple).safeTransferFrom(address(msg.sender), address(this), _amount);
        _sessions[_sessionId].injectedApple += _amount;
        emit ManualInjection(_sessionId, _amount);
    }

    // ------------------- AutoSessionFxn ---------------------

    function autoStartSession() internal {
        require(autoStartSessionEnabled , "Automatic sessions are not enabled!");
        startSession(block.timestamp + defaultLength, defaultMinBet, defaultMaxBet, defaultDevFee);
    }

    // ------------------- Start Session ---------------------- 

    function startSession(
        uint256 _endTime,
        uint256 _minBet,
        uint256 _maxBet,
        uint256 _devFee) 
        public
        onlyOwnerOrOperator()
        {
        require(
            (currentSessionId == 0) || 
            (_sessions[currentSessionId].status == Status.Claimable) || 
            (_sessions[currentSessionId].status == Status.Voided),
            "Session must be closed, claimable, or voided"
        );

        require(
            ((_endTime - block.timestamp) >= minDuration) && ((_endTime - block.timestamp) <= maxDuration),
            "Session length outside of range"
        );

        require(
            _devFee <= maxDevFee , "Dev fee is too high!"
        );

        currentSessionId++;

        _sessions[currentSessionId] = Session({
            status: Status.Open,
            sessionId: currentSessionId,
            startTime: block.timestamp,
            endTime: _endTime,
            minBet: _minBet,
            maxBet: _maxBet,
            headsCount: 0,
            tailsCount: 0,
            headsApple: 0,
            tailsApple: 0,
            injectedApple: 0,
            collectedApple: 0,
            appleForDisbursal: 0,
            totalPayouts: 0,
            totalRefunds: 0,
            devFee: _devFee,
            flipResult: 2 // init to 2 to avoid conflict with 0 (heads) or 1 (tails). is set to 0 or 1 later depending on coin flip result.
        });
        
        emit SessionOpened(
            currentSessionId,
            block.timestamp,
            _endTime,
            _minBet,
            _maxBet
        );
    }

    // ------------------- Bet Function ----------------------

    // heads = 0, tails = 1
    function bet(uint256 _amount, uint8 _choice) external nonReentrant notContract() notOwner() {
        require(_sessions[currentSessionId].status == Status.Open , "Session must be open to bet!");
        require(IERC20(Apple).balanceOf(address(msg.sender)) >= _amount , "You don't have enough Apple to place this bet!");
        require(_amount >= _sessions[currentSessionId].minBet && _amount <= _sessions[currentSessionId].maxBet , "Bet is not within bet limits!");
        require(_choice == 1 || _choice == 0, "Must choose 0 or 1!");
        require(!HasBet[msg.sender][currentSessionId] , "You have already bet in this session!");
        require(block.timestamp <= _sessions[currentSessionId].endTime, "Betting has ended!");
        IERC20(Apple).safeTransferFrom(address(msg.sender), address(this), _amount);
        _sessions[currentSessionId].collectedApple += _amount;

        if (_choice == 0) {
            Bets[msg.sender][currentSessionId].player = msg.sender;
            Bets[msg.sender][currentSessionId].amount = _amount;
            Bets[msg.sender][currentSessionId].choice = 0;
            _sessions[currentSessionId].headsCount++;
            _sessions[currentSessionId].headsApple += _amount;
        } else {
            Bets[msg.sender][currentSessionId].player = msg.sender;
            Bets[msg.sender][currentSessionId].amount = _amount;
            Bets[msg.sender][currentSessionId].choice = 1;  
            _sessions[currentSessionId].tailsCount++;
            _sessions[currentSessionId].tailsApple += _amount;
        }

        HasBet[msg.sender][currentSessionId] = true;
        EnteredSessions[msg.sender].push(currentSessionId);

        emit BetPlaced(
            msg.sender,
            currentSessionId,
            _amount,
            _choice
        );
    }

    // --------------------- CLOSE SESSION -----------------

    function closeSession(uint256 _sessionId) external nonReentrant onlyOwnerOrOperator() {
        require(_sessions[_sessionId].status == Status.Open , "Session must be open to close it!");
        require(block.timestamp > _sessions[_sessionId].endTime, "Lottery not over yet!");

        if (_sessions[_sessionId].headsCount == 0 || _sessions[_sessionId].tailsCount == 0) {
            _sessions[_sessionId].status = Status.Voided;
            if (autoStartSessionEnabled) {autoStartSession();}
            emit SessionVoided(
                _sessionId,
                block.timestamp,
                _sessions[_sessionId].headsCount,
                _sessions[_sessionId].tailsCount,
                _sessions[_sessionId].headsApple,
                _sessions[_sessionId].tailsApple,
                _sessions[_sessionId].injectedApple,
                _sessions[_sessionId].collectedApple
            );
        } else {
            generateRandomNumber();
            _sessions[_sessionId].status = Status.Closed;
            emit SessionClosed(
                _sessionId,
                block.timestamp,
                _sessions[_sessionId].headsCount,
                _sessions[_sessionId].tailsCount,
                _sessions[_sessionId].headsApple,
                _sessions[_sessionId].tailsApple,
                _sessions[_sessionId].injectedApple,
                _sessions[_sessionId].collectedApple
            );
        }
    }

    // -------------------- Flip Coin & Announce Result ----------------

    function flipCoinAndMakeClaimable(uint256 _sessionId) external nonReentrant onlyOwnerOrOperator returns (uint256) {
        require(_sessionId <= currentSessionId , "Nonexistent session!");
        require(_sessions[_sessionId].status == Status.Closed , "Session must be closed first!");
        uint256 sessionFlipResult = flipCoin();
        _sessions[_sessionId].flipResult = sessionFlipResult;

        uint256 amountToDevWallet;

        if (sessionFlipResult == 0) { // if heads, tails betters pay the winners
            _sessions[_sessionId].appleForDisbursal = (
            ((_sessions[_sessionId].tailsApple) * (10000 - _sessions[_sessionId].devFee))) / 10000;
            amountToDevWallet = (_sessions[_sessionId].tailsApple) - (_sessions[_sessionId].appleForDisbursal);
        } else { // if tails..
            _sessions[_sessionId].appleForDisbursal = (
            ((_sessions[_sessionId].headsApple) * (10000 - _sessions[_sessionId].devFee))) / 10000;
            amountToDevWallet = (_sessions[_sessionId].headsApple) - (_sessions[_sessionId].appleForDisbursal);
        }
        
        if (autoBurnEnabled) {
            AppleInterface.burn(amountToDevWallet);
            emit AppleBurned(_sessionId, amountToDevWallet);
        } else {
            IERC20(Apple).safeTransfer(devWallet, amountToDevWallet);
        }
        
        _sessions[_sessionId].status = Status.Claimable;
        emit CoinFlipped(_sessionId, sessionFlipResult);
        if (autoStartSessionEnabled) {autoStartSession();}
        return sessionFlipResult;
    }

    // ------------------ Claim Reward Function ---------------------

    function claimRewardPerSession(uint256 _sessionId) external nonReentrant notContract() notOwner() {
        require(_sessions[_sessionId].status == Status.Claimable , "Session is not yet claimable!");
        require(HasBet[msg.sender][_sessionId] , "You didn't bet in this session!"); // make sure they've bet
        require(!HasClaimed[msg.sender][_sessionId] , "Already claimed reward!"); // make sure they can't claim twice
        require(Bets[msg.sender][_sessionId].choice == _sessions[_sessionId].flipResult , "You didn't win!"); // make sure they won

            uint256 playerWeight;
            uint256 playerBet = Bets[msg.sender][_sessionId].amount; // how much a user bet

            if (_sessions[_sessionId].flipResult == 0) {
                playerWeight = (playerBet * accuracyFactor) / (_sessions[_sessionId].headsApple); // ratio of adjusted winner bet amt. / sum of all winning heads bets
            } else if (_sessions[_sessionId].flipResult == 1) {
                playerWeight = (playerBet * accuracyFactor) / (_sessions[_sessionId].tailsApple); // ratio of adjusted winner bet amt. / sum of all winning tails bets
            }

            uint256 payout = ((playerWeight * (_sessions[_sessionId].appleForDisbursal)) / accuracyFactor) + playerBet;

            if (IERC20(Apple).balanceOf(address(this)) >= payout) {
                IERC20(Apple).safeTransfer(msg.sender, payout);
            } else {
                autoInject(_sessionId, payout);
                IERC20(Apple).safeTransfer(msg.sender, payout);
            }
            
            _sessions[_sessionId].totalPayouts += payout;
            PlayerRewardPerSession[msg.sender][_sessionId] = payout;
            TotalRewards[msg.sender] += payout;
            HasClaimed[msg.sender][_sessionId] = true;
            emit RewardClaimed(msg.sender, _sessionId, payout);   
    }

    // ------------------ Refund Fxn for Voided Sessions ----------------

    // sessions are voided if there isn't at least one tails bet and one heads bet. In this case, betters receive full refunds
    function claimRefundForVoidedSession(uint256 _sessionId) external nonReentrant notContract() notOwner() {
        require(_sessions[_sessionId].status == Status.Voided , "This session is not voided");
        require(HasBet[msg.sender][_sessionId] , "You didn't bet in this session!");
        require(PlayerRewardPerSession[msg.sender][_sessionId] == 0 && !HasBeenRefunded[msg.sender][_sessionId], "Already claimed reward or refund!"); 

            uint256 refundAmount = Bets[msg.sender][_sessionId].amount;
        
            if (IERC20(Apple).balanceOf(address(this)) >= refundAmount) {
                IERC20(Apple).safeTransfer(msg.sender, refundAmount);
            } else {
                autoInject(_sessionId, refundAmount);
                IERC20(Apple).safeTransfer(msg.sender, refundAmount);
            }

        HasBeenRefunded[msg.sender][_sessionId] = true;
        PlayerRefundPerSession[msg.sender][_sessionId] += refundAmount;
        _sessions[_sessionId].totalRefunds += refundAmount;
        emit RefundClaimed(msg.sender, _sessionId, refundAmount); 

    }

    // ------------------ Read Fxn to Calculate Payout ------------------

    function calculatePayout(address _address, uint256 _sessionId) external view returns (uint256) {
        uint256 calculatedPayout;

        if (_sessions[_sessionId].status != Status.Claimable ||
            !HasBet[_address][_sessionId] ||
            Bets[_address][_sessionId].choice != _sessions[_sessionId].flipResult) {
            calculatedPayout = 0; 
            return calculatedPayout;
        } else {
            uint256 playerWeight;
            uint256 playerBet = Bets[_address][_sessionId].amount; // how much a user bet

            if (_sessions[_sessionId].flipResult == 0) {
                playerWeight = (playerBet * accuracyFactor) / (_sessions[_sessionId].headsApple); // ratio of adjusted winner bet amt. / sum of all winning heads bets
            } else if (_sessions[_sessionId].flipResult == 1) {
                playerWeight = (playerBet * accuracyFactor) / (_sessions[_sessionId].tailsApple); // ratio of adjusted winner bet amt. / sum of all winning tails bets
            }

            uint256 payout = ((playerWeight * (_sessions[_sessionId].appleForDisbursal)) / accuracyFactor) + playerBet;
            return payout;
        }
    }
}
