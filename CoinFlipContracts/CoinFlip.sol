
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./interfaces/ICoinFlipRNG.sol";

// contract that allows users to bet on a coin flip. RNG contract must be deployed first. 
// ********** THIS CONTRACT IS NOT YET FINALIZED AS OF 08 JUNE 2022 ********************

contract CoinFlip is Ownable, ReentrancyGuard {

    using SafeERC20 for IERC20;

    //----- Interfaces/Addresses -----

    ICoinFlipRNG public CoinFlipRNG;
    address public CoinFlipRNGAddress;
    address public Token;
    address public devWallet;

    //----- Mappings -----------------

    mapping(address => mapping(uint256 => Bet)) public Bets; // keeps track of each players bet for each sessionId
    mapping(address => mapping(uint256 => bool)) public HasBet; // keeps track of whether or not a user has bet in a certain session #
    mapping(address => mapping(uint256 => bool)) public HasClaimed; // keeps track of users and whether or not they have claimed reward for a session
    mapping(address => mapping(uint256 => uint256)) public PlayerRewardPerSession; // keeps track of player rewards per session
    mapping(address => uint256) public TotalRewards;
    mapping(uint256 => Session) private _sessions;

    //----- Lottery State Variables ---------------

    uint256 public maxDuration = 60 seconds;
    uint256 public minDuration = 5 seconds;
    uint256 public constant maxDevFee = 200; // 2%
    uint256 currentSessionId;

    // status for betting sessions
    enum Status {
        Closed,
        Open,
        Standby,
        Disbursing
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
        uint256 collectedToken;
        uint256 TokenForDisbursal;
        uint256 totalPayouts;
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
        uint256 collectedToken
    );

    event CoinFlipped(
        uint256 flipResult
    );

    event RewardClaimed(
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

    constructor(address _Token, address _devWallet) {
        Token = _Token;
        devWallet = _devWallet;
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

    // @dev: returns the size of the code of an address. If >0, address is a contract. 
    function _isContract(address _addr) internal view returns (bool) {
        uint256 size;
        assembly {
            size := extcodesize(_addr)
        }
        return size > 0;
    }

    modifier isPending(uint256 _sessionId) {
        require(_sessions[_sessionId].status == Status.Standby, "Session is not pending!");
        _;
    }

    modifier isOpen(uint256 _sessionId) {
        require(_sessions[_sessionId].status == Status.Open, "Session is not open!");
        _;
    }

    modifier isClosed(uint256 _sessionId) {
        require(_sessions[_sessionId].status == Status.Closed, "Session is not closed!");
        _;
    }


    modifier isDisbursing(uint256 _sessionId) {
        require(_sessions[_sessionId].status == Status.Disbursing, "Session is not disbursing!");
        _;
    }

    // ------------------- Setters/Getters ------------------------

    // dev: set the address of the RNG contract interface
    function setRNGAddress(address _address) external onlyOwner {
        CoinFlipRNGAddress = (_address);
        CoinFlipRNG = ICoinFlipRNG(_address);
    }

    function setDevWallet(address _address) external onlyOwner {
        devWallet = _address;
    }

    function setToken(address _Token) external onlyOwner {
        Token = _Token;
    }

    function setMaxMinDuration(uint256 _max, uint256 _min) external onlyOwner {
        maxDuration = _max;
        minDuration = _min;
    }

    function getCurrentSessionId() external view returns (uint256) {
        return currentSessionId;
    }
    
    function viewSessionById(uint256 _sessionId) external view onlyOwner returns (Session memory) {
        return _sessions[_sessionId];
    }

    function viewTokenBalance() external view returns (uint256) {
        return IERC20(Token).balanceOf(address(this));
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

    // ------------------- Bet Function ----------------------

    // heads = 0, tails = 1
    function bet(uint256 _amount, uint8 _choice) external {
        require(IERC20(Token).balanceOf(address(msg.sender)) >= _amount);
        require(_amount >= _sessions[currentSessionId].minBet , "Must bet more than minimum amount!");
        require(_amount <= _sessions[currentSessionId].maxBet , "Must bet less than maximum amount!");
        require(_choice == 1 || _choice == 0, "Must choose 0 or 1!");
        require(!HasBet[msg.sender][currentSessionId] , "You have already bet in this session!");
        IERC20(Token).safeTransferFrom(address(msg.sender), address(this), _amount);
        _sessions[currentSessionId].collectedToken += _amount;

        if (_choice == 0) {
            Bets[msg.sender][currentSessionId].player = msg.sender;
            Bets[msg.sender][currentSessionId].amount = _amount;
            Bets[msg.sender][currentSessionId].choice = 0;
            _sessions[currentSessionId].headsCount++;
        } else {
            Bets[msg.sender][currentSessionId].player = msg.sender;
            Bets[msg.sender][currentSessionId].amount = _amount;
            Bets[msg.sender][currentSessionId].choice = 1;  
            _sessions[currentSessionId].tailsCount++;
        }

        HasBet[msg.sender][currentSessionId] = true;

        emit BetPlaced(
            msg.sender,
            currentSessionId,
            _amount,
            _choice
        );
    }

    // ------------------- Start Session ---------------------- 

    function startSession(
        uint256 _endTime,
        uint256 _minBet,
        uint256 _maxBet,
        uint256 _devFee) 
        public
        {
        require(
            (currentSessionId == 0) || (_sessions[currentSessionId].status == Status.Closed),
            "Not time to start session!"
        );

        require(
            ((_endTime - block.timestamp) > minDuration) && ((_endTime - block.timestamp) < maxDuration),
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
            collectedToken: 0,
            TokenForDisbursal: 0,
            totalPayouts: 0,
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

    // --------------------- CLOSE SESSION -----------------

    function closeSession(uint256 _sessionId) external {
      
        require(block.timestamp > _sessions[_sessionId].endTime, "Lottery not over yet!");
        generateRandomNumber();
        _sessions[_sessionId].status = Status.Closed;

        emit SessionClosed(
            _sessionId,
            block.timestamp,
            _sessions[_sessionId].headsCount,
            _sessions[_sessionId].tailsCount,
            _sessions[_sessionId].collectedToken
        );
    }

    // -------------------- Flip Coin & Announce Result ----------------

    function flipCoinAndMakeDisbursable(uint256 _sessionId) external returns (uint256) {
        
        uint256 sessionFlipResult = flipCoin();
        _sessions[currentSessionId].TokenForDisbursal = (
            ((_sessions[_sessionId].collectedToken) * (10000 - _sessions[_sessionId].devFee))) / 10000;
        _sessions[_sessionId].flipResult = sessionFlipResult;
        uint256 amountToDevWallet = (_sessions[_sessionId].collectedToken) - (_sessions[_sessionId].TokenForDisbursal);
        IERC20(Token).safeTransfer(devWallet, amountToDevWallet);
        emit CoinFlipped(sessionFlipResult);
        return sessionFlipResult;
    }

    // ------------------ Injection Functions --------------------

    function autoInject(uint256 _sessionId, uint256 _amount) internal {
        IERC20(Token).safeTransferFrom(devWallet, address(this), _amount);
        _sessions[_sessionId].collectedToken += _amount;

        emit AutoInjection(_sessionId, _amount);
    }

    function injectFunds(uint256 _sessionId, uint256 _amount) external onlyOwner {
        IERC20(Token).safeTransferFrom(address(msg.sender), address(this), _amount);
        _sessions[_sessionId].collectedToken += _amount;

        emit ManualInjection(_sessionId, _amount);
    }

    // ------------------ Claim Reward Function ---------------------

    function claimRewardPerSession(uint256 _sessionId) external {
        
        require(HasBet[msg.sender][_sessionId] , "You didn't bet in this session!");
        require(!HasClaimed[msg.sender][_sessionId] , "Already claimed reward!");
        require(Bets[msg.sender][_sessionId].choice == _sessions[_sessionId].flipResult , "You didn't win!");

            uint256 playerBet = Bets[msg.sender][_sessionId].amount;
            uint256 intHelper = 10000 - (_sessions[_sessionId].devFee);
            uint256 adjustedBet = playerBet * intHelper;
            uint256 intHelper2 = (adjustedBet) / 10000;
            uint256 payout = playerBet + intHelper2;

            if (IERC20(Token).balanceOf(address(this)) >= payout) {
                IERC20(Token).safeTransfer(msg.sender, payout);
            } else {
                autoInject(_sessionId, payout);
                IERC20(Token).safeTransfer(msg.sender, payout);
            }
            
            _sessions[_sessionId].totalPayouts += payout;
            PlayerRewardPerSession[msg.sender][_sessionId] = payout;
            TotalRewards[msg.sender] += payout;
            HasClaimed[msg.sender][_sessionId] = true;
            emit RewardClaimed(msg.sender, _sessionId, payout);   
    }
}
