/*
Code snippet from a contract which keeps snapshot balances of staked tokens and allows users to claim multiple different reward tokens once and only once.
This sample was coded from scratch (with the exception of the ERC-20 snapshot framework code).
*/
    
    // copied from source: https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/token/ERC20/extensions/ERC20Snapshot.sol

    using Arrays for uint256[];
    using Counters for Counters.Counter;
    Counters.Counter private _currentSnapshotId;

    struct Snapshots {
        uint256[] ids;
        uint256[] values;
    }

    mapping(address => Snapshots) private _accountBalanceSnapshots;
    Snapshots private _totalStakedSnapshots;

    // @dev Emitted by {_snapshot} when a snapshot identified by `id` is created.
    event Snapshot(uint256 id);

    // generate a snapshot, calls internal _snapshot().
    function snapshot() public onlyOwner {
        _snapshot();
    }

    function _snapshot() internal returns (uint256) {
        _currentSnapshotId.increment();

        uint256 currentId = _getCurrentSnapshotId();
        emit Snapshot(currentId);
        return currentId;
    }

    function _getCurrentSnapshotId() internal view returns (uint256) {
        return _currentSnapshotId.current();
    }

    // @dev returns shares of a holder, not balanceOf, at a certain snapshot.
    function sharesOfAt(address account, uint256 snapshotId) public view returns (uint256) {
        (bool snapshotted, uint256 value) = _valueAt(snapshotId, _accountBalanceSnapshots[account]);

        return snapshotted ? value : shares[account].amount;
    }

    // @dev returns totalStakedTokens at a certain snapshot
    function totalStakedAt(uint256 snapshotId) public view returns (uint256) {
        (bool snapshotted, uint256 value) = _valueAt(snapshotId, _totalStakedSnapshots);

        return snapshotted ? value : totalStakedTokens;
    }

    function _beforeTokenTransfer(
        address from,
        address to,
        uint256 amount
    ) internal override {
        super._beforeTokenTransfer(from, to, amount);

        if (from == address(0)) {
            // mint
            _updateAccountSnapshot(to);
            _updateTotalStakedSnapshot();
        } else if (to == address(0)) {
            // burn
            _updateAccountSnapshot(from);
            _updateTotalStakedSnapshot();
        } else if (to == address(this)) {
            // user is staking
            _updateAccountSnapshot(from);
            _updateTotalStakedSnapshot();
        } else if (from == address(this)) {
            // user is unstaking
            _updateAccountSnapshot(to);
            _updateTotalStakedSnapshot();
        }
    }

    function _valueAt(uint256 snapshotId, Snapshots storage snapshots) private view returns (bool, uint256) {
        require(snapshotId > 0, "ERC20Snapshot: id is 0");
        require(snapshotId <= _getCurrentSnapshotId(), "ERC20Snapshot: nonexistent id");

        // When a valid snapshot is queried, there are three possibilities:
        //  a) The queried value was not modified after the snapshot was taken. Therefore, a snapshot entry was never
        //  created for this id, and all stored snapshot ids are smaller than the requested one. The value that corresponds
        //  to this id is the current one.
        //  b) The queried value was modified after the snapshot was taken. Therefore, there will be an entry with the
        //  requested id, and its value is the one to return.
        //  c) More snapshots were created after the requested one, and the queried value was later modified. There will be
        //  no entry for the requested id: the value that corresponds to it is that of the smallest snapshot id that is
        //  larger than the requested one.
        //
        // In summary, we need to find an element in an array, returning the index of the smallest value that is larger if
        // it is not found, unless said value doesn't exist (e.g. when all values are smaller). Arrays.findUpperBound does
        // exactly this.

        uint256 index = snapshots.ids.findUpperBound(snapshotId);

        if (index == snapshots.ids.length) {
            return (false, 0);
        } else {
            return (true, snapshots.values[index]);
        }
    }

    function _updateAccountSnapshot(address account) private {
        _updateSnapshot(_accountBalanceSnapshots[account], shares[account].amount);
    }

    function _updateTotalStakedSnapshot() private {
        _updateSnapshot(_totalStakedSnapshots, totalStakedTokens);
    }

    function _updateSnapshot(Snapshots storage snapshots, uint256 currentValue) private {
        uint256 currentId = _getCurrentSnapshotId();
        if (_lastSnapshotId(snapshots.ids) < currentId) {
            snapshots.ids.push(currentId);
            snapshots.values.push(currentValue);
        }
    }

    function _lastSnapshotId(uint256[] storage ids) private view returns (uint256) {
        if (ids.length == 0) {
            return 0;
        } else {
            return ids[ids.length - 1];
        }
    }

    // ------------------ BEGIN PRESALE TOKEN FUNCTIONALITY -------------------

    // @dev struct containing all elements of pre-sale token. 
    struct presaleToken {
        string presaleTokenName;
        address presaleTokenAddress;
        uint256 presaleTokenBalance;
        uint256 presaleTokenRewardsPerShare; 
        uint256 presaleTokenTotalDistributed;
        uint256 presaleTokenSnapshotId;
    }

    // @dev dynamic array of struct presaleToken
    presaleToken[] public presaleTokenList;
    bool checkDuplicateEnabled; 
    mapping (address => uint256) entitledTokenReward;
    mapping (address => mapping (address => bool)) hasClaimed;

    //------------------- BEGIN PRESALE-TOKEN ARRAY MODIFIERS AND GETTERS--------------------

    // performs safety checks when depositing.
    modifier depositCheck(address _presaleTokenAddress, uint256 _amount) {
        require(IERC20(_presaleTokenAddress).balanceOf(msg.sender) >= _amount , "Deposit amount exceeds balance!"); 
        require(msg.sender != address(0) || msg.sender != 0x000000000000000000000000000000000000dEaD , "Cannot deposit from address(0)!");
        require(_amount != 0 , "Cannot deposit 0 tokens!");
        require(totalStakedTokens != 0 , "Nobody is staked!");
            _;
    }

    // @dev deletes the last struct in the presaleTokenList. 
    function popToken() internal {
        presaleTokenList.pop();
    }

    // returns number of presale Tokens stored.
    function getTokenArrayLength() public view returns (uint256) {
        return presaleTokenList.length;
    }

    // @dev enter the address of token to delete. avoids empty gaps in the middle of the array.
    function deleteToken(address _address) public onlyOwner {
        uint tokenLength = presaleTokenList.length;
        for(uint i = 0; i < tokenLength; i++) {
            if (_address == presaleTokenList[i].presaleTokenAddress) {
                if (1 < presaleTokenList.length && i < tokenLength-1) {
                    presaleTokenList[i] = presaleTokenList[tokenLength-1]; }
                    delete presaleTokenList[tokenLength-1];
                    popToken();
                    break;
            }
        }
    }

    // @dev create presale token and fund it. requires allowance approval from token. 
    function createAndFundPresaleToken(string memory _presaleTokenName, address _presaleTokenAddress, uint256 _amount) external onlyOwner depositCheck(_presaleTokenAddress, _amount) {
        // check duplicates
        if (checkDuplicateEnabled) { checkDuplicates(_presaleTokenAddress); }

        // deposit the token
        IERC20(_presaleTokenAddress).transferFrom(address(msg.sender), address(this), _amount);
        // store staked balances at time of reward token deposit
        _snapshot();
        // push new struct, with most recent snapshot ID
        presaleTokenList.push(presaleToken(
            _presaleTokenName, 
            _presaleTokenAddress, 
            _amount, 
            (rewardsPerShareAccuracyFactor.mul(_amount).div(totalStakedTokens)), 
            0,
            _getCurrentSnapshotId()));
    }

    // @dev change whether or not createAndFundToken should check for duplicate presale tokens
    function shouldCheckDuplicates(bool _bool) external onlyOwner {
        checkDuplicateEnabled = _bool;
    }

    // @dev internal helper function that checks the array for preexisting addresses
    function checkDuplicates(address _presaleTokenAddress) internal view {
        for(uint i = 0; i < presaleTokenList.length; i++) {
            if (_presaleTokenAddress == presaleTokenList[i].presaleTokenAddress) {
                revert("Token already exists!");
            }
        }
    }

    //------------------- BEGIN PRESALE-TOKEN TRANSFER FXNS AND STRUCT MODIFIERS --------------------

    // @dev update an existing token's balance based on index.
    function fundExistingToken(uint256 _index, uint256 _amount) external onlyOwner depositCheck(presaleTokenList[_index].presaleTokenAddress, _amount) {
        require(_index <= presaleTokenList.length , "Index out of bounds!");

        if ((bytes(presaleTokenList[_index].presaleTokenName)).length == 0 || presaleTokenList[_index].presaleTokenAddress == address(0)) {
            revert("Attempting to fund a token with no name, or with an address of 0.");
        }

        // do the transfer
        uint256 presaleTokenBalanceBefore = presaleTokenList[_index].presaleTokenBalance;
        uint256 presaleTokenRewardsPerShareBefore = presaleTokenList[_index].presaleTokenRewardsPerShare;
        IERC20(presaleTokenList[_index].presaleTokenAddress).transferFrom(address(msg.sender), address(this), _amount);
        _snapshot();
        // update struct balances to add amount
        presaleTokenList[_index].presaleTokenBalance = presaleTokenBalanceBefore.add(_amount);
        presaleTokenList[_index].presaleTokenRewardsPerShare = presaleTokenRewardsPerShareBefore.add((rewardsPerShareAccuracyFactor.mul(_amount).div(totalStakedTokens)));
        
    }

    // remove unsafe or compromised token from availability
    function withdrawExistingToken(uint256 _index) external onlyOwner {
        require(_index <= presaleTokenList.length , "Index out of bounds!");
        
        if ((bytes(presaleTokenList[_index].presaleTokenName)).length == 0 || presaleTokenList[_index].presaleTokenAddress == address(0)) {
            revert("Attempting to withdraw from a token with no name, or with an address of 0.");
        }

        // do the transfer
        IERC20(presaleTokenList[_index].presaleTokenAddress).transfer(address(msg.sender), presaleTokenList[_index].presaleTokenBalance);
        // update struct balances to subtract amount
        presaleTokenList[_index].presaleTokenBalance = 0;
        presaleTokenList[_index].presaleTokenRewardsPerShare = 0;
    }

    //-------------------------------- BEGIN PRESALE TOKEN REWARD FUNCTION-----------

    function claimPresaleToken(uint256 _index) external nonReentrant {
        require(_index <= presaleTokenList.length , "Index out of bounds!");
        require(!hasClaimed[msg.sender][presaleTokenList[_index].presaleTokenAddress] , "You have already claimed your reward!");
        // calculate reward based on share at time of current snapshot (which is when a token is funded or created)
        if(sharesOfAt(msg.sender, presaleTokenList[_index].presaleTokenSnapshotId) == 0){ 
            entitledTokenReward[msg.sender] = 0; } 
            else { entitledTokenReward[msg.sender] = sharesOfAt(msg.sender, presaleTokenList[_index].presaleTokenSnapshotId).mul(presaleTokenList[_index].presaleTokenRewardsPerShare).div(rewardsPerShareAccuracyFactor); }
        
        require(presaleTokenList[_index].presaleTokenBalance >= entitledTokenReward[msg.sender]);
        // struct balances before transfer
        uint256 presaleTokenBalanceBefore = presaleTokenList[_index].presaleTokenBalance;
        uint256 presaleTokenTotalDistributedBefore = presaleTokenList[_index].presaleTokenTotalDistributed;
        // transfer
        IERC20(presaleTokenList[_index].presaleTokenAddress).transfer(address(msg.sender), entitledTokenReward[msg.sender]);
        hasClaimed[msg.sender][presaleTokenList[_index].presaleTokenAddress] = true;
        // update struct balances 
        presaleTokenList[_index].presaleTokenBalance = presaleTokenBalanceBefore.sub(entitledTokenReward[msg.sender]);
        presaleTokenList[_index].presaleTokenTotalDistributed = presaleTokenTotalDistributedBefore.add(entitledTokenReward[msg.sender]);       
    }

    // allows user to see their entitled presaleToken reward based on staked balance at time of token creation
    function getUnpaidEarningsPresale(uint256 _index, address staker) external view returns (uint256) {
        uint256 entitled;
        if (hasClaimed[staker][presaleTokenList[_index].presaleTokenAddress]) {
            entitled = 0;
        } else {
            entitled = sharesOfAt(staker, presaleTokenList[_index].presaleTokenSnapshotId).mul(presaleTokenList[_index].presaleTokenRewardsPerShare).div(rewardsPerShareAccuracyFactor);
        }
        return entitled;
    }
}
