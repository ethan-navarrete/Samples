// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "@chainlink/contracts/src/v0.8/interfaces/VRFCoordinatorV2Interface.sol";
import "@chainlink/contracts/src/v0.8/VRFConsumerBaseV2.sol";

// @ dev: A smart contract using chainlink VRF v2 to generate random number to decide a coin flip
// @ dev: *** YOU MUST ADD THIS DEPLOYED CONTRACT ADDRESS TO THE APPROVED CONSUMER LIST! ***

contract CoinFlipRNG is VRFConsumerBaseV2 {
  
  VRFCoordinatorV2Interface COORDINATOR;
  address vrfCoordinator = 0x6A2AAd07396B36Fe02a22b33cf443582f682c82f; // for bsc testnet
  bytes32 keyHash = 0xd4bb89654db74673a187bd804519e65e3f71a52bc55f11da7601a13dcf505314; // for bsc testnet
  uint64 s_subscriptionId; // 657 on BSC Testnet
  uint32 callbackGasLimit = 120000; // each result ~ 20,000 gas
  uint32 numWords =  1; 
  uint16 requestConfirmations = 3; 
  
  uint256[] public s_randomWords;
  uint256 public s_requestId; 
  address s_owner;
  address public coinFlipContractAddress;

  constructor(uint64 subscriptionId) VRFConsumerBaseV2(vrfCoordinator) {
    COORDINATOR = VRFCoordinatorV2Interface(vrfCoordinator);
    s_owner = msg.sender;
    s_subscriptionId = subscriptionId;
  }

  // Assumes the subscription is funded sufficiently.
  function requestRandomWords() external {
    // Will revert if subscription is not set and funded.
    s_requestId = COORDINATOR.requestRandomWords(
      keyHash,
      s_subscriptionId,
      requestConfirmations,
      callbackGasLimit,
      numWords
    );
  }
  
  function fulfillRandomWords(
    uint256, /* requestId */
    uint256[] memory randomWords
  ) internal override {
    s_randomWords = randomWords;
  }

  function flipCoin() external view returns (uint256) {
    require(s_randomWords[0] != 0 , "Random number has not yet been requested");
    return s_randomWords[0] % 2;
  }

  modifier onlyOwner() {
    require(msg.sender == s_owner , "You're not the owner");
    _;
  }

  modifier onlyCoinFlipContract() {
    require(msg.sender == coinFlipContractAddress, "Only CoinFlip contract");
    _;
  }

  function setCoinFlipContract(address _address) public onlyOwner {
    coinFlipContractAddress = _address;
  }

}