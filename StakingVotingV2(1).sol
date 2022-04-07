//  SPDX-License-Identifier: MIT
import "./lib/SafeMath.sol";
import "hardhat/console.sol";
pragma solidity >=0.6.0 <0.8.0;

contract Staking {
    using SafeMath for uint256;

       enum Status {
        // validator not exist, default status
        NotExist,
        // validator created
        Created,
        // anyone has staked for the validator
        Staked,
        // validator's staked coins < MinimalStakingCoin
        Unstaked,
        // validator is jailed by system(validator have to repropose)
        Jailed
    }

    // Validator Struct
    struct Validator {
        address validator;
        Status status;
        uint256 amount; // self amount
        uint256 coins; //  self + delegators
        address[] delegators;
    }

    //Delegator Struct
    struct Delegator {
        address delegatorAddress; //  delegator self address
        uint256 amount; // self stake
        uint256 unstakeblock; // unstakeblock = 0 means can stake if !=0 already unstake
        uint256 index; // index no represent in stakers array in Validator Struct
    }

    // Validator Address  = > Get Validator Information
    mapping(address => Validator) validatorInfo;
    // Delegator Address => Validator Address =>Staking Info
    mapping(address => mapping(address => Delegator)) stakingInfo;

    address[] public currentValidators; // All Validators
    address[] public highestValidators; // Only Top 21

    uint256 public totalDXTStake; //  To DXT Stake Amount

    /**********Constant**********/
    uint256 public minimumStakeAmount = 10 ether; // Minimum Stake DXT
    uint256 public MaxValidators = 3; // Total Max Validator
    uint64 public constant StakingLockPeriod = 10 seconds; // Stake Locking Period
    uint64 public constant WithdrawProfitPeriod = 2 minutes; // Withdraw Profit Period

    /**********Punish Params**********/

    uint256 public removeThreshold = 48;
    uint256 public punishThreshold = 24;

    struct PunishRecord {
        uint256 missedBlockCounter;
        uint256 index;
        bool isPunished;
    }

    mapping(address => PunishRecord) punishRecord;
    //Mapping for Block Number Tracking
    mapping(uint256 => bool) punished;
    mapping(uint256 => bool) decreased;

    enum Operations {
        Distribute,
        UpdateValidators
    }
    // Record the operations is done or not.
    mapping(uint256 => mapping(uint8 => bool)) operationsDone;

    /**********Events**********/
    event StakeValidator(
        address indexed validator,
        uint256 amount,
        uint256 time
    );
    event StakeDelegator(
        address indexed delegator,
        address indexed validator,
        uint256 amount,
        uint256 time
    );
    event RemoveFromHighestValidators(
        address indexed validator,
        uint256 time
    );
    event RemoveFromCurrentValidatorsList(
        address indexed validator,
        uint256 time
    );
    event UnstakeValidator(
        address indexed validator,
        uint256 indexed amount,
        uint256 time
    );
    event UnstakeDelegator(
        address indexed validator,
        address indexed delegator,
        uint256 amount,
        uint256 time
    );
    event WithdrawValidatorStaking(
        address indexed validator,
        uint256 indexed amount,
        uint256 time
    );
    event WithdrawDelegatorStaking(
        address indexed delegator,
        address indexed validator,
        uint256 indexed amount,
        uint256 time
    );

    function stakeValidator() external payable returns (bool) {
        address staker = msg.sender;
        uint256 stakeamount = msg.value;

        //Struct Validator Variable
        Validator storage valInfo = validatorInfo[staker];
        if (stakeamount < 0) {
            return false;
        }
        // Check for Minimum Stake DXT
        require(stakeamount >= minimumStakeAmount, "Must Stake minimumStakeAmount or More");
        // Check for the Validator Jail
        require( valInfo.status!= Status.Jailed, "Validator Jailed");
        if (valInfo.amount == 0 && Status.NotExist == valInfo.status) {
            valInfo.validator = staker;
            valInfo.status = Status.Created;
            valInfo.amount = valInfo.amount.add(stakeamount);
            valInfo.coins = valInfo.coins.add(stakeamount);
        } else if (valInfo.amount > 0 && Status.Staked == valInfo.status
        ) {
            valInfo.amount = valInfo.amount.add(stakeamount);
            valInfo.coins = valInfo.coins.add(stakeamount);
        }

        if (highestValidators.length < MaxValidators && !isTopValidator(staker)){
            highestValidators.push(staker); // push into highestValidator if there is space
        } else if (highestValidators.length >= MaxValidators && !isTopValidator(staker)) {
            
            // Find The Lowest Coins Address & Index in HighestValidators List
            uint256 lowCoin;
            uint256 lowIdx;
            address lowAddress;
            
            (lowCoin,lowIdx,lowAddress) = lowestCoinsInHighestValidator();

        
            if (valInfo.coins > lowCoin) {
                highestValidators[lowIdx] = staker;
            }
        }

        // Change the Status to Staked
        if (valInfo.status != Status.Staked) {
            valInfo.status = Status.Staked;
        }
        if (!isActiveValidator(staker)) {
            currentValidators.push(staker);
        }

        totalDXTStake = totalDXTStake.add(stakeamount);
        emit StakeValidator(staker, stakeamount, block.timestamp);
        return true;
    }

    function stakeDelegator(address validator) external payable returns (bool) {
        address staker = msg.sender; //Delegator Address
        uint256 stakeamount = msg.value; // Stake Amount

        if (stakeamount < 0) {
            return false;
        }
        // Struct Validator
        Validator storage valInfo = validatorInfo[validator];
        // Struct Delegator
        Delegator storage stakeInfo = stakingInfo[staker][validator];
        require(Status.Jailed != valInfo.status, "Validator Jailed");
        require(isActiveValidator(validator),"Validator Not Exist");
       
         if (valInfo.status == Status.Staked) {
            // Update Validator Coins
            valInfo.coins = valInfo.coins.add(stakeamount); // update in Validator Amount (Self)
            stakeInfo.amount = stakeInfo.amount.add(stakeamount); // update in Validator Coins(Total)

            stakeInfo.delegatorAddress = staker; // update in Delegator Staking Struct 
            stakeInfo.index = valInfo.delegators.length; // update the index of delegator struct for  delegators array in validator
            if(valInfo.delegators.length == 0){
                valInfo.delegators.push(staker);
            } else if(!isDelegatorsExist(staker,valInfo.delegators)){
                valInfo.delegators.push(staker);
             }
            
        }

        if (highestValidators.length < MaxValidators && !isTopValidator(validator)){
            highestValidators.push(validator); // push into highestValidator if there is space
        } else if (highestValidators.length >= MaxValidators && !isTopValidator(validator)) {

            // Find The Lowest Coins Address & Index in HighestValidators List
            uint256 lowCoin;
            uint256 lowIdx;
            address lowAddress;
            
            (lowCoin,lowIdx,lowAddress) = lowestCoinsInHighestValidator();

            if (
                valInfo.coins > lowCoin
            ) {
                if (!isTopValidator(validator)) {
                    highestValidators[lowIdx] = validator;
                }
            }
        }

        // Change the Status to Staked
        if (valInfo.status != Status.Staked) {
            valInfo.status = Status.Staked;
        }
        totalDXTStake = totalDXTStake.add(stakeamount);
        emit StakeDelegator(staker, validator, stakeamount, block.timestamp);
        return true;
    }

    function unstakeValidator() external returns (bool) {
        address staker = msg.sender; //get the validator address
        //Struct Validator
        Validator storage valInfo = validatorInfo[staker];
        Delegator storage stakeInfo = stakingInfo[staker][staker];

        uint256 unstakeamount = valInfo.amount; // self amount validator

        // Check for the unstakeBlock status
        require(stakingInfo[staker][staker].unstakeblock == 0,"Already in Unstaking Status");
        require(unstakeamount > 0, "Don't have any stake");
        require(highestValidators.length != 1 && isActiveValidator(staker),
            "You can't unstake, validator list will be empty after this operation!"
        );

        // Set Block No When Validator Unstake
        stakeInfo.unstakeblock = block.number;
        // Change the Status of the Validator
        valInfo.status = Status.Unstaked;
        emit UnstakeValidator(staker, unstakeamount, block.timestamp);
        return true;
    }

    function unstakeDelegators(address validator) external returns (bool) {
        address delegator = msg.sender; //get Delegator Address
        // Struct Delegator
        Delegator storage stakeInfo = stakingInfo[delegator][validator];
        Validator storage valInfo = validatorInfo[validator]; // Struct Validator

        require(stakeInfo.unstakeblock == 0, "Already in unstaking status");
        require(Status.Jailed != valInfo.status, "Validator Jailed");
        uint256 unstakeamount = stakeInfo.amount; // get the staking info
        require(unstakeamount > 0, "don't have any stake");
        require(
            highestValidators.length != 1,
            "You can't unstake, validator list will be empty after this operation!"
        );

        // Update The Unstake Block for Validator
        stakeInfo.unstakeblock = block.number; //update the ustakeblock status
        // valInfo.coins = valInfo.coins.sub(unstakeamount); // sub from validator coins
        // totalDXTStake = totalDXTStake.sub(unstakeamount); // sub from total

        // Find Lowest Coins in Highest Validator List
        
        emit UnstakeDelegator(
            validator,
            delegator,
            unstakeamount,
            block.timestamp
        );

        return true;
    }

    function isDelegatorsExist(address who,address[] memory delegators) private pure returns(bool){
        for(uint k=0;k<delegators.length;k++){
            if(who == delegators[k]){
                return true;
            }
        }

        return false;
    }

    function withdrawValidatorStaking() external returns (bool) {
        address payable staker = msg.sender; // validator address

        Validator storage valInfo = validatorInfo[staker];

        uint256 unstakeamount = valInfo.amount; // get the stake self amount

        Delegator storage stakeInfo = stakingInfo[staker][staker];
        require(stakeInfo.unstakeblock != 0, "you have to unstake first");
        require(stakeInfo.unstakeblock + StakingLockPeriod <= block.number,"Staking haven't unlocked yet");

        uint256 staking = valInfo.amount;
        valInfo.amount = 0;
        valInfo.coins = valInfo.coins.sub(unstakeamount);
        totalDXTStake = totalDXTStake.sub(unstakeamount);

        // Get the staking amount
        stakeInfo.unstakeblock = 0;
        

        console.log("Line 351 Validator Balance %s",valInfo.coins);

        // Get Highest Validator From Current List 
        uint256 highCoin;
        uint256 highIdx;
        address addValAddress;

        (highCoin,highIdx,addValAddress)= highestCoinsInCurrentValidatorsNotInTopValidator();

        console.log("validator to be add", addValAddress);
        
        if(valInfo.coins <= 0){
            console.log("Now Removing from Current Validators List......");
            removeFromHighestValidatorList(staker);
            removeFromCurrentValidatorList(staker);
        }

        if(highestValidators.length < MaxValidators && addValAddress!=address(0)){
            highestValidators.push(addValAddress);
        }
        valInfo.status = Status.NotExist;
        staker.transfer(staking);
        emit WithdrawValidatorStaking(staker, staking, block.timestamp);
        return true;
    }

    function withdrawDelegatorStaking(address validator)
        external
        returns (bool)
    {
        address payable staker = msg.sender; //Delegator Address

        Delegator storage stakeInfo = stakingInfo[staker][validator]; // Delegator Staking Info
        Validator storage valInfo = validatorInfo[validator]; // Validator 
        require(stakeInfo.unstakeblock != 0, "you have to unstake first");
        require(
            stakeInfo.unstakeblock + StakingLockPeriod <= block.number,
            "Staking haven't unlocked yet"
        );

        //Get The Staking Coins of Delegators
        uint256 staking = stakeInfo.amount;
        // Update The Coins in Validator Record
        valInfo.coins = valInfo.coins.sub(staking);

        // Update The Validator Info
        if (stakeInfo.index != valInfo.delegators.length - 1) {
            valInfo.delegators[stakeInfo.index] = valInfo.delegators[
                valInfo.delegators.length - 1
            ];
            //update index of staker
            stakingInfo[valInfo.delegators[stakeInfo.index]][validator]
                .index = stakeInfo.index;
        }

        valInfo.delegators.pop();


        if(valInfo.coins == 0){
            removeFromCurrentValidatorList(validator);
            removeFromHighestValidatorList(validator);
        }

        // Find Lowest in Highest Validator
        uint256 lowestCoin;
        uint256 lowIdx;
        address lowValidator;
        (lowestCoin,lowIdx,lowValidator) = lowestCoinsInHighestValidator();

        // Find Highest Coins in Current Validator List
        uint256 highCoins;
        uint256 highIndex;
        address highValidator;
        (highCoins,highIndex,highValidator) = highestCoinsInCurrentValidatorsNotInTopValidator();


        if(highCoins > lowestCoin){
            highestValidators[lowIdx] = highValidator;
        }
        staker.transfer(staking);

        emit WithdrawDelegatorStaking(
            staker,
            validator,
            staking,
            block.timestamp
        );
    }

    /**********Internal Functions**********/

    function isActiveValidator(address who) private view returns (bool) {
        for (uint256 k = 0; k < currentValidators.length; k++) {
            if (who == currentValidators[k]) {
                return true;
            }
        }
        return false;
    }

    function isTopValidator(address who) private view returns (bool) {
        for (uint256 i = 0; i < highestValidators.length; i++) {
            if (who == highestValidators[i]) {
                return true;
            }
        }
        return false;
    }

    function getValidatorInfo(address val)
        public
        view
        returns (
            address,
            Status,
            uint256,
            uint256,
            address[] memory
        )
    {
        Validator memory v = validatorInfo[val];

        return (v.validator, v.status, v.amount, v.coins, v.delegators);
    }

    function removeFromHighestValidatorList(address val) private {
        uint256 n = highestValidators.length;
        for (uint256 k = 0; k < n && n > 1; k++) {
            if (val == highestValidators[k]) {
                if (k != n - 1) {
                    highestValidators[k] = highestValidators[n - 1];
                }
                highestValidators.pop();
                emit RemoveFromHighestValidators(val, block.timestamp);
                break;
            }
        }
    }

    function removeFromCurrentValidatorList(address val) private {
        uint256 n = currentValidators.length;
        for (uint256 i = 0; i < n && n > 1; i++) {
            if (val == currentValidators[i]) {
                if (i != n - 1) {
                    currentValidators[i] = currentValidators[n - 1];
                }
                currentValidators.pop();
                emit RemoveFromCurrentValidatorsList(val, block.timestamp);
                break;
            }
        }
    }

    function getStakingInfo(address staker, address val)
        public
        view
        returns (
            uint256,
            uint256,
            uint256
        )
    {
        return (
            stakingInfo[staker][val].amount,
            stakingInfo[staker][val].unstakeblock,
            stakingInfo[staker][val].index
        );
    }

    function lowestCoinsInHighestValidator() private view returns(uint256,uint256,address){

        uint256 lowestCoin = validatorInfo[highestValidators[0]].coins; //first validator coins
        uint256 lowIndex;
        address lowValidator;

            for (uint256 j = 1; j < highestValidators.length; j++) {
                if (validatorInfo[highestValidators[j]].coins < lowestCoin) {
                    lowIndex = j;
                    lowestCoin = validatorInfo[highestValidators[j]].coins;
                    lowValidator = highestValidators[j];
                   
                }
            }

            return(lowestCoin,lowIndex,lowValidator);
    }

    function highestCoinsInCurrentValidatorsNotInTopValidator() private view returns(uint256,uint256,address){

        uint256 highCoins;
        uint256 highIndex;
        address highestValidatorAddress;
        for (uint256 k = 0; k < currentValidators.length; k++) {
            if (validatorInfo[currentValidators[k]].coins > highCoins && !isTopValidator(currentValidators[k])) {
                highCoins = validatorInfo[currentValidators[k]].coins;
                highIndex = k;
                highestValidatorAddress = currentValidators[k];
            }
        }
        return(highCoins,highIndex,highestValidatorAddress);
    }

    /*******Getter*******/
    function getCurrentValidators() public view returns (address[] memory) {
        return currentValidators;
    }

    function getBlockNumber() public view returns(uint256) {
        return block.number;
    }

    function getHighestValidators() public view returns (address[] memory) {
        return highestValidators;
    }

    function getContractBalance() public view returns (uint256) {
        return address(this).balance;
    }


    uint256 public proposalLastingPeriod;

    // record
    mapping(address => bool) public pass;

    struct ProposalInfo {
        // who propose this proposal
        address payable proposer;
        // propose who to be a validator
        address dst;
        // optional detail info of proposal
        string details;
        // time create proposal
        uint256 createTime;
        // propose string
        string variable_name;
        // propose value
        uint256 variable_value;
        //
        // vote info
        //
        // number agree this proposal
        uint16 agree;
        // number reject this proposal
        uint16 reject;
        // means you can get proposal of current vote.
        bool resultExist;
    }

    struct VoteInfo {
        address voter;
        uint256 voteTime;
        bool auth;
    }

    mapping(bytes32 => ProposalInfo) public proposals;
    mapping(address => mapping(bytes32 => VoteInfo)) public votes;
   // address[] public highestValidators; // Only Top 21
    bytes32[] public ProposalsArray;

    event LogCreateProposal(
        bytes32 indexed id,
        address indexed proposer,
        address indexed dst,
        uint256 time
    );
    event LogVote(
        bytes32 indexed id,
        address indexed voter,
        bool auth,
        uint256 time
    );
    event LogPassProposal(
        bytes32 indexed id,
        address indexed dst,
        uint256 time
    );
    event LogRejectProposal(
        bytes32 indexed id,
        address indexed dst,
        uint256 time
    );
    event LogSetUnpassed(address indexed val, uint256 time);

    modifier onlyValidator() {
         require(isTopValidator(msg.sender), "Validator only");
        _;
    }
    
    function chcekProposal() public view returns (bytes32[] memory) {
        return ProposalsArray;
    }

    function authchangevalues(bytes32 id) public {
        require(pass[msg.sender], "You must be authorized first");
        if(keccak256(bytes(proposals[id].variable_name)) == keccak256(bytes("minimumStakeAmount"))){
          require(proposals[id].variable_value >= 1, "minimumStakeAmount can't be less then 1");
          minimumStakeAmount = proposals[id].variable_value * 1 ether;
        }
        if(keccak256(bytes(proposals[id].variable_name)) == keccak256(bytes("MaxValidators"))){
          require(proposals[id].variable_value >= 2, "MaxValidators can't be less then 2");
          MaxValidators = proposals[id].variable_value;
        }
        pass[msg.sender] = false;
    }
    
    function createProposal(address dst, string calldata details, string calldata vari_name, uint256 value)
        external payable onlyValidator
        returns (bool)
    {
        require(msg.value == 1 ether, "insufficient balance");
        require(!pass[dst], "Dst already passed, You can start staking");
       
        if(keccak256(bytes(vari_name)) == keccak256(bytes("minimumStakeAmount"))){
          require(value >= 1, "minimumStakeAmount can't be less then 1");
        }
        if(keccak256(bytes(vari_name)) == keccak256(bytes("MaxValidators"))){
          require(value >= 2, "MaxValidators can't be less then 2");
        }

        proposalLastingPeriod = 7 days;
        // generate proposal id
        bytes32 id = keccak256(
            abi.encodePacked(msg.sender, dst, details, block.timestamp)
        );
        bytes32 pID = id;
        require(bytes(details).length <= 3000, "Details too long");
        require(proposals[id].createTime == 0, "Proposal already exists");

        ProposalInfo memory proposal;
        proposal.proposer = msg.sender;
        proposal.dst = dst;
        proposal.details = details;
        proposal.createTime = block.timestamp;
        proposal.variable_name = vari_name;
        proposal.variable_value = value;


        proposals[id] = proposal;
        ProposalsArray.push(pID);
        emit LogCreateProposal(id, msg.sender, dst, block.timestamp);
        return true;
    }

    function currentValue (string memory vari_name) public view returns (uint) 
    {
        if(keccak256(bytes(vari_name)) == keccak256(bytes("minimumStakeAmount"))){
            return(minimumStakeAmount);
        }  
    }

    function voteProposal(bytes32 id, string calldata vote)
        external
        onlyValidator
        returns (bool)
    {
        bool auth;
        if(keccak256(bytes(vote)) == keccak256(bytes("true"))){
            auth = true;
        }
        else if((keccak256(bytes(vote)) == keccak256(bytes("false")))){
            auth = false;
        }
        else{
            require((keccak256(bytes(vote)) == keccak256(bytes("true")))||(keccak256(bytes(vote)) == keccak256(bytes("false"))), "only takes true or false");
        }
        require(proposals[id].createTime != 0, "Proposal not exist");
        require(
            votes[msg.sender][id].voteTime == 0,
            "You can't vote for a proposal twice"
        );
        require(
            block.timestamp < proposals[id].createTime + proposalLastingPeriod,
            "Proposal expired"
        );

        votes[msg.sender][id].voteTime = block.timestamp;
        votes[msg.sender][id].voter = msg.sender;
        votes[msg.sender][id].auth = auth;
        emit LogVote(id, msg.sender, auth, block.timestamp);

        // update dst status if proposal is passed
        if (auth) {
            proposals[id].agree = proposals[id].agree + 1;
        } else {
            proposals[id].reject = proposals[id].reject + 1;
        }

        if (pass[proposals[id].dst] || proposals[id].resultExist) {
            // do nothing if dst already passed or rejected.
            return true;
        }

        if (
            proposals[id].agree >=
            getHighestValidators().length / 2 + 1
        ) {
            pass[proposals[id].dst] = true;
            proposals[id].resultExist = true;
            proposals[id].proposer.transfer(1 ether);
            // try to reactive validator if it isn't the first time
            // validators.tryReactive(proposals[id].dst);
            emit LogPassProposal(id, proposals[id].dst, block.timestamp);

            return true;
        }

        if (
            proposals[id].reject >=
            getHighestValidators().length / 2 + 1
        ) {
            proposals[id].resultExist = true;
            emit LogRejectProposal(id, proposals[id].dst, block.timestamp);
        }

        return true;
    }

}


