{\rtf1\ansi\ansicpg1252\cocoartf2580
\cocoatextscaling0\cocoaplatform0{\fonttbl\f0\fmodern\fcharset0 Courier;}
{\colortbl;\red255\green255\blue255;\red255\green255\blue255;}
{\*\expandedcolortbl;;\cssrgb\c100000\c100000\c100000;}
\margl1440\margr1440\vieww11520\viewh8400\viewkind0
\deftab720
\pard\pardeftab720\partightenfactor0

\f0\fs24 \cf2 \expnd0\expndtw0\kerning0
\outl0\strokewidth0 \strokec2 // SPDX-License-Identifier: MIT LICENSE\
pragma solidity ^0.8.15;\
\
// contract where staked Bull nfts are stored\
import "@openzeppelin/contracts/access/Ownable.sol";\
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";\
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";\
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";\
import "./interfaces/IGenesis.sol";\
\
contract Bullpen is Ownable, IERC721Receiver \{\
    \
    using EnumerableSet for EnumerableSet.UintSet;\
\
    constructor() \{\
        Genesis = 0x881935AC212d66C6C35317A93d39840bAbF67CF3;\
        GenesisInterface = IGenesis(0x881935AC212d66C6C35317A93d39840bAbF67CF3);\
    \}\
\
    address public immutable Genesis;\
    IGenesis public GenesisInterface;\
    address public BullRunGame; // BullRun game contract\
    mapping(uint16 => address) private OriginalOwner; // tokID => wallet of staker\
\
    EnumerableSet.UintSet private bullIds;\
\
    event BullReceived (address indexed _originalOwner, uint16 _id);\
    event BullReturned (address indexed _returnee, uint16 _id);\
    event RunnerThiefSelected (address indexed _thief);\
\
    modifier onlyBullRunGame() \{\
        require(BullRunGame != address(0) , "BullRunGame has not been set yet");\
        require(msg.sender == BullRunGame , "Only BullRun");\
        _;\
    \}\
\
    function onERC721Received(address, address, uint256, bytes memory) public virtual override returns (bytes4) \{\
        return this.onERC721Received.selector;\
    \}\
\
    function setBullRunGameContract(address _bullRun) external onlyOwner \{\
        BullRunGame = _bullRun;\
    \}\
\
    // number of bulls in this contract\
    function bullCount() public view returns (uint16) \{\
        return uint16(bullIds.length());\
    \}\
\
    // for Bull owners who are staking\
    function receiveBull(address _originalOwner, uint16 _id) external onlyBullRunGame() \{\
        OriginalOwner[_id] = _originalOwner;\
        bullIds.add(_id);\
        emit BullReceived(_originalOwner, _id);\
    \}\
\
    // for Bull owners who are unstaking\
    function returnBullToOwner(address _returnee, uint16 _id) external onlyBullRunGame() \{\
        require(_returnee == OriginalOwner[_id], "Bull does not belong to passed returnee");\
        IERC721(Genesis).safeTransferFrom(address(this), _returnee, _id);\
        delete OriginalOwner[_id];\
        bullIds.remove(_id);\
        emit BullReturned(_returnee, _id);\
    \}\
\
    // return staker address of a Bull ID\
    function getBullOwner(uint16 _id) external view returns (address) \{\
        return OriginalOwner[_id];\
    \}\
\
    // thief is selected by the Arena contract - address should be a staked matador holder\
    function stealBull(address _thief, uint16 _id) external onlyBullRunGame() \{\
        IERC721(Genesis).safeTransferFrom(address(this), _thief, _id);\
        delete OriginalOwner[_id];\
    \}\
\
    // if a Runner unstakes, and is selected to be stolen, choose a random Bull staker to receive \
    function selectRandomBullOwnerToReceiveStolenRunner(uint256 seed) external onlyBullRunGame() returns (address) \{\
        uint256 bucket = (seed & 0xFFFFFFFF) % bullIds.length();\
        address thief = OriginalOwner[uint16(bullIds.at(bucket))];\
        emit RunnerThiefSelected(thief);\
        return thief;\
    \}\
\}\
}